# ============================================================
# curl-runner — custom curl built with legacy TLS support
# Base: Ubuntu 22.04 (OpenSSL 3 default disabled TLS1.0/1.1)
# We rebuild OpenSSL + curl to re-enable all TLS versions
# ============================================================
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV OPENSSL_VERSION=3.2.1
ENV CURL_VERSION=8.7.1

RUN apt-get update && apt-get install -y \
    build-essential wget perl libpsl-dev libnghttp2-dev \
    zlib1g-dev ca-certificates python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── Build OpenSSL with legacy TLS enabled ────────────────────
WORKDIR /build/openssl
RUN wget -q https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz \
    && tar xzf openssl-${OPENSSL_VERSION}.tar.gz \
    && cd openssl-${OPENSSL_VERSION} \
    && ./Configure \
        linux-x86_64 \
        --prefix=/usr/local/openssl \
        enable-tls1 \
        enable-tls1_1 \
        enable-weak-ssl-ciphers \
    && make -j$(nproc) \
    && make install_sw

# ── Build curl linked against our OpenSSL ─────────────────────
WORKDIR /build/curl
RUN wget -q https://curl.se/download/curl-${CURL_VERSION}.tar.gz \
    && tar xzf curl-${CURL_VERSION}.tar.gz \
    && cd curl-${CURL_VERSION} \
    && ./configure \
        --with-ssl=/usr/local/openssl \
        --with-nghttp2 \
        --enable-ipv6 \
        --prefix=/usr/local/curl \
    && make -j$(nproc) \
    && make install

# ── Runtime image ─────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3 python3-pip ca-certificates libnghttp2-14 \
    && pip3 install --no-cache-dir requests azure-storage-blob \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/openssl /usr/local/openssl
COPY --from=builder /usr/local/curl    /usr/local/curl

ENV PATH="/usr/local/curl/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/local/openssl/lib64:$LD_LIBRARY_PATH"

# OpenSSL policy: allow TLS 1.0 and 1.1
COPY openssl-legacy.cnf /etc/ssl/openssl-legacy.cnf
ENV OPENSSL_CONF=/etc/ssl/openssl-legacy.cnf

WORKDIR /runner
COPY run.py         .
COPY entrypoint.sh  .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["/runner/entrypoint.sh"]