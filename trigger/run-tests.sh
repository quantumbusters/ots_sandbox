#!/usr/bin/env bash
# ============================================================
# run-tests.sh v3 — adds VNet TAP NIC attachment lifecycle
#
# New steps vs v2:
#   3b. After ACI containers are created, attach VNet TAP to
#       each container's NIC (TAP is per-NIC, not per-subnet)
#   6b. Before cleanup, detach TAP from NICs
#
# Full lifecycle:
#   1.  Start (allocate) capture VM
#   2.  Inject env → start capture-agent service
#   3.  Signal capture-agent START
#   3b. Create ACI containers → discover NIC IDs → attach TAP
#   4.  Wait for ACI runners to complete
#   5.  Signal capture-agent STOP
#   6.  Poll until VM phase=done (upload + webhook complete)
#   6b. Detach TAP from NICs
#   7.  Deallocate VM + delete ACI containers
# ============================================================
set -euo pipefail

# ── Required env vars ────────────────────────────────────────
: "${RESOURCE_GROUP:?}"
: "${ACR_LOGIN_SERVER:?}"
: "${RUNNER_SUBNET_ID:?}"
: "${STORAGE_CONN_STR:?}"
: "${STORAGE_ACCOUNT_NAME:?}"
: "${LAW_WORKSPACE_ID:?}"
: "${LAW_SHARED_KEY:?}"
: "${CAPTURE_VM_NAME:?}"
: "${CAPTURE_VM_PUBLIC_IP:?}"
: "${CAPTURE_VM_SSH_KEY:?}"
: "${OFFSITE_WEBHOOK_URL:?}"
: "${TAP_ID:?}"                  # Resource ID of the VNet TAP (from bicep output)
: "${LOCATION:?}"

RUNNER="both"
TARGETS_FILE="targets.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --targets) TARGETS_FILE="$2"; shift 2 ;;
    --runner)  RUNNER="$2";       shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

TARGETS_JSON=$(cat "$TARGETS_FILE")
RUN_ID=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
CAPTURE_AGENT_URL="http://${CAPTURE_VM_PUBLIC_IP}:9000"
ATTACHED_NICS=()   # track TAP-attached NIC IDs for cleanup

log()     { echo "$(date -u +%H:%M:%SZ) $*"; }
die()     { log "ERROR: $*"; teardown; exit 1; }
ssh_vm()  { ssh -i "$CAPTURE_VM_SSH_KEY" -o StrictHostKeyChecking=no \
                -o ConnectTimeout=15 "captureuser@${CAPTURE_VM_PUBLIC_IP}" "$@"; }
http_get()  { curl -sf "$1"; }
http_post() { curl -sf -X POST -H "Content-Type: application/json" -d "$2" "$1"; }

