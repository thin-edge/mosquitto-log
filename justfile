# Mosquitto Message Logger - Build Commands (Zig)
#
# Targets mosquitto 2.1.x (plugin API v5).

# Default recipe - show available commands
default:
    @just --list

# Build all architectures (glibc + musl variants)
build:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building all architectures (glibc + musl) using Zig..."
    zig build all -Doptimize=ReleaseSafe
    echo ""
    echo "Build complete! Binaries in zig-out/dist/:"
    ls -lh zig-out/dist/
    echo ""
    echo "Verifying architectures..."
    file zig-out/dist/*

# Alias for build
all: build

# Build the companion query CLI (mqtt-log) for the host
build-cli:
    zig build -Doptimize=ReleaseSafe
    @echo "Built: zig-out/bin/mqtt-log"
    @file zig-out/bin/mqtt-log

# Run the query CLI, forwarding arguments (e.g. `just run-cli --help`)
run-cli *ARGS:
    zig build run -- {{ARGS}}

# Run the CLI unit tests
test-cli:
    zig build test --summary all

# Target triple examples: aarch64-linux-gnu, x86_64-linux-musl, aarch64-macos,
# arm-linux-gnueabihf (add `-Dcpu=arm1176jzf_s` for ARMv6). Extra flags forward.

# Build the plugin + CLI for one Zig target triple (use `just build` for all archs).
build-target target *flags:
    zig build -Dtarget={{target}} -Doptimize=ReleaseSafe {{flags}}
    @echo "Built {{target}}:"
    @file zig-out/bin/mqtt-log zig-out/bin/mosquitto_message_logger.so

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache
    @echo "Cleaned build artifacts"

# Show configuration instructions
config:
    @echo ""
    @echo "Configuration:"
    @echo "=============="
    @echo ""
    @echo "Add to mosquitto.conf:"
    @echo "  plugin $(pwd)/zig-out/dist/libmosquitto_message_logger-<arch>.so"
    @echo ""
    @echo "Example for aarch64:"
    @echo "  plugin $(pwd)/zig-out/dist/libmosquitto_message_logger-aarch64.so"
    @echo ""
    @echo "Environment Variables:"
    @echo "  MQTT_LOG_DIR=/path/to/logs      (default: /var/log/mosquitto)"
    @echo "  MQTT_LOG_STDERR=1               (enable stderr logging)"
    @echo ""
    @echo "Log output format:"
    @echo "  File: JSON per line with payload (text) or payload_base64 (binary)"
    @echo "  Stderr: mosquitto_sub compatible format with payload_hex"
    @echo "  Stderr prefix: MQTT_LOG: (for easy filtering)"
    @echo ""

# Format the code (requires clang-format)
format:
    clang-format -i plugin/mosquitto_message_logger.c

# Build both tools' release archives + linux packages (deb/rpm/apk) locally with
# GoReleaser. Each tool has its own config and writes to dist/plugin and dist/cli.
package:
    goreleaser release -f plugin/.goreleaser.yaml --snapshot --clean --skip=publish,sign
    goreleaser release -f cli/.goreleaser.yaml    --snapshot --clean --skip=publish,sign
    @echo ""
    @echo "Artifacts in dist/plugin and dist/cli:"
    @ls -1 dist/plugin/* dist/cli/* 2>/dev/null | grep -E '\.(tar\.gz|deb|rpm|apk)$'

# Publish a real combined release to GitHub (needs a git tag + GITHUB_TOKEN).
# The plugin config creates the release; the CLI config appends to it, so order
# matters. Run `git tag vX.Y.Z && git push --tags` first.
release:
    goreleaser release -f plugin/.goreleaser.yaml --clean
    goreleaser release -f cli/.goreleaser.yaml    --clean

# Validate both GoReleaser configurations
package-check:
    goreleaser check -f plugin/.goreleaser.yaml
    goreleaser check -f cli/.goreleaser.yaml

# Run tests (build and verify all architectures)
test: build
    @echo ""
    @echo "✓ All architectures built successfully"
    @echo "✓ glibc requirements verified"

# Run the Docker-based functional test suite (requires Docker).
# Default version: 2.1.2. Override by passing versions, e.g.:
#   just test-docker 2.1.2
test-docker *versions:
    tests/run.sh {{versions}}

# Run a test mosquitto instance with the plugin
test-local:
    #!/usr/bin/env bash
    set -euo pipefail

    # Detect host OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    # Map architecture names
    case "$ARCH" in
        x86_64|amd64)
            ARCH_NAME="x86_64"
            ;;
        i386|i686)
            ARCH_NAME="x86"
            ;;
        aarch64|arm64)
            ARCH_NAME="aarch64"
            ;;
        armv7*|armhf)
            ARCH_NAME="armv7"
            ;;
        armv6*)
            ARCH_NAME="armv6"
            ;;
        riscv64)
            ARCH_NAME="riscv64"
            ;;
        *)
            echo "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    # Determine plugin file based on OS
    DIST_DIR="$(pwd)/zig-out/dist"
    if [[ "$OS" == "darwin" ]]; then
        SO_FILE="${DIST_DIR}/libmosquitto_message_logger-macos-${ARCH_NAME}.dylib"
    else
        SO_FILE="${DIST_DIR}/libmosquitto_message_logger-${ARCH_NAME}.so"
    fi
    
    echo "Detected: $OS / $ARCH (mapped to: $ARCH_NAME)"
    echo "Using plugin: $SO_FILE"
    echo ""
    
    if [ ! -f "$SO_FILE" ]; then
        echo "Plugin not found at: $SO_FILE"
        echo "Building all architectures..."
        just build
        
        if [ ! -f "$SO_FILE" ]; then
            echo "Error: Plugin still not found after build"
            exit 1
        fi
    fi
    
    echo "Starting mosquitto with plugin..."
    echo "Log directory: $(pwd)"
    echo "Press Ctrl+C to stop"
    echo ""
    
    export MQTT_LOG_DIR=$(pwd)
    export MQTT_LOG_STDERR=1
    
    # Create a minimal config
    cat > test_mosquitto.conf << EOFCONFIG
    listener 0 mosquitto.sock
    allow_anonymous true
    plugin ${SO_FILE}
    EOFCONFIG
    
    mosquitto -c test_mosquitto.conf -v
