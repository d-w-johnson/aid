#!/bin/bash
set -euo pipefail

# ── 1. Activate mise ──────────────────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
eval "$($HOME/.local/bin/mise activate bash)" 2>/dev/null || true

# ── 2. Rootless Docker daemon ─────────────────────────────────────────────────
if [ "${ENABLE_DOCKER:-false}" = "true" ]; then
    echo "[aid] Starting rootless Docker daemon..."
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/docker-$(id -u)}"
    mkdir -p "$XDG_RUNTIME_DIR"
    export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
    dockerd-rootless.sh > /tmp/dockerd.log 2>&1 &

    if ! timeout 30 sh -c 'until docker info >/dev/null 2>&1; do sleep 0.5; done'; then
        echo "[aid] ERROR: Docker daemon failed to start within 30s"
        cat /tmp/dockerd.log
        exit 1
    fi
    echo "[aid] Docker daemon ready"
fi

# ── 3. Validate auth ──────────────────────────────────────────────────────────
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    echo "[aid] WARNING: No auth credentials set."
    echo "[aid]   Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN in your profile."
fi

# ── 4. Git identity and credentials ───────────────────────────────────────────
# Trust all directories — workspace bind mounts are owned by the host UID, not
# the container's dev user, which git rejects by default.
git config --global --add safe.directory '*'

[ -n "${GIT_AUTHOR_NAME:-}"  ] && git config --global user.name  "$GIT_AUTHOR_NAME"
[ -n "${GIT_AUTHOR_EMAIL:-}" ] && git config --global user.email "$GIT_AUTHOR_EMAIL"

if [ -n "${GIT_TOKEN:-}" ]; then
    git config --global credential.helper store
    printf 'https://oauth2:%s@github.com\nhttps://oauth2:%s@gitlab.com\n' \
        "$GIT_TOKEN" "$GIT_TOKEN" > "$HOME/.git-credentials"
    chmod 600 "$HOME/.git-credentials"
fi

# ── 5. Configure Stop hook (idempotent) ───────────────────────────────────────
mkdir -p "$HOME/.claude"
node - <<'EOF'
const fs   = require('fs');
const path = require('path') ;
const file = path.join(process.env.HOME, '.claude', 'settings.json');
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) {}
if (!cfg.hooks?.Stop) {
    cfg.hooks       = cfg.hooks || {};
    cfg.hooks.Stop  = [{ hooks: [{ type: 'command',
        command: "printf '\\a'; echo '━━━ Claude is waiting for your input ━━━'" }] }];
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2));
    process.stderr.write('[aid] Stop hook configured\n');
}
EOF

# ── 6. Mise install in workspace repos ───────────────────────────────────────
if [ -d /workspace ]; then
    echo "[aid] Running mise install in workspace repos..."
    while IFS= read -r git_dir; do
        repo="$(dirname "$git_dir")"
        # Skip .git dirs nested inside another .git (git worktrees, submodules)
        if echo "$git_dir" | grep -qE '/.git/.'; then continue; fi
        if [ -f "$repo/.mise.toml" ] || [ -f "$repo/.tool-versions" ]; then
            echo "[aid]   $repo"
            bash --login -c "cd '$repo' && mise trust -y" \
                || echo "[aid]   WARNING: mise trust failed in $repo"
            bash --login -c "cd '$repo' && mise install" \
                || echo "[aid]   WARNING: mise install failed in $repo"
        fi
    done < <(find /workspace -maxdepth 10 -name ".git" -type d 2>/dev/null)
fi

# ── 7. Agent config ───────────────────────────────────────────────────────────
if [ -d /agent-config ]; then
    echo "[aid] Copying agent config to ~/.claude/"
    cp -r /agent-config/. "$HOME/.claude/"
    if [ -f /agent-config/managed-settings.json ]; then
        echo "[aid] Installing managed settings to /etc/claude-code/"
        sudo mkdir -p /etc/claude-code
        sudo cp /agent-config/managed-settings.json /etc/claude-code/managed-settings.json
    fi
fi

# ── 8. Chromium ───────────────────────────────────────────────────────────────
if [ "${ENABLE_BROWSER:-false}" = "true" ]; then
    echo "[aid] Starting Chromium on port 9222..."
    chromium \
        --headless=new \
        --no-sandbox \
        --disable-gpu \
        --remote-debugging-address=0.0.0.0 \
        --remote-debugging-port=9222 \
        --user-data-dir="$HOME/.chromium-profile" \
        > /tmp/chromium.log 2>&1 &

    if ! timeout 15 sh -c \
        'until curl -sf http://localhost:9222/json/version >/dev/null 2>&1; do sleep 0.5; done'; then
        echo "[aid] WARNING: Chromium may not have started. Check /tmp/chromium.log"
    else
        echo "[aid] Chromium ready"
    fi
fi

# ── 9. Launch Claude ──────────────────────────────────────────────────────────
if [ -n "${START_DIR:-}" ]; then
    cd "/workspace/$START_DIR" || cd /workspace
else
    cd /workspace 2>/dev/null || cd "$HOME"
fi

exec claude --dangerously-skip-permissions
