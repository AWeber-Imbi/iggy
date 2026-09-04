# Connector configuration

`config.toml` is the connectors runtime configuration baked into the
image. It is the only configuration file the image ships. Sink
definitions are **not** in this repository; the runtime fetches them from
imbi-api at startup through its `http` configuration provider.

This document is the contract imbi-api has to implement. Everything in it
was read from `apache/iggy` at commit
`996ac04c874da857d6d734db4f27ada344e5585d`, the revision label on
`apache/iggy:0.9.0-edge.6`. File paths and line numbers below refer to
that commit.

## Selecting the provider

`config.toml` sets `[connectors] config_type = "http"` and leaves
`base_url` empty. The entrypoint requires
`IGGY_CONNECTORS_CONNECTORS_BASE_URL` and refuses to start without it.

The doubled `CONNECTORS` is not a typo. The prefix is `IGGY_CONNECTORS_`
and the section is `[connectors]`. The provider enum is flattened into
the parent's environment namespace rather than adding a variant segment,
so the variant's fields sit directly under the section
(`core/configs_derive/src/config_env.rs:159-192`, `generate_enum_impl`).
Verified working end to end in `compose.test.yaml`.

`base_url` carries no trailing slash. Each template below is appended to
it verbatim.

## Endpoints

`UrlBuilder` in
`core/connectors/runtime/src/configs/connectors/http_provider/url_builder.rs:21-38`
defines the defaults. Every one is overridable through
`[connectors.url_templates]`, keyed by the template name in the middle
column. Templates substitute `{key}` and `{version}`.

| Method | Default path | Template key | Provider method |
| --- | --- | --- | --- |
| GET | `/configs/active` | `get_active_configs` | `get_active_configs` |
| GET | `/configs/active/versions` | `get_active_versions` | `get_active_configs_versions` |
| POST | `/sinks/{key}/configs` | `create_sink` | `create_sink_config` |
| GET | `/sinks/{key}/configs` | `get_sink_configs` | `get_sink_configs` |
| GET | `/sinks/{key}/configs/{version}` | `get_sink_config` | `get_sink_config`, version given |
| GET | `/sinks/{key}/configs/active` | `get_active_sink_config` | `get_sink_config`, version omitted |
| PUT | `/sinks/{key}/configs/active` | `set_active_sink` | `set_active_sink_version` |
| DELETE | `/sinks/{key}/configs` | `delete_sink_config` | `delete_sink_config` |

The six `source` equivalents exist as well (`create_source`,
`get_source_configs`, `get_source_config`, `get_active_source_config`,
`set_active_source`, `delete_source_config`). Imbi publishes no sources,
so imbi-api can return an empty `sources` object from `/configs/active`
and 404 the rest.

**Only `GET /configs/active` is required for the runtime to start.** It
is called exactly once, from `core/connectors/runtime/src/main.rs:152`,
before any connector is spawned. Nothing re-fetches or polls afterwards.
A configuration change takes effect on a runtime restart, exactly as the
file-based provider behaved.

The other endpoints back the runtime's own HTTP API on port 8081. When an
operator calls `POST /sinks/{key}/configs` or
`PUT /sinks/{key}/configs/active` on the runtime, the runtime forwards
that to imbi-api and returns what imbi-api answers. It stores nothing
locally: the `http` provider performs no filesystem writes, unlike the
local provider, which keeps `.active_versions.toml` beside the sink files
(`.../local_provider.rs:279-313`).

## Response shapes

Deserialization targets live in
`core/connectors/runtime/src/configs/connectors.rs`.

### `GET /configs/active`

`ConnectorsConfig` (`connectors.rs:286-291`), which carries
`#[serde(default)]`, so both keys may be omitted when empty.

```json
{"sinks": {"<key>": {"...SinkConfig..."}}, "sources": {}}
```

The map key and the `key` field inside the object must agree.

### `SinkConfig` (`connectors.rs:105-125`)

The struct has no container-level `#[serde(default)]`. Only `verbose` and
`benchmark` carry field-level defaults, so **every other field must be
present**, including the nullable ones. Send explicit `null` rather than
omitting `transforms`, `plugin_config_format` or `plugin_config`.

```json
{
  "key": "events",
  "enabled": true,
  "version": 0,
  "name": "ClickHouse sink: events",
  "path": "/opt/iggy/connectors/libiggy_connector_clickhouse_sink",
  "transforms": null,
  "streams": ["...StreamConsumerConfig..."],
  "plugin_config_format": "json",
  "plugin_config": {"url": "http://clickhouse:8123"},
  "verbose": false,
  "benchmark": false
}
```