# ── TAP attachment helpers ────────────────────────────────────
attach_tap_to_nic() {
  local nic_id=$1
  local nic_name=${nic_id##*/}
  log "  [tap] Attaching TAP to NIC: $nic_name"
  az network nic update \
    --ids "$nic_id" \
    --set "tapConfigurations=[{\"virtualNetworkTap\":{\"id\":\"${TAP_ID}\"}}]" \
    --output none
  ATTACHED_NICS+=("$nic_id")
  log "  [tap] ✓ $nic_name"
}

detach_tap_from_nics() {
  for nic_id in "${ATTACHED_NICS[@]}"; do
    local nic_name=${nic_id##*/}
    log "  [tap] Detaching TAP from NIC: $nic_name"
    az network nic update \
      --ids "$nic_id" \
      --set "tapConfigurations=[]" \
      --output none 2>/dev/null || true
  done
}

get_aci_nic_id() {
  # ACI containers in a VNet get a NIC in the runner subnet.
  # We find it by filtering NICs in the RG that have the container group name tag.
  local container_name=$1
  az network nic list \
    --resource-group "$RESOURCE_GROUP" \
    --query "[?contains(name, '${container_name}')].id" \
    -o tsv | head -1
}

# ── Teardown (called on error) ────────────────────────────────
teardown() {
  log "[teardown] Detaching TAPs..."
  detach_tap_from_nics
  log "[teardown] Removing ACI containers..."
  for suffix in "curl-${RUN_ID}" "chrome-${RUN_ID}"; do
    az container delete -g "$RESOURCE_GROUP" -n "aci-${suffix}" --yes --output none 2>/dev/null || true
  done
  log "[teardown] Deallocating VM..."
  az vm deallocate -g "$RESOURCE_GROUP" -n "$CAPTURE_VM_NAME" --no-wait 2>/dev/null || true
}
trap teardown ERR

# ── ACI launcher (returns container name) ────────────────────
create_aci() {
  local name=$1; local image=$2; local cpu=$3; local mem=$4
  shift 4; local extra_envs=("$@")
  local base_envs=(
    "RUN_ID=${RUN_ID}"
    "TARGETS_JSON=${TARGETS_JSON}"
    "STORAGE_CONN_STR=${STORAGE_CONN_STR}"
    "LAW_WORKSPACE_ID=${LAW_WORKSPACE_ID}"
    "LAW_SHARED_KEY=${LAW_SHARED_KEY}"
  )
  local all_envs=("${base_envs[@]}" "${extra_envs[@]}")
  local env_args=""
  for e in "${all_envs[@]}"; do env_args+=" --environment-variables $e"; done

  az container create \
    --resource-group "$RESOURCE_GROUP" --name "$name" \
    --image "$image" --cpu "$cpu" --memory "$mem" \
    --os-type Linux --restart-policy Never \
    --subnet "$RUNNER_SUBNET_ID" \
    --registry-server "$ACR_LOGIN_SERVER" \
    $env_args \
    --output none
  log "  ACI created: $name"
}

wait_aci() {
  local name=$1
  while true; do
    s=$(az container show -g "$RESOURCE_GROUP" -n "$name" \
          --query "containers[0].instanceView.currentState.state" -o tsv 2>/dev/null || echo "Unknown")
    [[ "$s" == "Terminated" ]] && { log "  ACI done: $name"; return 0; }
    [[ "$s" == "Failed"     ]] && die "ACI $name failed"
    sleep 10
  done
}

# ═══════════════════════════════════════════════════════════════
log "══════════════════════════════════════════════════"
log "  TLS Regression Run    RUN_ID=${RUN_ID}"
log "  Runner: ${RUNNER}"
log "══════════════════════════════════════════════════"

# ── 1. Start capture VM ───────────────────────────────────────
log "[1/7] Starting capture VM: $CAPTURE_VM_NAME"
az vm start -g "$RESOURCE_GROUP" -n "$CAPTURE_VM_NAME"
log "  Waiting 40s for boot + agent..."
sleep 40

# ── 2. Inject secrets → (re)start capture-agent ──────────────
log "[2/7] Configuring capture-agent"
az vm run-command invoke \
  -g "$RESOURCE_GROUP" -n "$CAPTURE_VM_NAME" \
  --command-id RunShellScript \
  --scripts "
    cat > /opt/capture/capture-agent.env <<'ENVEOF'
STORAGE_CONN_STR=${STORAGE_CONN_STR}
STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT_NAME}
OFFSITE_WEBHOOK_URL=${OFFSITE_WEBHOOK_URL}
RUNNER_SUBNET=10.10.1.0/24
CAPTURE_IFACE=vxlan0
ENVEOF
    chmod 600 /opt/capture/capture-agent.env
    systemctl restart capture-agent
    sleep 3
    systemctl is-active capture-agent
  " --output none

# ── 3. Signal capture START ───────────────────────────────────
log "[3/7] Starting packet capture"
RUNNERS_ARG='["curl","chrome"]'
[[ "$RUNNER" == "curl"   ]] && RUNNERS_ARG='["curl"]'
[[ "$RUNNER" == "chrome" ]] && RUNNERS_ARG='["chrome"]'
http_post "${CAPTURE_AGENT_URL}/start" \
  "{\"run_id\":\"${RUN_ID}\",\"runners\":${RUNNERS_ARG}}" \
  || die "capture-agent unreachable"

# ── 3b. Create ACI containers + attach TAP ───────────────────
log "[3b/7] Creating ACI containers and attaching VNet TAP"

if [[ "$RUNNER" == "curl" || "$RUNNER" == "both" ]]; then
  create_aci "aci-curl-${RUN_ID}" \
    "${ACR_LOGIN_SERVER}/curl-runner:latest" 2 4
  # TAP must be attached after NIC is created (NIC exists once container starts)
  sleep 15
  NIC_ID=$(get_aci_nic_id "aci-curl-${RUN_ID}")
  [[ -n "$NIC_ID" ]] && attach_tap_to_nic "$NIC_ID" || log "  WARN: could not find NIC for curl runner"
fi

if [[ "$RUNNER" == "chrome" || "$RUNNER" == "both" ]]; then
  create_aci "aci-chrome-${RUN_ID}" \
    "${ACR_LOGIN_SERVER}/chrome-runner:latest" 4 8 \
    "CHROME_WORKERS=4"
  sleep 15
  NIC_ID=$(get_aci_nic_id "aci-chrome-${RUN_ID}")
  [[ -n "$NIC_ID" ]] && attach_tap_to_nic "$NIC_ID" || log "  WARN: could not find NIC for chrome runner"
fi

# ── 4. Wait for ACI runners ───────────────────────────────────
log "[4/7] Waiting for ACI runners to complete"
[[ "$RUNNER" == "curl"   || "$RUNNER" == "both" ]] && wait_aci "aci-curl-${RUN_ID}"   &
[[ "$RUNNER" == "chrome" || "$RUNNER" == "both" ]] && wait_aci "aci-chrome-${RUN_ID}" &
wait

# ── 5. Stop capture ───────────────────────────────────────────
log "[5/7] Stopping packet capture"
http_post "${CAPTURE_AGENT_URL}/stop" "{\"run_id\":\"${RUN_ID}\"}" \
  || die "Failed to stop capture-agent"

# ── 6. Poll until upload + webhook done ──────────────────────
log "[6/7] Waiting for upload and webhook dispatch..."
MAX_WAIT=360; ELAPSED=0
while true; do
  PHASE=$(http_get "${CAPTURE_AGENT_URL}/status" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['phase'])")
  log "  capture-agent: $PHASE"
  [[ "$PHASE" == "done" ]] && break
  [[ $ELAPSED -ge $MAX_WAIT ]] && die "Timed out waiting for capture-agent"
  sleep 10; ELAPSED=$((ELAPSED+10))
done

# ── 6b. Detach TAP from all NICs ─────────────────────────────
log "[6b/7] Detaching VNet TAP from runner NICs"
detach_tap_from_nics

# ── 7. Cleanup ────────────────────────────────────────────────
log "[7/7] Cleaning up resources"
for suffix in "curl-${RUN_ID}" "chrome-${RUN_ID}"; do
  az container delete -g "$RESOURCE_GROUP" -n "aci-${suffix}" \
    --yes --output none 2>/dev/null || true
done
az vm deallocate -g "$RESOURCE_GROUP" -n "$CAPTURE_VM_NAME" --no-wait

log ""
log "══════════════════════════════════════════════════"
log "  Run complete"
log "  RUN_ID  : $RUN_ID"
log "  PCAPs   : pcap-staging/${RUN_ID}/ (24h TTL)"
log "  Webhook : $OFFSITE_WEBHOOK_URL notified"
log "  Cost    : VM + ACI now deallocating"
log "══════════════════════════════════════════════════"