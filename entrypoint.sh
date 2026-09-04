#!/bin/sh
# Entrypoint for the Imbi Apache Iggy image.
#
# IGGY_MODE=server     (default) runs the upstream iggy-server unchanged.
# IGGY_MODE=connectors runs the connectors runtime, which fetches its sink
#                      definitions from imbi-api over HTTP.
#
# The runtime reads every configuration value from the environment except
# the provider's request_headers, so connectors mode copies the shipped
# configuration and substitutes the imbi-api API key into it. The image
# itself never carries a key.
set -eu

CONFIG_SRC="${IGGY_CONNECTORS_CONFIG_SRC:-/etc/iggy/connectors/config.toml}"
CONFIG_DST="${IGGY_CONNECTORS_CONFIG_DST:-/tmp/iggy-connectors/config.toml}"

die() {
    echo "entrypoint: $*" >&2
    exit 1
}

# Escape a value for the contents of a TOML basic string, then for use as
# the replacement text of a sed s||| command. The order matters: the sed
# pass has to escape the backslashes the TOML pass introduced, or sed
# strips them back out again.
escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | sed -e 's/[\\&|]/\\&/g'
}

render_config() {
    [ -f "$CONFIG_SRC" ] || die "runtime configuration $CONFIG_SRC is missing"
    mkdir -p "$(dirname "$CONFIG_DST")"
    cp "$CONFIG_SRC" "$CONFIG_DST"
    chmod 600 "$CONFIG_DST"
    sed -i "s|@@IGGY_CONNECTORS_API_KEY@@|$(escape "$1")|g" "$CONFIG_DST"
}

case "${IGGY_MODE:-server}" in
    server)
        exec iggy-server "$@"
        ;;
    connectors)
        [ -n "${IGGY_CONNECTORS_CONNECTORS_BASE_URL:-}" ] || die \
            "IGGY_CONNECTORS_CONNECTORS_BASE_URL is required when IGGY_MODE=connectors: the base URL of the imbi-api connector configuration endpoints, without a trailing slash"
        [ -n "${IGGY_CONNECTORS_API_KEY:-}" ] || die \
            "IGGY_CONNECTORS_API_KEY is required when IGGY_MODE=connectors: the key imbi-api expects as 'Authorization: Bearer <key>' on the connector configuration endpoints"
        render_config "$IGGY_CONNECTORS_API_KEY"
        mkdir -p /var/lib/iggy-connectors/state
        echo "entrypoint: connectors mode, configuration from ${IGGY_CONNECTORS_CONNECTORS_BASE_URL}"
        IGGY_CONNECTORS_CONFIG_PATH="$CONFIG_DST"
        export IGGY_CONNECTORS_CONFIG_PATH
        exec iggy-connectors "$@"
        ;;
    *)
        die "unknown IGGY_MODE '${IGGY_MODE}', expected 'server' or 'connectors'"
        ;;
esac
