# ============================================================
# chrome-runner — Headless Chrome with xvfb for TLS testing
# Tests default browser TLS behavior (no forced version flags)
# ============================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1

# ── System deps + Chrome ──────────────────────────────────────
RUN apt-get update && apt-get install -y \
    wget gnupg ca-certificates python3 python3-pip \
    xvfb x11-utils fonts-liberation \
    libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 \
    libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 \
    libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 \
    libxrandr2 xdg-utils libasound2 \
    && wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | \
       gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
       https://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# ── chromedriver (must match Chrome version) ─────────────────
RUN CHROME_VER=$(google-chrome --version | grep -oP '\d+\.\d+\.\d+\.\d+') \
    && MAJOR=$(echo $CHROME_VER | cut -d. -f1) \
    && wget -q "https://chromedriver.storage.googleapis.com/LATEST_RELEASE_${MAJOR}" -O /tmp/cdver \
    && wget -q "https://chromedriver.storage.googleapis.com/$(cat /tmp/cdver)/chromedriver_linux64.zip" \
    && unzip chromedriver_linux64.zip -d /usr/local/bin/ \
    && chmod +x /usr/local/bin/chromedriver \
    && rm chromedriver_linux64.zip

# ── Python deps ───────────────────────────────────────────────
RUN pip3 install --no-cache-dir \
    selenium==4.20.0 \
    azure-storage-blob \
    requests

# ── Non-root user (Chrome sandbox requirement) ────────────────
RUN useradd -m -u 1000 runner
USER runner
WORKDIR /home/runner

COPY --chown=runner:runner run.py        .
COPY --chown=runner:runner entrypoint.sh .
RUN chmod +x entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]