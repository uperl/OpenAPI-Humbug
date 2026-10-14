package OpenAPI::Humbug;

use 5.042;
use warnings;
use JSON::PP ();
use List::Util qw( any );
use MIME::Base64 qw( encode_base64 );
use Path::Tiny ();
use OpenAPI::Humbug::Error;
use OpenAPI::Humbug::Transport::Command;
use namespace::autoclean -also => [qw( SHUTDOWN_GRACE )];

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

use constant SHUTDOWN_GRACE => 5;

use Class::Tiny qw( spec ), {
  executable       => 'humbug',
  args             => sub { [] },
  timeout          => 60,
  max_reply_bytes  => 64 * 1024 * 1024,
  max_stderr_bytes => 64 * 1024,
};

# Cpanel::JSON::XS is faster when installed; 4.38 is the first to encode core booleans as JSON booleans
my $json = eval {
  require Cpanel::JSON::XS;
  Cpanel::JSON::XS->VERSION('4.38');
  Cpanel::JSON::XS->new->utf8->canonical->unblessed_bool;
} // JSON::PP->new->utf8->canonical->core_bools;

sub BUILD ($self, $args) {
  my %known = map { $_ => 1 } Class::Tiny->get_all_attributes_for(ref $self);
  for my $key (sort keys %$args) {
    _argument("unknown option '$key'") unless $known{$key};
    # an explicit undef means the default
    delete $self->{$key} unless defined $args->{$key};
  }

  my $spec = $self->spec;
  _argument("spec is required and must be a path") unless defined $spec && !ref $spec && length $spec;
  $self->spec(Path::Tiny->new($spec)->absolute->stringify);

  my $extra = $self->args;
  _argument("args must be an array reference of strings")
    unless ref $extra eq 'ARRAY' && !any { !defined $_ || ref $_ } @$extra;
  $self->args([@$extra]);

  for my $key (qw( timeout max_reply_bytes max_stderr_bytes )) {
    my $value = $self->$key;
    _argument("$key must be a positive number")
      unless !ref $value && $value =~ /^[0-9]+(?:\.[0-9]+)?$/ && $value > 0;
  }

  $self->{next_id}   = 1;
  $self->{owner_pid} = $$;

  my $transport = $self->{transport} = $self->_build_transport;
  $self->executable($transport->executable) if $transport->can('executable');

  my $result = eval {
    $self->_command(initialize => {
      protocol_version => 1,
      spec             => { path => $self->spec },
    });
  };
  if(my $error = $@) {
    $self->{dead} = $error;
    $transport->abort;
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

sub _build_transport ($self) {
  return OpenAPI::Humbug::Transport::Command->new(
    executable       => $self->executable,
    args             => $self->args,
    max_reply_bytes  => $self->max_reply_bytes,
    max_stderr_bytes => $self->max_stderr_bytes,
  );
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
sub stderr         ($self) { $self->{transport}->stderr          }

=head1 METHODS

=head2 validate

 my $result = $humbug->validate(
   request  => \%request,
   response => \%response,                  # optional
   validate => { request => 1, response => 1 }, # optional
 );

 # Mojolicious messages, in place of either hash
 my $result = $humbug->validate(request => $tx->req, response => $tx->res);

 # a Mojolicious transaction, in place of both
 my $result = $humbug->validate($tx);
 my $result = $humbug->validate($tx, validate => { response => 0 });

Validates one HTTP transaction and returns the sidecar's complete C<result> object as a hash
reference.  A transaction that violates the specification, or that could not be fully checked, is
still a result; it is never an exception.

C<request> and C<response> may each be a hash reference, as described below, or a
L<Mojo::Message::Request> or L<Mojo::Message::Response>; a L<Mojo::Transaction::HTTP> may be passed
first in place of both.  See L</MOJOLICIOUS> for how those are converted.

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

sub validate ($self, @args) {
  # validate($tx, %options): a Mojo::Transaction::HTTP in place of request and response
  my $tx = @args % 2 ? shift @args : undef;
  my %args = @args;

  for my $key (sort keys %args) {
    _argument("unknown argument '$key'") unless $key =~ /^(?:request|response|validate)$/;
  }

  if(defined $tx) {
    _argument("a transaction must be a Mojo::Transaction::HTTP")
      unless blessed $tx && $tx->isa('Mojo::Transaction::HTTP');
    _argument("request and response cannot be given with a transaction")
      if exists $args{request} || exists $args{response};
    my %converted = _mojo()->transaction($tx);
    _argument("the transaction's response is not complete, so it cannot be validated")
      if !$converted{response} && ref $args{validate} eq 'HASH' && $args{validate}{response};
    %args = (%args, %converted);
  } else {
    if(blessed $args{request}) {
      _argument("request must be a hash reference or a Mojo::Message::Request")
        unless $args{request}->isa('Mojo::Message::Request');
      $args{request} = _mojo()->request($args{request});
    }
    if(blessed $args{response}) {
      _argument("response must be a hash reference or a Mojo::Message::Response")
        unless $args{response}->isa('Mojo::Message::Response');
      my $method = ref $args{request} eq 'HASH' ? $args{request}{method} : undef;
      $args{response} = _mojo()->response($args{response}, $method);
    }
  }

  my %params;

  my $request = $args{request};
  _argument("request is required and must be a hash reference or a Mojo::Message::Request") unless ref $request eq 'HASH';
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
    _argument("response must be a hash reference or a Mojo::Message::Response") unless ref $response eq 'HASH';
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

# the Mojolicious adapter, loaded only when a Mojo object is passed
sub _mojo () {
  require OpenAPI::Humbug::Adapter::Mojo;
  return 'OpenAPI::Humbug::Adapter::Mojo';
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
      ["$name", encode_base64($bytes, ''), true];
    } @$headers ];
  }

  if(defined $message->{body}) {
    my $body = $message->{body};
    _argument("$side body must be a byte string, not a reference") if ref $body;
    my $bytes = _bytes($body) // _argument("$side body contains characters above 0xFF; encode it to bytes first");
    $wire{body_base64} = encode_base64($bytes, '');
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
  return $self->{clean} if $self->{closed};
  $self->{closed} = 1;

  my $transport = $self->{transport};
  my $grace = $self->timeout < SHUTDOWN_GRACE ? $self->timeout : SHUTDOWN_GRACE;

  if(!$self->{dead} && $transport->is_open && $transport->ends_with_shutdown) {
    local $@;
    eval { $self->_command('shutdown', undef, $grace); 1 };
  }

  $self->{clean} = $transport->close($grace);
  $self->{dead} //= 1;
  return $self->{clean};
}

sub DEMOLISH ($self, $global_destruction) {
  local($@, $!, $?);
  # a forked copy must leave the parent's sidecar alone
  return if !defined $self->{owner_pid} || $self->{owner_pid} != $$;
  return unless $self->{transport};
  eval { $self->close };
  return;
}

sub _argument ($message) {
  OpenAPI::Humbug::Error->throw(kind => 'argument', code => 'client.argument', message => $message);
}

# a protocol failure: the reply cannot be trusted, so the client becomes unusable
sub _fail ($self, $kind, $code, $message) {
  my $transport = $self->{transport};
  my $error = OpenAPI::Humbug::Error->new(
    kind    => $kind,
    code    => $code,
    message => $message,
    stderr  => $transport->stderr,
  );
  $self->{dead} = $error;
  $transport->abort;
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

  # a transport failure has already closed the transport
  my $reply_line = eval { $self->{transport}->exchange($line, $timeout) };
  unless(defined $reply_line) {
    my $error = $@;
    $self->{dead} = $error;
    die $error;
  }

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

=head1 MOJOLICIOUS

L<Mojolicious> is optional.  It is never loaded by this module; when a L<Mojo::Message::Request>,
L<Mojo::Message::Response> or L<Mojo::Transaction::HTTP> is passed to L</validate>, it is converted
to the request and response hashes described there, and then validated exactly like them.  The Mojo
objects are only read, never changed.  Mojolicious 9.0 or later is supported.

=over 4

=item Requests

The method is sent as is.  The URL is Mojo's effective absolute URL (C<< $req->url->to_abs >>)
without its fragment or credentials.  A relative request URL is resolved against the base URL Mojo
keeps for it: on the server, from the connection and the C<Host> header; for a request parsed from
raw text, from C<Host> with scheme C<http>.  If Mojo has no scheme and host to resolve it against,
C<validate> throws an C<argument> error rather than guess.  Mojo stores the path and query as
received, but percent-encodes characters that are not allowed in a URL.

=item Responses

The status code is required: a response Mojo has not received or generated yet is an C<argument>
error.

=item Headers

Every header line is sent, and repeated lines (C<Set-Cookie> in particular) stay separate lines in
their original order.  Two things are lost inside Mojo before this module sees the message: the
relative order of lines with B<different> names (Mojo groups them by name and sorts the names), and
the original casing of common names (Mojo uses its canonical casing, such as C<Content-Type>, and
otherwise the casing of the first line with that name).  A folded (multi-line) value is joined with a
space.  Header values are the bytes Mojo holds.

=item Bodies

The body is the bytes Mojo holds for the message, never re-serialized.  Mojo has already removed
chunked transfer encoding, and, where it decompressed a body (its user agent does so for C<gzip>
responses), it also removed the C<Content-Encoding> header; a body Mojo did not decompress is sent
as is, still encoded.  Some bodies have no faithful bytes, and are an C<argument> error: a body that
is still being received, a streamed (dynamic) body, and a C<multipart> body, which Mojo keeps only
as parsed parts.

Mojo does not record whether a message had no body or an empty one, so the HTTP rules decide
(RFC 9112 section 6.3).  A request has a body if it has data, a C<Content-Length> or a
C<Transfer-Encoding>; otherwise it has none.  A response to C<HEAD> (when the request is known), and
a C<1xx>, C<204> or C<304> response, has no body; any other response has one, possibly empty.

=item Transactions

C<< validate($tx) >> validates C<< $tx->req >>, and C<< $tx->res >> only if the response is
complete: it has a status code and Mojo has finished it, that is received it in full (client side)
or sent it in full (server side).  Otherwise the response is left out, and only the request is
checked; asking for it with C<< validate => { response => 1 } >> is then an C<argument> error.  On
the server, before the response has been sent (in an C<after_dispatch> hook, for example), pass
C<< request => $tx->req, response => $tx->res >> instead.  Only C<validate> may follow the
transaction.

=back

L<OpenAPI::Humbug::Adapter::Mojo> does the conversion; it is internal and not a supported interface.

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
sidecar's C<code>), or the connection or protocol failed (C<transport>, C<protocol>, C<timeout>).  A
failure is never reported as a valid or invalid result.

=back

After an C<argument> or C<sidecar> error the client can be used again.  After a C<transport>,
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

=head1 JSON

L<Cpanel::JSON::XS> 4.38 or later is used if it is installed, and L<JSON::PP> otherwise.  Either way
results are the same.  L<Cpanel::JSON::XS> is optional, but recommended for large bodies or many
transactions.

=head1 PLATFORMS

Linux and macOS.  Windows is not supported yet.

=head1 SEE ALSO

=over 4

=item L<OpenAPI::Humbug::Error>

=item L<Humbug client guide|https://github.com/uperl/go-humbug/blob/main/docs/client-guide.md>

=item L<Humbug protocol|https://github.com/uperl/go-humbug/blob/main/docs/protocol.md>

=back

=cut
