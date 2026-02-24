"""
curl-runner/run.py
Wraps your existing curl regression script, fans out across
TLS versions and IP families, ships results to Blob + Log Analytics.

ENV VARS expected (injected by ACI):
  TARGETS_JSON     — JSON array of hostnames, or path to blob with list
  RUN_ID           — unique run identifier (e.g. UUID)
  STORAGE_CONN_STR — Azure Storage connection string
  LAW_WORKSPACE_ID — Log Analytics workspace ID
  LAW_SHARED_KEY   — Log Analytics shared key
"""

import os, json, subprocess, time, uuid, datetime, hashlib, hmac, base64
import urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from azure.storage.blob import BlobServiceClient

# ── Config ────────────────────────────────────────────────────
TARGETS      = json.loads(os.environ.get("TARGETS_JSON", "[]"))
RUN_ID       = os.environ.get("RUN_ID", str(uuid.uuid4()))
STORAGE_CONN = os.environ.get("STORAGE_CONN_STR", "")
LAW_WS_ID    = os.environ.get("LAW_WORKSPACE_ID", "")
LAW_KEY      = os.environ.get("LAW_SHARED_KEY", "")

TLS_VERSIONS = {
    "TLS1.0": "--tlsv1.0 --tls-max 1.0",
    "TLS1.1": "--tlsv1.1 --tls-max 1.1",
    "TLS1.2": "--tlsv1.2 --tls-max 1.2",
    "TLS1.3": "--tlsv1.3 --tls-max 1.3",
}
IP_VERSIONS = {
    "IPv4": "-4",
    "IPv6": "-6",
}
MAX_WORKERS  = 20
TIMEOUT_SECS = 15


def probe(host: str, tls_label: str, tls_flags: str, ip_label: str, ip_flag: str) -> dict:
    url  = f"https://{host}"
    t0   = time.monotonic()
    cmd  = (
        f"curl {ip_flag} {tls_flags} "
        f"--silent --output /dev/null "
        f"--write-out '%{{http_code}}|%{{ssl_verify_result}}|%{{remote_ip}}|"
        f"%{{time_total}}|%{{num_connects}}' "
        f"--max-time {TIMEOUT_SECS} "
        f"--insecure "        # we're testing connectivity/TLS version, not cert validity
        f"-w '\\n%{{ssl_verify_result}}' "
        f"'{url}'"
    )
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=TIMEOUT_SECS + 5)
        parts      = r.stdout.strip().split("|")
        http_code  = int(parts[0]) if parts[0].isdigit() else 0
        duration   = float(parts[3]) * 1000 if len(parts) > 3 else 0
        exit_code  = r.returncode
        error      = r.stderr.strip()[:500] if r.returncode != 0 else ""
    except subprocess.TimeoutExpired:
        http_code, exit_code, duration, error = 0, 28, TIMEOUT_SECS * 1000, "timeout"

    return {
        "TimeGenerated": datetime.datetime.utcnow().isoformat() + "Z",
        "RunId":         RUN_ID,
        "Runner":        "curl",
        "TargetHost":    host,
        "TargetUrl":     url,
        "TlsVersion":    tls_label,
        "IpVersion":     ip_label,
        "HttpStatus":    http_code,
        "CurlExitCode":  exit_code,
        "ErrorDetail":   error,
        "DurationMs":    round(duration, 2),
        "CertIssuer":    "",   # extend with --write-out %{ssl_peer_cert} if needed
        "CertExpiry":    "",
    }


def send_to_law(records: list):
    """POST records to Log Analytics Data Collector API."""
    if not LAW_WS_ID or not LAW_KEY:
        return
    body        = json.dumps(records).encode("utf-8")
    rfc1123date = datetime.datetime.utcnow().strftime("%a, %d %b %Y %H:%M:%S GMT")
    content_len = len(body)
    sig_str     = f"POST\n{content_len}\napplication/json\nx-ms-date:{rfc1123date}\n/api/logs"
    sig_bytes   = base64.b64decode(LAW_KEY)
    sig         = base64.b64encode(
        hmac.new(sig_bytes, sig_str.encode("utf-8"), hashlib.sha256).digest()
    ).decode()
    headers = {
        "Content-Type":  "application/json",
        "Authorization": f"SharedKey {LAW_WS_ID}:{sig}",
        "Log-Type":      "TLSTestResults",
        "x-ms-date":     rfc1123date,
    }
    url = f"https://{LAW_WS_ID}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        urllib.request.urlopen(req, timeout=30)
        print(f"  → Sent {len(records)} records to Log Analytics")
    except Exception as e:
        print(f"  ✗ LAW ingest failed: {e}")


def upload_to_blob(results: list):
    if not STORAGE_CONN:
        return
    client = BlobServiceClient.from_connection_string(STORAGE_CONN)
    ts     = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    name   = f"{RUN_ID}/{ts}-curl.json"
    blob   = client.get_blob_client(container="test-results", blob=name)
    blob.upload_blob(json.dumps(results, indent=2).encode(), overwrite=True)
    print(f"  → Uploaded results to blob: test-results/{name}")


def main():
    if not TARGETS:
        print("ERROR: TARGETS_JSON is empty. Set the env var before running.")
        return

    print(f"[curl-runner] RUN_ID={RUN_ID}  targets={len(TARGETS)}")
    tasks   = [
        (host, tls_label, tls_flags, ip_label, ip_flag)
        for host in TARGETS
        for tls_label, tls_flags in TLS_VERSIONS.items()
        for ip_label, ip_flag in IP_VERSIONS.items()
    ]
    print(f"  Total probes: {len(tasks)}")

    results = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futs = {ex.submit(probe, *t): t for t in tasks}
        done = 0
        for fut in as_completed(futs):
            r = fut.result()
            results.append(r)
            done += 1
            if done % 50 == 0:
                print(f"  Progress: {done}/{len(tasks)}")

    print(f"  Probes complete. Uploading {len(results)} records...")
    upload_to_blob(results)
    # Send in batches of 500 (LAW API limit per request)
    for i in range(0, len(results), 500):
        send_to_law(results[i:i+500])

    failures = [r for r in results if r["CurlExitCode"] not in (0, 35, 36)]
    print(f"\n  Summary: {len(results)} probes, {len(failures)} unexpected failures")


if __name__ == "__main__":
    main()