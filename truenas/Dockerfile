FROM python:3.11-slim

# System deps: git + gpg for signed commits; no inotify-tools needed
# (watchdog uses Python inotify bindings directly)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    gpg \
    gpg-agent \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ src/
COPY config/ config/

# Non-root user: watcher only needs to read /data/recordings (ro mount)
# and write to /data/store (rw mount). Running as root is unnecessary.
RUN useradd -r -u 999 -g 0 -d /app -s /bin/sh watcher \
    && chown -R watcher:root /app

# GPG keyring lives on the persistent /data/store volume so it survives
# container recreation without needing /root/.gnupg.
ENV CONFIG_PATH=/app/config/config.json \
    GNUPGHOME=/data/store/gnupg

USER 999

# Health check: verify the chain log exists (written on first file event).
# Allows TrueNAS to detect hangs or crash-loops via the container status.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s \
    CMD test -f /data/store/chain_log.csv || exit 1

CMD ["python", "src/watcher.py"]
