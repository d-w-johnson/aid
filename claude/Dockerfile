FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ───────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    curl git sudo ca-certificates gnupg lsb-release \
    iptables uidmap dbus-user-session fuse-overlayfs \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CE ─────────────────────────────────────────────────────────────────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
       -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y \
       docker-ce docker-ce-cli containerd.io \
       docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ── Node 22 (system-level — independent of mise-cache bind mount) ─────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code ───────────────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code

# ── Playwright Chromium ───────────────────────────────────────────────────────
# Install to a world-readable path so the non-root dev user can run it.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright-browsers
RUN npx playwright install --with-deps chromium \
    && chmod -R 755 /opt/playwright-browsers

# Create a chromium wrapper in PATH so entrypoint can call `chromium` directly.
RUN CHROME_BIN=$(find /opt/playwright-browsers -name 'chrome' -type f | head -1) \
    && [ -n "$CHROME_BIN" ] || { echo "[aid] ERROR: Chrome binary not found in /opt/playwright-browsers"; exit 1; } \
    && printf '#!/bin/bash\nexec "%s" "$@"\n' "$CHROME_BIN" > /usr/local/bin/chromium \
    && chmod +x /usr/local/bin/chromium

# ── dev user ──────────────────────────────────────────────────────────────────
# ubuntu:24.04 ships with an 'ubuntu' user at UID 1000; remove it first.
RUN userdel -r ubuntu 2>/dev/null || true \
    && useradd -m -u 1000 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && usermod -aG docker dev \
    && echo "dev:100000:65536" >> /etc/subuid \
    && echo "dev:100000:65536" >> /etc/subgid

# Managed settings directory (org-level policy, written by entrypoint if needed)
RUN mkdir -p /etc/claude-code

USER dev
WORKDIR /home/dev

# ── mise ──────────────────────────────────────────────────────────────────────
# Pre-create the mise data directory as dev so the bind mount for
# /home/dev/.local/share/mise/installs doesn't cause Docker to create the
# parent path as root, which would prevent mise from writing siblings
# (e.g. migrations) into it.
RUN mkdir -p /home/dev/.local/share/mise
RUN curl https://mise.run | sh
RUN echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc \
    && echo 'eval "$(~/.local/bin/mise activate bash --shims)"' >> ~/.profile

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY --chown=dev:dev entrypoint.sh /home/dev/entrypoint.sh
RUN chmod +x /home/dev/entrypoint.sh

ENTRYPOINT ["/home/dev/entrypoint.sh"]
CMD ["/bin/bash", "--login"]
