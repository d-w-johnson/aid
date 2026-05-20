# AID — Agent in Docker: Design Spec

**Date:** 2026-05-18
**Status:** Draft

---

## Goals

- Run Claude Code in `--dangerously-skip-permissions` mode safely inside a Docker container
- Host SSH keys, credentials, and filesystem are inaccessible unless explicitly mounted
- Single command launch per OS — easy enough for product managers and developers alike
- Named profiles switch between workspace contexts without maintaining multiple repo copies
- Multiple profiles can run simultaneously without conflict
- Persistent containers — Claude history, MCP config, inner Docker images survive between sessions
- Alert the user (terminal bell + visible message) when Claude pauses waiting for input
- Cross-platform: Windows (Docker Desktop + WSL2), macOS, Linux
- Extensible: structure supports future agents (GitHub Copilot, etc.) alongside Claude

## Non-Goals

- Cloud/server deployment orchestration (the Docker image is inherently compatible, but cloud orchestration is a separate project)
- Pre-configured language runtimes — repos supply their own `.mise.toml`
- SSH key forwarding into the container

---

## Repository Structure

```
aid/
├── claude/
│   ├── Dockerfile
│   ├── docker-compose.yml
│   ├── entrypoint.sh
│   ├── aid.sh                  # Linux/macOS lifecycle manager
│   ├── aid.ps1                 # Windows lifecycle manager
│   └── .claude-state/          # git-ignored — per-profile ~/.claude bind mounts
├── .env.example                # profile template — copy to .env.<profile>
├── .gitignore
├── .mise-cache/                # git-ignored — shared mise tool cache (Linux binaries)
└── README.md
```

Profile env files (`.env.<profile>`) live at the repo root. They are git-ignored. Future agents add their own subdirectory alongside `claude/`.

---

## Profile System

Each profile is a `.env.<profile>` file at the repo root. `SANDBOX_NAME` inside the file becomes the Docker container name and Compose project name — two profiles with different names run simultaneously without conflict.

### `.env.example`

```bash
# ── Identity ────────────────────────────────────────────────────────────────────
# Unique name for this profile. Becomes the container name and volume prefix.
# Two profiles with different SANDBOX_NAME values run simultaneously.
SANDBOX_NAME=myproject

# ── Authentication (choose ONE — do not set both) ────────────────────────────────
# Option A: API key from console.anthropic.com
# ANTHROPIC_API_KEY=sk-ant-...

# Option B: Long-lived OAuth token (requires Claude Pro/Max subscription)
# Generate with: claude setup-token    (run on a machine with a browser)
# Valid ~1 year. Verify exact command in current Claude Code docs.
# CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...

# ── Workspace ───────────────────────────────────────────────────────────────────
# Directory containing all repos for this profile. Mounted as /workspace.
# Linux/macOS: WORKSPACE_PATH=/home/me/sandboxes/myproject
# Windows:     WORKSPACE_PATH=C:/Users/me/sandboxes/myproject
WORKSPACE_PATH=/path/to/your/workspace

# ── Git identity ────────────────────────────────────────────────────────────────
# Name and email credited on commits. Use a dedicated "AI" identity if preferred.
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com

# ── Git token (HTTPS push/pull) ─────────────────────────────────────────────────
# GitHub:  generate at github.com → Settings → Developer settings →
#          Personal access tokens → Tokens (classic) → repo scope
# GitLab:  generate at gitlab.com → Edit profile → Access tokens →
#          read_repository + write_repository scopes
# GIT_TOKEN=ghp_...

# ── Port forwarding ─────────────────────────────────────────────────────────────
# Expose container ports to your host browser. Format: host_port:container_port
# For multiple simultaneous profiles use different host ports:
#   .env.profile-a → PORT_1=3000:3000
#   .env.profile-b → PORT_1=3001:3000   (same container port, different host port)
# PORT_1=3000:3000
# PORT_2=8080:8080

# ── Extra mounts ────────────────────────────────────────────────────────────────
# Mount additional host directories into the container.
# Format: /host/path:/container/path  (forward slashes on all platforms)
# MOUNT_1=/path/to/extra/data:/mnt/data

# ── Browser testing ─────────────────────────────────────────────────────────────
# Start a persistent Chromium instance with remote debugging on port 9222.
# Claude connects via Playwright MCP; you can follow along via chrome://inspect.
# Use a unique CHROMIUM_HOST_PORT per simultaneous profile to avoid conflicts.
# ENABLE_BROWSER=true
# CHROMIUM_HOST_PORT=9222

# ── Docker-in-Docker ────────────────────────────────────────────────────────────
# Allow Claude to run Docker commands inside the container (spin up databases,
# build images, run docker compose, etc.). Uses rootless DinD.
#
# ⚠️  LINUX SECURITY NOTE: adds --security-opt seccomp=unconfined, which relaxes
#    syscall filtering. Rootless mode means inner containers cannot escalate to
#    host root, but syscall filtering is disabled. On Windows/macOS this runs
#    inside Docker Desktop's VM — significantly lower risk.
#
# ENABLE_DOCKER=true

# ── Telemetry ───────────────────────────────────────────────────────────────────
# Disable Claude Code telemetry and error reporting sent to Anthropic.
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# ── Agent config ────────────────────────────────────────────────────────────────
# Path to a local clone of a shared config repository (e.g. company tooling repo).
# Everything in this directory is copied into ~/.claude/ inside the container:
# CLAUDE.md, skills/, MCP config, etc. Employees clone the repo locally and
# point their profiles at it. Updates are a git pull in that repo.
# AGENT_CONFIG_PATH=C:/work/company-aid-config
```

