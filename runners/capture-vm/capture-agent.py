#!/usr/bin/env python3
"""
capture-agent.py
Runs ON the capture VM. Manages the full lifecycle:
  1. Start rotating tcpdump processes (one per runner × IP family)
  2. Listen for STOP signal from orchestrator (HTTP on :9000)
  3. On STOP: flush + close PCAPs, gzip, upload to Blob
  4. Generate time-bounded SAS URLs
  5. POST manifest + SAS URLs to offsite webhook
  6. Exit cleanly (orchestrator will deallocate the VM)

Signal protocol (simple HTTP):
  POST /start   body: {"run_id": "...", "runners": ["curl","chrome"]}
  POST /stop    body: {"run_id": "..."}
  GET  /status  → {"state": "idle|capturing|uploading|done", "run_id": "..."}

ENV VARS (injected by run-tests.sh via az vm run-command):
  STORAGE_CONN_STR
  STORAGE_ACCOUNT_NAME
  OFFSITE_WEBHOOK_URL
  RUNNER_SUBNET          e.g. 10.10.1.0/24
  CAPTURE_IFACE          e.g. eth0
"""

import os, subprocess, signal, gzip, shutil, json, time
import hashlib, hmac, base64, datetime, urllib.request, urllib.parse
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from azure.storage.blob import BlobServiceClient, generate_blob_sas, BlobSasPermissions

# ── Config ────────────────────────────────────────────────────
STORAGE_CONN    = os.environ["STORAGE_CONN_STR"]
STORAGE_ACCT    = os.environ["STORAGE_ACCOUNT_NAME"]
WEBHOOK_URL     = os.environ["OFFSITE_WEBHOOK_URL"]
RUNNER_SUBNET   = os.environ.get("RUNNER_SUBNET", "10.10.1.0/24")
IFACE           = os.environ.get("CAPTURE_IFACE", "vxlan0")  # decap iface, not eth0
PCAP_DIR        = Path("/tmp/pcaps")
PCAP_CONTAINER  = "pcap-staging"
SAS_EXPIRY_HRS  = 24

RUNNER_PROFILES = {
    "curl":   {"ipv4_filter": f"src net {RUNNER_SUBNET} and tcp",
               "ipv6_filter": f"ip6 and src net ace:cab:deca:deed::/64 and tcp"},
    "chrome": {"ipv4_filter": f"src net {RUNNER_SUBNET} and tcp",
               "ipv6_filter": f"ip6 and src net ace:cab:deca:deed::/64 and tcp"},
}

# ── State ─────────────────────────────────────────────────────
state    = {"phase": "idle", "run_id": None}
procs    = {}   # key: "curl-ipv4" → subprocess.Popen
lock     = threading.Lock()


# ── tcpdump management ────────────────────────────────────────
def pcap_path(run_id: str, runner: str, ip_family: str) -> Path:
    PCAP_DIR.mkdir(parents=True, exist_ok=True)
    return PCAP_DIR / f"{run_id}-{runner}-{ip_family}.pcap"


def start_capture(run_id: str, runners: list):
    for runner in runners:
        for ip_family, filt_key in [("ipv4", "ipv4_filter"), ("ipv6", "ipv6_filter")]:
            key    = f"{runner}-{ip_family}"
            out    = str(pcap_path(run_id, runner, ip_family))
            filt   = RUNNER_PROFILES[runner][filt_key]
            cmd    = ["tcpdump", "-i", IFACE, "-w", out, "-s", "0", "--immediate-mode", filt]
            print(f"[capture] START {key}: {' '.join(cmd)}")
            procs[key] = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    state["phase"]  = "capturing"
    state["run_id"] = run_id


def stop_capture():
    print("[capture] Stopping all tcpdump processes...")
    for key, proc in procs.items():
        proc.send_signal(signal.SIGTERM)
    for key, proc in procs.items():
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        print(f"  [capture] {key} exit={proc.returncode}")
    procs.clear()


