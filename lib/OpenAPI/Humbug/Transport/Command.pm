package OpenAPI::Humbug::Transport::Command;

use 5.042;
use warnings;
use parent 'OpenAPI::Humbug::Transport';
use Fcntl qw( F_DUPFD F_GETFD F_SETFD FD_CLOEXEC );
use File::Which qw( which );
use POSIX ();
use Time::HiRes ();
use OpenAPI::Humbug::Error;
use namespace::autoclean -also => [qw( KILL_GRACE )];

# ABSTRACT: Internal transport that runs humbug as a child process
# VERSION

=head1 SYNOPSIS

 # internal; see OpenAPI::Humbug

=head1 DESCRIPTION

B<This class is internal to L<OpenAPI::Humbug> and may change without notice.>

Runs the C<humbug> executable as a child process and speaks to it over its stdin and stdout.  The
executable is run directly with C<fork> and C<exec>, never through a shell.  stderr is a separate
pipe, always drained so a noisy child cannot block, and the most recent C<max_stderr_bytes> of it
are kept.

The sidecar's life ends with the connection, so the client sends C<shutdown> before L</close>.
Closing closes the pipes and reaps the child, escalating to C<SIGTERM> and then C<SIGKILL> if it
does not exit in time.

=head1 ATTRIBUTES

=head2 executable

The executable.  If it contains a slash it is used as is, otherwise it is looked up in C<PATH>;
after construction this is the path that was run.

=head2 args

An array reference of extra command-line arguments.

=head2 max_stderr_bytes

How much of stderr to keep.

=head2 pid

The child's process id while it runs.

=head1 METHODS

See L<OpenAPI::Humbug::Transport>.

=cut

use constant KILL_GRACE => 2;

use Class::Tiny {
  executable       => 'humbug',
  args             => sub { [] },
  max_stderr_bytes => 64 * 1024,
};

sub BUILD ($self, $args) {
  $self->{stderr_buffer} = '';
  $self->executable(_find_executable($self->executable));
  $self->_spawn;
  return;
}

sub pid                ($self) { $self->{pid} }
sub ends_with_shutdown ($self) { 1 }
sub stderr             ($self) { $self->{stderr_buffer} }
sub _read_fh           ($self) { $self->{stdout} }
sub _write_fh          ($self) { $self->{stdin} }
sub _drain_fhs         ($self) { grep { defined } $self->{stderr} }

sub _drained ($self, $fh, $data) {
  $self->{stderr_buffer} .= $data;
  my $excess = length($self->{stderr_buffer}) - $self->max_stderr_bytes;
  substr($self->{stderr_buffer}, 0, $excess, '') if $excess > 0;
  return;
}

sub _spawn_failed ($message) {
  OpenAPI::Humbug::Error->throw(kind => 'transport', code => 'client.spawn_failed', message => $message);
}

sub _find_executable ($name) {
  OpenAPI::Humbug::Error->throw(kind => 'argument', code => 'client.argument',
    message => 'executable must be a non-empty string')
    unless defined $name && !ref $name && length $name;

  if($name =~ m{/}) {
    return $name if -f $name && -x _;
    _spawn_failed("executable '$name' is not an executable file");
  }

  my $path = which($name);
  return $path if defined $path;

  _spawn_failed("executable '$name' not found in PATH");
}

