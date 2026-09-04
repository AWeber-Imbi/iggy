"""Stub of the imbi-api connector configuration endpoints.

Serves exactly the JSON the Apache Iggy connectors runtime's `http`
configuration provider expects, for one sink named `events`. It exists so
`compose.test.yaml` can prove the response shape end to end before
imbi-api implements it. connectors/README.md documents the contract.

The runtime calls GET /configs/active once at startup and never again.
The other routes are here because the runtime's own HTTP API proxies to
them when an operator adds or activates a configuration version.
"""

import json
import os
from http import server

CLICKHOUSE_URL = os.environ.get('CLICKHOUSE_URL', 'http://clickhouse:8123')
CLICKHOUSE_DATABASE = os.environ.get('CLICKHOUSE_DATABASE', 'imbi')
CLICKHOUSE_USERNAME = os.environ.get('CLICKHOUSE_USERNAME', 'default')
CLICKHOUSE_PASSWORD = os.environ.get('CLICKHOUSE_PASSWORD', 'password')
PLUGIN_PATH = os.environ.get(
    'PLUGIN_PATH', '/opt/iggy/connectors/libiggy_connector_clickhouse_sink'
)
API_KEY = os.environ.get('API_KEY', 'test-api-key')

EVENTS_SINK = {
    'key': 'events',
    'enabled': True,
    'version': 0,
    'name': 'ClickHouse sink: events',
    'path': PLUGIN_PATH,
    'transforms': None,
    'streams': [
        {
            'stream': 'events',
            'topics': ['gateway'],
            'schema': 'json',
            'avro_schema_json': None,
            'avro_schema_path': None,
            'batch_length': 1000,
            'poll_interval': '250ms',
            'consumer_group': 'events',
        }
    ],
    'plugin_config_format': 'json',
    'plugin_config': {
        'url': CLICKHOUSE_URL,
        'database': CLICKHOUSE_DATABASE,
        'username': CLICKHOUSE_USERNAME,
        'password': CLICKHOUSE_PASSWORD,
        'table': 'events',
        'insert_format': 'json_each_row',
        'timeout_seconds': 30,
        'max_retries': 3,
        'retry_delay': 1,
        'verbose_logging': False,
    },
    'verbose': False,
    'benchmark': False,
}

ACTIVE_CONFIGS = {'sinks': {'events': EVENTS_SINK}, 'sources': {}}

ACTIVE_VERSIONS = {
    'sinks': {'events': {'version': 0, 'created_at': '2026-09-04T00:00:00Z'}},
    'sources': {},
}


class Handler(server.BaseHTTPRequestHandler):
    def _send(self, payload: object, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        """Reject anything that does not carry the expected bearer token.

        The runtime sends this from [connectors.request_headers], which
        the entrypoint renders from IGGY_CONNECTORS_API_KEY. Refusing
        here is what proves the header actually arrives.
        """
        if self.headers.get('Authorization') == f'Bearer {API_KEY}':
            return True
        print(
            'config-server: rejecting request without a valid bearer token',
            flush=True,
        )
        self._send({'error': 'unauthorized'}, 401)
        return False

    def do_GET(self) -> None:  # noqa: N802
        if self.path == '/healthz':
            # Unauthenticated so the compose healthcheck does not need the
            # token. Not part of the contract imbi-api implements.
            self._send({'status': 'ok'})
            return
        if not self._authorized():
            return
        if self.path == '/configs/active':
            self._send(ACTIVE_CONFIGS)
        elif self.path == '/configs/active/versions':
            self._send(ACTIVE_VERSIONS)
        elif self.path == '/sinks/events/configs':
            self._send([EVENTS_SINK])
        elif self.path in (
            '/sinks/events/configs/active',
            '/sinks/events/configs/0',
        ):
            self._send(EVENTS_SINK)
        elif self.path.startswith('/sources/'):
            self._send({'error': 'not found'}, 404)
        else:
            self._send({'error': 'not found'}, 404)

    def do_POST(self) -> None:  # noqa: N802
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if not self._authorized():
            return
        self._send(EVENTS_SINK, 201)

    def do_PUT(self) -> None:  # noqa: N802
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if not self._authorized():
            return
        self._send({}, 200)

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authorized():
            return
        self._send({}, 200)

    def log_message(self, fmt: str, *args: object) -> None:
        print(f'config-server: {fmt % args}', flush=True)


if __name__ == '__main__':
    server.HTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
