# TLS Regression Sandbox — How To Run

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Azure CLI (`az`) | ≥ 2.57 | Deploy infra, manage ACI + VM |
| Python 3 | ≥ 3.10 | Orchestration scripts |
| Docker | ≥ 24 | Build runner images locally |
| SSH keypair | — | Access capture VM |
| `jq` | any | JSON parsing in shell scripts |
| `curl` | any | Health-check capture-agent |

You must be logged in to Azure with sufficient permissions:

```bash
az login
az account set --subscription "<your-subscription-id>"
```

---

## Step 1 — Deploy Infrastructure (once)

```bash
# Create the resource group
az group create \
  --name tls-sandbox-rg \
  --location eastus

# Deploy all Bicep modules
az deployment group create \
  --resource-group tls-sandbox-rg \
  --template-file infra/main.bicep \
  --parameters \
      env=sandbox \
      adminSshKey="$(cat ~/.ssh/id_rsa.pub)" \
      offSiteWebhookUrl="https://your-app.example.com/ingest/pcap"
```

Save the outputs — you will need them in Step 3:

```bash
az deployment group show \
  --resource-group tls-sandbox-rg \
  --name main \
  --query properties.outputs \
  -o json
```

Key outputs to note:

| Output | Used for |
|---|---|
| `acrLoginServer` | Image push + ACI pull |
| `runnerSubnetId` | ACI container placement |
| `captureVmPublicIp` | SSH + capture-agent HTTP |
| `captureVmName` | VM start/stop |
| `tapId` | NIC TAP attachment |
| `storageAccount` | Connection string lookup |
| `lawWorkspaceId` | Log Analytics queries |

---

## Step 2 — Bootstrap the Capture VM (once)

Run this **one time** after infrastructure is deployed. It installs `tcpdump`, sets up the VXLAN decap interface, and registers the capture-agent as a systemd service.

```bash
# Start the VM temporarily
az vm start --resource-group tls-sandbox-rg --name vm-capture-sandbox

# Copy and run bootstrap
scp -i ~/.ssh/id_rsa \
    runners/capture-vm/bootstrap.sh \
    captureuser@<CAPTURE_VM_PUBLIC_IP>:/tmp/bootstrap.sh

ssh -i ~/.ssh/id_rsa captureuser@<CAPTURE_VM_PUBLIC_IP> \
    "sudo bash /tmp/bootstrap.sh"

# Reboot to validate vxlan0 persistence
ssh -i ~/.ssh/id_rsa captureuser@<CAPTURE_VM_PUBLIC_IP> "sudo reboot"

# Deallocate when done — do not leave running
az vm deallocate --resource-group tls-sandbox-rg --name vm-capture-sandbox
```

---

## Step 3 — Build and Push Runner Images (once, then on change)

```bash
ACR="<acrLoginServer>"   # e.g. tlssandboxabc123.azurecr.io
az acr login --name "${ACR%%.*}"

az acr build --registry "${ACR%%.*}" \
  --image curl-runner:latest \
  runners/curl-runner/

az acr build --registry "${ACR%%.*}" \
  --image chrome-runner:latest \
  runners/chrome-runner/
```

---

## Step 4 — Prepare Your Targets File

Create `targets.json` — a JSON array of hostnames (no scheme, no path):

```json
[
  "example.com",
  "tls13.1password.com",
  "badssl.com",
  "expired.badssl.com",
  "tls-v1-0.badssl.com",
  "tls-v1-1.badssl.com"
]
```

> **Tip:** `badssl.com` subdomains are purpose-built for TLS regression testing and cover every failure mode your scripts should handle.

---

## Step 5 — Set Environment Variables

Export these before every run. Store them in a `.env` file (never commit it):

```bash
export RESOURCE_GROUP="tls-sandbox-rg"
export ACR_LOGIN_SERVER="<acrLoginServer>"
export RUNNER_SUBNET_ID="<runnerSubnetId>"
export CAPTURE_VM_NAME="vm-capture-sandbox"
export CAPTURE_VM_PUBLIC_IP="<captureVmPublicIp>"
export CAPTURE_VM_SSH_KEY="$HOME/.ssh/id_rsa"
export TAP_ID="<tapId>"
export LOCATION="eastus"
export OFFSITE_WEBHOOK_URL="https://your-app.example.com/ingest/pcap"

# Retrieve storage connection string
export STORAGE_ACCOUNT_NAME="<storageAccount>"
export STORAGE_CONN_STR=$(az storage account show-connection-string \
  --resource-group "$RESOURCE_GROUP" \
  --name "$STORAGE_ACCOUNT_NAME" \
  --query connectionString -o tsv)

# Retrieve Log Analytics keys
export LAW_WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "law-tls-sandbox" \
  --query customerId -o tsv)

export LAW_SHARED_KEY=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$RESOURCE_GROUP" \
  --workspace-name "law-tls-sandbox" \
  --query primarySharedKey -o tsv)
```

