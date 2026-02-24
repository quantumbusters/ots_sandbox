# Azure TLS Regression Sandbox
**Profile: On-demand runs · Minimal cost · Continuous monitoring readiness**

---

## Architecture Decision Record (First Principles)

### Constraints derived from your answers
| Signal | Implication |
|---|---|
| On-demand only | No always-on compute — zero idle cost |
| Minimal cost | ACI (pay-per-second) beats VMs, App Service, AKS |
| Continuous monitoring | Results must persist and be queryable after each run |
| Manual trigger needed | Need a low-friction invocation path (CLI, portal, or webhook) |

### What we're NOT building (and why)
- ❌ **AKS** — cluster control plane costs ~$70/mo even idle
- ❌ **Azure Functions** — 10-min timeout too short; TLS 1.0/1.1 probing of 300 hosts will exceed it
- ❌ **App Service** — always-on billing model contradicts cost posture
- ❌ **Azure DevOps pipelines as primary trigger** — adds pipeline agent complexity; overkill for on-demand manual runs

---

## Target Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  TRIGGER LAYER  (zero-cost at rest)                             │
│                                                                 │
│  Option A: az cli  →  az container create ...                  │
│  Option B: Azure Logic App (HTTP trigger, consumption plan)    │
│  Option C: GitHub Actions (manual_dispatch workflow)           │
└────────────────────────┬──────────────────────┬────────────────┘
                         │                      │
           ┌─────────────▼──────┐   ┌───────────▼────────────┐
           │  CURL RUNNER (ACI) │   │  CHROME RUNNER (ACI)   │
           │                    │   │                         │
           │  Image:            │   │  Image:                 │
           │  custom-curl:latest│   │  chrome-headless:latest │
           │                    │   │                         │
           │  • curl (multi-TLS)│   │  • Chromium             │
           │  • Python wrapper  │   │  • chromedriver         │
           │  • Dual-stack NIC  │   │  • xvfb                 │
           │  • 2 vCPU / 4GB    │   │  • Python wrapper       │
           │  • ~$0.002/min     │   │  • 4 vCPU / 8GB         │
           └─────────┬──────────┘   └──────────┬─────────────┘
                     │                         │
           ┌─────────▼─────────────────────────▼─────────────┐
           │  RESULTS LAYER  (always-on, cheap)               │
           │                                                  │
           │  Azure Storage Account (Blob)                    │
           │  └── container: test-results/                    │
           │      └── {run-id}/{timestamp}-curl.json          │
           │      └── {run-id}/{timestamp}-chrome.json        │
           │                                                  │
           │  Azure Log Analytics Workspace                   │
           │  └── Custom log table: TLSTestResults_CL         │
           │  └── Saved queries + alert rules                 │
           │                                                  │
           │  Optional: Azure Workbook (Grafana-style UI)     │
           └──────────────────────────────────────────────────┘
```

---

## Resource Inventory & Cost Estimate

| Resource | SKU | Est. Monthly Cost |
|---|---|---|
| Resource Group | — | Free |
| Virtual Network (dual-stack) | Standard | ~$0 (no gateway) |
| Container Registry (ACR) | Basic | ~$5/mo |
| ACI — curl runner | 2 vCPU, 4GB, ~10 min/run | ~$0.02/run |
| ACI — chrome runner | 4 vCPU, 8GB, ~20 min/run | ~$0.08/run |
| Storage Account | LRS, Hot | ~$1–2/mo |
| Log Analytics Workspace | Pay-per-GB | ~$2–5/mo |
| **Total at 10 runs/month** | | **~$10–12/mo** |

---

## File Structure

```
tls-sandbox/
├── infra/
│   ├── main.bicep              # Top-level orchestration (v2 — wires TAP)
│   ├── network.bicep           # Dual-stack VNet + 2 subnets (runners + capture)
│   ├── acr.bicep               # Container registry
│   ├── capture-vm.bicep        # Capture VM + NIC + NSG
│   ├── vnet-tap.bicep          # VNet TAP resource + ILB (HA ports, VXLAN/4789)
│   ├── nic-backend-assoc.bicep # Breaks circular dep: NIC → ILB backend pool
│   ├── storage.bicep           # Blob (pcap-staging 24hTTL + test-results) + Log Analytics
│   └── parameters.json
├── runners/
│   ├── curl-runner/
│   │   ├── Dockerfile
│   │   ├── run.py
│   │   └── entrypoint.sh
│   ├── chrome-runner/
│   │   ├── Dockerfile
│   │   ├── run.py
│   │   └── entrypoint.sh
│   └── capture-vm/
│       ├── bootstrap.sh        # One-time: VXLAN iface + systemd service setup
│       └── capture-agent.py    # HTTP-controlled tcpdump on vxlan0 + uploader
├── trigger/
│   └── run-tests.sh            # v3 — full lifecycle with TAP attach/detach
└── results/
    └── webhook-payload-schema.json
```

## VNet TAP Data Flow

```
curl-runner NIC ──[TAP config]──┐
                                 ├──► ILB frontend (10.10.2.10:4789)
chrome-runner NIC ─[TAP config]─┘         │
                                           │  VXLAN encapsulated
                                      capture VM eth0
                                           │
                                      kernel vxlan0 (decap)
                                           │
                                      tcpdump -i vxlan0
                                           │
                               {run_id}-{runner}-{ipfamily}.pcap
```

---

## IPv6 on Azure — Critical Notes

Azure dual-stack requires **explicit configuration** at three layers:

1. **VNet** — must have both an IPv4 prefix (e.g. `10.0.0.0/16`) and an IPv6 prefix (e.g. `ace:cab:deca::/48`)
2. **Subnet** — must have both address prefixes
3. **ACI NIC** — must request both `ipv4` and `ipv6` via `ipAddressType: Private` with explicit subnet delegation

ACI **public IPv6** is not yet GA on Azure as of early 2026. Workaround: deploy ACI into a VNet subnet and route IPv6 egress via a NAT Gateway or dual-stack load balancer with a public IPv6 prefix.

---

## TLS Version Testing — curl Notes

Default `curl` on Ubuntu/Debian links against OpenSSL 3.x, which **disables TLS 1.0 and 1.1 at the library level** via policy. To test all four versions you need one of:

- **Option A (recommended):** Build curl against OpenSSL with `enable-tls1` and `enable-tls1_1` flags — done in Dockerfile
- **Option B:** Use `--tls-max 1.0` flag + set `OPENSSL_CONF` to a permissive policy file
- **Option C:** Use a separate `curl` binary per TLS version (most isolation, most container layers)

The Dockerfile below uses Option A.