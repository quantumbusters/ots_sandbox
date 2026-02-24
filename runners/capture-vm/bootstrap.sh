#!/usr/bin/env bash
# ============================================================
# bootstrap.sh
# Runs ONCE on capture VM after provisioning (via CustomScript
# extension or manual SSH). Sets up:
#   1. VXLAN decapsulation interface (vxlan0) bound to UDP/4789
#   2. tcpdump permissions
#   3. capture-agent as a systemd service
#   4. az cli + python deps
#
# The VNet TAP delivers mirrored frames as VXLAN encapsulated
# UDP to this VM on port 4789. We create a kernel VXLAN
# interface to decapsulate — tcpdump on vxlan0 then sees the
# original inner Ethernet frames from the runner containers.
# ============================================================
set -euo pipefail

CAPTURE_USER="captureuser"
CAPTURE_DIR="/opt/capture"
VXLAN_IFACE="vxlan0"
VXLAN_PORT=4789
VXLAN_VNI=0       # Azure TAP uses VNI=0; match exactly

log() { echo "[bootstrap] $*"; }

# ── 1. System packages ────────────────────────────────────────
log "Installing packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    tcpdump tshark gzip jq curl iproute2 python3 python3-pip \
    net-tools ethtool

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Python deps for capture-agent
pip3 install --no-cache-dir azure-storage-blob

# ── 2. VXLAN interface ────────────────────────────────────────
log "Configuring VXLAN decap interface: $VXLAN_IFACE"

# Create VXLAN interface — no remote (any source), dstport must match TAP
ip link add "$VXLAN_IFACE" type vxlan \
    id "$VXLAN_VNI" \
    dstport "$VXLAN_PORT" \
    local 10.10.2.4 \
    nolearning \
    dev eth0 \
    || log "vxlan0 may already exist, continuing"

ip link set "$VXLAN_IFACE" up
ip link set "$VXLAN_IFACE" promisc on

log "vxlan0 up: $(ip link show $VXLAN_IFACE | head -1)"

# Persist across reboots via systemd-networkd override
cat > /etc/systemd/network/10-vxlan0.netdev << 'EOF'
[NetDev]
Name=vxlan0
Kind=vxlan

[VXLAN]
VNI=0
Local=10.10.2.4
DestinationPort=4789
Independent=true
EOF

cat > /etc/systemd/network/10-vxlan0.network << 'EOF'
[Match]
Name=vxlan0

[Link]
Promiscuous=yes

[Network]
# No IP needed — we only capture, not route
EOF

systemctl enable systemd-networkd
systemctl restart systemd-networkd || true

# ── 3. tcpdump capabilities (no-sudo) ────────────────────────
log "Granting tcpdump CAP_NET_RAW to $CAPTURE_USER..."
setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
# Allow wireshark group to capture
usermod -aG wireshark "$CAPTURE_USER" 2>/dev/null || true

# ── 4. Capture agent directory ────────────────────────────────
mkdir -p "$CAPTURE_DIR"
mkdir -p /tmp/pcaps
chown -R "$CAPTURE_USER":"$CAPTURE_USER" "$CAPTURE_DIR" /tmp/pcaps

# ── 5. systemd service for capture-agent ─────────────────────
log "Installing capture-agent systemd service..."

cat > /etc/systemd/system/capture-agent.service << EOF
[Unit]
Description=TLS Sandbox Capture Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CAPTURE_USER
WorkingDirectory=$CAPTURE_DIR
EnvironmentFile=$CAPTURE_DIR/capture-agent.env
ExecStart=/usr/bin/python3 $CAPTURE_DIR/capture-agent.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Env file template — populated by run-tests.sh before each run
cat > "$CAPTURE_DIR/capture-agent.env" << 'EOF'
# Populated by run-tests.sh via az vm run-command invoke before each run
STORAGE_CONN_STR=
STORAGE_ACCOUNT_NAME=
OFFSITE_WEBHOOK_URL=
RUNNER_SUBNET=10.10.1.0/24
CAPTURE_IFACE=vxlan0
EOF

chown "$CAPTURE_USER":"$CAPTURE_USER" "$CAPTURE_DIR/capture-agent.env"
chmod 600 "$CAPTURE_DIR/capture-agent.env"  # env contains secrets

systemctl daemon-reload
systemctl enable capture-agent

log "Bootstrap complete. Reboot recommended to validate vxlan0 persistence."
log "After reboot: systemctl start capture-agent"