# OpenAPI::Humbug ![static](https://github.com/uperl/OpenAPI-Humbug/workflows/static/badge.svg) ![linux](https://github.com/uperl/OpenAPI-Humbug/workflows/linux/badge.svg)

Humbug OpenAPI client

# SYNOPSIS

```perl
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
```

# DESCRIPTION

This module validates captured HTTP transactions against an OpenAPI 3.1 specification using
[humbug](https://github.com/uperl/go-humbug), a validator that runs as a persistent child
process and speaks a line-oriented JSON protocol over its stdin and stdout.

The Perl side only manages the process and carries data faithfully; all OpenAPI semantics live in
the sidecar.  Each client starts one child, loads one specification into it once, and then
validates any number of transactions through it, one at a time.

The `humbug` executable is a separate program that must be installed on its own; see
["INSTALLING HUMBUG"](#installing-humbug).

# CONSTRUCTOR

## new

```perl
my $humbug = OpenAPI::Humbug->new(%options);
```

Starts the sidecar, initializes it with the specification, and waits for it to confirm.  Throws an
[OpenAPI::Humbug::Error](https://metacpan.org/pod/OpenAPI::Humbug::Error) on any failure (for example `kind` `sidecar` with `code`
`spec.invalid` for a broken specification), after terminating and reaping the child.

Options:

- spec

    Required.  The path of a local OpenAPI 3.1 specification file.  A relative path is resolved against
    the current working directory at the time `new` is called, and the absolute path is sent to the
    sidecar, so changing directory later has no effect.  The child also inherits the working directory
    from the caller.

- executable

    The `humbug` executable.  If it contains a slash it is used as is; otherwise it is looked up in
    `PATH`.  Defaults to `humbug`.  The executable is always run directly, never through a shell.

- args

    An array reference of extra command-line arguments for the executable, for example
    `['-max-body-bytes', 1048576]`.  Resource limits are set this way, never over the protocol.

- timeout

    How long to wait for the reply to any one command (including `initialize`), in seconds.
    Defaults to 60.  A timeout terminates the child and makes the client unusable; the command is not
    retried.

- max\_reply\_bytes

    The longest reply line accepted from the sidecar, in bytes, to bound memory if the child
    misbehaves.  Defaults to 64 MiB.

- max\_stderr\_bytes

    How much of the sidecar's stderr to keep (the most recent bytes).  stderr is always drained so a
    noisy child cannot block; only this much is retained.  Defaults to 64 KiB.

# ATTRIBUTES

## specification

```perl
my $hash = $humbug->specification;
```

The `specification` object from the `initialize` reply, such as `openapi_version` and `title`.

## limits

```perl
my $hash = $humbug->limits;
```

The resource limits the sidecar reported, such as `max_body_bytes`, or `undef` if it reported
none.  The set of keys belongs to the sidecar; treat a missing key as unknown.

## implementation

```perl
my $hash = $humbug->implementation;
```

The `implementation` object from the `initialize` reply (`name`, `version`, `libraries`), or
`undef`.  It is for logs and bug reports; do not branch on it.

## stderr

```perl
my $text = $humbug->stderr;
```

The most recent bytes (up to `max_stderr_bytes`) the sidecar wrote to stderr.  A healthy sidecar
normally writes nothing.

## spec

## executable

## args

## timeout

## max\_reply\_bytes

## max\_stderr\_bytes

The constructor options, with defaults applied.  `spec` is the absolute path sent to the sidecar
and `executable` the path that was run.  Changing them after construction has no effect on the
running child, except that `timeout` applies to later commands.

# METHODS

## validate

```perl
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
```

Validates one HTTP transaction and returns the sidecar's complete `result` object as a hash
reference.  A transaction that violates the specification, or that could not be fully checked, is
still a result; it is never an exception.

`request` and `response` may each be a hash reference, as described below, or a
[Mojo::Message::Request](https://metacpan.org/pod/Mojo::Message::Request) or [Mojo::Message::Response](https://metacpan.org/pod/Mojo::Message::Response); a [Mojo::Transaction::HTTP](https://metacpan.org/pod/Mojo::Transaction::HTTP) may be passed
first in place of both.  See ["MOJOLICIOUS"](#mojolicious) for how those are converted.

The request is a hash reference with these keys:

- method

    Required.  The HTTP method as captured.  Case is not normalized.

- url

    Required.  The effective absolute URL as captured (scheme, host, path and query; no fragment).
    It is not normalized.

- headers

    Optional.  The header lines as an array reference of `[$name, $value]` pairs; see ["HEADERS"](#headers).

- body

    Optional.  The decoded body as a byte string; see ["BODIES"](#bodies).

The response, if given, has the same `headers` and `body` keys, plus:

- status

    Required.  The integer status code, 100 to 599.

`validate` selects which sides are checked: `request` defaults to true, and `response` defaults
to true if and only if a response was given.  Values are interpreted as Perl booleans.  Asking for the
response without a response, or turning both off, is refused by the sidecar.

Unknown keys, references where strings are expected, and similar mistakes throw an exception of
`kind` `argument` before anything is sent.

## close

```
$humbug->close;
```

Sends `shutdown` if the child is still usable, closes the pipes, and reaps the child, terminating
it if it does not exit promptly (after the smaller of `timeout` and 5 seconds, then `SIGTERM`, then
`SIGKILL`).  Returns true if the child exited cleanly with status 0.  Calling it again is harmless.
It does not throw.

Dropping the last reference to the client does the same on a best-effort basis, but an explicit
`close` is recommended.

# MOJOLICIOUS

[Mojolicious](https://metacpan.org/pod/Mojolicious) is optional.  It is never loaded by this module; when a [Mojo::Message::Request](https://metacpan.org/pod/Mojo::Message::Request),
[Mojo::Message::Response](https://metacpan.org/pod/Mojo::Message::Response) or [Mojo::Transaction::HTTP](https://metacpan.org/pod/Mojo::Transaction::HTTP) is passed to ["validate"](#validate), it is converted
to the request and response hashes described there, and then validated exactly like them.  The Mojo
objects are only read, never changed.  Mojolicious 9.0 or later is supported.

- Requests

    The method is sent as is.  The URL is Mojo's effective absolute URL (`$req->url->to_abs`)
    without its fragment or credentials.  A relative request URL is resolved against the base URL Mojo
    keeps for it: on the server, from the connection and the `Host` header; for a request parsed from
    raw text, from `Host` with scheme `http`.  If Mojo has no scheme and host to resolve it against,
    `validate` throws an `argument` error rather than guess.  Mojo stores the path and query as
    received, but percent-encodes characters that are not allowed in a URL.

- Responses

    The status code is required: a response Mojo has not received or generated yet is an `argument`
    error.

- Headers

    Every header line is sent, and repeated lines (`Set-Cookie` in particular) stay separate lines in
    their original order.  Two things are lost inside Mojo before this module sees the message: the
    relative order of lines with **different** names (Mojo groups them by name and sorts the names), and
    the original casing of common names (Mojo uses its canonical casing, such as `Content-Type`, and
    otherwise the casing of the first line with that name).  A folded (multi-line) value is joined with a
    space.  Header values are the bytes Mojo holds.

- Bodies

    The body is the bytes Mojo holds for the message, never re-serialized.  Mojo has already removed
    chunked transfer encoding, and, where it decompressed a body (its user agent does so for `gzip`
    responses), it also removed the `Content-Encoding` header; a body Mojo did not decompress is sent
    as is, still encoded.  Some bodies have no faithful bytes, and are an `argument` error: a body that
    is still being received, a streamed (dynamic) body, and a `multipart` body, which Mojo keeps only
    as parsed parts.

    Mojo does not record whether a message had no body or an empty one, so the HTTP rules decide
    (RFC 9112 section 6.3).  A request has a body if it has data, a `Content-Length` or a
    `Transfer-Encoding`; otherwise it has none.  A response to `HEAD` (when the request is known), and
    a `1xx`, `204` or `304` response, has no body; any other response has one, possibly empty.

- Transactions

    `validate($tx)` validates `$tx->req`, and `$tx->res` only if the response is
    complete: it has a status code and Mojo has finished it, that is received it in full (client side)
    or sent it in full (server side).  Otherwise the response is left out, and only the request is
    checked; asking for it with `validate => { response => 1 }` is then an `argument` error.  On
    the server, before the response has been sent (in an `after_dispatch` hook, for example), pass
    `request => $tx->req, response => $tx->res` instead.  Only `validate` may follow the
    transaction.

[OpenAPI::Humbug::Adapter::Mojo](https://metacpan.org/pod/OpenAPI::Humbug::Adapter::Mojo) does the conversion; it is internal and not a supported interface.

# HEADERS

Headers are an ordered array reference of `[$name, $value]` pairs, never a hash, because HTTP
headers are ordered lines that may repeat:

```perl
headers => [
  ['Content-Type', 'application/json'],
  ['Set-Cookie',   'a=1'],
  ['Set-Cookie',   'b=2'],
  ['X-Empty',      ''],
],
```

Order, repeats, name casing, empty values and whitespace are sent exactly as given.  Lines are never
combined (in particular `Set-Cookie`), split, trimmed or merged.  Every pair must have
exactly two elements.

Header values are byte strings.  Every value is sent base64-encoded, which the protocol allows for
any value, so values that are not valid UTF-8 travel unchanged.  Names are sent as text and never
encoded; a header name is ASCII in practice, and the sidecar rejects one that is not an HTTP token
with a `validator.unsupported_input` error.

# BODIES

`body` is the HTTP body as a byte string, **after** any transfer and content decoding (gzip and so
on): exactly the bytes the application saw.  It is not a Perl data structure; pass
`encode_json($data)` yourself if that is what you have, and remember that the sidecar judges the
bytes it receives.  References are rejected rather than serialized.

- A missing `body` key, or `body => undef`, means the message has no body.
- `body => ''` means the message has a body of zero bytes.  The two are not the same:
for an operation that requires a body, the first is reported as `body.required` and the second as
`body.decode`.

The body is never parsed, re-serialized, compressed or decompressed.  A `Content-Encoding` header
is passed through but ignored by the sidecar, so send decoded bytes.  Diagnostic spans are byte
offsets into the body you sent.

# BYTES AND CHARACTERS

Header values and bodies are bytes.  If you have a Perl character string (for example JSON text
from a decoder), encode it first with `Encode::encode('UTF-8', $text)`.  A string containing a
character above `0xFF` cannot be bytes and is rejected with an `argument` error rather than
guessed at.  A string with Perl's internal UTF-8 flag on but only characters up to `0xFF` is
treated as the bytes those characters denote, as Perl's own I/O would.

`method`, `url` and header names are text.  They are encoded as UTF-8 in the JSON sent to the
sidecar.  An effective URL is ASCII (percent-encoded) as it appeared on the wire, so send it that
way.

# RESULTS

`validate` returns the sidecar's `result` object unchanged, with JSON booleans as Perl's
`true` and `false`.  Unknown fields and diagnostic codes are preserved.  The important fields:

- `valid`, `complete`, `has_violations`

    For the transaction (over the sides that were checked).  `valid` is true only if the checks
    completed and found no violations.  Decide on `valid`, not on `has_violations` alone.

- `request`, `response`

    Each side has a `status` (`valid`, `invalid`, `incomplete` or `skipped`), its own `valid`,
    `complete` and `has_violations`, and an ordered `diagnostics` array.  A side that was not
    checked is `skipped` and never `valid`.

- diagnostics

    Each has `id`, `code`, `severity` (`error`, `warning` or `info`), `message`, and where
    relevant `instance`, `schema`, `detail`, `operation` and the relationships `parent`,
    `children`, `caused_by` and `suppressed_by`.  Suppressed diagnostics are kept; hide them in a
    display if you like.  Warnings and info do not make a transaction invalid.  Use the
    machine-readable fields, never `message`.

See the sidecar's [diagnostics documentation](https://github.com/uperl/go-humbug/blob/main/docs/diagnostics.md)
for the codes.  The findings for a given input may change between sidecar releases.

# ERRORS

There are three different outcomes, and they must not be confused:

- Invalid

    `validate` returns a result with `valid` false and `has_violations` true: the transaction
    violates the specification.

- Incomplete

    `validate` returns a result with `complete` false: something could not be checked (a body over
    the size limit, an unsupported media type, an unknown operation, ...).  Such a result is not valid,
    but not necessarily a violation either.  `validation.incomplete` diagnostics say why.

- Failure

    `validate` throws an [OpenAPI::Humbug::Error](https://metacpan.org/pod/OpenAPI::Humbug::Error): there is no verdict at all.  Its `kind` says
    whether the arguments were bad (`argument`), the sidecar refused the command (`sidecar`, with the
    sidecar's `code`), or the connection or protocol failed (`transport`, `protocol`, `timeout`).  A
    failure is never reported as a valid or invalid result.

After an `argument` or `sidecar` error the client can be used again.  After a `transport`,
`protocol` or `timeout` failure the child is terminated and the client is unusable: further calls
throw `closed`.  Nothing is restarted or retried automatically; construct a new client if you want
to continue.

# PROCESS LIFETIME

- `new` starts one child and initializes it with one specification.  The specification cannot
be changed afterwards; create another client for another specification.
- `validate` may be called any number of times.  Commands are sent one at a time.
- `close` shuts the child down and reaps it.  Destroying the object does the same, best
effort.
- A client must not be shared between threads, or used in a child process after `fork`;
create a new client in each process.  A forked copy of the object never touches the parent's child.

# INSTALLING HUMBUG

The `humbug` executable comes from [go-humbug](https://github.com/uperl/go-humbug) and is a
separate, runtime-only prerequisite; this distribution never builds or downloads it, and Go is not
needed at runtime.  With Go installed:

```
go install github.com/uperl/go-humbug/cmd/humbug@latest
```

or build it from a checkout with `make build` and pass the path as `executable`.

# TESTING

The unit tests use a fake sidecar and need neither Go nor `humbug`.  The integration tests run
against a real `humbug` if `OPENAPI_HUMBUG_EXECUTABLE` names one, and are skipped otherwise:

```
OPENAPI_HUMBUG_EXECUTABLE=/path/to/humbug prove -lv t/integration.t
```

# JSON

[Cpanel::JSON::XS](https://metacpan.org/pod/Cpanel::JSON::XS) 4.38 or later is used if it is installed, and [JSON::PP](https://metacpan.org/pod/JSON::PP) otherwise.  Either way
results are the same.  [Cpanel::JSON::XS](https://metacpan.org/pod/Cpanel::JSON::XS) is optional, but recommended for large bodies or many
transactions.

# PLATFORMS

Linux and macOS.  Windows is not supported yet.

# SEE ALSO

- [OpenAPI::Humbug::Error](https://metacpan.org/pod/OpenAPI::Humbug::Error)
- [Humbug client guide](https://github.com/uperl/go-humbug/blob/main/docs/client-guide.md)
- [Humbug protocol](https://github.com/uperl/go-humbug/blob/main/docs/protocol.md)

# AUTHOR

Graham Ollis <plicease@cpan.org>

# COPYRIGHT AND LICENSE

This software is copyright (c) 2026 by Graham Ollis.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.
