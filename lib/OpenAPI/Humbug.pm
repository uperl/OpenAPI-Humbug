package OpenAPI::Humbug;

use 5.042;
use warnings;
use Errno ();
use File::Which ();
use IO::Select;
use JSON::PP ();
use List::Util ();
use MIME::Base64 ();
use Path::Tiny ();
use POSIX ();
use Time::HiRes ();
use OpenAPI::Humbug::Error;

# ABSTRACT: Humbug OpenAPI client
# VERSION

=head1 SYNOPSIS

 use OpenAPI::Humbug;

 my $humbug = OpenAPI::Humbug->new(
   spec       => 'openapi.yaml',
   executable => '/usr/local/bin/humbug', # optional, otherwise PATH
 );

 my $result = $humbug->validate(
   request => {
     method  => 'POST',
     url     => 'https://api.example.test/users',
     headers => [
       ['Content-Type', 'application/json'],
       ['X-Trace', 'one'],
       ['X-Trace', 'two'],
     ],
     body => qq|{"age":-1}|,
   },
   response => {
     status  => 201,
     headers => [['Content-Type', 'application/json']],
     body    => qq|{"id":42}|,
   },
 );

 if(!$result->{valid}) {
   for my $d ($result->{request}{diagnostics}->@*) {
     next if defined $d->{suppressed_by};
     warn "$d->{code}: $d->{message}\n";
   }
 }

 $humbug->close;

=head1 DESCRIPTION

This module validates captured HTTP transactions against an OpenAPI 3.1 specification using
L<humbug|https://github.com/uperl/go-humbug>, a validator that runs as a persistent child
process and speaks a line-oriented JSON protocol over its stdin and stdout.

The Perl side only manages the process and carries data faithfully; all OpenAPI semantics live in
the sidecar.  Each client starts one child, loads one specification into it once, and then
validates any number of transactions through it, one at a time.

The C<humbug> executable is a separate program that must be installed on its own; see
L</INSTALLING HUMBUG>.

=head1 CONSTRUCTOR

=head2 new

 my $humbug = OpenAPI::Humbug->new(%options);

Starts the sidecar, initializes it with the specification, and waits for it to confirm.  Throws an
L<OpenAPI::Humbug::Error> on any failure (for example C<kind> C<sidecar> with C<code>
C<spec.invalid> for a broken specification), after terminating and reaping the child.

Options:

=over 4

=item spec

Required.  The path of a local OpenAPI 3.1 specification file.  A relative path is resolved against
the current working directory at the time C<new> is called, and the absolute path is sent to the
sidecar, so changing directory later has no effect.  The child also inherits the working directory
from the caller.

=item executable

The C<humbug> executable.  If it contains a slash it is used as is; otherwise it is looked up in
C<PATH>.  Defaults to C<humbug>.  The executable is always run directly, never through a shell.

=item args

An array reference of extra command-line arguments for the executable, for example
C<['-max-body-bytes', 1048576]>.  Resource limits are set this way, never over the protocol.

=item timeout

How long to wait for the reply to any one command (including C<initialize>), in seconds.
Defaults to 60.  A timeout terminates the child and makes the client unusable; the command is not
retried.

=item max_reply_bytes

The longest reply line accepted from the sidecar, in bytes, to bound memory if the child
misbehaves.  Defaults to 64 MiB.

=item max_stderr_bytes

How much of the sidecar's stderr to keep (the most recent bytes).  stderr is always drained so a
noisy child cannot block; only this much is retained.  Defaults to 64 KiB.

=back

=cut

use constant {
  SHUTDOWN_GRACE => 5,
  FAILURE_GRACE  => 0.2,
  KILL_GRACE     => 2,
  CHUNK          => 65536,
};

use Class::Tiny qw( spec ), {
  executable       => 'humbug',
  args             => sub { [] },
  timeout          => 60,
  max_reply_bytes  => 64 * 1024 * 1024,
  max_stderr_bytes => 64 * 1024,
};

my $json = JSON::PP->new->utf8->canonical->core_bools;

