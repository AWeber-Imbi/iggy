#!/usr/bin/env bash
# End-to-end check: publish one JSON message to the Iggy stream
# events / topic gateway and read the row back from ClickHouse.
#
# Usage:  docker compose -f compose.test.yaml up -d --wait
#         test/e2e.sh
#         docker compose -f compose.test.yaml down -v
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f compose.test.yaml)
CH=("${COMPOSE[@]}" exec -T clickhouse clickhouse client --user default
    --password password --database imbi -q)
IGGY=("${COMPOSE[@]}" exec -T iggy iggy --username iggy --password iggy)

echo "==> creating the events table"
"${CH[@]}" "
CREATE TABLE IF NOT EXISTS imbi.events (
  id                   String           DEFAULT '',
  project_id           LowCardinality(String),
  recorded_at          DateTime64(3, 'UTC'),
  type                 LowCardinality(String) DEFAULT '',
  integration          LowCardinality(String) DEFAULT '',
  attributed_to        LowCardinality(String) DEFAULT '',
  metadata             JSON,
  payload              JSON,
  version              UInt8 DEFAULT 0
) ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(recorded_at)
ORDER BY (project_id, id)"

echo "==> creating the events stream and the gateway topic"
"${IGGY[@]}" stream create events || echo "    the stream already exists"
"${IGGY[@]}" topic create events gateway 1 none || echo "    the topic already exists"

echo "==> restarting the connectors runtime so it joins the consumer group"
"${COMPOSE[@]}" up -d --force-recreate iggy-connect
sleep 5

ID="e2e-$(date +%s)-$RANDOM"
RECORDED_AT="$(date -u +%Y-%m-%dT%H:%M:%S.000)"
MESSAGE=$(printf '{"id":"%s","project_id":"1","recorded_at":"%s","type":"deployment","integration":"github","attributed_to":"e2e","metadata":{"webhook_id":"wh-1"},"payload":{"ok":true},"version":0}' \
          "$ID" "$RECORDED_AT")

echo "==> publishing to events/gateway"
echo "    $MESSAGE"
"${IGGY[@]}" message send events gateway "$MESSAGE"

echo "==> polling ClickHouse for the row"
for _ in $(seq 1 30); do
    COUNT=$("${CH[@]}" "SELECT count() FROM imbi.events WHERE id = '$ID'" | tr -d '[:space:]')
    if [ "$COUNT" = "1" ]; then
        echo "==> found the row after the wait"
        "${CH[@]}" "SELECT * FROM imbi.events WHERE id = '$ID' FORMAT Vertical"
        exit 0
    fi
    sleep 1
done

echo "==> the row never arrived; connectors runtime log follows" >&2
"${COMPOSE[@]}" logs --tail 50 iggy-connect >&2
exit 1