# ── Compress + upload ─────────────────────────────────────────
def compress_and_upload(run_id: str) -> list:
    """Returns list of dicts: {key, blob_name, sas_url, size_bytes}"""
    state["phase"] = "uploading"
    client  = BlobServiceClient.from_connection_string(STORAGE_CONN)
    results = []

    for pcap_file in sorted(PCAP_DIR.glob(f"{run_id}-*.pcap")):
        gz_path = pcap_file.with_suffix(".pcap.gz")
        print(f"[upload] Compressing {pcap_file.name}...")
        with open(pcap_file, "rb") as f_in, gzip.open(gz_path, "wb", compresslevel=6) as f_out:
            shutil.copyfileobj(f_in, f_out)
        pcap_file.unlink()  # remove raw file immediately

        size       = gz_path.stat().st_size
        blob_name  = f"{run_id}/{gz_path.name}"
        print(f"[upload] Uploading {blob_name} ({size // 1024}KB)...")

        blob = client.get_blob_client(container=PCAP_CONTAINER, blob=blob_name)
        with open(gz_path, "rb") as data:
            blob.upload_blob(data, overwrite=True)
        gz_path.unlink()  # remove local gzip after upload

        # Generate 24h SAS URL
        expiry  = datetime.datetime.utcnow() + datetime.timedelta(hours=SAS_EXPIRY_HRS)
        sas_tok = generate_blob_sas(
            account_name   = STORAGE_ACCT,
            container_name = PCAP_CONTAINER,
            blob_name      = blob_name,
            account_key    = BlobServiceClient.from_connection_string(STORAGE_CONN).credential.account_key,
            permission     = BlobSasPermissions(read=True),
            expiry         = expiry,
        )
        sas_url = f"https://{STORAGE_ACCT}.blob.core.windows.net/{PCAP_CONTAINER}/{blob_name}?{sas_tok}"
        results.append({
            "key":        gz_path.stem,        # e.g. "abc123-curl-ipv4.pcap"
            "blob_name":  blob_name,
            "sas_url":    sas_url,
            "sas_expiry": expiry.isoformat() + "Z",
            "size_bytes": size,
        })
        print(f"  ✓ {blob_name}")

    return results


# ── Offsite webhook ───────────────────────────────────────────
def notify_offsite(run_id: str, pcap_files: list) -> int:
    payload = json.dumps({
        "run_id":     run_id,
        "timestamp":  datetime.datetime.utcnow().isoformat() + "Z",
        "pcap_files": pcap_files,
        "note":       "SAS URLs expire in 24h. Fetch promptly.",
    }).encode()
    req = urllib.request.Request(
        WEBHOOK_URL,
        data    = payload,
        headers = {"Content-Type": "application/json"},
        method  = "POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"[webhook] POST {WEBHOOK_URL} → {resp.status}")
            return resp.status
    except Exception as e:
        print(f"[webhook] FAILED: {e}")
        return 0


# ── HTTP control server ───────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[http] {fmt % args}")

    def send_json(self, code: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/status":
            self.send_json(200, state)
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body   = json.loads(self.rfile.read(length)) if length else {}

        if self.path == "/start":
            with lock:
                if state["phase"] != "idle":
                    self.send_json(409, {"error": f"already in phase: {state['phase']}"})
                    return
                run_id  = body.get("run_id", "unknown")
                runners = body.get("runners", ["curl", "chrome"])
                start_capture(run_id, runners)
            self.send_json(200, {"started": True, "run_id": run_id})

        elif self.path == "/stop":
            with lock:
                if state["phase"] != "capturing":
                    self.send_json(409, {"error": f"not capturing, phase={state['phase']}"})
                    return
                run_id = state["run_id"]
                stop_capture()

            # Upload + notify in background so HTTP response returns quickly
            def finish():
                pcap_files = compress_and_upload(run_id)
                wh_status  = notify_offsite(run_id, pcap_files)
                with lock:
                    state["phase"]            = "done"
                    state["last_webhook_http"] = wh_status
                print("[capture] All done. Ready for deallocation.")

            threading.Thread(target=finish, daemon=True).start()
            self.send_json(200, {"stopping": True, "run_id": run_id})

        else:
            self.send_json(404, {"error": "not found"})


if __name__ == "__main__":
    print(f"[capture-agent] Starting on :9000  iface={IFACE}  subnet={RUNNER_SUBNET}")
    HTTPServer(("0.0.0.0", 9000), Handler).serve_forever()