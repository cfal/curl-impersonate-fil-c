# syntax=docker/dockerfile:1

ARG FILC_VERSION=0.684
ARG FILC_SHA256=eefb594bcbc1261a18dfa8b50041674635f53df2b5fe067915b5652adaed4e3f

FROM ubuntu:24.04 AS builder

ARG FILC_VERSION
ARG FILC_SHA256

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV FETCH_RETRY="--retry 5 --retry-delay 2 --retry-all-errors \
    --connect-timeout 20 --speed-limit 1024 --speed-time 30"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        binutils \
        bzip2 \
        ca-certificates \
        cmake \
        curl \
        file \
        git \
        golang-go \
        gperf \
        libc6-dev \
        libtool \
        linux-libc-dev \
        make \
        ninja-build \
        patch \
        patchelf \
        perl \
        pkg-config \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/filc
RUN curl -fsSL ${FETCH_RETRY} -o /tmp/filc.tar.xz \
        "https://github.com/pizlonator/fil-c/releases/download/v${FILC_VERSION}/filc-${FILC_VERSION}-linux-x86_64.tar.xz" \
    && echo "${FILC_SHA256}  /tmp/filc.tar.xz" | sha256sum -c - \
    && tar --strip-components=1 -xJf /tmp/filc.tar.xz \
    && ./setup.sh \
    && rm /tmp/filc.tar.xz

ENV CC=/opt/filc/build/bin/clang \
    CXX=/opt/filc/build/bin/clang++ \
    CFLAGS="-O2 -g" \
    CXXFLAGS="-O2 -g" \
    LDFLAGS="-static"

WORKDIR /build
COPY . /build

RUN mkdir /build/install && \
    BUILD_ARGS="-DCMAKE_INSTALL_PREFIX=/build/install -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX} -DCMAKE_EXE_LINKER_FLAGS=-static -DBUILD_SHARED_LIBS=OFF -DDISABLE_BORINGSSL_ASM=ON -DDISABLE_ZSTD_ASM=ON -DBORINGSSL_PATCH=/build/docker/patches/boringssl-filc.patch -DZSTD_PATCH=/build/docker/patches/zstd-filc.patch -DCURL_IMPERSONATE_CXX_RUNTIME_LIBRARY=c++ -DCURL_CA_PATH=/etc/ssl/certs -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt" && \
    make prepare-libidn2 BUILD_DIR=build && \
    make build BUILD_DIR=build CMAKE_CONFIGURE_ARGS="$BUILD_ARGS" && \
    make checkbuild BUILD_DIR=build CMAKE_CONFIGURE_ARGS="$BUILD_ARGS" && \
    make install BUILD_DIR=build CMAKE_CONFIGURE_ARGS="$BUILD_ARGS" && \
    strip --strip-debug /build/install/bin/curl-impersonate && \
    binary=/build/install/bin/curl-impersonate && \
    file "${binary}" | grep -Fq "static-pie linked" && \
    ! readelf -lW "${binary}" | grep -Fq " INTERP " && \
    readelf -sW "${binary}" > /tmp/curl.symbols && \
    grep -Fq "pizlonated" /tmp/curl.symbols && \
    grep -Eq "filc_call_user_main|zgc_alloc" /tmp/curl.symbols && \
    nm -a "${binary}" > /tmp/curl.nm && \
    grep -Eq '[[:space:]][Tt][[:space:]]+filc_' /tmp/curl.nm && \
    strings -a "${binary}" > /tmp/curl.strings && \
    ! grep -q "@llvm\\." /tmp/curl.strings && \
    "${binary}" --fail --silent --show-error --retry 3 --retry-all-errors --connect-timeout 20 --output /dev/null https://github.com/ && \
    install -Dm644 /opt/filc/LLVM-LICENSE.txt /build/install/share/licenses/fil-c/LLVM-LICENSE.txt && \
    install -Dm644 /opt/filc/MUSL-LICENSE.txt /build/install/share/licenses/fil-c/MUSL-LICENSE.txt && \
    install -Dm644 /opt/filc/PAS-LICENSE.txt /build/install/share/licenses/fil-c/PAS-LICENSE.txt


FROM scratch AS artifact

COPY --from=builder /build/install /


FROM alpine:3.21

RUN apk update && \
    apk add ca-certificates \
    && rm -rf /var/cache/apk/*

COPY --from=builder /build/install /usr/local

# Replace /usr/bin/env bash with /usr/bin/env ash
RUN sed -i 's@/usr/bin/env bash@/usr/bin/env ash@' /usr/local/bin/curl_*

CMD ["curl-impersonate", "--version"]
