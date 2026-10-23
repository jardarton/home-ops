#!/bin/bash
# Hands each finished album folder to Lidarr. Soulseek folder names rarely
# parse, so files are matched by their tags through Lidarr's manual import and
# only clean matches are moved; anything left over stays for manual review.
# The event data comes from the Soulseek network, so only jq ever parses it.
set -euo pipefail
api() { wget -qO- --header "X-Api-Key: ${LIDARR_API_KEY}" --header "Content-Type: application/json" "$@"; }
dir=$(jq -r '.localDirectoryName // empty' <<<"$SLSKD_SCRIPT_DATA")
[[ -n $dir ]] || exit 0
query=$(jq -rn --arg dir "$dir" '"folder=\($dir|@uri)&filterExistingFiles=true"')
body=$(api "${LIDARR_URL}/api/v1/manualimport?${query}" | jq -c '
  [.[] | select(.artist and .album and .albumReleaseId and (.tracks | length > 0) and (.rejections | length == 0))
       | {path, artistId: .artist.id, albumId: .album.id, albumReleaseId, trackIds: [.tracks[].id],
          quality, indexerFlags, disableReleaseSwitching: false}]
  | if length == 0 then empty else {name: "ManualImport", importMode: "move", files: .} end')
if [[ -z $body ]]; then
  echo "lidarr-import: no confident match in ${dir}" >&2
  exit 0
fi
api --post-data "$body" "${LIDARR_URL}/api/v1/command" | jq -c '{id, name, status}'
