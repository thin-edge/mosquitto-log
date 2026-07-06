# Functional test suite (Docker)

End-to-end tests that load the plugin into a real mosquitto broker, publish MQTT
messages, and assert that they are logged correctly.

For each mosquitto version, [`run.sh`](run.sh):

1. builds the plugin with Zig — musl, matching the broker container's architecture;
2. starts a mosquitto broker with the plugin loaded ([`mosquitto.conf`](mosquitto.conf));
3. publishes a range of messages with `mosquitto_pub`;
4. asserts the JSON log file **and** the `MQTT_LOG:` stderr stream.

## Requirements

- Docker (running)
- Zig 0.16+
- Builds/runs on `aarch64` and `x86_64` hosts (the broker's architecture is
  detected and the plugin is cross-built to match).

## Running

```bash
tests/run.sh                  # default: 2.1.2
tests/run.sh 2.1.2            # specific versions
just test-docker              # via justfile
just test-docker 2.1.2

MOSQ_VERSIONS="2.1.2" tests/run.sh   # via environment
```

## Mosquitto versions

| Version | Broker image |
|---------|--------------|
| `2.1.x` | Built from source on first use — there is **no** official 2.1 image — via [`docker/mosquitto-2.1.Dockerfile`](docker/mosquitto-2.1.Dockerfile), cached as `mosquitto-logger-test:<version>` |

The first 2.1 run compiles mosquitto from source (a minute or two); later runs
reuse the cached image. Remove it with
`docker rmi mosquitto-logger-test:2.1.2` to force a rebuild.

## What is covered

| Check | Asserts |
|-------|---------|
| plugin loaded | broker logs `Loading plugin: …` with no load error |
| text payload | `topic`, `payload`, `qos:0`, `retain:0`, `payload_len`, `client_id`, `payload_encoding:"text"`, `payload_base64` |
| qos + retain | `qos:1`, `retain:1` from `-q 1 -r` |
| JSON payload | quotes JSON-escaped in `payload`; embedded natively as `payload_json`; `payload_encoding:"json"` |
| pretty JSON | multi-line JSON payload is minified to a single-line `payload_json` |
| binary payload | NUL-containing payload stored as `payload_base64` (verified against `base64`) with `payload_encoding:"binary"`, and no `payload` string |
| stderr output | `MQTT_LOG:` prefix, `payload_hex`, and `type` field present |
| event type | publishes tagged `"type":"publish_in"` in file and stderr |
| disconnect | a `"type":"disconnect"` record with a `reason` is logged |
| connect / subscribe / publish_out | subscribing drives `connect` + `subscribe` (with `topic`/`qos`) records, and delivering to the subscriber drives a `publish_out` record |

## Files

```
tests/
├── run.sh                       # orchestrator
├── lib.sh                       # assertion + reporting helpers
├── mosquitto.conf               # broker config that loads the plugin
├── docker/
│   └── mosquitto-2.1.Dockerfile # builds a 2.1.x broker from source
└── README.md
```
