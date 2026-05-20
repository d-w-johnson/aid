# AID — Agent in Docker: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Docker-based sandbox that runs Claude Code in `--dangerously-skip-permissions` mode with persistent profiles, cross-platform launcher scripts, and automatic alerting when Claude pauses.

**Architecture:** A single Docker image (`claude-sandbox:latest`) built from `claude/Dockerfile` is managed by `claude/aid.sh` (Linux/macOS) and `claude/aid.ps1` (Windows). Per-profile configuration lives in `.env.<profile>` files at the repo root. All persistent state uses bind mounts so containers can be recreated without data loss. The entrypoint handles all setup on each container start; the lifecycle scripts handle create/start/stop/shell/logs.

**Tech Stack:** Docker CE, Docker Compose v2, Ubuntu 24.04, Node 22 (NodeSource), mise, Playwright/Chromium, bash, PowerShell 7+

---

## File Map

| File | Purpose |
|---|---|
| `.gitignore` | Ignore profiles, state dirs, override file |
| `.env.example` | Profile template with all options documented |
| `claude/Dockerfile` | Image definition — system tools, Node, Claude Code, Chromium, mise |
| `claude/docker-compose.yml` | Service definition — volumes, ports, env vars |
| `claude/entrypoint.sh` | Container startup — mise, dockerd, git, stop hook, workspace scan, chromium, claude |
| `claude/aid.sh` | Linux/macOS lifecycle manager — start/stop/shell/logs |
| `claude/aid.ps1` | Windows lifecycle manager — same interface |
| `README.md` | User documentation |

---

## Task 1: Repository Scaffolding

**Files:**
- Modify: `.gitignore`
- Create: `claude/.gitkeep` (ensures claude/ is tracked before other files land there)

- [ ] **Step 1: Update .gitignore**

Replace the contents of `.gitignore` with:

```
# Profile env files — copy .env.example to .env.<profile> and fill in
.env.*
!.env.example

# Per-profile Claude state (history, settings, MCPs)
claude/.claude-state/

# Shared mise tool cache
.mise-cache/

# Generated Docker Compose override (built from PORT_*/MOUNT_* profile vars)
claude/docker-compose.override.yml
```

- [ ] **Step 2: Create claude directory marker**

```bash
mkdir -p claude
touch claude/.gitkeep
```

- [ ] **Step 3: Create state and cache directories (git-ignored)**

```bash
mkdir -p .mise-cache
mkdir -p claude/.claude-state
```

- [ ] **Step 4: Verify .gitignore works**

```bash
echo "SANDBOX_NAME=test" > .env.test
git status
```

Expected: `.env.test` does NOT appear in untracked files. `.gitignore` and `claude/.gitkeep` DO appear.

- [ ] **Step 5: Commit**

```bash
git add .gitignore claude/.gitkeep
git commit -m "feat: add repository scaffolding"
```

---

## Task 2: `.env.example`

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Write `.env.example`**

```bash
# ── Identity ─────────────────────────────────────────────────────────────────
# Unique name for this profile. Becomes the container name and Compose project
# name. Two profiles with different SANDBOX_NAME values run simultaneously.
SANDBOX_NAME=myproject

# ── Authentication (choose ONE — do not set both) ─────────────────────────────
# Option A: API key from console.anthropic.com
# ANTHROPIC_API_KEY=sk-ant-...

# Option B: Long-lived OAuth token (uses your Claude Pro/Max subscription)
# Generate with: claude setup-token   (run on a machine with a browser)
# Token is valid ~1 year. Verify the exact command in the Claude Code docs.
# CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...

# ── Workspace ─────────────────────────────────────────────────────────────────
# Directory containing all repos for this profile. Mounted as /workspace.
# Linux/macOS: WORKSPACE_PATH=/home/me/sandboxes/myproject
# Windows:     WORKSPACE_PATH=C:/Users/me/sandboxes/myproject
WORKSPACE_PATH=/path/to/your/workspace

# ── Git identity ──────────────────────────────────────────────────────────────
# Name and email credited on commits. Use a dedicated AI identity if preferred.
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com

# ── Git token (HTTPS push/pull) ───────────────────────────────────────────────
# GitHub:  github.com → Settings → Developer settings →
#          Personal access tokens → Tokens (classic) → check "repo" scope
# GitLab:  gitlab.com → Edit profile → Access tokens →
#          check read_repository + write_repository
# GIT_TOKEN=ghp_...

# ── Port forwarding ───────────────────────────────────────────────────────────
# Expose container ports to your host browser. Format: host_port:container_port
# Running multiple profiles at once? Use different host ports per profile:
#   .env.profile-a:  PORT_1=3000:3000
#   .env.profile-b:  PORT_1=3001:3000   ← same container port, different host port
# PORT_1=3000:3000
# PORT_2=8080:8080

# ── Extra mounts ──────────────────────────────────────────────────────────────
# Mount additional host directories into the container.
# Use forward slashes on all platforms — Docker Desktop normalises Windows paths.
# MOUNT_1=C:/Users/me/shared-assets:/mnt/assets

# ── Browser testing ───────────────────────────────────────────────────────────
# Start a persistent Chromium instance with remote debugging on port 9222.
# Claude connects to it via the Playwright MCP; you can follow along via
# chrome://inspect in your host Chrome and share the same live session.
# Use a unique CHROMIUM_HOST_PORT per simultaneous profile to avoid conflicts.
# ENABLE_BROWSER=true
# CHROMIUM_HOST_PORT=9222

# ── Docker-in-Docker ──────────────────────────────────────────────────────────
# Allow Claude to run Docker commands inside the container: spin up databases,
# run docker compose, build images. Uses rootless Docker-in-Docker.
#
# ⚠️  LINUX SECURITY NOTE: enables --security-opt seccomp=unconfined, relaxing
#    syscall filtering. Rootless DinD means inner containers cannot escalate to
#    host root, but syscall filtering is disabled. On Windows/macOS this runs
#    inside Docker Desktop's VM — significantly lower risk.
#
# ENABLE_DOCKER=true

# ── Telemetry ─────────────────────────────────────────────────────────────────
# Disable Claude Code telemetry and error reporting sent to Anthropic.
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# ── Agent config ──────────────────────────────────────────────────────────────
# Path to a local clone of a shared config repo (e.g. a company tooling repo).
# Everything in this directory is copied into ~/.claude/ on container start:
# CLAUDE.md (global instructions), skills/, MCP configs, etc.
# If managed-settings.json is present it is also installed to
# /etc/claude-code/managed-settings.json for org-level policy enforcement.
# AGENT_CONFIG_PATH=C:/work/company-aid-config
```