# fork and exec directly (IPC::Open3 would use the shell for a single string with metacharacters)
sub _spawn ($self) {
  my($child_in, $stdin, $stdout, $child_out, $stderr, $child_err, $status_r, $status_w);
  pipe($child_in, $stdin)    or _spawn_failed("pipe: $!");
  pipe($stdout, $child_out)  or _spawn_failed("pipe: $!");
  pipe($stderr, $child_err)  or _spawn_failed("pipe: $!");
  pipe($status_r, $status_w) or _spawn_failed("pipe: $!");

  # Perl only marks fds above $^F close-on-exec, and a pipe can get fd 0, 1 or 2 when the caller
  # has closed a standard handle, so set it on every end explicitly.  Only the fds the child
  # dup2s onto 0, 1 and 2 survive exec; $status_w closing on exec is how the parent learns that
  # exec succeeded.
  for my $fh ($child_in, $stdin, $stdout, $child_out, $stderr, $child_err, $status_r, $status_w) {
    _close_on_exec($fh, 1) or _spawn_failed("fcntl: $!");
  }

  my $executable = $self->executable;
  my @args       = $self->args->@*;

  my $pid = fork;
  _spawn_failed("fork: $!") unless defined $pid;

  if($pid == 0) {
    # child: put the pipes on 0, 1 and 2, which dup2 leaves open across exec; if exec fails,
    # $status_w reports the errno to the parent.  The ends are first copied above 2 so that
    # one landing on 0, 1 or 2 cannot be overwritten by another's dup2.
    eval {
      my @high = map { fcntl($_, F_DUPFD, 3) // die } $child_in, $child_out, $child_err;
      POSIX::dup2($high[$_], $_) // die for 0..2;
      POSIX::close($_) for @high;
      no warnings 'exec';
      exec { $executable } $executable, @args;
    };
    syswrite $status_w, 0 + $!;
    POSIX::_exit(127);
  }

  CORE::close $_ for $child_in, $child_out, $child_err, $status_w;

  my $errno = '';
  1 while sysread($status_r, $errno, 64, length $errno);
  CORE::close $status_r;
  if(length $errno) {
    waitpid $pid, 0;
    local $! = $errno;
    _spawn_failed("cannot execute '$executable': $!");
  }

  for my $fh ($stdin, $stdout, $stderr) {
    binmode $fh;
    $fh->blocking(0);
  }

  @$self{qw( pid stdin stdout stderr )} = ($pid, $stdin, $stdout, $stderr);
  return;
}

sub _close_on_exec ($fh, $on) {
  my $flags = fcntl $fh, F_GETFD, 0;
  return undef unless defined $flags;
  $flags = $on ? $flags | FD_CLOEXEC : $flags & ~FD_CLOEXEC;
  return fcntl $fh, F_SETFD, $flags;
}

# how the child ended, if it already has
sub _eof_detail ($self) {
  return '' unless defined $self->{pid};
  for (1..20) {
    my $pid = waitpid $self->{pid}, POSIX::WNOHANG();
    if($pid == $self->{pid}) {
      $self->{exit_status} = $?;
      delete $self->{pid};
      return $? & 127 ? " (killed by signal @{[ $? & 127 ]})" : " (exit status @{[ $? >> 8 ]})";
    }
    last if $pid < 0;
    Time::HiRes::sleep(0.01);
  }
  return '';
}

# close the pipes and reap the child, escalating to SIGTERM and SIGKILL
sub _teardown ($self, $grace) {
  for my $key (qw( stdin stdout stderr )) {
    my $fh = delete $self->{$key};
    CORE::close $fh if defined $fh;
  }

  if(defined(my $pid = delete $self->{pid})) {
    my $reaped = _reap($pid, $grace);
    unless($reaped) {
      kill 'TERM', $pid;
      $reaped = _reap($pid, KILL_GRACE);
    }
    unless($reaped) {
      kill 'KILL', $pid;
      $reaped = _reap($pid, KILL_GRACE);
    }
    $self->{exit_status} = $reaped ? $? : undef;
  }

  return defined $self->{exit_status} && $self->{exit_status} == 0;
}

sub _reap ($pid, $seconds) {
  my $deadline = Time::HiRes::time() + $seconds;
  while(1) {
    my $got = waitpid $pid, POSIX::WNOHANG();
    return 1 if $got == $pid;
    return 1 if $got < 0;  # already reaped elsewhere
    return 0 if Time::HiRes::time() >= $deadline;
    Time::HiRes::sleep(0.01);
  }
}
