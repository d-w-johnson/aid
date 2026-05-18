# AID — Agent in Docker

Run Claude Code in `--dangerously-skip-permissions` mode inside an isolated Docker container. Your SSH keys, credentials, and host filesystem stay outside. Profiles let you maintain separate Claude contexts for different projects.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows/macOS) or Docker Engine (Linux)
- A Claude Pro/Max subscription **or** an Anthropic API key

## Authentication

Claude will ask you on startup for a key and will give you a URL to get one if the browser doesn't launch.

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
#   ANTHROPIC_API_KEY=sk-ant-...    # Option A: API key
#   (or leave unset — browser OAuth prompt on first start, Option B)
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

To drive the browser from Claude, install a Playwright MCP server inside the container (e.g. via `AGENT_CONFIG_PATH` pointing at a team config repo that includes an MCP config). You follow along in your host browser regardless:
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

# Wipe completely (removes container, then removes persistent state)
docker compose -f claude/docker-compose.yml -p myproject down
rm -rf claude/.claude-state/myproject    # Linux/macOS
# Windows: Remove-Item -Recurse -Force claude\.claude-state\myproject
```

Persistent state lives in bind mounts (`claude/.claude-state/<SANDBOX_NAME>/`), not Docker-managed volumes, so `down -v` alone leaves it behind.

## When Claude Pauses

When Claude finishes a turn and waits for your input, your terminal bell rings and a visible separator appears:

```
━━━ Claude is waiting for your input ━━━
```

The bell flashes the taskbar/tab in Windows Terminal, iTerm2, macOS Terminal, and VS Code's integrated terminal.