- [ ] **Step 2: Verify it is tracked (not ignored)**

```bash
git status
```

Expected: `.env.example` appears as an untracked file.

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "feat: add .env.example profile template"
```

---

## Task 3: Dockerfile

**Files:**
- Create: `claude/Dockerfile`

- [ ] **Step 1: Write `claude/Dockerfile`**

```dockerfile
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
    && printf '#!/bin/bash\nexec "%s" "$@"\n' "$CHROME_BIN" > /usr/local/bin/chromium \
    && chmod +x /usr/local/bin/chromium

# ── dev user ──────────────────────────────────────────────────────────────────
RUN useradd -m -u 1000 -s /bin/bash dev \
    && echo "dev ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && usermod -aG docker dev \
    && echo "dev:100000:65536" >> /etc/subuid \
    && echo "dev:100000:65536" >> /etc/subgid

# Managed settings directory (org-level policy, written by entrypoint if needed)
RUN mkdir -p /etc/claude-code

USER dev
WORKDIR /home/dev

# ── mise ──────────────────────────────────────────────────────────────────────
RUN curl https://mise.run | sh
RUN echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc \
    && echo 'eval "$(~/.local/bin/mise activate bash --shims)"' >> ~/.profile

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY --chown=dev:dev entrypoint.sh /home/dev/entrypoint.sh
RUN chmod +x /home/dev/entrypoint.sh

ENTRYPOINT ["/home/dev/entrypoint.sh"]
CMD ["/bin/bash", "--login"]
```

- [ ] **Step 2: Build the image**

```bash
docker build -t claude-sandbox:latest claude/
```

Expected: build succeeds. First build takes 5–15 minutes. Subsequent builds use layer cache.

- [ ] **Step 3: Verify key binaries are present**

```bash
docker run --rm claude-sandbox:latest which claude
docker run --rm claude-sandbox:latest node --version
docker run --rm claude-sandbox:latest mise --version
docker run --rm claude-sandbox:latest chromium --version
docker run --rm claude-sandbox:latest dockerd-rootless.sh --version 2>&1 | head -1
```

Expected:
```
/usr/local/bin/claude
v22.x.x
mise x.x.x ...
Chromium 1xx.x.x.x
...
```

- [ ] **Step 4: Verify dev user is non-root**

```bash
docker run --rm claude-sandbox:latest id
```

Expected: `uid=1000(dev) gid=1000(dev) groups=1000(dev),999(docker)`

- [ ] **Step 5: Commit**

```bash
git add claude/Dockerfile
git commit -m "feat: add Dockerfile with Node 22, Claude Code, mise, Chromium, rootless DinD"
```

---

## Task 4: `docker-compose.yml`

**Files:**
- Create: `claude/docker-compose.yml`

- [ ] **Step 1: Write `claude/docker-compose.yml`**

```yaml
name: ${SANDBOX_NAME:-claude-sandbox}