---

## Docker Image

**Base:** `ubuntu:24.04`

**Build steps:**
1. `ENV DEBIAN_FRONTEND=noninteractive`
2. Install system packages: `curl git sudo ca-certificates gnupg lsb-release iptables uidmap`
3. Install Docker CE (docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin) via the official Ubuntu apt repo
4. Create non-root user `dev` (uid 1000), passwordless sudo, member of `docker` group
5. Configure `/etc/subuid` and `/etc/subgid` for `dev` user (required for rootless DinD)
6. Install Node 22 at system level via the NodeSource apt repository — this keeps Claude Code's Node independent of the `.mise-cache` bind mount which would otherwise hide a mise-managed installation
7. Install Claude Code globally as root: `npm install -g @anthropic-ai/claude-code`
8. Install Playwright's Chromium and system dependencies unconditionally (adds ~200MB, avoids a browser image variant): `npx playwright install --with-deps chromium`
9. Switch to `dev` user, `WORKDIR /home/dev`
10. Install mise: `curl https://mise.run | sh`
11. Add mise activation to `~/.bashrc` and `~/.profile`
12. Copy `entrypoint.sh`, set executable
13. `ENTRYPOINT ["/home/dev/entrypoint.sh"]`
14. `CMD ["/bin/bash", "--login"]`

Node 22 and Claude Code are system-level installations unaffected by the runtime `.mise-cache` mount. Mise is activated for the `dev` user and used exclusively for workspace repo tool management. Chromium is always installed in the image; it only runs as a process when `ENABLE_BROWSER=true`.

---

## `claude/docker-compose.yml`

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
      - ENABLE_BROWSER=${ENABLE_BROWSER:-false}
      - DISABLE_AUTOUPDATER=1
      - CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}
    volumes:
      - ../.mise-cache:/home/dev/.local/share/mise/installs
      - ./.claude-state/${SANDBOX_NAME}:/home/dev/.claude
      - ${WORKSPACE_PATH}:/workspace
    ports:
      - "${CHROMIUM_HOST_PORT:-9222}:9222"
    # PORT_*, MOUNT_*, AGENT_CONFIG_PATH, and ENABLE_DOCKER entries injected via
    # docker-compose.override.yml generated by the start command
```

The `ENABLE_DOCKER` flag is handled in the entrypoint (not via privileged/security-opt in the base compose file) — the start script adds `--security-opt seccomp=unconfined` via the override file when `ENABLE_DOCKER=true`.

---

## `claude/entrypoint.sh`

Runs inside the container on every start. All steps are idempotent.

```
1. Activate mise
   eval "$(~/.local/bin/mise activate bash)"

2. Start rootless Docker daemon (if ENABLE_DOCKER=true)
   dockerd-rootless.sh &
   Wait up to 30s for `docker info` to succeed. Exit 1 on timeout.

3. Validate auth
   Warn clearly if neither ANTHROPIC_API_KEY nor CLAUDE_CODE_OAUTH_TOKEN is set.

4. Configure git identity
   git config --global user.name / user.email from env vars.
   If GIT_TOKEN is set, write ~/.git-credentials for github.com and gitlab.com.
   chmod 600 ~/.git-credentials.

5. Configure Stop hook
   Use `node` to merge the Stop hook into ~/.claude/settings.json without
   overwriting other settings. Hook command:
     printf '\a'; echo '━━━ Claude is waiting for your input ━━━'
   Idempotent — skips if hook already present.

