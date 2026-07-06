# Builds a mosquitto broker image for the 2.1.x line from source.
#
# There is no official eclipse-mosquitto 2.1 image on Docker Hub, so the test
# suite builds one on demand. Single-stage on purpose: this is a throwaway test
# image, so reliability (all libs present, standard install prefix) beats size.
ARG MOSQUITTO_VERSION=2.1.2

FROM alpine:3.21
ARG MOSQUITTO_VERSION

# Build deps: compiler/cmake, TLS, cJSON (used by libcommon), libuuid.
RUN apk add --no-cache build-base cmake openssl-dev cjson-dev util-linux-dev curl

RUN curl -fsSL "https://github.com/eclipse-mosquitto/mosquitto/archive/refs/tags/v${MOSQUITTO_VERSION}.tar.gz" \
    | tar -xz -C /tmp
WORKDIR /tmp/mosquitto-${MOSQUITTO_VERSION}

# Install into /usr so the broker and libmosquitto land on standard paths
# (avoids musl loader-path issues with /usr/local/lib). Build only what the
# tests need: the broker and the mosquitto_pub/sub clients.
RUN cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DWITH_BROKER=ON \
        -DWITH_CLIENTS=ON \
        -DWITH_APPS=OFF \
        -DWITH_PLUGINS=OFF \
        -DWITH_DOCS=OFF \
        -DWITH_TESTS=OFF \
        -DWITH_WEBSOCKETS=OFF \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build

RUN addgroup -S mosquitto && adduser -S -G mosquitto -H -h /mosquitto mosquitto \
    && mkdir -p /mosquitto/config && chown -R mosquitto:mosquitto /mosquitto

USER mosquitto
CMD ["mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
