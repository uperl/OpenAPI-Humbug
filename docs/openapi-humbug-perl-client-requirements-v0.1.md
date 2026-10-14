# OpenAPI::Humbug — Perl Client Requirements v0.1

**Status:** Proposed MVP requirements  
**Backend:** [uperl/go-humbug](https://github.com/uperl/go-humbug)  
**Protocol:** Humbug NDJSON protocol v1  
**Perl distribution:** `OpenAPI::Humbug`  
**Purpose:** Validate captured HTTP transactions against OpenAPI 3.1 using a persistent external sidecar.

## 1. Goals

Build a small, synchronous Perl client that starts `humbug`, initializes it once with a local OpenAPI specification, submits many HTTP transactions, and returns the backend's structured validation results. The Perl layer is responsible for process management, protocol framing, and faithful data transfer—not OpenAPI validation or diagnostic interpretation.

Pre-1.0 breaking changes are acceptable. Optimize for correctness and use in the author's projects, not for a large framework abstraction.

### MVP includes

- Executable discovery and configurable path.
- One persistent child process per client instance; one OpenAPI spec per child.
- Request-only and request/response validation, including selecting which sides to check.
- Lossless transfer of headers and body bytes.
- Structured results, distinct from process/protocol failures.
- Explicit shutdown, error handling, unit tests, and opt-in integration tests.

### Explicitly deferred

- HTTP::Request/Response, Mojo, Plack, and other adapters.
- HTTP capture, network requests, automatic gzip/transfer decoding, or JSON serialization of payload objects.
- Async operation, pipelining, concurrency, pooling, automatic retries, or multiple specifications per child.
- Rendering diagnostics as TAP, pretty reports, or editor annotations.
- Downloading/building/bundling the Go binary or implementing OpenAPI semantics in Perl.

## 2. Proposed API

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

if (!$result->{valid}) {
    for my $d (@{ $result->{request}{diagnostics} }) {
        next if defined $d->{suppressed_by};
        warn "$d->{code}: $d->{message}\n";
    }
}

$humbug->close;
```

- `new(spec => ..., executable => ...)` starts and initializes the process; errors throw exceptions.
- `validate(request => ..., response => ..., validate => ...)` returns the **full `result` hashref** from the sidecar. `request` is required; `response` and `validate` are optional.
- `validate => { request => 0|1, response => 0|1 }` controls checks, following protocol defaults if omitted.
- `close` sends `shutdown` if possible and reaps the process; repeated calls are harmless.
- Read-only accessors `implementation`, `specification`, and `limits` expose optional initialization metadata.
- `body` is a byte scalar, **not** a Perl data structure. The client converts it to `body_base64` internally. Reject references instead of silently serializing them.
- Prefer ordinary Perl hashes/arrays for results; no elaborate diagnostic object hierarchy in v0.1.

## 3. Process lifecycle

1. Find the executable at an explicit path or via `PATH`; never invoke it through a shell.
2. Start a persistent subprocess with distinct stdin, stdout, and stderr channels.
3. Send `initialize` with `protocol_version: 1` and `spec: { path: ... }`; await a successful matching reply before returning from `new`.
4. Use a local spec path with documented working-directory semantics; preferably resolve it to an absolute path.
5. Cache the optional `limits` and `implementation` and required `specification` metadata. Do not branch on the backend implementation version.
6. On failed initialization, close pipes and reap/terminate the child.
7. Allow repeated `validate` calls on one process; do not reinitialize it with a new spec.
8. `close` should shut down and reap the child. `DESTROY` performs best-effort cleanup without throwing or hanging.
9. A client instance is not safe to share across threads or use after `fork`; create a new client in each process.

**stderr must not be merged into stdout.** Drain stderr so a noisy backend cannot deadlock. A bounded capture with a dedicated reader or equivalent is acceptable. Avoid echoing payloads in exceptions.

## 4. NDJSON transport

- Serialize **exactly one JSON object per line**, newline-terminated, to stdin.
- Read one complete JSON reply per command, and verify `id` and `type`.
- Generate unique monotonically increasing integer IDs per client instance.
- Allow only one command in flight; no pipelining in MVP.
- Use an appropriate JSON encoder/decoder preserving real JSON booleans and Unicode semantics.
- Treat HTTP body and header values as bytes, not text requiring character transcoding.
- Reject malformed replies, mismatched IDs, unexpected EOF, excessive reply length, and protocol desynchronization as transport/protocol failures.
- Support a configurable per-command timeout with a documented finite default. A timeout makes the instance unusable; terminate/reap the child, and **do not retry the in-flight transaction**.
- A process death is not an invalid OpenAPI transaction. Never synthesize `valid => 0` or `valid => 1` for a transport failure.
- Accept unknown optional reply fields and diagnostic codes. Preserve them rather than stripping them.

The normative schema is [schema/protocol.schema.json](https://github.com/uperl/go-humbug/blob/main/schema/protocol.schema.json).

## 5. HTTP input fidelity

### Requests and responses

A request requires `method` and effective absolute `url`. A response, when supplied, requires integer `status` (100–599). Both may include `headers` and `body`.

Do not normalize method case, URLs, paths, query strings, or content. The effective URL should be sent as captured, without a fragment. Host/scheme/port matching is a backend concern.

### Headers

- **Require an ordered arrayref of entries**, not a hashref.
- Preserve order, duplicates, casing, empty values, whitespace, and raw bytes. In particular, never combine `Set-Cookie` lines.
- Expose `[name, raw_value]` as the primary high-level representation.
- Encode values as wire `[name, base64(value), true]` when needed; **recommended MVP simplification: encode every header value as base64**, which the protocol explicitly allows.
- Never base64-encode header *names*.
- Reject invalid Perl input shapes instead of guessing or repairing them.
- Document the distinction between Perl Unicode character scalars and raw byte scalars; avoid silent double-encoding or corruption.

### Bodies

- Convert a defined `body` byte scalar to standard RFC 4648 padded base64 without line breaks.
- **Absent `body` means no body; `body => ''` means an explicitly present zero-byte body.** Preserve that distinction.
- Do not parse, reserialize, normalize, compress, or decompress bodies.
- The caller must first decode transfer/content encoding. Preserve the original `Content-Encoding` header; the backend ignores it for decoding.
- Diagnostic byte offsets refer to the exact bytes supplied.

## 6. Results and exceptions

A successful `validate` command returns a result even when the HTTP exchange is invalid or incomplete.

- Preserve transaction-level `valid`, `complete`, and `has_violations` separately. `valid` is true only if complete and without violations.
- Preserve request/response side status, diagnostics, operation, IDs, pointers, spans, severity, details, and diagnostic relationships (`parent`, `children`, `caused_by`, `suppressed_by`).
- Do not discard suppressed diagnostics. Presentation code may choose to hide them.
- Warnings and info diagnostics are not automatically contract violations.
- A `type: error` reply must throw a structured or distinguishable exception containing `error.code` and `error.message`; it is **not** a validation result.
- Local argument errors, sidecar errors, transport failures, and timeouts should be distinguishable without parsing human messages.
- Do not parse diagnostic `message` strings to make decisions; use machine-readable `code`, `severity`, `detail`, and other fields.
- Unknown diagnostic codes, optional fields, and incomplete reasons must not break the client.
- Do not pin exact findings across backend versions; the backend's versioning policy explicitly allows them to change.

## 7. Limits and safety

- Expose the backend's optional initialization `limits` without hard-coding an exhaustive set of keys.
- Respect the backend's line, body, nesting, and header limits; preflight checks are optional, but must not convert backend `incomplete` results into fabricated exceptions.
- Set a configurable maximum **reply** line length to bound memory use from a faulty subprocess.
- Bound stderr capture and subprocess wait times.
- Never log raw HTTP payloads or sensitive header values by default.
- No automatic restart/replay after a child failure; caller may construct a fresh client explicitly.

## 8. Perl packaging

- Distribute as `OpenAPI::Humbug`, with conventional CPAN metadata, README, `t/` tests, and an explicit license.
- Pick and document a supported minimum Perl version before implementation.
- Prefer a small set of established dependencies (e.g. a reliable JSON library, `MIME::Base64`, and a process-management solution with safe stderr handling and timeouts).
- Support Linux and macOS for MVP. Windows is deferred until subprocess behavior is tested.
- The `humbug` binary is a separate runtime prerequisite. The Perl distribution must not require Go at runtime.

## 9. Test plan

### Unit tests (fake sidecar; no Go binary required)

1. Initialization, one validation, repeated validations, shutdown, and idempotent close.
2. Matching IDs; detection of mismatched/null IDs and unexpected reply types.
3. `type: error` versus invalid (`valid: false`) and incomplete results.
4. Unknown diagnostic codes/fields passed through unchanged.
5. Header ordering, duplicates, empty values, non-UTF-8 values, and exact wire base64.
6. Body absent versus empty; binary bodies; UTF-8-flag edge cases.
7. Bad Perl input rejected before sending a malformed command.
8. Malformed JSON reply, unexpected EOF, child exit, broken pipe, and command timeout.
9. Stderr cannot corrupt stdout or deadlock the process.
10. Cleanup after construction failure and after errors; no zombies.

### Integration tests (real sidecar; opt-in if unavailable)

- Initialize from a checked-in OpenAPI 3.1 fixture.
- Valid request, invalid request, request plus response, response-only check via selector, warning-only result, and incomplete result.
- Invalid specification fails initialization with a useful code/message.
- Multiple transactions use the same child.
- Assert semantic properties and representative diagnostic codes, not entire golden JSON replies or human-readable messages.
- Document the command to run these tests locally and in CI.

## 10. Documentation

The README must include installation of the Perl module and separate Go executable, minimal request-only and request/response examples, the header array representation, byte/body handling, absent-versus-empty semantics, lifecycle and error handling, and how to distinguish invalid, incomplete, and operational failures.

Authoritative sidecar references:

- [Client guide](https://github.com/uperl/go-humbug/blob/main/docs/client-guide.md)
- [Protocol](https://github.com/uperl/go-humbug/blob/main/docs/protocol.md)
- [Diagnostics](https://github.com/uperl/go-humbug/blob/main/docs/diagnostics.md)
- [Versioning](https://github.com/uperl/go-humbug/blob/main/docs/versioning.md)
- [Protocol schema](https://github.com/uperl/go-humbug/blob/main/schema/protocol.schema.json)

## 11. MVP acceptance criteria

The Perl client is MVP-ready when:

- It starts and initializes a real Humbug sidecar and validates multiple transactions through one process.
- It faithfully preserves HTTP header lines and raw body bytes, including duplicates and absent/empty distinctions.
- It returns complete structured results for valid, invalid, and incomplete exchanges.
- Operational errors are distinct from contract violations; failures never silently become success.
- It cleans up children and pipes reliably.
- Fake-sidecar tests pass without Go; real-sidecar integration tests pass when the binary is available.
- Its public API is small, documented, and usable in the author's actual Perl workflow.

## 12. Decisions before coding

1. Minimum supported Perl version.
2. JSON implementation and explicit Unicode/byte policy.
3. Process management library/strategy, including stderr draining and timeouts.
4. Whether to always base64-encode header values (recommended) or only when necessary.
5. Timeout defaults and exception representation.

**Recommended first implementation:** synchronous, eager initialization, one child per object, byte-oriented `body`, all header values base64 on the wire, hashref results, explicit `close`, and fake-sidecar transport tests before adapters or formatting helpers.