sub BUILD ($self, $args) {
  my %known = map { $_ => 1 } Class::Tiny->get_all_attributes_for(ref $self);
  for my $key (sort keys %$args) {
    _argument("unknown option '$key'") unless $known{$key};
    # an explicit undef means the default
    delete $self->{$key} unless defined $args->{$key};
  }

  my $spec = $self->spec;
  _argument("spec is required and must be a path") unless defined $spec && !ref $spec && length $spec;
  $self->spec(Path::Tiny::path($spec)->absolute->stringify);

  my $extra = $self->args;
  _argument("args must be an array reference of strings")
    unless ref $extra eq 'ARRAY' && !List::Util::any { !defined $_ || ref $_ } @$extra;
  $self->args([@$extra]);

  for my $key (qw( timeout max_reply_bytes max_stderr_bytes )) {
    my $value = $self->$key;
    _argument("$key must be a positive number")
      unless !ref $value && $value =~ /^[0-9]+(?:\.[0-9]+)?$/ && $value > 0;
  }

  $self->executable(_find_executable($self->executable));

  $self->{next_id}       = 1;
  $self->{stdout_buffer} = '';
  $self->{stderr_buffer} = '';
  $self->{owner_pid}     = $$;

  $self->_spawn;

  my $result = eval {
    $self->_command(initialize => {
      protocol_version => 1,
      spec             => { path => $self->spec },
    });
  };
  if(my $error = $@) {
    $self->_terminate;
    $self->{dead} = $error;
    die $error;
  }

  unless(ref $result->{specification} eq 'HASH'
      && defined $result->{protocol_version}
      && !ref $result->{protocol_version}
      && $result->{protocol_version} eq '1') {
    die $self->_fail(protocol => 'client.unexpected_reply',
      'initialize result lacks protocol_version 1 or specification');
  }

  $self->{initialize} = $result;
  return;
}

=head1 ATTRIBUTES

=head2 specification

 my $hash = $humbug->specification;

The C<specification> object from the C<initialize> reply, such as C<openapi_version> and C<title>.

=head2 limits

 my $hash = $humbug->limits;

The resource limits the sidecar reported, such as C<max_body_bytes>, or C<undef> if it reported
none.  The set of keys belongs to the sidecar; treat a missing key as unknown.

=head2 implementation

 my $hash = $humbug->implementation;

The C<implementation> object from the C<initialize> reply (C<name>, C<version>, C<libraries>), or
C<undef>.  It is for logs and bug reports; do not branch on it.

=head2 stderr

 my $text = $humbug->stderr;

The most recent bytes (up to C<max_stderr_bytes>) the sidecar wrote to stderr.  A healthy sidecar
normally writes nothing.

=head2 spec

=head2 executable

=head2 args

=head2 timeout

=head2 max_reply_bytes

=head2 max_stderr_bytes

The constructor options, with defaults applied.  C<spec> is the absolute path sent to the sidecar
and C<executable> the path that was run.  Changing them after construction has no effect on the
running child, except that C<timeout> applies to later commands.

=cut

sub specification  ($self) { $self->{initialize}{specification}  }
sub limits         ($self) { $self->{initialize}{limits}         }
sub implementation ($self) { $self->{initialize}{implementation} }
sub stderr         ($self) { $self->{stderr_buffer}              }

=head1 METHODS

=head2 validate

 my $result = $humbug->validate(
   request  => \%request,
   response => \%response,                  # optional
   validate => { request => 1, response => 1 }, # optional
 );

Validates one HTTP transaction and returns the sidecar's complete C<result> object as a hash
reference.  A transaction that violates the specification, or that could not be fully checked, is
still a result; it is never an exception.

The request is a hash reference with these keys:

=over 4

=item method

Required.  The HTTP method as captured.  Case is not normalized.

=item url

Required.  The effective absolute URL as captured (scheme, host, path and query; no fragment).
It is not normalized.

=item headers

Optional.  The header lines as an array reference of C<[$name, $value]> pairs; see L</HEADERS>.

=item body

Optional.  The decoded body as a byte string; see L</BODIES>.

=back

The response, if given, has the same C<headers> and C<body> keys, plus:

=over 4

=item status

