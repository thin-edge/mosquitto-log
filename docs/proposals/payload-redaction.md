# Proposal: Redacting sensitive data in MQTT payloads (thin-edge.io)

Status: **Phase 1 implemented** (`plugin/redact.c`, `plugin/redact.h`)
Date: 2026-07-07

## 1. Problem

The logger persists MQTT payloads to disk (and optionally stderr) verbatim.
Some thin-edge.io / Cumulocity payloads carry secrets — JWT tokens, device
passwords, API keys. Two shapes occur:

1. **Structured (JSON)** — the secret is the value of a well-known key, e.g.
   `{"password":"hunter2"}` or `{"access_token":"ey..."}`. Identifiable by the
   **key name**.
2. **Unstructured (SmartREST text)** — the payload is comma-delimited text with
   no key. The **topic** identifies it as sensitive (e.g. the Cumulocity JWT and
   device-credentials responses).

Matching values must be masked **before they are written**, so secrets never
touch the log files or stderr.

This tool is thin-edge.io–specific, so the rules are **hard-coded** in the
plugin — no config files, no env vars, no fail-closed startup logic. Adding a
rule is a small source edit + rebuild.

## 2. The one constraint that drives the design

Every file record carries the payload in **three** representations, and stderr a
fourth:

| Field            | Where  | Derived from |
|------------------|--------|--------------|
| `payload`        | file   | raw bytes → JSON-escaped string |
| `payload_json`   | file   | raw bytes → minified native JSON |
| `payload_base64` | file   | raw bytes → base64 (**always present**) |
| `payload_hex`    | stderr | raw bytes → hex |

If we only rewrite the readable `payload`, the secret is still recoverable from
`payload_base64` / `payload_hex`. So **redaction rewrites the raw byte buffer
once, and every representation is derived from the redacted buffer.**

This is also why redaction lives in the **plugin (write-side)**: it is the only
place that keeps secrets off disk. (A read-side `mqtt-log --redact` would leave
the on-disk file unchanged, so it's not the control we want.)

## 3. Placement in the message path

`callback_message` currently points `r.payload`/`r.payloadlen` at the broker's
buffer and calls `emit_log()`, which renders all four representations. We insert
one redaction step that returns a possibly-rewritten buffer; `emit_log()` then
renders every representation from it.

```
callback_message
  └─ build log_record (topic, qos, ...)
  └─ redact(topic, payload, len) → {buf, len, changed}     ← NEW (zero-copy if nothing matches)
  └─ emit_log() renders payload / payload_json / payload_base64 / payload_hex
     all from the (possibly redacted) buffer
  └─ free the redacted buffer if one was allocated
```

Runs once per message; all encodings share the result. No match → original
buffer returned unchanged, no allocation.

## 4. The hard-coded rules

A single `redact(topic, payload, len)` entry point applies, in order:

### 4.1 Topic rules (checked first, exact topic match)

| Topic         | Payload format                       | Action |
|---------------|--------------------------------------|--------|
| `c8y/s/dat`   | `71,<jwt>`                           | keep `71,`; mask everything after the first comma |
| `c8y/s/dcr`   | `70,<tenant>,<username>,<password>`  | keep `70,<tenant>`; mask fields 3+ (username, password) |

These are fixed SmartREST shapes, so the implementation is a trivial
comma-field masker — split on `,`, keep the leading field(s), replace the rest
with the mask. **No regex engine required.** Topics are matched exactly (the
plugin runs on the thin-edge local broker where these arrive as
`c8y/s/dat` / `c8y/s/dcr`).

> If a topic rule fires, JSON-key redaction is skipped for that message (these
> payloads aren't JSON anyway).

### 4.2 JSON-key rule (applied to any other payload that parses as JSON)

Redact the **value** of any object member whose key matches, at any depth,
**case-insensitively**:

```
password   token   access_token   secret   apikey
```

Implementation walks the jsmn token stream the plugin already produces (jsmn is
vendored and already used by `payload_to_minified_json`):

- For each object-member **key** token matching the set, replace its **value**
  token's byte span `[start,end]` with the mask string `"***"`.
- A matched value that is a nested object/array (`token.end` spans the whole
  subtree) is replaced wholesale — the entire subtree is masked.
- Matching is structural, so a same-named **string value**
  (`{"note":"the password is safe"}`) is **not** touched — only keys.

The rewritten bytes become the canonical payload; `write_payload_fields()` then
re-validates/minifies as normal, so `payload_encoding` stays `json` and
`payload_json` remains valid JSON with masked values.

### 4.3 Mask

A single fixed constant, e.g.:

```c
#define REDACT_MASK "***"
```

(Kept as one `#define` so it's a one-line change if the placeholder ever needs
to differ.)

## 5. Implementation sketch

New `plugin/redact.c` + `redact.h`, compiled into the plugin by `build.zig`:

```c
/* Returns 1 and sets *out/*outlen to a malloc'd redacted buffer (caller frees)
 * when something was redacted; returns 0 and touches nothing otherwise. */
int redact_payload(const char *topic,
                   const void *payload, uint32_t len,
                   void **out, uint32_t *outlen);
```

- `redact_smartrest_fields(payload, len, keep_fields)` — comma masker for §4.1.
- `redact_json_keys(payload, len, ...)` — jsmn walk for §4.2.
- `callback_message` calls `redact_payload`; if it returns 1, point the record
  at the new buffer, `emit_log()`, then free it.

Everything else (config loading, regex, env vars, fail-closed) from the earlier
draft is **dropped**.

## 6. Testing

- **Unit tests** for `redact.c`: table of (topic, payload) → expected bytes.
  Assert the secret is absent from the output — the test decodes what would
  become `payload_base64`, not just `payload`.
- **Docker functional tests** (`tests/`): publish the real thin-edge shapes and
  assert with the existing CLI:
  ```bash
  # secret never lands on disk, in any representation
  mqtt-log --topic 'c8y/s/dat' --payload-contains '<jwt>' --max-count 0 -q
  # the mask did land
  mqtt-log --topic 'c8y/s/dat' --payload-contains '***' --min-count 1 -q
  ```
- Edge cases: nested JSON, key as a string value (must survive), duplicate keys,
  malformed JSON (no JSON rule fires → logged as-is), binary payloads (JSON rule
  can't parse → unchanged; topic rules still apply), `c8y/s/dcr` with a missing
  field, mask longer/shorter than the original span (buffer sizing).

## 7. Notes

- Redact **before** every encoding — the base64/hex leak is the classic mistake.
- Zero-copy when nothing matches; keep the broker hot path allocation-light.
- Adding a JSON key or a new sensitive topic is a small edit to the rule table +
  rebuild — acceptable for a thin-edge-specific tool.
- README: document the fixed rule set so operators know what is and isn't
  masked (and that pre-existing logs written before an upgrade are not
  retroactively redacted).

## 8. Decisions & open questions

1. ~~On `c8y/s/dcr`, mask both username and password, or the password only?~~
   **Resolved: mask both** (`70,<tenant>,***,***`).
2. Any additional sensitive topics beyond the two Cumulocity flows (e.g.
   config-operation URLs that embed tokens)? — *open; add to the topic table in
   `redact_payload()` when identified.*
3. ~~Stamp a `"redacted":true` field on affected records for auditability?~~
   **Resolved: implemented.** Records whose payload was masked carry
   `"redacted":true` (file + stderr); untouched records omit it, so they stay
   byte-identical to before.
