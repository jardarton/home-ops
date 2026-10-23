#!/bin/bash
# Hands each finished album folder to Lidarr. The event data comes from the
# Soulseek network, so it is only ever parsed by jq, never by the shell.
set -euo pipefail
dir=$(jq -r '.localDirectoryName // empty' <<<"$SLSKD_SCRIPT_DATA")
[[ -n $dir ]] || exit 0
jq -n --arg path "$dir" '{name: "DownloadedAlbumsScan", path: $path, importMode: "Move"}' |
  wget -qO- --header "X-Api-Key: ${LIDARR_API_KEY}" --header "Content-Type: application/json" \
    --post-file /dev/stdin "${LIDARR_URL}/api/v1/command"
