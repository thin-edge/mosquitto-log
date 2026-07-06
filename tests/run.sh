#!/usr/bin/env bash
set -euo pipefail
#
# Docker-based functional test suite for the mosquitto message logger plugin.
#
# For each mosquitto version, this script:
#   1. builds the plugin (musl, matching the broker container's architecture)
#   2. starts a mosquitto broker with the plugin loaded
#   3. publishes a range of MQTT messages
#   4. asserts the JSON log file and the stderr stream captured them correctly
#
# Mosquitto 2.1.x has no official image, so the broker is built from source on
# first use (tests/docker/mosquitto-2.1.Dockerfile).
#
# Usage:
#   tests/run.sh                  # default version (2.1.2)
#   tests/run.sh 2.1.2            # explicit versions
#   MOSQ_VERSIONS="2.1.2" tests/run.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=tests/lib.sh
source "tests/lib.sh"

DEFAULT_VERSIONS=(2.1.2)
if [ "$#" -gt 0 ]; then
    VERSIONS=("$@")
elif [ -n "${MOSQ_VERSIONS:-}" ]; then
    read -r -a VERSIONS <<<"$MOSQ_VERSIONS"
else
    VERSIONS=("${DEFAULT_VERSIONS[@]}")
fi

CONTAINER="mqtt-logger-test"
WORKDIR="$(mktemp -d)"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$WORKDIR"; }
trap cleanup EXIT

zig_target_for_arch() {
    case "$1" in
        aarch64 | arm64) echo "aarch64-linux-musl" ;;
        x86_64 | amd64) echo "x86_64-linux-musl" ;;
        *) return 1 ;;
    esac
}

resolve_image() { echo "mosquitto-logger-test:$1"; } # built locally from source

ensure_image() {
    local ver="$1" image="$2"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo "→ no official 2.1 image exists; building $image from source (one-off, slow)..."
        docker build -f tests/docker/mosquitto-2.1.Dockerfile \
            --build-arg "MOSQUITTO_VERSION=$ver" -t "$image" tests/docker
    fi
}

wait_for_broker() {
    local i
    for i in $(seq 1 40); do
        if docker exec "$CONTAINER" mosquitto_pub -t test/ready -m x >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    return 1
}

# combined contents of the plugin's log file(s) inside the container
read_logfile() { docker exec "$CONTAINER" sh -c 'cat /tmp/mqtt-logs/*.log 2>/dev/null' || true; }

# publish a message, then wait until <marker> appears in the log file
pub_and_wait() {
    local marker="$1"; shift
    docker exec "$CONTAINER" mosquitto_pub "$@" || true
    local i
    for i in $(seq 1 20); do
        if read_logfile | grep -qF -- "$marker"; then return 0; fi
        sleep 0.25
    done
    return 1
}

# isolate the single log line for a given topic marker
log_line_for() { printf '%s\n' "$1" | grep -F -- "$2" | head -1; }

# poll the log file until <marker> appears (for events with no publish to drive)
wait_for_log() {
    local marker="$1" i
    for i in $(seq 1 20); do
        if read_logfile | grep -qF -- "$marker"; then return 0; fi
        sleep 0.25
    done
    return 1
}

