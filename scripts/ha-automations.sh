#!/usr/bin/env bash
set -euo pipefail

namespace="home"
selector="app.kubernetes.io/name=home-assistant"
remote_path="/config/automations.yaml"
local_dir=".private/home-assistant"
local_file="$local_dir/automations.yaml"

usage() {
  cat <<EOF
Usage: $0 pull|push|diff|path

Commands:
  pull    Copy Home Assistant automations.yaml from the pod to $local_file
  push    Copy $local_file back to the pod, making a local timestamped backup first
  diff    Diff local file against the pod version
  path    Print the local editable file path

Environment overrides:
  HA_NAMESPACE=$namespace
  HA_SELECTOR=$selector
  HA_REMOTE_PATH=$remote_path
  HA_LOCAL_DIR=$local_dir
EOF
}

namespace="${HA_NAMESPACE:-$namespace}"
selector="${HA_SELECTOR:-$selector}"
remote_path="${HA_REMOTE_PATH:-$remote_path}"
local_dir="${HA_LOCAL_DIR:-$local_dir}"
local_file="$local_dir/automations.yaml"

pod() {
  kubectl -n "$namespace" get pod -l "$selector" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' \
    | sort \
    | head -n 1
}

require_pod() {
  local p
  p="$(pod)"
  if [[ -z "$p" ]]; then
    echo "No running Home Assistant pod found in namespace '$namespace' with selector '$selector'" >&2
    exit 1
  fi
  printf '%s\n' "$p"
}

cmd="${1:-}"
case "$cmd" in
  pull)
    mkdir -p "$local_dir"
    p="$(require_pod)"
    kubectl -n "$namespace" cp "$p:$remote_path" "$local_file"
    echo "Pulled $namespace/$p:$remote_path -> $local_file"
    ;;
  push)
    if [[ ! -f "$local_file" ]]; then
      echo "Local file missing: $local_file" >&2
      echo "Run: $0 pull" >&2
      exit 1
    fi
    p="$(require_pod)"
    mkdir -p "$local_dir/backups"
    backup="$local_dir/backups/automations.$(date +%Y%m%d-%H%M%S).yaml"
    kubectl -n "$namespace" cp "$p:$remote_path" "$backup"
    kubectl -n "$namespace" cp "$local_file" "$p:$remote_path"
    echo "Backed up current pod file -> $backup"
    echo "Pushed $local_file -> $namespace/$p:$remote_path"
    echo "Reload automations in Home Assistant, or restart: kubectl -n $namespace rollout restart deploy/home-assistant"
    ;;
  diff)
    if [[ ! -f "$local_file" ]]; then
      echo "Local file missing: $local_file" >&2
      echo "Run: $0 pull" >&2
      exit 1
    fi
    p="$(require_pod)"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    kubectl -n "$namespace" cp "$p:$remote_path" "$tmp" >/dev/null
    diff -u "$tmp" "$local_file" || true
    ;;
  path)
    echo "$local_file"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
