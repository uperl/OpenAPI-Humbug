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
```

Validates one HTTP transaction and returns the sidecar's complete `result` object as a hash
reference.  A transaction that violates the specification, or that could not be fully checked, is
still a result; it is never an exception.

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
    sidecar's `code`), or the process or protocol failed (`process`, `protocol`, `timeout`).  A
    failure is never reported as a valid or invalid result.

After an `argument` or `sidecar` error the client can be used again.  After a `process`,
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