---

## Step 6 — Run the Tests

```bash
# Both runners (default)
./trigger/run-tests.sh --targets targets.json

# curl only
./trigger/run-tests.sh --targets targets.json --runner curl

# Chrome only
./trigger/run-tests.sh --targets targets.json --runner chrome
```

### What happens during a run

```
 1. Capture VM starts (allocated)
 2. Secrets injected → capture-agent (re)started via systemd
 3. Capture-agent signals tcpdump START on vxlan0
 3b. ACI containers created → VNet TAP attached to each NIC
 4. curl-runner and chrome-runner execute in parallel
 5. ACI containers reach Terminated state
 6. Capture-agent signals STOP → pcaps flushed and closed
    → gzip compressed → uploaded to pcap-staging/
    → SAS URLs generated → webhook POSTed to offsite app
 7. TAP detached from NICs
 8. ACI containers deleted · VM deallocated (async)

Typical wall-clock time: 12–18 minutes for 300 targets
```

---

## Step 7 — Retrieve Results

### PCAPs (via webhook)

Your offsite application receives a POST to `OFFSITE_WEBHOOK_URL` with the payload defined in `results/webhook-payload-schema.json`. Each `sas_url` is a direct HTTPS link to a `.pcap.gz` file, valid for **24 hours**.

To download manually:

```bash
# List blobs for the run
az storage blob list \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name pcap-staging \
  --prefix "<RUN_ID>/" \
  --query "[].name" -o tsv

# Generate a SAS URL manually (if webhook was missed)
az storage blob generate-sas \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name pcap-staging \
  --name "<RUN_ID>/<filename>.pcap.gz" \
  --permissions r \
  --expiry $(date -u -d '+24 hours' +%Y-%m-%dT%H:%MZ) \
  --full-uri -o tsv
```

Open in Wireshark directly:

```bash
curl -sL "<sas_url>" | gunzip | wireshark -k -i -
```

### JSON test summaries

```bash
az storage blob download \
  --account-name "$STORAGE_ACCOUNT_NAME" \
  --container-name test-results \
  --name "<RUN_ID>/<timestamp>-curl.json" \
  --file results-curl.json
```

### Log Analytics (KQL)

Open **Log Analytics workspace → Logs** in the Azure Portal and use the saved queries in `results/kql-queries.kql`. Key queries:

| Query | Purpose |
|---|---|
| #1 Pass/fail by TLS version | Run summary |
| #3 Sites accepting TLS 1.0/1.1 | Security findings |
| #4 IPv6 reachability gaps | Network coverage |
| #5 curl vs Chrome divergence | Browser-specific issues |

---

## Troubleshooting

**capture-agent unreachable on port 9000**
SSH to the VM and check: `sudo systemctl status capture-agent` and `journalctl -u capture-agent -n 50`

**TAP not capturing traffic**
Verify `vxlan0` is up on the capture VM: `ip link show vxlan0`. Check the ILB health probe is passing in the Azure Portal under the load balancer's backend pool.

**ACI NIC not found after container creation**
The 15s sleep in `run-tests.sh` may be insufficient in slow regions. Increase to 30s or switch to the retry-loop approach described in the architecture notes.

**TLS 1.0/1.1 curl exits with code 35**
Expected — the target refused the handshake. This is an informational result, not an infrastructure failure. Exit code 35 means SSL connect error (remote server rejected).

**Chrome runner OOM killed**
Increase ACI memory from 8GB to 12GB in `run-tests.sh` line `--memory 8`.

---

## Cost Reference

| Resource | State | Cost |
|---|---|---|
| Capture VM (B2s) | Running (~15 min/run) | ~$0.04/run |
| curl ACI (2 vCPU/4GB) | ~10 min/run | ~$0.02/run |
| Chrome ACI (4 vCPU/8GB) | ~20 min/run | ~$0.08/run |
| ACR Basic | Always-on | ~$5/mo |
| Storage + Log Analytics | Always-on | ~$3–7/mo |
| **Total at 10 runs/month** | | **~$15–20/mo** |

All compute resources are **deallocated between runs** — you are not charged for stopped VMs or terminated ACI containers.