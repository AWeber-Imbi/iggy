# iggy

Custom [Apache Iggy](https://iggy.apache.org) image based on the
[official server image](https://hub.docker.com/r/apache/iggy), adding
everything Imbi needs to move its analytics writes onto a message stream:

- the **connectors runtime** (`iggy-connectors`), compiled from the same
  upstream commit as the server binary in the base image
- the **ClickHouse sink plugin**
  (`libiggy_connector_clickhouse_sink.so`), which upstream does not
  distribute as a binary
- an **entrypoint** that runs either the server or the connectors
  runtime, so one image backs both containers in Compose and both
  deployments in the Helm chart

Sink definitions are not in this image. The connectors runtime fetches
them from imbi-api at startup over HTTP. `connectors/README.md` is the
contract that API implements.

## Pinned upstream versions

| What                      | Pin                                                                        |
| ------------------------- | -------------------------------------------------------------------------- |
| Server base image         | `apache/iggy:0.9.0-edge.6`                                                  |
| Server image digest       | `sha256:aafc890249616591791c775b4ea04eb9f01292306524decd031d451980061b0c`   |
| Upstream commit           | `996ac04c874da857d6d734db4f27ada344e5585d`                                  |
| Connectors runtime crate  | `iggy-connectors` 0.5.0-edge.5, built here                                   |
| ClickHouse sink crate     | `iggy_connector_clickhouse_sink` 0.2.0-edge.4, built here                    |
| Rust toolchain            | `rust:1.98.0-trixie` (Debian 13, glibc 2.41, matching the base image)        |

The commit comes from the `org.opencontainers.image.revision` label on
`apache/iggy:0.9.0-edge.6`. The published `apache/iggy-connect:0.5.0-edge.6`
image carries a different revision (`dc1cdf23209c91fd703b59ceb47bdb9b4c662480`),
so its `iggy-connectors` binary is not copied in. The plugin FFI is not
versioned, so the runtime and the plugin are both compiled from the
server's commit instead.

## Pulling the image

The image is published to
[GitHub Container Registry](https://ghcr.io/aweber-imbi/iggy).
Multi-architecture builds are available for `linux/amd64` and
`linux/arm64`.

```bash
# Latest from main
docker pull ghcr.io/aweber-imbi/iggy:latest

# Specific git tag
docker pull ghcr.io/aweber-imbi/iggy:0.9.0-edge.6-0
```

Tags follow `<upstream server version>-<n>`, where `n` increments for each
change to this repository against the same upstream server version.

### Use in Docker Compose

```yaml
services:
  iggy:
    image: ghcr.io/aweber-imbi/iggy:0.9.0-edge.6-0
    ports:
      - 3000
      - 8090
    environment:
      IGGY_ROOT_USERNAME: iggy
      IGGY_ROOT_PASSWORD: iggy
      IGGY_HTTP_ENABLED: true
      IGGY_HTTP_ADDRESS: 0.0.0.0:3000
      IGGY_TCP_ENABLED: true
      IGGY_TCP_ADDRESS: 0.0.0.0:8090
    cap_add:
      - SYS_NICE
    security_opt:
      - seccomp:unconfined
    ulimits:
      memlock:
        soft: -1
        hard: -1
    healthcheck:
      test: ["CMD", "iggy", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10

  iggy-connect:
    image: ghcr.io/aweber-imbi/iggy:0.9.0-edge.6-0
    environment:
      IGGY_MODE: connectors
      IGGY_CONNECTORS_CONNECTORS_BASE_URL: http://imbi-api:8000/iggy/connectors
      IGGY_CONNECTORS_API_KEY: ${IGGY_CONNECTORS_API_KEY:?}
      IGGY_CONNECTORS_IGGY_ADDRESS: iggy:8090
      IGGY_CONNECTORS_IGGY_USERNAME: iggy
      IGGY_CONNECTORS_IGGY_PASSWORD: iggy
    depends_on:
      iggy:
        condition: service_healthy
      clickhouse:
        condition: service_healthy
```

## Environment variables

### Read by this image's entrypoint

#### `IGGY_MODE`

`server` (default) or `connectors`. In `server` mode the entrypoint execs
the upstream `iggy-server` unchanged, passing through any arguments. In
`connectors` mode it checks that the configuration URL is set and execs
`iggy-connectors`.

#### `IGGY_CONNECTORS_CONNECTORS_BASE_URL`

**Required when `IGGY_MODE=connectors`.** The base URL of the imbi-api
connector configuration endpoints, without a trailing slash, for example
`http://imbi-api:8000/iggy/connectors`. The runtime appends
`/configs/active` and the other paths in `connectors/README.md` to it.

The doubled `CONNECTORS` is not a typo. The runtime's environment prefix
is `IGGY_CONNECTORS_` and the configuration section is `[connectors]`.

#### `IGGY_CONNECTORS_API_KEY`

**Required when `IGGY_MODE=connectors`.** The key imbi-api expects as
`Authorization: Bearer <key>` on the connector configuration endpoints.

The runtime sends that header from `[connectors.request_headers]`, which
is the one provider setting it does not read from the environment. So
connectors mode copies `/etc/iggy/connectors/config.toml` to
`/tmp/iggy-connectors/config.toml`, mode 600, substitutes this value into
the placeholder, and points the runtime at the copy. The image itself
never carries a key.

#### `IGGY_CONNECTORS_CONFIG_SRC`, `IGGY_CONNECTORS_CONFIG_DST`

Where that configuration is read from and rendered to. They default to
`/etc/iggy/connectors/config.toml` and `/tmp/iggy-connectors/config.toml`.
`IGGY_CONNECTORS_CONFIG_PATH` is set by the entrypoint to the rendered
copy; do not set it yourself.

### Read by the connectors runtime

Every section of `connectors/config.toml` is overridable with
`IGGY_CONNECTORS_<SECTION>_<KEY>`. The ones Imbi sets:

- `IGGY_CONNECTORS_IGGY_ADDRESS` — the Iggy server's TCP address,
  `iggy:8090` in Compose
- `IGGY_CONNECTORS_IGGY_USERNAME` — defaults to `iggy`
- `IGGY_CONNECTORS_IGGY_PASSWORD` — defaults to `iggy`
- `IGGY_CONNECTORS_CONNECTORS_TIMEOUT` — configuration request timeout,
  `10s` by default

`[connectors.request_headers]` is the one provider setting that is not
env-addressable. The entrypoint renders the API key into it, as described
under `IGGY_CONNECTORS_API_KEY` above.

### Read by the upstream server

Unchanged from the base image. The ones Imbi's Compose sets:

- `IGGY_ROOT_USERNAME`, `IGGY_ROOT_PASSWORD` — the root user created on
  first start
- `IGGY_TCP_ENABLED`, `IGGY_TCP_ADDRESS` — the TCP transport, `0.0.0.0:8090`
- `IGGY_HTTP_ENABLED`, `IGGY_HTTP_ADDRESS` — the HTTP API, `0.0.0.0:3000`
- `IGGY_SYSTEM_SHARDING_PIN_CORES` — see below

#### Running on Docker Desktop

Since 0.9.0 the server pins each shard thread to a core and binds that
shard's memory to the core's NUMA node. `mbind()` is not supported inside
the Docker Desktop virtual machine, so every shard fails and the server
exits with `ShardJoinFailures ... MemoryAffinityFailed`. This is upstream
behaviour; `apache/iggy:0.9.0-edge.6` fails the same way on its own.

Set `IGGY_SYSTEM_SHARDING_PIN_CORES=false` to drop both the CPU and the
memory-node binding. `compose.test.yaml` sets it, and Imbi's `compose.yaml`
and `compose.ci.yaml` need it too. Leave it unset on a Linux host, where
pinning is what you want.

## Streams and topics

Which streams and topics reach ClickHouse is decided by imbi-api, not by
this repository. It answers `GET /configs/active` with one sink per
ClickHouse-bound stream, where the stream name, the consumer group name
and the ClickHouse table name are the same string, and where each sink
sets `schema = "json"`, `insert_format = "json_each_row"`,
`batch_length = 1000` and `poll_interval = "250ms"`.

`imbi.common.iggy.TOPICS` in the Imbi repository is the source of both
that response and the publisher's topic list, so the two cannot drift.

The runtime reads the configuration exactly once at startup and never
polls, so a change to a topic list takes effect when the connectors
container restarts.

`connectors/README.md` carries the full contract, and
`test/config_server.py` is a working implementation of it for one sink.

## Running the end-to-end test

`compose.test.yaml` starts this image in both modes alongside ClickHouse
and `test/config_server.py`, a stub of the imbi-api configuration
endpoints that serves one `events` sink and rejects any request without
the expected bearer token, so the run proves the header arrives. `test/e2e.sh` creates the
`events` table, creates the `events` stream and its `gateway` topic,
publishes one JSON row with the `iggy` CLI, and polls ClickHouse for it.

```bash
docker compose -f compose.test.yaml up -d --wait
test/e2e.sh
docker compose -f compose.test.yaml down -v
```

The connectors runtime joins a consumer group on a topic that has to exist
already, so its first start before the script runs will exit. It is
configured with `restart: on-failure`, and the script recreates it once
the stream and topic are in place.