`path` may omit the file extension; the runtime appends `.so` and, for a
relative path, searches beside the executable and the usual library
directories (`main.rs:323-363`).

`plugin_config` is a **nested JSON object**, not an encoded string. The
runtime serializes it straight back to JSON and hands it to the plugin
over the foreign-function boundary (`runtime/src/sink.rs:459-478`,
`init_sink`), and the plugin parses it with `serde_json`. This is why the
ClickHouse credentials no longer need rendering into TOML.

`plugin_config_format` does not change what the plugin receives. It only
labels the configuration for the runtime's
`GET /sinks/{key}/configs/plugin?format=` endpoint.

### `StreamConsumerConfig` (`connectors.rs:186-198`)

Same rule: the `Option` fields are required to be present, so send `null`
where there is no value.

```json
{
  "stream": "events",
  "topics": ["gateway"],
  "schema": "json",
  "avro_schema_json": null,
  "avro_schema_path": null,
  "batch_length": 1000,
  "poll_interval": "250ms",
  "consumer_group": "events"
}
```

The stream and every topic must already exist in Iggy before the runtime
starts. A sink whose stream is missing fails with `Failed to set up sink
consumers` and is skipped for the life of the process.

### `GET /configs/active/versions`

`ConnectorConfigVersions` (`connectors.rs:219-223`).

```json
{"sinks": {"events": {"version": 0, "created_at": "2026-09-04T00:00:00Z"}},
 "sources": {}}
```

### The single-configuration endpoints

`GET /sinks/{key}/configs` returns a JSON array of `SinkConfig`.
`GET /sinks/{key}/configs/active` and `/{version}` return one
`SinkConfig`, or `404` to mean "no such configuration", which the
provider maps to absent rather than to an error
(`http_provider.rs:314-317`).

`POST /sinks/{key}/configs` receives a `CreateSinkConfig`
(`connectors.rs:74-86`), which is a `SinkConfig` without `key` and
`version`, and must answer with the full `SinkConfig` that was stored,
including the version imbi-api assigned.

`PUT /sinks/{key}/configs/active` receives `{"version": 0}`
(`http_provider.rs:39-42`, `SetActiveVersionRequest`) and its response
body is ignored.

`DELETE /sinks/{key}/configs` takes an optional `?version=` query
parameter; without it, every version is meant to go.

## Status codes and error handling

Any non-2xx is an error carrying the status and the response body
(`http_provider.rs:112-125`). The one exception is `404` on the two
single-configuration GETs, which means absent.

Server errors, timeouts and connection failures are retried with
exponential backoff and bounded jitter, per `[connectors.retry]` in
`config.toml`.

## `data_path` and `error_path`

Both are optional and unset in `config.toml`, so responses are
deserialized whole. Setting them changes every endpoint at once
(`response_extractor.rs:36-76`):

- `data_path` is a dot-separated path navigated before deserialization,
  so `"data"` unwraps an envelope keyed on `data`. Numeric segments index
  arrays. A path that does not resolve is an error.
- `error_path` is checked first. If it resolves to anything other than
  null, the request fails with that value as the message, whatever the
  HTTP status said.

If imbi-api wraps its payloads in an envelope, set `data_path`. Serving
the bare objects, as the stub does, needs neither.

## Authentication

imbi-api must require `Authorization: Bearer <key>` on every endpoint in
this document and answer `401` without it.

The runtime sends the header from `[connectors.request_headers]`, a plain
TOML table of header name to value that is attached verbatim to every
request (`http_provider.rs:59-70`). Header names go through
`HeaderName::from_str` and values through `HeaderValue::from_str`, with
no allowlist and no reserved names, so `Authorization` is accepted as
written. This is the same shape the runtime's own README shows for the
state provider.

`request_headers` is the one provider setting that is not
env-addressable (`runtime.rs:295-297`, `#[config_env(skip)]`), so the
image cannot read the key from the environment directly. Instead
`config.toml` ships a placeholder:

```toml
[connectors.request_headers]
Authorization = "Bearer @@IGGY_CONNECTORS_API_KEY@@"
```

and the entrypoint copies the file to `/tmp/iggy-connectors/config.toml`,
mode 600, substituting `IGGY_CONNECTORS_API_KEY` before starting the
runtime. No key is ever baked into the image. The runtime logs
`request_headers` by key only (`runtime.rs:311-314`), so the token does
not reach the log.

Set `[http] api_key` separately if the runtime's own API on port 8081
needs protecting; that is a different key.

## The stub

`test/config_server.py` serves this shape for one sink and is what
`compose.test.yaml` points the runtime at. It is the executable version
of this document: the end-to-end test passes against it, so a response
that matches it is known to work.
