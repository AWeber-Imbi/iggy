# syntax=docker/dockerfile:1

# Apache Iggy for Imbi: the upstream server image, plus the connectors
# runtime and the ClickHouse sink plugin compiled from the same upstream
# commit as the server binary, plus Imbi's sink configuration.
#
# Upstream does not publish the ClickHouse sink as a binary, and the
# apache/iggy-connect image is built from a different commit than the
# apache/iggy server image (see README, "Pinned upstream versions"), so
# the runtime is compiled here as well. The plugin FFI is not versioned;
# server, runtime and plugin must come from one commit.

ARG IGGY_COMMIT=996ac04c874da857d6d734db4f27ada344e5585d
ARG RUST_VERSION=1.98.0

FROM rust:${RUST_VERSION}-trixie AS rust

ARG IGGY_COMMIT
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      cmake pkg-config libssl-dev protobuf-compiler \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git init -q . \
 && git remote add origin https://github.com/apache/iggy.git \
 && git -c protocol.version=2 fetch --depth 1 -q origin "${IGGY_COMMIT}" \
 && git checkout -q FETCH_HEAD

RUN --mount=type=cache,id=cargo-registry-${TARGETARCH},target=/usr/local/cargo/registry \
    --mount=type=cache,id=cargo-git-${TARGETARCH},target=/usr/local/cargo/git \
    --mount=type=cache,id=cargo-target-${TARGETARCH},target=/src/target \
    cargo build --release \
      -p iggy_connector_clickhouse_sink \
      -p iggy-connectors \
 && mkdir -p /out/bin /out/lib \
 && cp target/release/iggy-connectors /out/bin/ \
 && cp target/release/libiggy_connector_clickhouse_sink.so /out/lib/

FROM apache/iggy:0.9.0-edge.6@sha256:aafc890249616591791c775b4ea04eb9f01292306524decd031d451980061b0c

# The upstream server image carries no CA certificates. The ClickHouse
# sink builds a reqwest client at startup, and reqwest's rustls backend
# loads the native trust store while building it, so without these the
# plugin fails to initialize even against a plain http:// endpoint.
COPY --from=rust /etc/ssl/certs /etc/ssl/certs
COPY --from=rust /usr/share/ca-certificates /usr/share/ca-certificates

COPY --from=rust /out/bin/iggy-connectors /usr/local/bin/iggy-connectors
COPY --from=rust /out/lib/libiggy_connector_clickhouse_sink.so \
                 /opt/iggy/connectors/libiggy_connector_clickhouse_sink.so
# Only the runtime configuration is baked in. Sink definitions come from
# imbi-api over HTTP at startup, and the runtime's http configuration
# provider never writes to disk, so this stays read-only.
COPY connectors/config.toml /etc/iggy/connectors/config.toml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/iggy-connectors

ENV IGGY_MODE=server

ENTRYPOINT ["/entrypoint.sh"]
