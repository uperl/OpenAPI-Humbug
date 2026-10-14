package OpenAPI::Humbug::Transport;

use 5.042;
use warnings;
use Errno ();
use IO::Select;
use Time::HiRes ();
use OpenAPI::Humbug::Error;
use namespace::autoclean -also => [qw( CHUNK FAILURE_GRACE CLOSE_GRACE )];

# ABSTRACT: Internal base class for OpenAPI::Humbug transports
# VERSION

=head1 SYNOPSIS

 # internal; see OpenAPI::Humbug

=head1 DESCRIPTION

B<This class is internal to L<OpenAPI::Humbug> and may change without notice.>

A transport carries the sidecar's line protocol: it writes one command line and reads one reply
line at a time, and knows nothing about JSON.  This base class implements that exchange over a
pair of non-blocking handles (the same handle twice for a socket), with a timeout, a bound on the
reply length, and detection of output nobody asked for.  A subclass connects, provides the
handles, and tears the connection down.

Failures are thrown as L<OpenAPI::Humbug::Error> with C<kind> C<transport>, C<protocol> or
C<timeout>, and leave the transport closed.

=head1 SUBCLASS INTERFACE

A subclass connects in C<BUILD> and implements:

=over 4

=item C<_read_fh>, C<_write_fh>

The handles replies are read from and commands written to, in non-blocking binary mode.

=item C<_drain_fhs>

