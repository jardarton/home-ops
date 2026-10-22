#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="${LOG_LEVEL:-info}"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

readonly TALOS_DIR="${ROOT_DIR}/talos"
readonly OUT_DIR="${TALOS_DIR}/clusterconfig"
readonly CLUSTER_NAME="heim"
readonly CLUSTER_ENDPOINT="https://192.168.1.8:6443"
readonly CERT_SANS="127.0.0.1,192.168.1.8"
# The patches are written for this config contract; migrate them before moving to another minor.
readonly SUPPORTED_CONTRACT="v1.13"

# Rendered configs and decrypted secrets never leave this directory until every node renders.
umask 077
WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
trap 'rm -rf "${WORK_DIR}"' EXIT

# Substitute ${VARS} in string values; fails on unset variables so a typo cannot render silently.
function render_patch() {
    local -r src="${1}" dest="${2}"

    if ! yq '(.. | select(tag == "!!str")) |= envsubst(nu)' "${src}" >"${dest}"; then
        log error "Failed to render patch" "file=${src}"
    fi
}

# Appends a talosctl patch flag to PATCH_FLAGS for every patch in a directory, rendered into the work directory.
PATCH_FLAGS=()
function add_patch_flags() {
    local -r flag="${1}" dir="${2}"

    for patch in "${dir}"/*.yaml; do
        local rendered="${WORK_DIR}/patch-$(basename "${dir}")-$(basename "${patch}")"
        render_patch "${patch}" "${rendered}"
        PATCH_FLAGS+=("${flag}" "@${rendered}")
    done
}

function schematic_id() {
    local -r schematic="${TALOS_DIR}/schematics/${1}.yaml"
    local response id

    if [[ ! -f "${schematic}" ]]; then
        log error "Schematic does not exist" "file=${schematic}"
    fi

    # Runs inside $(...), where errexit does not apply, so every step is checked explicitly.
    if ! response=$(curl --fail --silent --show-error --request POST --data-binary "@${schematic}" \
        https://factory.talos.dev/schematics); then
        log error "Failed to resolve schematic" "file=${schematic}"
    fi
    if ! id=$(jq --exit-status --raw-output '.id' <<<"${response}") || [[ ! "${id}" =~ ^[0-9a-f]{64}$ ]]; then
        log error "Image Factory returned an invalid schematic ID" "file=${schematic}"
    fi

    echo "${id}"
}

function generate_base() {
    add_patch_flags --config-patch "${TALOS_DIR}/patches/global"
    add_patch_flags --config-patch-control-plane "${TALOS_DIR}/patches/controlplane"

    log debug "Generating base configs" "talos=${TALOS_VERSION}" "kubernetes=${KUBERNETES_VERSION}"

    sops --decrypt "${TALOS_DIR}/secrets.sops.yaml" >"${WORK_DIR}/secrets.yaml"

    talosctl gen config "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" \
        --with-secrets "${WORK_DIR}/secrets.yaml" \
        --talos-version "${TALOS_VERSION}" \
        --kubernetes-version "${KUBERNETES_VERSION}" \
        --additional-sans "${CERT_SANS}" \
        --with-docs=false \
        --with-examples=false \
        --output-types controlplane,worker,talosconfig \
        --output "${WORK_DIR}" \
        "${PATCH_FLAGS[@]}" >/dev/null
}

function generate_node() {
    local -r node="${1}"
    local role schematic id

    # Assigned separately from local, so a failed lookup still stops the script.
    role=$(yq --exit-status ".\"${node}\".role" "${TALOS_DIR}/nodes.yaml")
    schematic=$(yq --exit-status ".\"${node}\".schematic" "${TALOS_DIR}/nodes.yaml")
    id=$(schematic_id "${schematic}")

    log debug "Generating node config" "node=${node}" "role=${role}" "schematic=${id}"

    cat >"${WORK_DIR}/install-${node}.yaml" <<EOF
machine:
  install:
    image: factory.talos.dev/metal-installer/${id}:${TALOS_VERSION}
EOF
    render_patch "${TALOS_DIR}/nodes/${node}.yaml" "${WORK_DIR}/node-${node}.yaml"

    talosctl machineconfig patch "${WORK_DIR}/${role}.yaml" \
        --patch "@${WORK_DIR}/install-${node}.yaml" \
        --patch "@${WORK_DIR}/node-${node}.yaml" \
        --output "${WORK_DIR}/${CLUSTER_NAME}-${node}.yaml"

    # machineconfig patch does not validate the result, e.g. a node left without an install disk.
    if ! talosctl validate --mode metal --config "${WORK_DIR}/${CLUSTER_NAME}-${node}.yaml" >/dev/null; then
        log error "Rendered config is invalid" "node=${node}"
    fi
}

# Fills NODES, IPS and ENDPOINTS, refusing an inventory with a missing or malformed field.
NODES=() IPS=() ENDPOINTS=()
function load_inventory() {
    local names node ip role

    names=$(yq --exit-status 'keys | .[]' "${TALOS_DIR}/nodes.yaml")
    for node in ${names}; do
        ip=$(yq ".\"${node}\".ip" "${TALOS_DIR}/nodes.yaml")
        role=$(yq ".\"${node}\".role" "${TALOS_DIR}/nodes.yaml")
        if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || ! "${role}" =~ ^(controlplane|worker)$ ]]; then
            log error "Invalid node in inventory" "node=${node}" "ip=${ip}" "role=${role}"
        fi
        NODES+=("${node}")
        IPS+=("${ip}")
        if [[ "${role}" == "controlplane" ]]; then
            ENDPOINTS+=("${ip}")
        fi
    done

    if ((${#ENDPOINTS[@]} == 0)); then
        log error "Inventory has no controlplane nodes"
    fi
}

function generate_talosconfig() {
    talosctl --talosconfig "${WORK_DIR}/talosconfig" config endpoint "${ENDPOINTS[@]}"
    talosctl --talosconfig "${WORK_DIR}/talosconfig" config node "${IPS[@]}"
}

# Older clients cannot parse the multi-document config; other minors need the patches migrated first.
function check_versions() {
    local client

    if [[ "${TALOS_VERSION%.*}" != "${SUPPORTED_CONTRACT}" ]]; then
        log error "Patches target a different Talos minor; migrate them first" \
            "talosVersion=${TALOS_VERSION}" "supported=${SUPPORTED_CONTRACT}"
    fi

    client=$(talosctl version --client --short | awk '/^Talos/ {print $2}')
    if [[ "$(printf '%s\n' "${SUPPORTED_CONTRACT}" "${client%.*}" | sort --version-sort | head -n1)" != "${SUPPORTED_CONTRACT}" ]]; then
        log error "talosctl is older than the config contract" "client=${client}" "supported=${SUPPORTED_CONTRACT}"
    fi
}

function main() {
    check_cli curl jq sops talosctl yq

    TALOS_VERSION=$(yq --exit-status '.talosVersion' "${TALOS_DIR}/talenv.yaml")
    KUBERNETES_VERSION=$(yq --exit-status '.kubernetesVersion' "${TALOS_DIR}/talenv.yaml")
    check_versions
    # Variables available to patches as ${NAME}.
    local env key value
    env=$(sops --decrypt --output-type dotenv "${TALOS_DIR}/talenv.sops.yaml")
    while IFS='=' read -r key value; do
        export "${key}=${value}"
    done <<<"${env}"

    local -a outputs=()
    load_inventory

    generate_base
    for node in "${NODES[@]}"; do
        generate_node "${node}"
        outputs+=("${WORK_DIR}/${CLUSTER_NAME}-${node}.yaml")
    done
    generate_talosconfig

    mv "${outputs[@]}" "${WORK_DIR}/talosconfig" "${OUT_DIR}/"
    log info "Talos configs generated" "dir=${OUT_DIR}"
}

main "$@"