services:
  sandbox:
    build:
      context: .
      dockerfile: Dockerfile
    image: claude-sandbox:latest
    container_name: ${SANDBOX_NAME:-claude-sandbox}
    stdin_open: true
    tty: true
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}
      - GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-}
      - GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-}
      - GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME:-}
      - GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL:-}
      - GIT_TOKEN=${GIT_TOKEN:-}
      - ENABLE_DOCKER=${ENABLE_DOCKER:-false}
      - ENABLE_BROWSER=${ENABLE_BROWSER:-false}
      - DISABLE_AUTOUPDATER=1
      - CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}
      - START_DIR=${START_DIR:-}
    volumes:
      - ../.mise-cache:/home/dev/.local/share/mise/installs
      - ./.claude-state/${SANDBOX_NAME:-default}:/home/dev/.claude
      - ${WORKSPACE_PATH:-/tmp}:/workspace
    ports:
      - "${CHROMIUM_HOST_PORT:-9222}:9222"
    # Additional ports (PORT_*), mounts (MOUNT_*), agent config, and
    # security_opt for ENABLE_DOCKER are injected via docker-compose.override.yml
    # generated by aid.sh / aid.ps1 before each start.
```

- [ ] **Step 2: Verify compose syntax**

```bash
SANDBOX_NAME=test WORKSPACE_PATH=/tmp \
  docker compose -f claude/docker-compose.yml config --quiet
```

Expected: exits 0 with no errors.

- [ ] **Step 3: Commit**

```bash
git add claude/docker-compose.yml
git commit -m "feat: add docker-compose.yml"
```

---

## Task 5: `entrypoint.sh`

**Files:**
- Create: `claude/entrypoint.sh`

- [ ] **Step 1: Write `claude/entrypoint.sh`**

```bash
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
            (cd "$repo" \
                && mise trust --quiet 2>/dev/null \
                && mise install --quiet 2>/dev/null) \
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
```

- [ ] **Step 2: Rebuild image to include entrypoint**

```bash
docker build -t claude-sandbox:latest claude/
```

Expected: builds quickly using cached layers. Only the final `COPY entrypoint.sh` layer rebuilds.

- [ ] **Step 3: Verify entrypoint setup steps run (without needing auth)**

```bash
docker run --rm \
  -e GIT_AUTHOR_NAME="Test User" \
  -e GIT_AUTHOR_EMAIL="test@example.com" \
  -v "$(pwd):/workspace" \
  --entrypoint bash \
  claude-sandbox:latest -c "
    source /home/dev/entrypoint.sh 2>&1 | head -20 || true
  "
```

Expected: output includes `[aid] Running mise install in workspace repos...` and eventually fails on `exec claude` (expected — no auth). The setup steps should complete without errors.

- [ ] **Step 4: Verify Stop hook is written**

```bash
mkdir -p /tmp/test-claude-state
docker run --rm \
  -v "/tmp/test-claude-state:/home/dev/.claude" \
  -v "$(pwd):/workspace" \
  --entrypoint bash \
  claude-sandbox:latest -c "
    mkdir -p /home/dev/.claude
    node - <<'EOF'
