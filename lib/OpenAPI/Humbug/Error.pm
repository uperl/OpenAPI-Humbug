package OpenAPI::Humbug::Error;

use 5.042;
use warnings;
use overload
  '""'     => sub ($self, @) { $self->as_string },
  bool     => sub { 1 },
  fallback => 1;

# ABSTRACT: Exception thrown by OpenAPI::Humbug
# VERSION

=head1 SYNOPSIS

 use OpenAPI::Humbug;

 my $result = eval { $humbug->validate(request => $request) };
 if(my $error = $@) {
   die $error unless ref $error && $error->isa('OpenAPI::Humbug::Error');
   if($error->kind eq 'sidecar') {
     # the sidecar refused the command; the client is still usable
     warn "humbug said @{[ $error->code ]}: @{[ $error->message ]}";
   } else {
     # argument, process, protocol, timeout or closed
     ...
   }
 }

=head1 DESCRIPTION

Every exception thrown by L<OpenAPI::Humbug> is an instance of this class.  Use L</kind> and
L</code> to decide what happened; never parse L</message>.

An exception is never a validation verdict.  A transaction that violates the specification is
reported as an ordinary result with C<valid> false, not as an exception.

=head1 KINDS

=over 4

=item argument

The caller passed bad input.  Nothing was sent to the sidecar, and the client is still usable.
L</code> is C<client.argument>.

=item sidecar

The sidecar replied with C<type: error>: the command could not run, so there is no verdict.
L</code> and L</message> are the sidecar's C<error.code> and C<error.message> (for example
C<validator.unsupported_input> or C<spec.invalid>), and L</error> is the whole C<error> object.
After a sidecar error from C<validate>, the client is still usable.

=item process

The child could not be started (C<client.spawn_failed>), closed its stdout without replying
(C<client.eof>), or stopped reading its stdin (C<client.broken_pipe>).

=item protocol

The reply could not be trusted: it was not a JSON object (C<client.malformed_reply>), was longer
than C<max_reply_bytes> (C<client.reply_too_long>), had the wrong C<id> (C<client.id_mismatch>),
had an unexpected C<type> or shape (C<client.unexpected_reply>), or the sidecar wrote output
nobody asked for (C<client.unsolicited_output>).

=item timeout

The sidecar did not reply within C<timeout> seconds (C<client.timeout>).  The command is not
retried.

=item closed

The client was closed, or an earlier process, protocol or timeout failure made it unusable
(C<client.closed>).

=back

After a C<process>, C<protocol> or C<timeout> failure the child is terminated and reaped and the
client is unusable; construct a new one to continue.

=head1 ATTRIBUTES

=head2 kind

One of C<argument>, C<sidecar>, C<process>, C<protocol>, C<timeout> or C<closed>.

=head2 code

A machine-readable code.  For C<sidecar> errors it is the sidecar's code; otherwise it is one of
the C<client.*> codes listed above.

=head2 message

A human-readable message.  It never contains HTTP payloads or header values.

=head2 error

For C<sidecar> errors, the complete C<error> object from the reply (unknown fields included);
otherwise C<undef>.

=head2 stderr

For C<process>, C<protocol> and C<timeout> errors, the tail of what the sidecar wrote to stderr
(possibly empty); otherwise C<undef>.

=head2 file

=head2 line

Where the exception was thrown from, in the caller's code.

=cut

=head1 CONSTRUCTOR

=head2 new

 my $error = OpenAPI::Humbug::Error->new(kind => $kind, code => $code, message => $message, %more);

Create an exception without throwing it.  Accepts the L</ATTRIBUTES> other than C<file> and
C<line>, which are filled in from the caller.

=cut

sub new ($class, %args) {
  my $self = bless {
    kind    => $args{kind},
    code    => $args{code},
    message => $args{message},
    error   => $args{error},
    stderr  => $args{stderr},
  }, $class;

  # report the location in the caller's code, not inside this distribution
  my $level = 0;
  while(my @frame = caller($level++)) {
    next if $frame[0] =~ /^OpenAPI::Humbug(::|$)/;
    @$self{qw( file line )} = @frame[1,2];
    last;
  }

  return $self;
}

sub throw ($class, %args) {
  die $class->new(%args);
}

sub kind    ($self) { $self->{kind}    }
sub code    ($self) { $self->{code}    }
sub message ($self) { $self->{message} }
sub error   ($self) { $self->{error}   }
sub stderr  ($self) { $self->{stderr}  }
sub file    ($self) { $self->{file}    }
sub line    ($self) { $self->{line}    }

=head1 METHODS

=head2 throw

 OpenAPI::Humbug::Error->throw(kind => $kind, code => $code, message => $message);

Create and throw an exception.

=head2 as_string

 my $string = $error->as_string;

The code, message and location.  This is also what you get when the exception is stringified.

=cut

sub as_string ($self) {
  my $string = "humbug $self->{kind} error ($self->{code}): $self->{message}";
  $string .= " at $self->{file} line $self->{line}." if defined $self->{file};
  return "$string\n";
}