Required.  The integer status code, 100 to 599.

=back

C<validate> selects which sides are checked: C<request> defaults to true, and C<response> defaults
to true if and only if a response was given.  Values are interpreted as Perl booleans.  Asking for the
response without a response, or turning both off, is refused by the sidecar.

Unknown keys, references where strings are expected, and similar mistakes throw an exception of
C<kind> C<argument> before anything is sent.

=cut

my %request_keys  = map { $_ => 1 } qw( method url headers body );
my %response_keys = map { $_ => 1 } qw( status headers body );

sub validate ($self, %args) {
  for my $key (sort keys %args) {
    _argument("unknown argument '$key'") unless $key =~ /^(?:request|response|validate)$/;
  }

  my %params;

  my $request = $args{request};
  _argument("request is required and must be a hash reference") unless ref $request eq 'HASH';
  for my $key (sort keys %$request) {
    _argument("unknown request key '$key'") unless $request_keys{$key};
  }
  for my $key (qw( method url )) {
    _argument("request $key is required and must be a non-empty string")
      unless defined $request->{$key} && !ref $request->{$key} && length $request->{$key};
  }
  $params{request} = {
    method => "$request->{method}",
    url    => "$request->{url}",
    _message_common('request', $request),
  };

  if(defined $args{response}) {
    my $response = $args{response};
    _argument("response must be a hash reference") unless ref $response eq 'HASH';
    for my $key (sort keys %$response) {
      _argument("unknown response key '$key'") unless $response_keys{$key};
    }
    my $status = $response->{status};
    _argument("response status is required and must be an integer from 100 to 599")
      unless defined $status && !ref $status && $status =~ /^[0-9]{3}$/ && $status >= 100 && $status <= 599;
    $params{response} = {
      status => 0 + $status,
      _message_common('response', $response),
    };
  }

  if(defined $args{validate}) {
    my $validate = $args{validate};
    _argument("validate must be a hash reference") unless ref $validate eq 'HASH';
    for my $key (sort keys %$validate) {
      _argument("unknown validate key '$key'") unless $key =~ /^(?:request|response)$/;
      _argument("validate $key must be a boolean scalar") if ref $validate->{$key};
      $params{validate}{$key} = $validate->{$key} ? true : false;
    }
    $params{validate} //= {};
  }

  return $self->_command(validate => \%params);
}

sub _message_common ($side, $message) {
  my %wire;

  if(defined $message->{headers}) {
    my $headers = $message->{headers};
    _argument("$side headers must be an array reference of [name, value] pairs") unless ref $headers eq 'ARRAY';
    my $n = 0;
    $wire{headers} = [ map {
      my $entry = $_;
      $n++;
      _argument("$side header $n must be an array reference of exactly [name, value]")
        unless ref $entry eq 'ARRAY' && @$entry == 2;
      my ($name, $value) = @$entry;
      _argument("$side header $n name must be a non-empty string")
        unless defined $name && !ref $name && length $name;
      _argument("$side header $n value must be a defined string") unless defined $value && !ref $value;
      my $bytes = _bytes($value) // _argument("$side header $n value contains characters above 0xFF; encode it to bytes first");
      ["$name", MIME::Base64::encode_base64($bytes, ''), true];
    } @$headers ];
  }

  if(defined $message->{body}) {
    my $body = $message->{body};
    _argument("$side body must be a byte string, not a reference") if ref $body;
    my $bytes = _bytes($body) // _argument("$side body contains characters above 0xFF; encode it to bytes first");
    $wire{body_base64} = MIME::Base64::encode_base64($bytes, '');
  }

  return %wire;
}

# a byte string with the same bytes, or undef if the string has characters above 0xFF
sub _bytes ($string) {
  my $copy = "$string";
  return utf8::downgrade($copy, 1) ? $copy : undef;
}

=head2 close

 $humbug->close;

Sends C<shutdown> if the child is still usable, closes the pipes, and reaps the child, terminating
it if it does not exit promptly (after the smaller of C<timeout> and 5 seconds, then C<SIGTERM>, then
C<SIGKILL>).  Returns true if the child exited cleanly with status 0.  Calling it again is harmless.
It does not throw.