Other handles to read while waiting (for example a child's stderr); each chunk read is passed to
C<_drained($fh, $data)>.  Optional.

=item C<_eof_detail>

Text appended to the message when the peer closes without replying.  Optional.

=item C<_teardown($grace)>

Release the connection, waiting up to C<$grace> seconds for an orderly end.  Returns true if it
ended cleanly.

=back

=head1 ATTRIBUTES

=head2 max_reply_bytes

The longest reply line accepted, in bytes.

=head1 METHODS

=head2 exchange

 my $reply_line = $transport->exchange($command_line, $timeout);

Write one newline-terminated line and return the one reply line, with its newline.

=head2 close

 my $clean = $transport->close($grace);

End the connection in an orderly way, waiting up to C<$grace> seconds.  Returns true if it ended
cleanly.  Repeated calls return the same answer.

=head2 abort

 $transport->abort;

End the connection at once after a failure.

=head2 is_open

True until the transport is closed or aborted.

=head2 ends_with_shutdown

True if the client should send C<shutdown> before L</close>, because the sidecar's life ends with
this connection.

=head2 stderr

Diagnostic output captured from the sidecar, or C<undef> if the transport has none.

=cut

use constant {
  CHUNK         => 65536,
  FAILURE_GRACE => 0.2,
  CLOSE_GRACE   => 1,
};

use Class::Tiny {
  max_reply_bytes => 64 * 1024 * 1024,
};

sub BUILD ($self, $args) {
  $self->{owner_pid}   = $$;
  $self->{read_buffer} = '';
  return;
}

sub DEMOLISH ($self, $global_destruction) {
  local($@, $!, $?);
  # a forked copy must leave the parent's connection alone
  return if $self->{owner_pid} != $$;
  eval { $self->close(CLOSE_GRACE) };
  return;
}

sub is_open            ($self) { !$self->{closed} }
sub ends_with_shutdown ($self) { 0 }
sub stderr             ($self) { undef }
sub _drain_fhs         ($self) { () }
sub _drained           ($self, $fh, $data) { return }
sub _eof_detail        ($self) { '' }

sub close ($self, $grace) {
  return $self->{clean} if $self->{closed};
  $self->{closed} = 1;
  $self->{clean} = $self->_teardown($grace) ? 1 : 0;
  return $self->{clean};
}

sub abort ($self) {
  return $self->close(FAILURE_GRACE);
}

# a failure that ends the connection
sub _fail ($self, $kind, $code, $message) {
  my $error = OpenAPI::Humbug::Error->new(
    kind    => $kind,
    code    => $code,
    message => $message,
    stderr  => $self->stderr,
  );
  $self->abort;
  return $error;
}

sub exchange ($self, $out, $timeout) {
  OpenAPI::Humbug::Error->throw(kind => 'closed', code => 'client.closed', message => 'the transport is closed')
    if $self->{closed};
  OpenAPI::Humbug::Error->throw(kind => 'closed', code => 'client.closed', message => 'the transport was created in another process')
    if $self->{owner_pid} != $$;

  my $in   = $self->_read_fh;
  my $send = $self->_write_fh;

  # anything already waiting was not asked for, and would be mistaken for our reply
  if(IO::Select->new($in)->can_read(0)) {
    sysread $in, $self->{read_buffer}, CHUNK, length $self->{read_buffer};
  }
  die $self->_fail(protocol => 'client.unsolicited_output', 'sidecar wrote output before the command was sent')
    if length $self->{read_buffer};

  local $SIG{PIPE} = 'IGNORE';

  my $deadline  = Time::HiRes::time() + $timeout;
  my $written   = 0;
  my $broken    = 0;
  my $eof       = 0;
  my $scan_from = 0;
  my $reply;

  my $readers = IO::Select->new($in, $self->_drain_fhs);
  my $writers = IO::Select->new($send);

  while(1) {
    last if defined $reply && ($written == length $out || $broken);

    if($eof && !defined $reply) {
      die $self->_fail(transport => ($broken ? 'client.broken_pipe' : 'client.eof'),
        'sidecar closed its output without replying' . $self->_eof_detail);
    }

    my $remaining = $deadline - Time::HiRes::time();
    die $self->_fail(timeout => 'client.timeout', "no reply within $timeout seconds")
      if $remaining <= 0;

    my $want_write = !$broken && $written < length $out;
    my($can_read, $can_write) = IO::Select->select(
      $readers->count ? $readers : undef,
      $want_write     ? $writers : undef,
      undef,
      $remaining,
    );

    if($want_write && @{ $can_write // [] }) {
      my $n = syswrite $send, $out, CHUNK, $written;
      if(defined $n) {
        $written += $n;
      } elsif($! == Errno::EPIPE) {
        $broken = 1;
      } elsif($! != Errno::EAGAIN && $! != Errno::EINTR) {
        die $self->_fail(transport => 'client.broken_pipe', "write to sidecar failed: $!");
      }
    }

    for my $fh (@{ $can_read // [] }) {
      if($fh != $in) {
        my $n = sysread $fh, my $data, CHUNK;
        if(defined $n && $n == 0) {
          $readers->remove($fh);
        } elsif($n) {
          $self->_drained($fh, $data);
        }
        next;
      }

      my $n = sysread $in, $self->{read_buffer}, CHUNK, length $self->{read_buffer};
      if(defined $n && $n == 0) {
        $readers->remove($in);
        $eof = 1;
        next;
      }
      next unless $n;
      next if defined $reply;

      my $newline = index $self->{read_buffer}, "\n", $scan_from;
      my $too_long = $newline < 0
        ? length($self->{read_buffer}) > $self->max_reply_bytes
        : $newline > $self->max_reply_bytes;
      die $self->_fail(protocol => 'client.reply_too_long', "reply exceeds @{[ $self->max_reply_bytes ]} bytes")
        if $too_long;
      if($newline < 0) {
        $scan_from = length $self->{read_buffer};
        next;
      }
      $reply = substr $self->{read_buffer}, 0, $newline + 1, '';
    }
  }

  die $self->_fail(protocol => 'client.unsolicited_output', 'sidecar wrote more than one reply line')
    if length $self->{read_buffer};

  # the peer stopped reading part way through our line, so the stream cannot continue
  die $self->_fail(transport => 'client.broken_pipe', 'sidecar stopped reading its input')
    if $broken;

  return $reply;
}