6. Scan workspace for git repositories
   find /workspace -maxdepth 10 -name ".git" -type d
   For each found repo (dirname of .git), run:
     mise trust && mise install
   Skips entries where the .git is itself inside another .git (submodule guard).
   Fast after first run due to shared .mise-cache mount.

7. Copy agent config (if /agent-config is mounted)
   [ -d /agent-config ] && cp -r /agent-config/. ~/.claude/
   Copies everything — CLAUDE.md, skills/, MCP configs, etc.
   The start script mounts AGENT_CONFIG_PATH to /agent-config via the override
   file when the var is set; absent that mount, this step is a no-op.
   If /agent-config/managed-settings.json exists, also copy it to
   /etc/claude-code/managed-settings.json (requires sudo) so it takes effect
   at the highest settings precedence.

8. Start Chromium (if ENABLE_BROWSER=true)
   chromium --headless=new --no-sandbox --disable-gpu \
     --remote-debugging-address=0.0.0.0 --remote-debugging-port=9222 \
     --user-data-dir=/home/dev/.chromium-profile > /tmp/chromium.log 2>&1 &
   Wait up to 15s for http://localhost:9222/json/version to respond.

9. Launch Claude
   cd /workspace/${START_DIR:-}
   exec claude --dangerously-skip-permissions
```

---

## `aid.sh` / `aid.ps1` — Lifecycle Commands

Both scripts accept the same interface. The profile name is the second argument; if omitted, `.env` is used as the default.

```
./claude/aid.sh <command> [profile] [start-dir]

Commands:
  start [profile] [subdir]   Build image (cached), create or restart container,
                             attach terminal. If subdir given, Claude starts in
                             /workspace/<subdir> instead of /workspace root.
  stop  [profile]            Stop the container (and all inner containers).
  shell [profile]            Open a bash shell in the running container.
  logs  [profile]            Tail container logs.
```

### `start` logic in detail

1. Resolve profile: load `.env.<profile>` or `.env`
2. Validate `SANDBOX_NAME` and `WORKSPACE_PATH` are set; warn if no auth var
3. Generate `claude/docker-compose.override.yml`:
   - Add port entries from `PORT_*` vars
   - Add volume entries from `MOUNT_*` vars
   - If `AGENT_CONFIG_PATH` is set, add `<AGENT_CONFIG_PATH>:/agent-config:ro` volume entry and `ENABLE_DOCKER` env var pointing to the path
   - Add `security_opt: [seccomp:unconfined]` if `ENABLE_DOCKER=true`
   - Write `services: {}` no-op if nothing to add
4. Set `GITCONFIG_PATH` to `~/.gitconfig` (Linux/macOS) or `$USERPROFILE/.gitconfig` (Windows)
5. Run `docker compose -f claude/docker-compose.yml build` (uses layer cache — fast unless Dockerfile changed)
6. Determine container state:
   - **Does not exist:** `docker compose up -d` → `docker attach <container>`
   - **Exists, stopped, same image:** `docker start <container>` → `docker attach <container>`
   - **Exists, stopped, image changed:** Print warning ("image was rebuilt — container will be recreated; workspace and Claude state are preserved"), remove old container, `docker compose up -d` → `docker attach <container>`
   - **Exists, running:** Print "already running — use `shell` to open a second session"
7. If `ENABLE_BROWSER=true`, print:
   ```
   Browser ready. To follow along:
     1. Open chrome://inspect in your host Chrome
     2. Click Configure... and add: localhost:<CHROMIUM_HOST_PORT>
     3. The sandbox tab appears under Remote Target
   ```
8. Pass `START_DIR` as env var to the container if a subdir argument was given

---

## Persistence Model

| What | Where | Survives container stop | Survives container recreate |
|---|---|---|---|
| Claude history, settings, MCPs | `.claude-state/<SANDBOX_NAME>/` (bind mount) | ✅ | ✅ |
| Mise tool installations | `.mise-cache/` (bind mount, shared across profiles) | ✅ | ✅ |
| Workspace repos | `WORKSPACE_PATH` (bind mount) | ✅ | ✅ |
| Inner Docker images Claude pulled | Container writable layer | ✅ | ❌ (re-pulled after recreate) |
| Chromium profile | Container writable layer | ✅ | ❌ |

Container is recreated only when the Docker image changes (Dockerfile edited). All bind-mounted state is always preserved.

---

## Feature Details

### Stop Hook / Alert

Configured in `~/.claude/settings.json` by the entrypoint on first run (idempotent merge via `node`):

```json
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "printf '\\a'; echo '━━━ Claude is waiting for your input ━━━'"
      }]
    }]
  }
}
```

The terminal bell (`\a`) propagates through the `docker attach` session to the host terminal, which flashes the taskbar/tab in Windows Terminal, iTerm2, macOS Terminal, and VS Code's integrated terminal.

### Mise Integration

- Mise binary installed at `/home/dev/.local/bin/mise`, activated in `~/.bashrc` and `~/.profile`
- Tool installations bind-mounted from `.mise-cache/` (Linux binaries, compatible with all Linux containers regardless of host OS)
- No tools pre-installed in image beyond Node 22 (required for Claude Code); each repo's `.mise.toml` governs its own versions
- Entrypoint scans `/workspace` up to depth 10 for git repos and runs `mise trust && mise install` in each

### Browser Testing

- Chromium always installed in image
- Only started as a process when `ENABLE_BROWSER=true`
- Runs headless with `--remote-debugging-address=0.0.0.0 --remote-debugging-port=9222`
- `CHROMIUM_HOST_PORT` maps a host port to container's 9222 (use different values per simultaneous profile)
- Playwright MCP connects via `--cdp-endpoint ws://localhost:9222`
- Host user connects via `chrome://inspect` — both share the same live browser session