Dropping the last reference to the client does the same on a best-effort basis, but an explicit
C<close> is recommended.

=cut

sub close ($self) {
  return $self->{exit_ok} if $self->{closed};
  $self->{closed} = 1;

  my $grace = $self->timeout < SHUTDOWN_GRACE ? $self->timeout : SHUTDOWN_GRACE;

  if(defined $self->{pid} && !$self->{dead}) {
    local $@;
    eval { $self->_command('shutdown', undef, $grace); 1 };
  }

  $self->_terminate($grace);
  $self->{dead} //= 1;
  return $self->{exit_ok};
}

sub DEMOLISH ($self, $global_destruction) {
  local($@, $!, $?);
  return unless defined $self->{pid};
  if($self->{owner_pid} != $$) {
    # forked copy: the child belongs to the parent process; leave it alone
    delete $self->{pid};
    return;
  }
  eval { $self->close };
  return;
}

sub _argument ($message) {
  OpenAPI::Humbug::Error->throw(kind => 'argument', code => 'client.argument', message => $message);
}

sub _find_executable ($name) {
  _argument("executable must be a non-empty string") unless defined $name && !ref $name && length $name;

  if($name =~ m{/}) {
    return $name if -f $name && -x _;
    OpenAPI::Humbug::Error->throw(kind => 'process', code => 'client.spawn_failed',
      message => "executable '$name' is not an executable file");
  }

  my $path = File::Which::which($name);
  return $path if defined $path;

  OpenAPI::Humbug::Error->throw(kind => 'process', code => 'client.spawn_failed',
    message => "executable '$name' not found in PATH");
}