const fs = require('fs');
const path = '/home/dev/.claude/settings.json';
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path, 'utf8')); } catch (_) {}
if (!cfg.hooks?.Stop) {
    cfg.hooks = cfg.hooks || {};
    cfg.hooks.Stop = [{ hooks: [{ type: 'command', command: \"printf '\\\\a'\" }] }];
    fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
    console.log('hook written');
} else { console.log('hook already present'); }
EOF
    cat /home/dev/.claude/settings.json
  "
rm -rf /tmp/test-claude-state
```

Expected: outputs a settings.json containing the Stop hook.

- [ ] **Step 5: Commit**

```bash
git add claude/entrypoint.sh
git commit -m "feat: add container entrypoint"
```

---

## Task 6: `aid.sh` (Linux/macOS)

**Files:**
- Create: `claude/aid.sh`

- [ ] **Step 1: Write `claude/aid.sh`**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

COMMAND="${1:-}"
PROFILE="${2:-}"
START_SUBDIR="${3:-}"

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: ./claude/aid.sh <command> [profile] [subdir]

Commands:
  start [profile] [subdir]  Build image, start container, launch Claude.
                            Optionally start Claude in /workspace/<subdir>.
  stop  [profile]           Stop container (and all inner containers).
  shell [profile]           Open bash shell in the running container.
  logs  [profile]           Tail container logs.

profile  Name of .env.<profile> file to load (default: .env)
subdir   Start Claude in /workspace/<subdir> instead of /workspace root
EOF
    exit 1
}

[ -z "$COMMAND" ] && usage

# ── Load profile ──────────────────────────────────────────────────────────────
cd "$REPO_ROOT"

ENV_FILE=".env${PROFILE:+.$PROFILE}"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found."
    echo ""
    echo "Available profiles:"
    ls .env.* 2>/dev/null | sed 's/^\.env\./  /' || echo "  (none)"
    echo ""
    echo "Copy .env.example to .env.<profile> and fill in your settings."
    exit 1
fi

echo "[aid] Loading profile: $ENV_FILE"
set -a; source "$ENV_FILE"; set +a

# ── Validate ──────────────────────────────────────────────────────────────────
[ -z "${SANDBOX_NAME:-}"   ] && { echo "ERROR: SANDBOX_NAME not set in $ENV_FILE";   exit 1; }
[ -z "${WORKSPACE_PATH:-}" ] && { echo "ERROR: WORKSPACE_PATH not set in $ENV_FILE"; exit 1; }

CONTAINER="$SANDBOX_NAME"

# ── Override generator ────────────────────────────────────────────────────────
generate_override() {
    local out="$SCRIPT_DIR/docker-compose.override.yml"
    local body=""

    # PORT_* → extra port bindings
    local ports_block=""
    while IFS= read -r line; do
        ports_block+="      - \"${line#*=}\"\n"
    done < <(env | grep '^PORT_' | sort)

    # MOUNT_* + AGENT_CONFIG_PATH → extra volume mounts
    local vols_block=""
    while IFS= read -r line; do
        vols_block+="      - \"${line#*=}\"\n"
    done < <(env | grep '^MOUNT_' | sort)
    if [ -n "${AGENT_CONFIG_PATH:-}" ]; then
        vols_block+="      - \"${AGENT_CONFIG_PATH}:/agent-config:ro\"\n"
    fi

    # START_DIR → env var override
    local env_block=""
    if [ -n "$START_SUBDIR" ]; then
        env_block="      - START_DIR=${START_SUBDIR}\n"
    fi

    # ENABLE_DOCKER → security_opt
    local sec_block=""
    if [ "${ENABLE_DOCKER:-false}" = "true" ]; then
        sec_block="    security_opt:\n      - seccomp:unconfined\n"
    fi

    if [ -z "$ports_block" ] && [ -z "$vols_block" ] && [ -z "$env_block" ] && [ -z "$sec_block" ]; then
        echo "services: {}" > "$out"
        return
    fi

    {
        echo "services:"
        echo "  sandbox:"
        if [ -n "$ports_block" ]; then
            echo "    ports:"
            printf "%b" "$ports_block"
        fi
        if [ -n "$vols_block" ]; then
            echo "    volumes:"
            printf "%b" "$vols_block"
        fi
        if [ -n "$env_block" ]; then
            echo "    environment:"
            printf "%b" "$env_block"
        fi
        if [ -n "$sec_block" ]; then
            printf "%b" "$sec_block"
        fi
    } > "$out"
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "$COMMAND" in

start)
    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        echo "[aid] WARNING: No auth credentials found. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN."
    fi

    # Ensure bind-mount host dirs exist (Docker creates them as root otherwise)
    mkdir -p "$SCRIPT_DIR/.claude-state/$SANDBOX_NAME"
    mkdir -p "$REPO_ROOT/.mise-cache"

    generate_override

    echo "[aid] Building image (uses layer cache)..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" -p "$SANDBOX_NAME" build

    # Determine container state
    RUNNING=$(docker ps     --filter "name=^${CONTAINER}$" --format "{{.Names}}" 2>/dev/null || true)
    EXISTS=$( docker ps -a  --filter "name=^${CONTAINER}$" --format "{{.Names}}" 2>/dev/null || true)

    if [ -n "$RUNNING" ]; then
        echo "[aid] Container '$CONTAINER' is already running."
        echo "[aid] Use './claude/aid.sh shell $PROFILE' to open a second session."
        exit 0
    fi

    if [ -n "$EXISTS" ]; then
        # Check if image changed since container was created
        CONTAINER_IMG=$(docker inspect "$CONTAINER" --format='{{.Image}}' 2>/dev/null || true)
        LATEST_IMG=$(docker images -q claude-sandbox:latest 2>/dev/null || true)
        if [ -n "$CONTAINER_IMG" ] && [ -n "$LATEST_IMG" ] \
            && [ "$CONTAINER_IMG" != "sha256:$LATEST_IMG" ] \
            && [ "$CONTAINER_IMG" != "$LATEST_IMG" ]; then
            echo "[aid] Image has changed — recreating container."
            echo "[aid] Workspace and Claude state are preserved (bind mounts)."
            docker rm "$CONTAINER"
            EXISTS=""
        fi
    fi

    if [ -z "$EXISTS" ]; then
        echo "[aid] Creating container '$CONTAINER'..."
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" -p "$SANDBOX_NAME" up --no-start
    fi

    if [ "${ENABLE_BROWSER:-false}" = "true" ]; then
        PORT="${CHROMIUM_HOST_PORT:-9222}"
        echo ""
        echo "[aid] Browser ready. To follow along from your host Chrome:"
        echo "  1. Open chrome://inspect"
        echo "  2. Click Configure... and add: localhost:${PORT}"
        echo "  3. The sandbox tab appears under Remote Target"
        echo ""
    fi

    echo "[aid] Starting '$CONTAINER'..."
    docker start -ai "$CONTAINER"
    ;;

stop)
    echo "[aid] Stopping '$CONTAINER'..."
    docker stop "$CONTAINER" 2>/dev/null || echo "[aid] Container not running."
    ;;

shell)
    RUNNING=$(docker ps --filter "name=^${CONTAINER}$" --format "{{.Names}}" 2>/dev/null || true)
    if [ -z "$RUNNING" ]; then
        echo "[aid] Container '$CONTAINER' is not running. Use 'start' first."
        exit 1
    fi
    docker exec -it "$CONTAINER" /bin/bash --login
    ;;

logs)
    docker logs -f "$CONTAINER"
    ;;

*)
    echo "Unknown command: $COMMAND"
    usage
    ;;
esac
```

- [ ] **Step 2: Make executable**

```bash
chmod +x claude/aid.sh
```

- [ ] **Step 3: Test usage / help**

```bash
./claude/aid.sh
```

Expected: prints usage and exits 1.

- [ ] **Step 4: Test profile not found error**

```bash
./claude/aid.sh start nonexistent 2>&1
```

Expected: prints `ERROR: .env.nonexistent not found.` and lists available profiles.

- [ ] **Step 5: Create a minimal test profile and run start (smoke test)**

```bash
cat > .env.smoketest <<'EOF'
SANDBOX_NAME=aid-smoketest
WORKSPACE_PATH=/tmp
ANTHROPIC_API_KEY=test-key-intentionally-invalid
GIT_AUTHOR_NAME=Test
GIT_AUTHOR_EMAIL=test@test.com
EOF

./claude/aid.sh start smoketest
```

Expected: image builds (cached), container created, entrypoint runs, warns about auth, then claude launches and fails with an auth error (expected — key is invalid). Container will stop after claude exits. Verify no shell errors before claude launch.

- [ ] **Step 6: Test stop**

```bash
# Container will have exited after previous step, but test stop on non-running:
./claude/aid.sh stop smoketest
```

Expected: `[aid] Container not running.` (graceful, not an error exit).

- [ ] **Step 7: Clean up smoke test**

```bash
docker rm aid-smoketest 2>/dev/null || true
rm .env.smoketest
```

- [ ] **Step 8: Commit**

```bash
git add claude/aid.sh
git commit -m "feat: add aid.sh Linux/macOS lifecycle manager"
```

---

## Task 7: `aid.ps1` (Windows)

**Files:**
- Create: `claude/aid.ps1`

- [ ] **Step 1: Write `claude/aid.ps1`**

```powershell
param(
    [string]$Command     = "",
    [string]$Profile     = "",
    [string]$StartSubdir = ""
)
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent $ScriptDir

function Show-Usage {
    Write-Host @"
Usage: .\claude\aid.ps1 <command> [profile] [subdir]

Commands:
  start [profile] [subdir]  Build image, start container, launch Claude.
                            Optionally start Claude in /workspace/<subdir>.
  stop  [profile]           Stop container (and all inner containers).
  shell [profile]           Open bash shell in the running container.
  logs  [profile]           Tail container logs.

profile  Name of .env.<profile> file to load (default: .env)
subdir   Start Claude in /workspace/<subdir> instead of /workspace root
"@
    exit 1
}

if (-not $Command) { Show-Usage }

# ── Load profile ──────────────────────────────────────────────────────────────
Set-Location $RepoRoot

$EnvFile = if ($Profile) { ".env.$Profile" } else { ".env" }

if (-not (Test-Path $EnvFile)) {
    Write-Host "ERROR: $EnvFile not found."
    Write-Host ""
    Write-Host "Available profiles:"
    $profiles = Get-ChildItem ".env.*" -ErrorAction SilentlyContinue
    if ($profiles) {
        $profiles | ForEach-Object { Write-Host "  $($_.Name -replace '^\.env\.','')" }
    } else {
        Write-Host "  (none)"
    }
    Write-Host ""
    Write-Host "Copy .env.example to .env.<profile> and fill in your settings."
    exit 1
}

Write-Host "[aid] Loading profile: $EnvFile"
Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([^#][^=\s]+)\s*=\s*(.*)$') {
        $key   = $Matches[1].Trim()
        $value = $Matches[2].Trim()
        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
}

# ── Validate ──────────────────────────────────────────────────────────────────
if (-not $env:SANDBOX_NAME)   { Write-Error "SANDBOX_NAME not set in $EnvFile";   exit 1 }
if (-not $env:WORKSPACE_PATH) { Write-Error "WORKSPACE_PATH not set in $EnvFile"; exit 1 }

$Container = $env:SANDBOX_NAME

# ── Override generator ────────────────────────────────────────────────────────
function New-Override {
    $out   = Join-Path $ScriptDir "docker-compose.override.yml"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("services:")
    $lines.Add("  sandbox:")

    $hasPorts  = $false
    $hasVols   = $false
    $hasEnv    = $false
    $hasSec    = $false

    # PORT_* vars
    $portVars = [System.Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { $_.Key -match '^PORT_' } | Sort-Object Key
    if ($portVars) {
        $lines.Add("    ports:")
        foreach ($v in $portVars) { $lines.Add("      - `"$($v.Value)`"") }
        $hasPorts = $true
    }

    # MOUNT_* + AGENT_CONFIG_PATH
    $mountVars = [System.Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { $_.Key -match '^MOUNT_' } | Sort-Object Key
    if ($mountVars -or $env:AGENT_CONFIG_PATH) {
        $lines.Add("    volumes:")
        foreach ($v in $mountVars) { $lines.Add("      - `"$($v.Value)`"") }
        if ($env:AGENT_CONFIG_PATH) {
            $ap = $env:AGENT_CONFIG_PATH -replace '\\', '/'
            $lines.Add("      - `"${ap}:/agent-config:ro`"")
        }
        $hasVols = $true
    }

    # START_DIR
    if ($StartSubdir) {
        $lines.Add("    environment:")
        $lines.Add("      - START_DIR=$StartSubdir")
        $hasEnv = $true
    }

    # ENABLE_DOCKER
    if ($env:ENABLE_DOCKER -eq "true") {
        $lines.Add("    security_opt:")
        $lines.Add("      - seccomp:unconfined")
        $hasSec = $true
    }

    if (-not ($hasPorts -or $hasVols -or $hasEnv -or $hasSec)) {
        "services: {}" | Set-Content $out -Encoding UTF8
        return
    }

    $lines | Set-Content $out -Encoding UTF8
}

# ── Commands ──────────────────────────────────────────────────────────────────
switch ($Command) {

    "start" {
        if (-not $env:ANTHROPIC_API_KEY -and -not $env:CLAUDE_CODE_OAUTH_TOKEN) {
            Write-Warning "No auth credentials found. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN."
        }

        # Ensure bind-mount host dirs exist
        New-Item -ItemType Directory -Force (Join-Path $ScriptDir ".claude-state\$Container") | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $RepoRoot ".mise-cache")               | Out-Null

        New-Override

        Write-Host "[aid] Building image (uses layer cache)..."
        docker compose -f "$ScriptDir\docker-compose.yml" -p $env:SANDBOX_NAME build

        $running = docker ps    --filter "name=^${Container}$" --format "{{.Names}}" 2>$null
        $exists  = docker ps -a --filter "name=^${Container}$" --format "{{.Names}}" 2>$null

        if ($running) {
            Write-Host "[aid] Container '$Container' is already running."
            Write-Host "[aid] Use '.\claude\aid.ps1 shell $Profile' to open a second session."
            exit 0
        }

        if ($exists) {
            $containerImg = docker inspect $Container --format='{{.Image}}' 2>$null
            $latestImg    = docker images -q claude-sandbox:latest 2>$null
            if ($containerImg -and $latestImg `
                -and $containerImg -ne "sha256:$latestImg" `
                -and $containerImg -ne $latestImg) {
                Write-Host "[aid] Image has changed — recreating container."
                Write-Host "[aid] Workspace and Claude state are preserved (bind mounts)."
                docker rm $Container | Out-Null
                $exists = $null
            }
        }

        if (-not $exists) {
            Write-Host "[aid] Creating container '$Container'..."
            docker compose -f "$ScriptDir\docker-compose.yml" -p $env:SANDBOX_NAME up --no-start
        }

        if ($env:ENABLE_BROWSER -eq "true") {
            $port = if ($env:CHROMIUM_HOST_PORT) { $env:CHROMIUM_HOST_PORT } else { "9222" }
            Write-Host ""
            Write-Host "[aid] Browser ready. To follow along from your host Chrome:"
            Write-Host "  1. Open chrome://inspect"
            Write-Host "  2. Click Configure... and add: localhost:$port"
            Write-Host "  3. The sandbox tab appears under Remote Target"
            Write-Host ""
        }

        Write-Host "[aid] Starting '$Container'..."
        docker start -ai $Container
    }

    "stop" {
        Write-Host "[aid] Stopping '$Container'..."
        $result = docker stop $Container 2>$null
        if ($LASTEXITCODE -ne 0) { Write-Host "[aid] Container not running." }
    }

    "shell" {
        $running = docker ps --filter "name=^${Container}$" --format "{{.Names}}" 2>$null
        if (-not $running) {
            Write-Error "[aid] Container '$Container' is not running. Use 'start' first."
            exit 1
        }
        docker exec -it $Container /bin/bash --login
    }

    "logs" {
        docker logs -f $Container
    }

    default {
        Write-Host "Unknown command: $Command"
        Show-Usage
    }
}
```

- [ ] **Step 2: Test usage / help (on Windows)**

```powershell
.\claude\aid.ps1
```

Expected: prints usage and exits.

- [ ] **Step 3: Test profile not found (on Windows)**

```powershell
.\claude\aid.ps1 start nonexistent
```

Expected: prints error and lists available profiles.

- [ ] **Step 4: Commit**

```bash
git add claude/aid.ps1
git commit -m "feat: add aid.ps1 Windows lifecycle manager"
```

---

## Task 8: `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Write `README.md`**

```markdown
# AID — Agent in Docker

Run Claude Code in `--dangerously-skip-permissions` mode inside an isolated Docker container. Your SSH keys, credentials, and host filesystem stay outside. Profiles let you maintain separate Claude contexts for different projects.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows/macOS) or Docker Engine (Linux)
- A Claude Pro/Max subscription **or** an Anthropic API key

## Authentication

Choose one method per profile. Do not set both.

### Option A — API key
Generate a key at [console.anthropic.com](https://console.anthropic.com). Set `ANTHROPIC_API_KEY=sk-ant-...` in your profile.

### Option B — Long-lived OAuth token (uses your Pro/Max subscription)
On any machine with Claude Code installed and a browser:
```bash
claude setup-token
```
Copy the printed token into your profile as `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...`. Tokens are valid for approximately one year. Run the same command again before they expire.

> Verify the exact command name against the [Claude Code authentication docs](https://code.claude.com/docs/en/authentication) as it may change between releases.

## Quick Start

**1. Create a workspace directory and clone your repos into it**
```bash
mkdir -p ~/sandboxes/myproject
cd ~/sandboxes/myproject
git clone <repo1>
git clone <repo2>
```

**2. Create a profile**
```bash
cp .env.example .env.myproject
# Edit .env.myproject:
#   SANDBOX_NAME=myproject
#   WORKSPACE_PATH=/home/me/sandboxes/myproject   (absolute path)
#   ANTHROPIC_API_KEY=sk-ant-...
#   GIT_AUTHOR_NAME=Your Name
#   GIT_AUTHOR_EMAIL=you@example.com
```

**3. Start**
```bash
# Linux/macOS
./claude/aid.sh start myproject

# Windows
.\claude\aid.ps1 start myproject
```

The first start builds the Docker image (~5–15 minutes). Subsequent starts use the layer cache and are fast.

## Commands

```bash
./claude/aid.sh start [profile] [subdir]   # Build, start, launch Claude
./claude/aid.sh stop  [profile]            # Stop container
./claude/aid.sh shell [profile]            # Open bash shell in container
./claude/aid.sh logs  [profile]            # Tail container logs
```

`subdir` is optional — starts Claude in `/workspace/<subdir>` instead of the workspace root.

Omit `profile` to load `.env` (useful as a symlink to your current profile).

## Workspace Layout

Claude sees all repos under `/workspace/`. Organise your workspace however you like — Claude Code loads per-repo `CLAUDE.md` and skills on demand as it works in each directory.

```
~/sandboxes/
├── myproject/          ← WORKSPACE_PATH for .env.myproject
│   ├── frontend/
│   └── backend/
└── data-pipeline/      ← WORKSPACE_PATH for .env.data-pipeline
    ├── etl-service/
    └── shared-lib/
```

## Git Token

For HTTPS push/pull, add a personal access token to your profile as `GIT_TOKEN=...`.

**GitHub:** github.com → Settings → Developer settings → Personal access tokens → Tokens (classic) → check `repo` scope

**GitLab:** gitlab.com → Edit profile → Access tokens → check `read_repository` + `write_repository`

Your SSH keys are never mounted into the container.

## Multiple Profiles

Each profile is a `.env.<name>` file. Two profiles with different `SANDBOX_NAME` values run simultaneously on the same machine without conflict.

```bash
# List available profiles
ls .env.*

# Run two profiles at once (open two terminals)
./claude/aid.sh start feature-a
./claude/aid.sh start data-pipeline

# Stop a specific profile
./claude/aid.sh stop feature-a
```

## Sharing Claude State Between Profiles

Claude's history, MCP configuration, and settings are stored in `claude/.claude-state/<SANDBOX_NAME>/`. To give a new profile the same setup as an existing one:

```bash
cp -r claude/.claude-state/existing-profile/ claude/.claude-state/new-profile/
```

The two profiles diverge independently from that point.

## Company / Team Config (`AGENT_CONFIG_PATH`)

Point your profile at a local clone of a shared team config repository:

```bash
AGENT_CONFIG_PATH=/path/to/company-aid-config
```

On each container start, everything in that directory is copied into `~/.claude/` — instructions, skills, MCP configuration, etc. Employees clone the repo once and update it with `git pull`. If the repo contains `managed-settings.json`, it is also installed as org-level policy that overrides individual settings.

## Browser Testing

Enable a persistent Chromium instance that Claude and you share:

```bash
# In your .env.<profile>:
ENABLE_BROWSER=true
CHROMIUM_HOST_PORT=9222   # use a unique port per simultaneous profile
```

Claude connects via the Playwright MCP. You follow along:
1. Open `chrome://inspect` in your host Chrome
2. Click **Configure...** and add `localhost:9222`
3. The container's browser tab appears under **Remote Target** → click **inspect**

You can intervene at any point — click through a login, solve a CAPTCHA — and tell Claude to continue from where you left off.

## Docker Inside the Container (`ENABLE_DOCKER`)

```bash
ENABLE_DOCKER=true
```

Claude can run `docker compose up`, spin up databases, build images. Uses rootless Docker-in-Docker.

> ⚠️ **Linux users:** this adds `--security-opt seccomp=unconfined`, relaxing syscall filtering. Rootless mode prevents inner containers from escalating to host root, but syscall filtering is disabled. On Windows/macOS this runs inside Docker Desktop's VM and the risk is much lower.

## Stopping vs. Wiping

```bash
# Stop (preserves all state — history, Docker images, Chromium profile)
./claude/aid.sh stop myproject

# Wipe completely (removes container AND all volumes)
docker compose -f claude/docker-compose.yml -p myproject down -v
```

## When Claude Pauses

When Claude finishes a turn and waits for your input, your terminal bell rings and a visible separator appears:

```
━━━ Claude is waiting for your input ━━━
```

The bell flashes the taskbar/tab in Windows Terminal, iTerm2, macOS Terminal, and VS Code's integrated terminal.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: write README"
```

---

## Task 9: End-to-End Smoke Test

This task verifies the full stack works together. It requires a real workspace directory on the host.

- [ ] **Step 1: Create a minimal test workspace**

```bash
mkdir -p /tmp/aid-test-workspace
cd /tmp/aid-test-workspace
git init test-repo
cd test-repo
echo 'node = "20"' > .mise.toml
git add . && git commit -m "init"
cd "$OLDPWD"
```

- [ ] **Step 2: Create a real test profile**

```bash
cat > .env.e2etest <<EOF
SANDBOX_NAME=aid-e2etest
WORKSPACE_PATH=/tmp/aid-test-workspace
ANTHROPIC_API_KEY=dummy-key-for-smoke-test
GIT_AUTHOR_NAME=AID Test
GIT_AUTHOR_EMAIL=test@aid.local
PORT_1=19999:9999
EOF
```

- [ ] **Step 3: Run start (expect Claude to fail auth, not infrastructure)**

```bash
./claude/aid.sh start e2etest
```

Observe:
- `[aid] Building image` line appears
- `[aid] Creating container 'aid-e2etest'` appears
- `[aid] Running mise install in workspace repos...` appears
- `[aid] Stop hook configured` appears (first run)
- Claude Code launches and fails with an authentication error (expected — key is dummy)
- Container exits cleanly

- [ ] **Step 4: Verify override file was generated**

```bash
cat claude/docker-compose.override.yml
```

Expected: contains `PORT_1=19999:9999` under ports.

- [ ] **Step 5: Verify state directory was created**

```bash
ls claude/.claude-state/aid-e2etest/
```

Expected: `settings.json` present with Stop hook.

- [ ] **Step 6: Verify second start is fast (container exists, image unchanged)**

```bash
./claude/aid.sh start e2etest
```

Expected: `[aid] Building image` completes quickly (all cached). Container restarts immediately without recreation.

- [ ] **Step 7: Clean up**

```bash
docker rm aid-e2etest 2>/dev/null || true
rm -rf claude/.claude-state/aid-e2etest
rm .env.e2etest
rm -rf /tmp/aid-test-workspace
```

- [ ] **Step 8: Final commit**

```bash
git add .
git status  # verify only intended files are staged
git commit -m "feat: complete initial AID implementation"
```

---

## Self-Review Checklist

- [x] `.gitignore` covers `.env.*`, `claude/.claude-state/`, `.mise-cache/`, `docker-compose.override.yml`
- [x] `.env.example` documents all profile options with comments
- [x] Dockerfile: Node 22 system-level (not via mise), Playwright browsers path world-readable
- [x] docker-compose.yml: `DISABLE_AUTOUPDATER=1` hardcoded, `START_DIR` passthrough
- [x] entrypoint.sh: all 9 steps, idempotent Stop hook, submodule-safe workspace scan
- [x] aid.sh: all 4 commands, override generation, image-change detection, bind-mount dir creation
- [x] aid.ps1: equivalent interface to aid.sh
- [x] README: auth setup, quick start, workspace layout, git token, profiles, state sharing, browser, DinD, stop vs wipe, alert