### Rootless Docker-in-Docker

- Only active when `ENABLE_DOCKER=true`
- Uses `dockerd-rootless.sh` — inner daemon runs as `dev` user via Linux user namespaces
- Requires `--security-opt seccomp=unconfined` (injected via override file); does NOT require `privileged: true`
- Inner containers cannot escalate to host root even if compromised
- On Windows/macOS: runs inside Docker Desktop's VM — lower risk profile than Linux

### Git Credentials

- `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` configured globally in git; can be set to a dedicated AI identity
- `GIT_TOKEN` written to `~/.git-credentials` for `github.com` and `gitlab.com` HTTPS auth
- No SSH keys ever enter the container

### Agent Config Path

- `AGENT_CONFIG_PATH` in profile points to a local clone of a shared config repo (e.g. company tooling)
- Mounted read-only at `/agent-config`, then `cp -r /agent-config/. ~/.claude/` at startup
- Supports any content: `CLAUDE.md` (global instructions), `skills/` (team skills), MCP configs
- If the config repo includes a `managed-settings.json`, the entrypoint copies it to `/etc/claude-code/managed-settings.json` inside the container — Claude Code reads this at the highest settings precedence, overriding anything in `~/.claude`. Useful for enforcing team-wide policy (allowed tools, MCP allowlists, etc.) that individual users cannot override
- Updates to the shared repo are available after the next `start`
- Copying state between profiles: `.claude-state/<profile-a>/` can be copied to `.claude-state/<profile-b>/` to share MCP setup; they diverge independently from that point

---

## `.gitignore`

```
.env.*
!.env.example
claude/.claude-state/
.mise-cache/
claude/docker-compose.override.yml
```

---

## README Coverage

- Prerequisites (Docker Desktop, Claude Pro/Max or API key)
- Auth setup: `claude setup-token` for OAuth token; GitHub/GitLab PAT steps
- Quick start (copy `.env.example`, fill in, run `aid.sh start`)
- Recommended workspace layout (`~/sandboxes/<profile>/` containing repo clones)
- Profile workflow: list, switch, run simultaneously, stop
- Copying Claude state between profiles
- Company config repo pattern (`AGENT_CONFIG_PATH`)
- Browser testing workflow (connecting `chrome://inspect`, taking over from Claude)
- Docker-in-Docker Linux security note
- Stopping vs. wiping a profile (`docker compose down` vs. `down -v`)

---

## Optional: Network Egress Firewall

For teams that want to restrict what Claude can reach over the network, Anthropic's reference dev container ships an `init-firewall.sh` that blocks all outbound traffic except the domains Claude Code requires (inference, auth, telemetry). It runs as a container init script and requires `NET_ADMIN` and `NET_RAW` capabilities.

This is not part of the default AID setup — it adds operational complexity and the capability requirements are not needed otherwise. Teams that want it can adapt the reference script from the [`anthropics/claude-code`](https://github.com/anthropics/claude-code/tree/main/.devcontainer) repository and add it to the `claude/` Dockerfile and entrypoint.

---

## Cloud Compatibility Note

The Docker image is inherently compatible with headless/cloud deployment. The entrypoint reads pure environment variables and does not assume an interactive terminal. Cloud orchestration (task triggers, Kubernetes manifests, Cloud Run config) is a separate future project that uses this same image.
