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

# ── Platform detection ────────────────────────────────────────────────────────
# Native Linux uses rootless Docker-in-Docker (no privilege escalation needed).
# macOS, Windows Git Bash, and WSL2 all run containers inside Docker Desktop's
# VM whose kernel blocks user-namespace nesting — privileged mode required.
KERNEL=$(uname -s)
KERNEL_RELEASE=$(uname -r)
if [[ "$KERNEL" == "Linux" ]] && ! echo "$KERNEL_RELEASE" | grep -qi "microsoft"; then
    DOCKER_NEEDS_PRIVILEGED=false
else
    DOCKER_NEEDS_PRIVILEGED=true
fi

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
# source via sed so Windows backslash paths (C:\foo) are normalised to C:/foo
set -a; source <(sed 's/\\/\//g' "$ENV_FILE"); set +a

# ── Validate ──────────────────────────────────────────────────────────────────
[ -z "${SANDBOX_NAME:-}"   ] && { echo "ERROR: SANDBOX_NAME not set in $ENV_FILE";   exit 1; }
[ -z "${WORKSPACE_PATH:-}" ] && { echo "ERROR: WORKSPACE_PATH not set in $ENV_FILE"; exit 1; }

CONTAINER="$SANDBOX_NAME"

# Resolve Claude state directory — defaults to SANDBOX_NAME if CLAUDE_STATE_NAME unset.
# Exporting ensures docker-compose.yml picks it up as ${CLAUDE_STATE_NAME}.
CLAUDE_STATE="${CLAUDE_STATE_NAME:-$SANDBOX_NAME}"
export CLAUDE_STATE_NAME="$CLAUDE_STATE"

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

    # ENABLE_DOCKER → platform-appropriate security config
    local sec_block=""
    if [ "${ENABLE_DOCKER:-false}" = "true" ]; then
        if [ "$DOCKER_NEEDS_PRIVILEGED" = "true" ]; then
            sec_block="    privileged: true\n"
        else
            sec_block="    security_opt:\n      - seccomp:unconfined\n      - apparmor:unconfined\n"
        fi
    fi

    # ENABLE_HOST_NETWORK → network_mode: host
    local net_block=""
    if [ "${ENABLE_HOST_NETWORK:-false}" = "true" ]; then
        net_block="    network_mode: host\n"
    fi

    if [ -z "$ports_block" ] && [ -z "$vols_block" ] && [ -z "$env_block" ] && [ -z "$sec_block" ] && [ -z "$net_block" ]; then
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
        if [ -n "$net_block" ]; then
            printf "%b" "$net_block"
        fi
    } > "$out"
}

# ── Commands ──────────────────────────────────────────────────────────────────
case "$COMMAND" in

start)
    # Ensure bind-mount host dirs exist (Docker creates them as root otherwise)
    mkdir -p "$SCRIPT_DIR/.claude-state/$CLAUDE_STATE"
    mkdir -p "$REPO_ROOT/.mise-cache"
    mkdir -p "$REPO_ROOT/.gradle-cache"
    mkdir -p "$REPO_ROOT/.npm-cache"

    # Ensure .claude.json host file exists (Docker requires file mounts to pre-exist)
    CLAUDE_JSON="$SCRIPT_DIR/.claude-state/$CLAUDE_STATE/.claude.json"
    [ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

    generate_override

    echo "[aid] Building image (uses layer cache)..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" -f "$SCRIPT_DIR/docker-compose.override.yml" -p "$SANDBOX_NAME" build

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
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" -f "$SCRIPT_DIR/docker-compose.override.yml" -p "$SANDBOX_NAME" up --no-start
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
    docker exec -it -w /workspace "$CONTAINER" /bin/bash --login
    ;;

logs)
    docker logs -f "$CONTAINER"
    ;;

*)
    echo "Unknown command: $COMMAND"
    usage
    ;;
esac
