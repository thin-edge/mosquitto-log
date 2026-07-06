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

# Build for x86_64 Linux
build-x86_64:
    zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for x86 (32-bit) Linux
build-x86:
    zig build -Dtarget=x86-linux-gnu -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for ARM64 (aarch64) Linux
build-arm64:
    zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for ARMv7 Linux
build-armv7:
    zig build -Dtarget=arm-linux-gnueabihf -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for ARMv6 Linux (Raspberry Pi 1, Zero)
build-armv6:
    zig build -Dtarget=arm-linux-gnueabihf -Dcpu=arm1176jzf_s -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for macOS ARM64
build-macos:
    zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.dylib"
    @file zig-out/lib/libmosquitto_message_logger.dylib

# Build for RISC-V 64-bit Linux
build-riscv64:
    zig build -Dtarget=riscv64-linux-gnu -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for x86_64 Linux (musl / Alpine)
build-x86_64-musl:
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for x86 (32-bit) Linux (musl / Alpine)
build-x86-musl:
    zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for ARM64 (aarch64) Linux (musl / Alpine)
build-arm64-musl:
    zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for ARMv7 Linux (musl / Alpine)
build-armv7-musl:
    zig build -Dtarget=arm-linux-musleabihf -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for ARMv6 Linux (musl / Alpine)
build-armv6-musl:
    zig build -Dtarget=arm-linux-musleabihf -Dcpu=arm1176jzf_s -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Build for RISC-V 64-bit Linux (musl / Alpine)
build-riscv64-musl:
    zig build -Dtarget=riscv64-linux-musl -Doptimize=ReleaseSafe
    @echo "Built: zig-out/lib/libmosquitto_message_logger.so"
    @file zig-out/lib/libmosquitto_message_logger.so

# Clean build artifacts
clean:
    rm -rf zig-out .zig-cache
    @echo "Cleaned build artifacts"

# Show plugin info
info:
    @echo "Built binaries:"
    @ls -lh zig-out/dist/*.{so,dylib} 2>/dev/null || echo "No binaries found. Run: just build"
    @echo ""
    @echo "Architectures:"
    @file zig-out/dist/*.{so,dylib} 2>/dev/null || true

# Check glibc version requirements for Linux binaries
check-glibc:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking glibc version requirements..."
    echo ""
    for f in zig-out/dist/*.so; do
        if [ -f "$f" ]; then
            basename="$(basename "$f")"
            max_version=$(nm -D "$f" 2>/dev/null | grep GLIBC | sed 's/.*GLIBC_//' | sort -V | uniq | tail -1)
            echo "$basename: GLIBC $max_version"
        fi
    done
    echo ""
    echo "Compatibility guide:"
    echo "  2.4  = Very old systems (2006+)"
    echo "  2.17 = RHEL 7 / CentOS 7 (2013+)"
    echo "  2.19 = Ubuntu 14.04 (2014+)"
    echo "  2.27 = Ubuntu 18.04 / Debian 10 (2018+)"

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
    clang-format -i mosquitto_message_logger.c

# Build release archives + linux packages (deb/rpm/apk) locally with GoReleaser.
# Output goes to dist/. Requires goreleaser (and zig).
package:
    goreleaser release --snapshot --clean --skip=publish,sign
    @echo ""
    @echo "Artifacts in dist/:"
    @ls -1 dist/*.tar.gz dist/*.deb dist/*.rpm dist/*.apk 2>/dev/null

# Validate the GoReleaser configuration
package-check:
    goreleaser check

# Run tests (build and verify all architectures)
test: build check-glibc
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
    listener 1883
    allow_anonymous true
    plugin ${SO_FILE}
    EOFCONFIG
    
    mosquitto -c test_mosquitto.conf -v
