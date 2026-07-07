# Mosquitto Message Logger Plugin

A standalone Mosquitto broker plugin that logs MQTT messages and control-plane events with comprehensive metadata to file and/or stderr.

## Features

- **File logging**: Append-only JSON log files with daily rotation
- **Stderr logging**: Optional mosquitto_sub compatible format with `MQTT_LOG:` prefix
- **Control-plane events**: Beyond publishes, logs connect/disconnect/subscribe/unsubscribe, each tagged with a `type` field for easy filtering (see [Logged event types](#logged-event-types))
- **Multi-representation payloads**: each file record carries the payload as an escaped string, native minified JSON (when applicable), and always as canonical base64 — tagged with `payload_encoding` for easy parsing (see [Payload Encoding](#payload-encoding))
- **Smart payload handling**: binary payloads are automatically detected and stored as base64 only
- **Rich metadata**: ISO 8601 timestamp + nanosecond Unix-epoch timestamp, event type, topic, QoS, retain flag, payload length, client ID
- **Configurable**: Via environment variables
- **Auto-creating directories**: Log directories are created automatically if they don't exist
- **Cross-compilation support**: Build for multiple architectures (ARM64, ARMv7, x86_64, etc.)
- **Companion query CLI**: [`mqtt-log`](#querying-logs-with-mqtt-log) filters and formats the log files (by time, topic, type, payload, and more), reads archived `.gz` logs, and is built and released alongside the plugin

## Requirements

- [Zig](https://ziglang.org/download/) 0.16.0 or later (`brew install zig`) — bundles its own C compiler and cross-compiles to every target
- A running **Mosquitto 2.1.x** broker (plugin API v5) to load the plugin into
- Optional: `just` command runner (`brew install just`)

The mosquitto development headers are **not** required: the build downloads the
matching v2.1.2 headers automatically (declared in `build.zig.zon`).

## Building

Zig drives the whole build: it bundles a C compiler and cross-compiles to every
target with no extra toolchains, and the mosquitto headers are downloaded
automatically. One build produces both the plugin and the
[`mqtt-log` CLI](#querying-logs-with-mqtt-log).

```bash
# Build for the host (plugin -> zig-out/lib, CLI -> zig-out/bin)
zig build -Doptimize=ReleaseSafe
# or: just build          # builds every architecture into zig-out/dist/

# Cross-compile for one target triple
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
just build-target aarch64-linux-gnu                        # same, via just
just build-target arm-linux-gnueabihf -Dcpu=arm1176jzf_s   # ARMv6

# Build every supported architecture at once (into zig-out/dist/)
zig build all -Doptimize=ReleaseSafe
```

Supported targets: x86_64 / x86 / aarch64 / armv7 / armv6 / riscv64 (glibc and
musl variants) plus aarch64 macOS. Works identically on macOS, Linux, and
Windows.

### Releasing & Packaging (GoReleaser)

Each tool has its own GoReleaser config — [`plugin/.goreleaser.yaml`](plugin/.goreleaser.yaml)
and [`cli/.goreleaser.yaml`](cli/.goreleaser.yaml) — building cross-compiled
archives and Linux packages (`deb`, `rpm`, `apk`) with GoReleaser's
[Zig builder](https://goreleaser.com/customization/builds/builders/zig/) (the
actual compilation is still driven by the shared `build.zig`). Both publish to
the **same** GitHub release/tag: the plugin config creates the release and the
CLI config appends to it (`release.mode: append`), so the plugin runs first.
Each writes to its own `dist/plugin` and `dist/cli` directory.

```bash
just package        # build both tools' archives + packages (snapshot, no publish)
just package-check  # validate both configs
just release        # real combined release (needs a git tag + GITHUB_TOKEN)

# Or directly (plugin first, then CLI appends to the release):
goreleaser release -f plugin/.goreleaser.yaml --snapshot --clean --skip=publish,sign
goreleaser release -f cli/.goreleaser.yaml    --snapshot --clean --skip=publish,sign
```

Every package installs the plugin at the same **architecture-independent path**,
so `mosquitto.conf` is identical on every target:

```conf
plugin /usr/lib/mosquitto/mosquitto_message_logger.so
```

Target architectures and their package labels:

| Target | Package arch | Notes |
|--------|--------------|-------|
| `x86_64-linux-gnu`   | `amd64`        | |
| `aarch64-linux-gnu`  | `arm64`        | |
| `x86-linux-gnu`      | `x86`          | labeled `x86`, not `i386` (see below) |
| `arm-linux-gnueabihf`| `arm`          | hard-float (armhf); labeled `arm` |

> **Note:** GoReleaser's experimental Zig builder maps zig target triples to
> GOARCH for packaging. `amd64`/`arm64` are labeled correctly, but 32-bit x86 is
> labeled `x86` (not `i386`/`i686`) and 32-bit arm is labeled `arm` (it cannot
> distinguish `armhf` from `armel`, so only the hard-float variant is shipped).
> Installing those two with `dpkg -i` may need `--force-architecture`. Correct
> `i386`/`armhf`/`armel` labels would require GoReleaser Pro's `prebuilt` builder.
> The compiled `.so` files themselves are correct for every architecture.

Binaries pin an old glibc (2.17, RHEL 7 / Debian 8 era) so the gnu/linux packages
install across a wide range of distributions.

GoReleaser injects the release version into the plugin (reported to the broker via
`mosquitto_plugin_set_info`) by passing `-Dplugin-version={{ .Version }}` to Zig. A
plain `zig build` reports `0.0.0-dev`; override it with
`zig build -Dplugin-version=1.2.3`.

## Installation

Install from a released Linux package (see
[Releasing & Packaging](#releasing--packaging-goreleaser) for how they are built):

```bash
sudo dpkg -i mosquitto-log-plugin_*_amd64.deb              # Debian/Ubuntu
sudo rpm -i  mosquitto-log-plugin*.x86_64.rpm             # RHEL/Fedora
sudo apk add --allow-untrusted mosquitto-log-plugin_*.apk  # Alpine
```

The package installs the plugin to the fixed path
`/usr/lib/mosquitto/mosquitto_message_logger.so`. The `mqtt-log` CLI ships as a
separate `mqtt-log` package installed to `/usr/bin`.

Alternatively, copy a locally built `.so` wherever you like and point
`mosquitto.conf` at it:

```bash
sudo cp zig-out/lib/libmosquitto_message_logger.so \
        /usr/lib/mosquitto/mosquitto_message_logger.so
```

## Configuration

### mosquitto.conf

Point your Mosquitto configuration at the installed `.so`:

```conf
# Packaged install path
plugin /usr/lib/mosquitto/mosquitto_message_logger.so

# Or an absolute path to any built .so
plugin /path/to/mosquitto_message_logger.so
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MQTT_LOG_DIR` | `/var/log/mosquitto` | Directory for log files |
| `MQTT_LOG_STDERR` | unset | Set to `1` to enable stderr logging |

### Example

```bash
# Set environment variables before starting mosquitto
export MQTT_LOG_DIR=/var/log/mqtt
export MQTT_LOG_STDERR=1
mosquitto -c /etc/mosquitto/mosquitto.conf
```

Or in a systemd service file:

```ini
[Service]
Environment="MQTT_LOG_DIR=/var/log/mqtt"
Environment="MQTT_LOG_STDERR=1"
ExecStart=/usr/sbin/mosquitto -c /etc/mosquitto/mosquitto.conf
```

## Logged event types

Every log entry carries a `"type"` field so publishes can be distinguished from
control-plane activity and filtered (e.g. `jq 'select(.type=="publish_in")'`).

| `type`        | MQTT event                          | Extra fields                |
|---------------|-------------------------------------|-----------------------------|
| `publish_in`  | PUBLISH received by the broker      | topic, qos, retain, payload |
| `publish_out` | PUBLISH delivered to a client       | topic, qos, retain, payload |
| `connect`     | Client finished connecting          | client_id                   |
| `disconnect`  | Client disconnected                 | client_id, reason           |
| `subscribe`   | Client subscribed to a topic filter | topic, qos                  |
| `unsubscribe` | Client unsubscribed                 | topic                       |

> **Note:** The mosquitto plugin API does not surface the low-level MQTT
> acknowledgement/flow-control packets — **PUBACK, PUBREC, PUBREL, PUBCOMP,
> CONNACK, SUBACK, UNSUBACK, PINGREQ, PINGRESP**. These are handled entirely
> inside the broker and are never passed to a plugin, so they cannot be logged.

## Log Output Formats

### File Output (JSON Lines)

Daily rotated files: `mqtt-messages-YYYYMMDD.log`

Every record carries two forms of the same instant: `timestamp` (human-readable
ISO 8601) and `timestamp_unix` (Unix seconds with nanosecond resolution, as an
exact `sec.nsec` number — convenient for sorting and time-delta assertions).

**Text payload** (`payload` + `payload_base64`):
```json
{"timestamp":"2026-02-13T06:40:07.822347+0000","timestamp_unix":1770964807.822347123,"type":"publish_in","client_id":"sensor01","topic":"home/status","qos":0,"retain":0,"payload_len":6,"payload_encoding":"text","payload":"online","payload_base64":"b25saW5l"}
```

**JSON payload** (adds native `payload_json`):
```json
{"timestamp":"2026-02-13T06:40:07.900000+0000","timestamp_unix":1770964807.900000456,"type":"publish_in","client_id":"sensor01","topic":"home/temperature","qos":0,"retain":0,"payload_len":13,"payload_encoding":"json","payload":"{\"temp\":22.5}","payload_json":{"temp":22.5},"payload_base64":"eyJ0ZW1wIjoyMi41fQ=="}
```

**Binary payload** (`payload_base64` only):
```json
{"timestamp":"2026-02-13T06:40:08.123456+0000","timestamp_unix":1770964808.123456789,"type":"publish_in","client_id":"device01","topic":"binary/data","qos":1,"retain":1,"payload_len":6,"payload_encoding":"binary","payload_base64":"AAECaGkA"}
```

**Control-plane events:**
```json
{"timestamp":"2026-02-13T06:40:06.100000+0000","timestamp_unix":1770964806.100000111,"type":"connect","client_id":"sensor01"}
{"timestamp":"2026-02-13T06:40:06.200000+0000","timestamp_unix":1770964806.200000222,"type":"subscribe","client_id":"sensor01","topic":"home/#","qos":1}
{"timestamp":"2026-02-13T06:40:09.900000+0000","timestamp_unix":1770964809.900000333,"type":"disconnect","client_id":"sensor01","reason":0}
```

### Stderr Output (mosquitto_sub format)

Messages are prefixed with `MQTT_LOG:` for easy filtering:

```json
MQTT_LOG: {"timestamp":1770964807.822347000,"message":{"tst":"2026-02-13T06:40:07.822347+0000","type":"publish_in","client_id":"sensor01","topic":"home/temperature","qos":0,"retain":0,"payload_len":4,"payload":"22.5"},"payload_hex":"32322e35"}
```

**Filtering stderr output:**
```bash
mosquitto -v 2>&1 | grep "MQTT_LOG:"
```

## Querying logs with `mqtt-log`

The repository also ships a companion command-line tool, **`mqtt-log`**, that
filters and formats the JSON-Lines files written above. It is built by the same
`build.zig` (a standalone, pure-Zig executable — no mosquitto headers), so
`zig build` produces both the plugin and the CLI, and a release ships both. The
CLI is packaged separately as `mqtt-log` (installed to `/usr/bin`) and is also
included in the release archives.

Filters apply across all matched files, so archived (including `.gz`) logs are
searched together; results are merged and sorted by time.

```bash
# Everything from the default log directory (/var/log/mosquitto)
mqtt-log

# A specific directory or explicit files (.log or .gz)
mqtt-log --dir /var/log/mosquitto
mqtt-log mqtt-messages-20260213.log archive/mqtt-messages-20260212.log.gz

# Time window: absolute ISO 8601, relative offsets, or Unix seconds (inclusive)
mqtt-log --from 2026-02-13T06:00:00Z --to 2026-02-13T07:00:00Z
mqtt-log --from -1h                     # last hour
mqtt-log --from -2d --to -1d            # the day before yesterday

# Filter by MQTT/protocol characteristics
mqtt-log --type publish_in,publish_out  # event type
mqtt-log --encoding json                # payload encoding: json|text|binary
mqtt-log --topic 'home/+/temperature'   # MQTT topic filter (+ and # wildcards)
mqtt-log --topic-contains temperature   # topic substring
mqtt-log --client sensor01              # client id
mqtt-log --qos 1,2 --retain             # QoS level(s) and retained flag
mqtt-log --min-size 10 --max-size 256   # payload_len bounds (bytes)
mqtt-log --payload-contains '"temp"'    # literal substring of the decoded payload
mqtt-log --payload-matches 'temp[0-9]+' # regex on the decoded payload
mqtt-log --reason 0                      # disconnect reason code

# Choose fields, output format, order, and how many
mqtt-log --fields timestamp,topic,payload            # projection
mqtt-log --output json                               # json | ndjson | text | list | table
mqtt-log --format '{timestamp} {topic} {payload}'    # custom line template
mqtt-log --sort-by newest --head 20                  # newest 20 (or --tail N)
```

### Count assertions (for tests)

`--min-count` / `--max-count` (both inclusive) turn a query into an assertion on
how many messages matched. If the count is out of range the process exits **1**
and prints a message to stderr listing the expected/actual counts and the active
criteria; otherwise it exits **0**. `--quiet` (`-q`) suppresses the matched
records so only the assertion result is emitted — handy in test scripts. The
count is evaluated on the full match set, before any `--head`/`--tail` limit.

```bash
# Assert exactly one retained birth message on a topic (fail the test otherwise)
mqtt-log --topic 'devices/+/status' --retain --min-count 1 --max-count 1 -q

# Assert at least one publish arrived in the last minute
mqtt-log --topic 'home/#' --type publish_in --from -1m --min-count 1 -q

# Assert no error events were logged
mqtt-log --type disconnect --reason 1 --max-count 0 -q

# Assert a payload matches a regex (--payload-matches) or contains a literal
mqtt-log --topic 'sensors/+/temp' --payload-matches '^[0-9]+(\.[0-9]+)?$' --min-count 1 -q
mqtt-log --payload-contains 'ERROR' --max-count 0 -q
```

A failed assertion looks like:

```
mqtt-log: assertion failed: expected at least 1 matching message(s), but found 0
  criteria:
    dir: /var/log/mosquitto (recursive)
    from: -1m (2026-07-06T15:55:39Z)
    type: publish_in
    topic: home/#
```

Relative (`-1m`) and Unix-seconds `--from`/`--to` values are shown with their
resolved absolute UTC instant in parentheses, so the assertion is unambiguous.

**Payload matching.** `--payload-contains <S>` (literal substring) and
`--payload-matches <REGEX>` both match against the **decoded payload** and
combine with the count assertions to check message content. The regex engine is
a small built-in (no external dependency) supporting `.`, `*`, `+`, `?`,
`{n}`/`{n,}`/`{n,m}`, `|`, `(...)`, character classes `[...]`/`[^...]` with
`a-z` ranges, anchors `^`/`$`, and the shorthands `\d \w \s` (and `\D \W \S`).
Matching is unanchored — `--payload-matches ON` matches any payload containing
`ON`; use `^ON$` for an exact match.

Exit codes: `0` success (assertions passed), `1` a count assertion failed,
`2` usage/argument error.

Output modes:

| `--output` | Description                                                    |
|------------|----------------------------------------------------------------|
| `text`     | Human-readable single `key=value` line per record (default)   |
| `list`     | One `key=value` per line, blank line between records (like PowerShell's Format-List) |
| `table`    | Column-aligned rows with a header (like PowerShell's Format-Table); numeric columns right-aligned. Use `--fields` to pick/narrow columns. The header and separator are clipped to the terminal width so they never wrap; data rows print in full |
| `ndjson`   | One JSON object per line — pipe straight into `jq`             |
| `json`     | A single JSON array                                            |
| `--format` | Custom template; `{field}` is substituted, `{payload}` decodes the payload (works for binary via base64), `{{`/`}}` are literal braces |

Run `mqtt-log --help` for the full flag reference.

## Testing

### Automated Functional Tests (Docker)

The [`tests/`](tests/) directory contains a Docker-based suite that loads the
plugin into a real mosquitto broker (2.1.x, built from source), publishes
messages, and asserts they are logged correctly:

```bash
just test-docker              # default: 2.1.2
just test-docker 2.1.2        # specific versions
```

See [tests/README.md](tests/README.md) for details and coverage.

### Local Test Run

```bash
just test-local
```

Starts a local mosquitto instance with the plugin loaded, logging to the current
directory.

### Manual Testing

```bash
# Terminal 1: Start mosquitto
export MQTT_LOG_DIR=/tmp/mqtt-logs
export MQTT_LOG_STDERR=1
mosquitto -c mosquitto.conf

# Terminal 2: Publish a message
mosquitto_pub -t "test/topic" -m "Hello World"

# Check the logs
cat /tmp/mqtt-logs/mqtt-messages-$(date +%Y%m%d).log
```

## Payload Encoding

To make the log file easy to consume from different tooling, each **file** record
describes its payload in several representations at once. Which fields appear
depends on the payload, and `payload_encoding` names the richest one available:

| Field | Type | When present | Consume with |
|-------|------|--------------|--------------|
| `payload_len` | number | always | — |
| `payload_encoding` | string | always | `"json"` / `"text"` / `"binary"` |
| `payload_base64` | string | **always** | byte-exact assertions, any language; canonical lossless bytes |
| `payload` | string | payload is valid UTF-8 | `grep`, `jq '.payload'`, or `jq '.payload \| fromjson'` |
| `payload_json` | native JSON | payload is a well-formed JSON object/array | `jq '.payload_json.temp'` — no `fromjson` needed |

So a JSON message carries all of `payload`, `payload_json`, and `payload_base64`;
plain text carries `payload` + `payload_base64`; binary carries only
`payload_base64`. `payload_base64` is present on **every** record, so there is
always one field with a stable name and type to assert against.

`payload_json` is validated (jsmn, strict mode) and minified to a single line
before embedding, so pretty-printed payloads still produce one JSON-Lines record
and a malformed payload can never corrupt the log — it simply falls back to
`payload` / `payload_base64`.

**Binary detection.** A payload is treated as binary (base64 only) when it is not
valid UTF-8, or when the first 1 KB contains more than 10% null bytes or more
than 10% control characters (excluding tab/newline/carriage-return).

**Stderr** output keeps its compact, human-oriented `mosquitto_sub` form: the
JSON-escaped `payload` plus a hex `payload_hex` field.

## Payload Redaction

Sensitive values are masked **before** a message is written, so secrets never
reach the log file or stderr. Redaction rewrites the raw payload once and every
representation (`payload`, `payload_json`, `payload_base64`, and the stderr
`payload_hex`) is derived from the masked bytes — no encoding can leak the
original value. The masked value is the fixed string `***`.

The rules are **hard-coded** for thin-edge.io / Cumulocity (this is not a
generic tool — see [`plugin/redact.c`](plugin/redact.c)):

| Rule | Match | Result |
|------|-------|--------|
| Cumulocity JWT | topic `c8y/s/dat`, payload `71,<jwt>` | `71,***` (template id kept, token masked) |
| Device credentials | topic `c8y/s/dcr`, payload `70,<tenant>,<user>,<pass>` | `70,<tenant>,***,***` (id + tenant kept; username and password masked) |
| JSON keys | any JSON payload | the value of `password`, `token`, `access_token`, `secret`, `apikey` (case-insensitive, at any depth) is replaced with `***` |

JSON-key matching is **structural** (via the same jsmn tokeniser used for
`payload_json`), so only object **keys** are redacted — a same-named string
*value* such as `{"note":"the password is safe"}` is left untouched. A matched
value that is itself an object or array is masked wholesale (`"secret":"***"`).
Non-JSON payloads on non-matching topics are logged unchanged.

Any record whose payload was masked carries a `"redacted":true` field (in both
the file and stderr output) so redacted messages are easy to spot and filter;
records that were not touched omit the field entirely:

```json
{"timestamp":"...","type":"publish_in","client_id":"c8y-mapper","topic":"c8y/s/dat","qos":0,"retain":0,"payload_len":6,"payload_encoding":"text","payload":"71,***","payload_base64":"NzEsKioq","redacted":true}
```

Adding a sensitive key or a new sensitive topic is a small edit to the rule set
in `plugin/redact.c` followed by a rebuild. Redaction applies only to messages
logged **after** the change — pre-existing log files are not retroactively
masked.

## Performance Considerations

- File I/O is buffered and only happens on message receipt
- Log files are opened, written, and closed for each message (ensures durability)
- Binary detection is limited to first 1KB of payload
- Minimal memory allocation with cleanup after each message

For high-throughput scenarios, consider:
- Using a dedicated disk/partition for log storage
- Setting `MQTT_LOG_STDERR=0` to disable stderr logging
- Implementing log rotation/cleanup scripts

## Development

### Project Structure

The two tools are separated into their own directories, sharing one `build.zig`
that produces both:

```
mosquitto-log/
├── plugin/                              # The mosquitto broker plugin (C)
│   ├── mosquitto_message_logger.c       #   Plugin source code
│   ├── redact.c / redact.h              #   Hard-coded payload redaction (thin-edge/Cumulocity)
│   ├── compat/cjson/cJSON.h             #   Stub satisfying a 2.1 header reference we never call
│   ├── compat/jsmn/jsmn.h               #   Vendored jsmn (MIT) — validates JSON payloads for payload_json
│   └── .goreleaser.yaml                 #   Plugin release config (creates the GitHub release)
├── cli/                                 # The mqtt-log query CLI (Zig)
│   ├── src/*.zig                        #   CLI source (main, options, filter, output, sources, time, regex)
│   └── .goreleaser.yaml                 #   CLI release config (appends to the release)
├── build.zig                            # Shared Zig build — builds both plugin and CLI
├── build.zig.zon                        # Mosquitto 2.1.x header dependency
├── tests/                               # Docker-based functional test suite (plugin)
├── justfile                             # Convenience commands (requires just)
├── README.md                            # This file
├── LICENSE                              # Apache-2.0
└── .gitignore                           # Git ignore rules
```

### Debug Build

```bash
zig build                     # Debug is the default optimize mode
zig build -Doptimize=Debug    # explicit
```

### Running the CLI unit tests

```bash
just test-cli    # or: zig build test
```

### Code Formatting

```bash
just format  # clang-format on the plugin C source
```

## License

Apache-2.0

This project includes code originally derived from Eclipse Mosquitto.

See the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes with clear commit messages
4. Test your changes
5. Submit a pull request

## Acknowledgments

- Eclipse Mosquitto project for the plugin API and original example code
- thin-edge.io community for message logging requirements

## Support

For issues, questions, or contributions, please use the GitHub issue tracker.