# fork and exec directly (IPC::Open3 would use the shell for a single string with metacharacters)
sub _spawn ($self) {
  my($child_in, $stdin, $stdout, $child_out, $stderr, $child_err, $status_r, $status_w);
  pipe($child_in, $stdin)        or $self->_spawn_failed("pipe: $!");
  pipe($stdout, $child_out)      or $self->_spawn_failed("pipe: $!");
  pipe($stderr, $child_err)      or $self->_spawn_failed("pipe: $!");
  pipe($status_r, $status_w)     or $self->_spawn_failed("pipe: $!");

  my $pid = fork;
  $self->_spawn_failed("fork: $!") unless defined $pid;

  if($pid == 0) {
    # child: fds above $^F are close-on-exec, so only 0, 1 and 2 survive exec,
    # and $status_w reports exec failure to the parent.
    eval {
      POSIX::dup2(fileno $child_in,  0) // die;
      POSIX::dup2(fileno $child_out, 1) // die;
      POSIX::dup2(fileno $child_err, 2) // die;
      no warnings 'exec';
      my $executable = $self->executable;
      exec { $executable } $executable, $self->args->@*;
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
    $self->_spawn_failed("cannot execute '@{[ $self->executable ]}': $!");
  }

  for my $fh ($stdin, $stdout, $stderr) {
    binmode $fh;
    $fh->blocking(0);
  }

  @$self{qw( pid stdin stdout stderr )} = ($pid, $stdin, $stdout, $stderr);
  return;
}

sub _spawn_failed ($self, $message) {
  OpenAPI::Humbug::Error->throw(kind => 'process', code => 'client.spawn_failed', message => $message);
}

# record a fatal failure: the client becomes unusable and the child is terminated
sub _fail ($self, $kind, $code, $message) {
  my $error = OpenAPI::Humbug::Error->new(
    kind    => $kind,
    code    => $code,
    message => $message,
    stderr  => $self->{stderr_buffer},
  );
  $self->{dead} = $error;
  $self->_terminate(FAILURE_GRACE);
  return $error;
}

# send one command and return its result, or throw
sub _command ($self, $type, $params = undef, $timeout = $self->timeout) {
  if($self->{dead} || $self->{closed} && $type ne 'shutdown') {
    OpenAPI::Humbug::Error->throw(kind => 'closed', code => 'client.closed',
      message => 'the client is closed or unusable after an earlier failure');
  }
  OpenAPI::Humbug::Error->throw(kind => 'closed', code => 'client.closed',
    message => 'the client was created in another process')
    if $self->{owner_pid} != $$;

  my $id = $self->{next_id}++;
  my %command = ( id => $id, type => $type );
  $command{params} = $params if defined $params;
  my $line = $json->encode(\%command) . "\n";

  my $reply_line = $self->_exchange($line, $timeout);

  my $reply = eval { $json->decode($reply_line) };
  die $self->_fail(protocol => 'client.malformed_reply', 'reply is not valid JSON')
    unless defined $reply;
  die $self->_fail(protocol => 'client.malformed_reply', 'reply is not a JSON object')
    unless ref $reply eq 'HASH';

  my $reply_type = $reply->{type};
  die $self->_fail(protocol => 'client.unexpected_reply', 'reply has no string type')
    unless defined $reply_type && !ref $reply_type;

  my $reply_id = $reply->{id};
  # A null id answers a line the sidecar could not attribute (for example
  # protocol.line_too_long).  With one command in flight that line is ours.
  my $id_ok = defined $reply_id
    ? !ref $reply_id && $reply_id =~ /^[0-9]+$/ && $reply_id == $id
    : $reply_type eq 'error';
  die $self->_fail(protocol => 'client.id_mismatch', "reply id does not match command id $id")
    unless $id_ok;

  if($reply_type eq 'error') {
    my $error = $reply->{error};
    die $self->_fail(protocol => 'client.unexpected_reply', 'error reply lacks error code and message')
      unless ref $error eq 'HASH'
          && defined $error->{code}    && !ref $error->{code}
          && defined $error->{message} && !ref $error->{message};
    OpenAPI::Humbug::Error->throw(
      kind    => 'sidecar',
      code    => $error->{code},
      message => $error->{message},
      error   => $error,
    );
  }

  die $self->_fail(protocol => 'client.unexpected_reply', "unexpected reply type '$reply_type'")
    unless $reply_type eq 'result';
  die $self->_fail(protocol => 'client.unexpected_reply', 'result reply lacks a result object')
    unless ref $reply->{result} eq 'HASH';

  return $reply->{result};
}

# write one line and read one line, draining stderr, within the timeout
sub _exchange ($self, $out, $timeout) {
  # anything already waiting on stdout was not asked for, and would be mistaken for our reply
  if(IO::Select->new($self->{stdout})->can_read(0)) {
    sysread $self->{stdout}, $self->{stdout_buffer}, CHUNK, length $self->{stdout_buffer};
  }
  die $self->_fail(protocol => 'client.unsolicited_output', 'sidecar wrote output before the command was sent')
    if length $self->{stdout_buffer};

  local $SIG{PIPE} = 'IGNORE';

  my $deadline = Time::HiRes::time() + $timeout;
  my($stdin, $stdout, $stderr) = @$self{qw( stdin stdout stderr )};
  my $written    = 0;
  my $broken     = 0;
  my $stdout_eof = 0;
  my $scan_from  = 0;
  my $reply;

  my $readers = IO::Select->new($stdout, $stderr);
  my $writers = IO::Select->new($stdin);

  while(1) {
    if(defined $reply && ($written == length $out || $broken)) {
      last;
    }
    if($stdout_eof && !defined $reply) {
      my $what = $broken ? 'client.broken_pipe' : 'client.eof';
      die $self->_fail(process => $what, 'sidecar exited or closed its stdout without replying'
        . $self->_exit_description);
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

    for my $fh (@{ $can_write // [] }) {
      my $n = syswrite $fh, $out, CHUNK, $written;
      if(defined $n) {
        $written += $n;
      } elsif($! == Errno::EPIPE) {
        $broken = 1;
      } elsif($! != Errno::EAGAIN && $! != Errno::EINTR) {
        die $self->_fail(process => 'client.broken_pipe', "write to sidecar failed: $!");
      }
    }

    for my $fh (@{ $can_read // [] }) {
      if($fh == $stderr) {
        my $n = sysread $fh, $self->{stderr_buffer}, CHUNK, length $self->{stderr_buffer};
        if(defined $n && $n == 0) {
          $readers->remove($stderr);
        }
        my $excess = length($self->{stderr_buffer}) - $self->max_stderr_bytes;
        substr($self->{stderr_buffer}, 0, $excess, '') if $excess > 0;
        next;
      }

      my $n = sysread $fh, $self->{stdout_buffer}, CHUNK, length $self->{stdout_buffer};
      if(defined $n && $n == 0) {
        $readers->remove($stdout);
        $stdout_eof = 1;
        next;
      }
      next unless $n;
      next if defined $reply;

      my $newline = index $self->{stdout_buffer}, "\n", $scan_from;
      if($newline < 0) {
        $scan_from = length $self->{stdout_buffer};
        die $self->_fail(protocol => 'client.reply_too_long', "reply exceeds @{[ $self->max_reply_bytes ]} bytes")
          if $scan_from > $self->max_reply_bytes;
        next;
      }
      die $self->_fail(protocol => 'client.reply_too_long', "reply exceeds @{[ $self->max_reply_bytes ]} bytes")
        if $newline > $self->max_reply_bytes;
      $reply = substr $self->{stdout_buffer}, 0, $newline + 1, '';
    }
  }

  die $self->_fail(protocol => 'client.unsolicited_output', 'sidecar wrote more than one reply line')
    if length $self->{stdout_buffer};

  # the child stopped reading part way through our line, so the stream cannot continue
  die $self->_fail(process => 'client.broken_pipe', 'sidecar stopped reading its stdin')
    if $broken;

  return $reply;
}

sub _exit_description ($self) {
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
sub _terminate ($self, $grace = SHUTDOWN_GRACE) {
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

  $self->{exit_ok} = defined $self->{exit_status} && $self->{exit_status} == 0 ? 1 : 0;
  return;
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

=head1 HEADERS

Headers are an ordered array reference of C<[$name, $value]> pairs, never a hash, because HTTP
headers are ordered lines that may repeat:

 headers => [
   ['Content-Type', 'application/json'],
   ['Set-Cookie',   'a=1'],
   ['Set-Cookie',   'b=2'],
   ['X-Empty',      ''],
 ],

Order, repeats, name casing, empty values and whitespace are sent exactly as given.  Lines are never
combined (in particular C<Set-Cookie>), split, trimmed or merged.  Every pair must have
exactly two elements.

Header values are byte strings.  Every value is sent base64-encoded, which the protocol allows for
any value, so values that are not valid UTF-8 travel unchanged.  Names are sent as text and never
encoded; a header name is ASCII in practice, and the sidecar rejects one that is not an HTTP token
with a C<validator.unsupported_input> error.

=head1 BODIES

C<body> is the HTTP body as a byte string, B<after> any transfer and content decoding (gzip and so
on): exactly the bytes the application saw.  It is not a Perl data structure; pass
C<encode_json($data)> yourself if that is what you have, and remember that the sidecar judges the
bytes it receives.  References are rejected rather than serialized.

=over 4

=item * A missing C<body> key, or C<body =E<gt> undef>, means the message has no body.

=item * C<body =E<gt> ''> means the message has a body of zero bytes.  The two are not the same:
for an operation that requires a body, the first is reported as C<body.required> and the second as
C<body.decode>.

=back

The body is never parsed, re-serialized, compressed or decompressed.  A C<Content-Encoding> header
is passed through but ignored by the sidecar, so send decoded bytes.  Diagnostic spans are byte
offsets into the body you sent.

=head1 BYTES AND CHARACTERS

Header values and bodies are bytes.  If you have a Perl character string (for example JSON text
from a decoder), encode it first with C<Encode::encode('UTF-8', $text)>.  A string containing a
character above C<0xFF> cannot be bytes and is rejected with an C<argument> error rather than
guessed at.  A string with Perl's internal UTF-8 flag on but only characters up to C<0xFF> is
treated as the bytes those characters denote, as Perl's own I/O would.

C<method>, C<url> and header names are text.  They are encoded as UTF-8 in the JSON sent to the
sidecar.  An effective URL is ASCII (percent-encoded) as it appeared on the wire, so send it that
way.

=head1 RESULTS

C<validate> returns the sidecar's C<result> object unchanged, with JSON booleans as Perl's
C<true> and C<false>.  Unknown fields and diagnostic codes are preserved.  The important fields:

=over 4

=item C<valid>, C<complete>, C<has_violations>

For the transaction (over the sides that were checked).  C<valid> is true only if the checks
completed and found no violations.  Decide on C<valid>, not on C<has_violations> alone.

=item C<request>, C<response>

Each side has a C<status> (C<valid>, C<invalid>, C<incomplete> or C<skipped>), its own C<valid>,
C<complete> and C<has_violations>, and an ordered C<diagnostics> array.  A side that was not
checked is C<skipped> and never C<valid>.

=item diagnostics

Each has C<id>, C<code>, C<severity> (C<error>, C<warning> or C<info>), C<message>, and where
relevant C<instance>, C<schema>, C<detail>, C<operation> and the relationships C<parent>,
C<children>, C<caused_by> and C<suppressed_by>.  Suppressed diagnostics are kept; hide them in a
display if you like.  Warnings and info do not make a transaction invalid.  Use the
machine-readable fields, never C<message>.

=back

See the sidecar's L<diagnostics documentation|https://github.com/uperl/go-humbug/blob/main/docs/diagnostics.md>
for the codes.  The findings for a given input may change between sidecar releases.

=head1 ERRORS

There are three different outcomes, and they must not be confused:

=over 4

=item Invalid

C<validate> returns a result with C<valid> false and C<has_violations> true: the transaction
violates the specification.

=item Incomplete

C<validate> returns a result with C<complete> false: something could not be checked (a body over
the size limit, an unsupported media type, an unknown operation, ...).  Such a result is not valid,
but not necessarily a violation either.  C<validation.incomplete> diagnostics say why.

=item Failure

C<validate> throws an L<OpenAPI::Humbug::Error>: there is no verdict at all.  Its C<kind> says
whether the arguments were bad (C<argument>), the sidecar refused the command (C<sidecar>, with the
sidecar's C<code>), or the process or protocol failed (C<process>, C<protocol>, C<timeout>).  A
failure is never reported as a valid or invalid result.

=back

After an C<argument> or C<sidecar> error the client can be used again.  After a C<process>,
C<protocol> or C<timeout> failure the child is terminated and the client is unusable: further calls
throw C<closed>.  Nothing is restarted or retried automatically; construct a new client if you want
to continue.

=head1 PROCESS LIFETIME

=over 4

=item * C<new> starts one child and initializes it with one specification.  The specification cannot
be changed afterwards; create another client for another specification.

=item * C<validate> may be called any number of times.  Commands are sent one at a time.

=item * C<close> shuts the child down and reaps it.  Destroying the object does the same, best
effort.

=item * A client must not be shared between threads, or used in a child process after C<fork>;
create a new client in each process.  A forked copy of the object never touches the parent's child.

=back

=head1 INSTALLING HUMBUG

The C<humbug> executable comes from L<go-humbug|https://github.com/uperl/go-humbug> and is a
separate, runtime-only prerequisite; this distribution never builds or downloads it, and Go is not
needed at runtime.  With Go installed:

 go install github.com/uperl/go-humbug/cmd/humbug@latest

or build it from a checkout with C<make build> and pass the path as C<executable>.

=head1 TESTING

The unit tests use a fake sidecar and need neither Go nor C<humbug>.  The integration tests run
against a real C<humbug> if C<OPENAPI_HUMBUG_EXECUTABLE> names one, and are skipped otherwise:

 OPENAPI_HUMBUG_EXECUTABLE=/path/to/humbug prove -lv t/integration.t

=head1 PLATFORMS

Linux and macOS.  Windows is not supported yet.

=head1 SEE ALSO

=over 4

=item L<OpenAPI::Humbug::Error>

=item L<Humbug client guide|https://github.com/uperl/go-humbug/blob/main/docs/client-guide.md>

=item L<Humbug protocol|https://github.com/uperl/go-humbug/blob/main/docs/protocol.md>

=back

=cut