run_version() {
    local ver="$1" image carch ztarget plugin log line blog b64

    image="$(resolve_image "$ver")"

    echo ""
    echo "${C_BOLD}══ mosquitto $ver  ·  $image ══${C_RESET}"

    ensure_image "$ver" "$image"

    carch="$(docker run --rm "$image" uname -m)"
    if ! ztarget="$(zig_target_for_arch "$carch")"; then
        fail "$ver: unsupported broker architecture '$carch'"
        return
    fi
    echo "→ broker arch $carch → building plugin for $ztarget"
    if ! zig build -Dtarget="$ztarget" -Doptimize=ReleaseSafe >/dev/null; then
        fail "$ver: plugin build failed"
        return
    fi
    plugin="$ROOT/zig-out/lib/libmosquitto_message_logger.so"
    if [ ! -f "$plugin" ]; then
        fail "$ver: plugin build produced no .so"
        return
    fi

    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" \
        -e MQTT_LOG_DIR=/tmp/mqtt-logs \
        -e MQTT_LOG_STDERR=1 \
        -v "$plugin:/plugin/logger.so:ro" \
        -v "$ROOT/tests/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro" \
        "$image" >/dev/null

    if ! wait_for_broker; then
        fail "$ver: broker did not become ready"
        docker logs "$CONTAINER" 2>&1 | sed 's/^/      /' | tail -20
        return
    fi

    # --- plugin actually loaded ---
    blog="$(docker logs "$CONTAINER" 2>&1)"
    assert_contains    "$ver · plugin loaded"   "Loading plugin: /plugin/logger.so" "$blog"
    assert_not_contains "$ver · no load error"  "Unable to load plugin"             "$blog"

    # --- T1: plain text payload, default qos/retain, known client id ---
    pub_and_wait '"topic":"test/text"' -t test/text -m "hello world" -i pub-text || true
    log="$(read_logfile)"
    line="$(log_line_for "$log" '"topic":"test/text"')"
    assert_contains "$ver · text: topic"      '"topic":"test/text"'     "$line"
    assert_contains "$ver · text: payload"    '"payload":"hello world"' "$line"
    assert_contains "$ver · text: qos 0"      '"qos":0'                 "$line"
    assert_contains "$ver · text: retain 0"   '"retain":0'              "$line"
    assert_contains "$ver · text: payload_len" '"payload_len":11'         "$line"
    assert_contains "$ver · text: client_id"  '"client_id":"pub-text"'  "$line"
    assert_contains "$ver · text: type"       '"type":"publish_in"'     "$line"
    assert_contains "$ver · text: encoding"   '"payload_encoding":"text"'           "$line"
    assert_contains "$ver · text: base64"     '"payload_base64":"aGVsbG8gd29ybGQ="' "$line"
    # timestamp_unix: Unix seconds with nanosecond (9-digit) resolution
    if printf '%s' "$line" | grep -qE '"timestamp_unix":[0-9]+\.[0-9]{9},'; then
        pass "$ver · text: unix timestamp"
    else
        fail "$ver · text: unix timestamp" "expected \"timestamp_unix\":<sec>.<9-digit-nsec>"
    fi

    # --- T2: qos 1 + retain flag ---
    pub_and_wait '"topic":"test/retain"' -t test/retain -m keep -q 1 -r -i pub-ret || true
    log="$(read_logfile)"
    line="$(log_line_for "$log" '"topic":"test/retain"')"
    assert_contains "$ver · retain: qos 1"    '"qos":1'    "$line"
    assert_contains "$ver · retain: retain 1" '"retain":1' "$line"

    # --- T3: JSON payload is escaped as a string AND embedded natively ---
    pub_and_wait '"topic":"test/json"' -t test/json -m '{"temp":22.5}' -i pub-json || true
    log="$(read_logfile)"
    line="$(log_line_for "$log" '"topic":"test/json"')"
    assert_contains "$ver · json: escaped payload" '"payload":"{\"temp\":22.5}"' "$line"
    assert_contains "$ver · json: encoding"        '"payload_encoding":"json"'   "$line"
    assert_contains "$ver · json: native json"     '"payload_json":{"temp":22.5}' "$line"

    # --- T3b: pretty-printed JSON is minified to a single line in payload_json ---
    printf '{\n  "a": 1,\n  "b": [2, 3]\n}' >"$WORKDIR/pretty.json"
    docker cp "$WORKDIR/pretty.json" "$CONTAINER:/tmp/pretty.json" >/dev/null
    pub_and_wait '"topic":"test/pretty"' -t test/pretty -f /tmp/pretty.json -i pub-pretty || true
    log="$(read_logfile)"
    line="$(log_line_for "$log" '"topic":"test/pretty"')"
    assert_contains "$ver · pretty: minified json" '"payload_json":{"a":1,"b":[2,3]}' "$line"

    # --- T4: binary payload (with NUL bytes) -> base64, not stored as text ---
    printf '\x00\x01\x02hello\x00world' >"$WORKDIR/bin.dat"
    docker cp "$WORKDIR/bin.dat" "$CONTAINER:/tmp/bin.dat" >/dev/null
    b64="$(base64 <"$WORKDIR/bin.dat" | tr -d '\n')"
    pub_and_wait '"topic":"test/binary"' -t test/binary -f /tmp/bin.dat -i pub-bin || true
    log="$(read_logfile)"
    line="$(log_line_for "$log" '"topic":"test/binary"')"
    assert_contains     "$ver · binary: base64 field"  "\"payload_base64\":\"$b64\"" "$line"
    assert_contains     "$ver · binary: encoding"       '"payload_encoding":"binary"' "$line"
    assert_not_contains "$ver · binary: not raw text"   '"payload":"'                "$line"

    # --- T5: stderr MQTT_LOG output (mosquitto_sub-style, with hex) ---
    blog="$(docker logs "$CONTAINER" 2>&1)"
    assert_contains "$ver · stderr: MQTT_LOG prefix" "MQTT_LOG: {"   "$blog"
    assert_contains "$ver · stderr: payload_hex"     '"payload_hex":' "$blog"
    assert_contains "$ver · stderr: type field"      '"type":"publish_in"' "$blog"

    # --- T6: control-plane events carry their own type ---
    # The publishers above all connected and disconnected, so a disconnect
    # record must have been logged.
    wait_for_log '"type":"disconnect"' || true
    log="$(read_logfile)"
    line="$(log_line_for "$log" '"type":"disconnect"')"
    assert_contains "$ver · disconnect: type"   '"type":"disconnect"' "$line"
    assert_contains "$ver · disconnect: reason"  '"reason":'          "$line"

    # --- T7: connect / subscribe / publish_out ---
    # A detached subscriber connects and subscribes; publishing to its
    # topic then drives a publish_out delivery.
    docker exec -d "$CONTAINER" sh -c \
        'mosquitto_sub -t test/sub -q 1 -i sub-cli >/dev/null 2>&1'
    wait_for_log '"type":"subscribe"' || true
    log="$(read_logfile)"
    assert_contains "$ver · subscribe: type"      '"type":"subscribe"'    "$log"
    assert_contains "$ver · subscribe: topic"     '"topic":"test/sub"'    "$log"
    assert_contains "$ver · subscribe: qos"       '"qos":1'               "$(log_line_for "$log" '"type":"subscribe"')"
    assert_contains "$ver · connect: type"        '"type":"connect"'      "$log"
    # Several clients connected before sub-cli, so match against all
    # connect lines rather than just the first one.
    assert_contains "$ver · connect: client_id"   '"client_id":"sub-cli"' \
        "$(printf '%s\n' "$log" | grep -F '"type":"connect"')"

    pub_and_wait '"topic":"test/sub"' -t test/sub -m out -q 1 -i pub-out || true
    wait_for_log '"type":"publish_out"' || true
    log="$(read_logfile)"
    assert_contains "$ver · publish_out: type"  '"type":"publish_out"' "$log"
    assert_contains "$ver · publish_out: topic" '"topic":"test/sub"'   "$(log_line_for "$log" '"type":"publish_out"')"

    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

echo "${C_BOLD}Mosquitto message logger — Docker functional tests${C_RESET}"
echo "versions: ${VERSIONS[*]}"
for v in "${VERSIONS[@]}"; do
    run_version "$v"
done

summary
