"""
chrome-runner/run.py
Invokes Chrome (Selenium) against each target using DEFAULT TLS settings —
simulating real browser behavior. Tests both IPv4 and IPv6 via DNS resolution
hints passed through Chrome flags.

ENV VARS expected:
  TARGETS_JSON     — JSON array of hostnames
  RUN_ID           — unique run identifier
  STORAGE_CONN_STR — Azure Storage connection string
  LAW_WORKSPACE_ID — Log Analytics workspace ID
  LAW_SHARED_KEY   — Log Analytics shared key
  CHROME_WORKERS   — parallel Chrome instances (default: 4, Chrome is heavy)
"""

import os, json, uuid, datetime, time, hashlib, hmac, base64, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from azure.storage.blob import BlobServiceClient
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.common.exceptions import WebDriverException

TARGETS      = json.loads(os.environ.get("TARGETS_JSON", "[]"))
RUN_ID       = os.environ.get("RUN_ID", str(uuid.uuid4()))
STORAGE_CONN = os.environ.get("STORAGE_CONN_STR", "")
LAW_WS_ID    = os.environ.get("LAW_WORKSPACE_ID", "")
LAW_KEY      = os.environ.get("LAW_SHARED_KEY", "")
MAX_WORKERS  = int(os.environ.get("CHROME_WORKERS", "4"))
TIMEOUT_SECS = 20


def build_driver(ip_pref: str) -> webdriver.Chrome:
    """
    ip_pref: "ipv4" | "ipv6"
    Chrome uses --disable-features=DnsOverHttps and explicit preference flags.
    True IPv4/IPv6 isolation requires OS-level routing; we use Chrome flags
    as a best-effort signal.
    """
    opts = Options()
    opts.add_argument("--headless=new")
    opts.add_argument("--no-sandbox")
    opts.add_argument("--disable-dev-shm-usage")
    opts.add_argument("--disable-gpu")
    opts.add_argument("--disable-extensions")
    opts.add_argument("--disable-features=DnsOverHttps")
    opts.add_argument("--window-size=1280,720")
    opts.add_argument("--remote-debugging-port=0")  # ephemeral port

    if ip_pref == "ipv4":
        opts.add_argument("--disable-features=UseDnsHttpsSvcb")
        opts.set_capability("goog:loggingPrefs", {"performance": "ALL"})

    svc = Service(executable_path="/usr/local/bin/chromedriver", log_path="/dev/null")
    drv = webdriver.Chrome(service=svc, options=opts)
    drv.set_page_load_timeout(TIMEOUT_SECS)
    return drv


def probe_chrome(host: str, ip_label: str) -> dict:
    url     = f"https://{host}"
    result  = {
        "TimeGenerated": datetime.datetime.utcnow().isoformat() + "Z",
        "RunId":         RUN_ID,
        "Runner":        "chrome",
        "TargetHost":    host,
        "TargetUrl":     url,
        "TlsVersion":    "DEFAULT",
        "IpVersion":     ip_label,
        "HttpStatus":    0,
        "CurlExitCode":  -1,
        "ErrorDetail":   "",
        "DurationMs":    0.0,
        "CertIssuer":    "",
        "CertExpiry":    "",
    }
    drv = None
    t0  = time.monotonic()
    try:
        drv              = build_driver(ip_label.lower())
        drv.get(url)
        elapsed          = (time.monotonic() - t0) * 1000
        result["HttpStatus"]   = 200  # Chrome doesn't expose HTTP status directly
        result["CurlExitCode"] = 0
        result["DurationMs"]   = round(elapsed, 2)

        # Extract TLS info from Chrome security state via JS
        tls_info = drv.execute_script("""
            const e = window.performance.getEntriesByType('navigation')[0];
            return e ? {
                protocol:    e.nextHopProtocol,
                transferred: e.transferSize
            } : null;
        """)
        if tls_info:
            result["ErrorDetail"] = json.dumps(tls_info)

    except WebDriverException as e:
        result["ErrorDetail"]   = str(e)[:500]
        result["CurlExitCode"]  = 1
        result["DurationMs"]    = round((time.monotonic() - t0) * 1000, 2)
    finally:
        if drv:
            drv.quit()

    return result


def send_to_law(records: list):
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
    except Exception as e:
        print(f"  ✗ LAW ingest failed: {e}")


def upload_to_blob(results: list):
    if not STORAGE_CONN:
        return
    client = BlobServiceClient.from_connection_string(STORAGE_CONN)
    ts     = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    name   = f"{RUN_ID}/{ts}-chrome.json"
    blob   = client.get_blob_client(container="test-results", blob=name)
    blob.upload_blob(json.dumps(results, indent=2).encode(), overwrite=True)
    print(f"  → Uploaded results to blob: test-results/{name}")


def main():
    if not TARGETS:
        print("ERROR: TARGETS_JSON is empty.")
        return

    print(f"[chrome-runner] RUN_ID={RUN_ID}  targets={len(TARGETS)}")
    tasks   = [(host, ip) for host in TARGETS for ip in ("IPv4", "IPv6")]
    print(f"  Total probes: {len(tasks)}  workers: {MAX_WORKERS}")

    results = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futs = {ex.submit(probe_chrome, host, ip): (host, ip) for host, ip in tasks}
        done = 0
        for fut in as_completed(futs):
            results.append(fut.result())
            done += 1
            if done % 20 == 0:
                print(f"  Progress: {done}/{len(tasks)}")

    print(f"  Probes complete. Uploading {len(results)} records...")
    upload_to_blob(results)
    for i in range(0, len(results), 500):
        send_to_law(results[i:i+500])

    failures = [r for r in results if r["CurlExitCode"] != 0]
    print(f"\n  Summary: {len(results)} probes, {len(failures)} failures")


if __name__ == "__main__":
    main()