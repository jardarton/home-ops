#!/usr/bin/env bash
set -euo pipefail

env_file="${HA_ENV_FILE:-.private/home-assistant/env}"

if [[ ! -f "$env_file" ]]; then
  echo "Missing env file: $env_file" >&2
  echo "Create it with HASS_SERVER and HASS_TOKEN." >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$env_file"

if [[ -z "${HASS_SERVER:-}" || -z "${HASS_TOKEN:-}" || "${HASS_TOKEN}" == "paste-long-lived-access-token-here" ]]; then
  echo "Set HASS_SERVER and HASS_TOKEN in $env_file" >&2
  exit 1
fi

export HASS_SERVER HASS_TOKEN

exec hass-cli "$@"
