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

## Requirements

- Mosquitto 2.1.x (plugin API v5)
- GCC or Clang
- Mosquitto development headers (`mosquitto-dev` or `libmosquitto-dev` package)
- Optional: `just` command runner (`brew install just` or `cargo install just`)

## Building

### Quick Start

```bash
# Build the plugin
make

# Or with just
just build
```

### Cross-Compilation

The Makefile supports cross-compilation for different architectures.

#### On Linux (Native Cross-Compilation)

```bash
# Install cross-compilation toolchains
sudo apt-get install gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf

# For ARM64 (aarch64)
make CROSS_COMPILE=aarch64-linux-gnu-

# For ARMv7 (32-bit ARM)
make CROSS_COMPILE=arm-linux-gnueabihf-

# With just
just build-arm64
just build-armv7
```

#### On macOS (Docker-based Cross-Compilation)

Cross-compiling on macOS requires Docker. This method works reliably and produces Linux binaries:

```bash
# Build all Linux architectures at once
just build-linux-all

# Or build specific architectures
just build-linux-x86_64   # x86_64 Linux
just build-linux-arm64    # ARM64/aarch64 Linux
just build-linux-armv7    # ARMv7 32-bit Linux
```

Binaries will be saved to the `dist/` directory with architecture-specific names.

**Requirements:**
- Docker Desktop for Mac
- `just` command runner: `brew install just`

The Docker approach uses pre-built cross-compilation containers from [cross-rs](https://github.com/cross-rs/cross) with mosquitto development headers included.

#### Using Zig (Recommended - Works on All Platforms)

Zig provides the easiest cross-compilation experience and works on macOS, Linux, and Windows. Mosquitto headers are automatically downloaded as a dependency:

```bash
# Build all architectures
zig build all -Doptimize=ReleaseSafe

# Build a single architecture for the host
zig build -Doptimize=ReleaseSafe
```

Binaries are saved under `zig-out/dist/`, e.g.
`zig-out/dist/libmosquitto_message_logger-aarch64.so`.

The plugin targets **mosquitto 2.1.x** (plugin API v5, callback-based). The
matching headers (pinned to v2.1.2) are downloaded automatically as a build
dependency declared in `build.zig.zon`.

**Requirements:**
- Zig 0.16.0 or later: [Download](https://ziglang.org/download/) or `brew install zig`
- `just` command runner (optional): `brew install just`

**Advantages of Zig:**
- No Docker needed
- No manual header installation required (mosquitto headers downloaded automatically)
- Native cross-compilation for all targets
- Fast compilation
- Works identically on macOS, Linux, and Windows

### Releasing & Packaging (GoReleaser)

[`.goreleaser.yaml`](.goreleaser.yaml) builds cross-compiled archives and Linux
packages (`deb`, `rpm`, `apk`) using GoReleaser's
[Zig builder](https://goreleaser.com/customization/builds/builders/zig/) — the
actual compilation is still driven by `build.zig`.

```bash
just package        # build archives + packages into dist/ (snapshot, no publish)
just package-check  # validate .goreleaser.yaml

# Or directly:
goreleaser release --snapshot --clean --skip=publish,sign
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

### Custom Mosquitto Headers

If you have mosquitto headers in a non-standard location:

```bash
make MOSQUITTO_INCLUDE=/path/to/mosquitto/include

# Or with just
just build-custom /path/to/mosquitto
```

## Installation

### System-wide Installation

```bash
sudo make install

# Or with just
just install
```

Default installation path: `/usr/local/lib/mosquitto_message_logger.so`

### Custom Installation Path

```bash
sudo make install PREFIX=/opt/mosquitto
sudo make install DESTDIR=/tmp/staging LIBDIR=/usr/lib/mosquitto
```

## Configuration

### mosquitto.conf

Add the plugin to your Mosquitto configuration:

```conf
# If installed system-wide
plugin /usr/local/lib/mosquitto_message_logger.so

# Or use absolute path to the .so file
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

Use the `just` command to run a test instance:

```bash
just test-local
```

This starts a local mosquitto instance on port 1883 with the plugin loaded, logging to the current directory.

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

```
mosquitto-message-logger/
├── mosquitto_message_logger.c   # Plugin source code
├── build.zig                      # Zig build (cross-compilation)
├── build.zig.zon                  # Mosquitto 2.1.x header dependency
├── .goreleaser.yaml               # Release archives + deb/rpm/apk packaging
├── compat/cjson/cJSON.h           # Stub satisfying a 2.1 header reference we never call
├── compat/jsmn/jsmn.h             # Vendored jsmn (MIT) — validates JSON payloads for payload_json
├── tests/                         # Docker-based functional test suite
├── justfile                       # Convenience commands (requires just)
├── README.md                      # This file
├── LICENSE                        # Apache-2.0
└── .gitignore                     # Git ignore rules
```

### Building with Debug Symbols

```bash
make CFLAGS="-Wall -Werror -g -O0 -fPIC"
```

### Code Formatting

```bash
just format  # Requires clang-format
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
