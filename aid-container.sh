#!/bin/bash
# AID Container Manager — interactive terminal UI for Claude AI-in-Docker sessions.
# Works on Linux, macOS, and Git Bash on Windows.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AID_DIR="$SCRIPT_DIR/claude"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
STATE_DIR="$SCRIPT_DIR/claude/.claude-state"

# ── Pretty output ─────────────────────────────────────────────────────────────
hr()    { printf '─%.0s' $(seq 1 64); printf '\n'; }
title() { echo; hr; echo "  $1"; hr; }
pause() { local _; read -r -p "  Press Enter to continue... " _ || true; }

# ── Prompts ───────────────────────────────────────────────────────────────────
prompt_default() {
    local label="$1" default="${2:-}" input
    if [ -n "$default" ]; then
        read -r -p "  $label [$default]: " input
        printf '%s' "${input:-$default}"
    else
        read -r -p "  $label: " input
        printf '%s' "$input"
    fi
}

prompt_secret() {
    local label="$1" default="${2:-}" input
    if [ -n "$default" ]; then
        read -r -s -p "  $label [press Enter to keep current]: " input
        echo >&2
        printf '%s' "${input:-$default}"
    else
        read -r -s -p "  $label: " input
        echo >&2
        printf '%s' "$input"
    fi
}

prompt_yes_no() {
    local label="$1" default="${2:-n}" input hint="[y/N]"
    [ "$default" = "y" ] && hint="[Y/n]"
    read -r -p "  $label $hint: " input
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy] ]]
}

# ── Profile discovery ─────────────────────────────────────────────────────────
get_profiles() {
    local f name
    for f in "$SCRIPT_DIR"/.env.*; do
        [ -f "$f" ] || continue
        name="${f##*/.env.}"
        [ "$name" = "example" ] && continue
        printf '%s\n' "$name"
    done
}

get_profile_value() {
    local profile="$1" key="$2"
    local env_file="$SCRIPT_DIR/.env.$profile"
    [ -f "$env_file" ] || return
    local val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2-)
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    val="${val//\\/\/}"
    printf '%s' "$val"
}

# Effective Claude state: CLAUDE_STATE_NAME if set, otherwise SANDBOX_NAME
get_claude_state() {
    local profile="$1"
    local cs
    cs="$(get_profile_value "$profile" "CLAUDE_STATE_NAME")"
    [ -z "$cs" ] && cs="$(get_profile_value "$profile" "SANDBOX_NAME")"
    printf '%s' "$cs"
}

set_profile_value() {
    local profile="$1" key="$2" value="$3"
    local env_file="$SCRIPT_DIR/.env.$profile"
    local tmp found=0
    tmp="$(mktemp)"
    if [ -f "$env_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]]; then
                printf '%s="%s"\n' "$key" "$value" >> "$tmp"
                found=1
            else
                printf '%s\n' "$line" >> "$tmp"
            fi
        done < "$env_file"
    fi
    [ $found -eq 0 ] && printf '%s="%s"\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$env_file"
}

# ── Docker helpers ────────────────────────────────────────────────────────────
container_running() {
    docker ps --filter "name=^${1}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${1}$"
}

container_exists() {
    docker ps -a --filter "name=^${1}$" --format "{{.Names}}" 2>/dev/null | grep -q "^${1}$"
}

# ── Host port inventory (for conflict warnings) ───────────────────────────────
# Prints "port:profile:label" for every bound host port across all profiles
get_all_host_ports() {
    local profile
    while IFS= read -r profile; do
        local env_file="$SCRIPT_DIR/.env.$profile"
        local chrom
        chrom="$(get_profile_value "$profile" "CHROMIUM_HOST_PORT")"
        [ -n "$chrom" ] && printf '%s:%s:chromium\n' "$chrom" "$profile"
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^(PORT_[^=]+)=([0-9]+):.+ ]]; then
                printf '%s:%s:%s\n' "${BASH_REMATCH[2]}" "$profile" "${BASH_REMATCH[1]}"
            fi
        done < "$env_file"
    done < <(get_profiles)
}

# ── New terminal launcher ─────────────────────────────────────────────────────
# Writes a self-deleting temp script, then opens it in a new terminal tab/window.
# Returns 0 on success, 1 if no supported terminal emulator was found.
launch_new_terminal() {
    local sn="$1" profile="$2" is_running="${3:-false}"
    local title="AID: $sn"

    # Build the command the new terminal should run
    local tmpscript
    tmpscript="$(mktemp /tmp/aid-session-XXXXXX.sh)"
    if [ "$is_running" = "true" ]; then
        cat > "$tmpscript" <<SCRIPT
#!/bin/bash
echo "[aid] Attaching to '$sn'..."
docker start -ai $(printf '%q' "$sn")
echo
read -r -p "Session ended. Press Enter to close..." _
rm -f "\$0"
SCRIPT
    else
        cat > "$tmpscript" <<SCRIPT
#!/bin/bash
bash $(printf '%q' "$AID_DIR/aid.sh") start $(printf '%q' "$profile")
echo
read -r -p "Session ended. Press Enter to close..." _
rm -f "\$0"
SCRIPT
    fi
    chmod +x "$tmpscript"

    # Windows Terminal — works on native Windows and from WSL2
    local wt_bin
    wt_bin="$(command -v wt.exe 2>/dev/null || command -v wt 2>/dev/null || true)"
    if [ -n "$wt_bin" ]; then
        "$wt_bin" new-tab --title "$title" -- bash "$tmpscript" &
        return 0
    fi

    # macOS Terminal
    if [[ "$(uname -s)" == "Darwin" ]]; then
        osascript -e "tell application \"Terminal\" to do script \"bash $(printf '%q' "$tmpscript")\"" &>/dev/null
        return 0
    fi

    # Linux terminal emulators (tried in order of prevalence)
    if command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="$title" -- bash "$tmpscript" &
        return 0
    fi
    if command -v konsole &>/dev/null; then
        konsole --new-tab -e bash "$tmpscript" &
        return 0
    fi
    if command -v xfce4-terminal &>/dev/null; then
        xfce4-terminal --title="$title" -e "bash $tmpscript" &
        return 0
    fi
    if command -v xterm &>/dev/null; then
        xterm -title "$title" -e bash "$tmpscript" &
        return 0
    fi
    if command -v tilix &>/dev/null; then
        tilix -e "bash $tmpscript" &
        return 0
    fi

    rm -f "$tmpscript"
    return 1
}

# ── Start session ─────────────────────────────────────────────────────────────
start_session() {
    title "Start a Claude Session"
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)

    if [ ${#profiles[@]} -eq 0 ]; then
        echo "  No profiles found. Use 'Profile management → New profile' to create one."
        pause; return
    fi

    echo "  Select a profile:"
    echo
    local i sn ws tag
    for i in "${!profiles[@]}"; do
        sn="$(get_profile_value "${profiles[$i]}" "SANDBOX_NAME")"
        ws="$(get_profile_value "${profiles[$i]}" "WORKSPACE_PATH")"
        tag=""
        container_running "$sn" && tag="  [RUNNING — will attach]"
        printf "  %d) %-20s  sandbox: %-22s  %s%s\n" \
            $((i + 1)) "${profiles[$i]}" "$sn" "$ws" "$tag"
    done
    echo "  $((${#profiles[@]} + 1))) Back"
    echo

    local choice
    read -r -p "  Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
        local profile="${profiles[$((choice - 1))]}"
        sn="$(get_profile_value "$profile" "SANDBOX_NAME")"
        echo

        local new_tab=false
        if prompt_yes_no "Open in a new tab/window (keep this menu open)?" "y"; then
            new_tab=true
        fi
        echo

        if container_running "$sn"; then
            echo "  Container '$sn' already running — attaching to existing session..."
            if $new_tab && launch_new_terminal "$sn" "$profile" "true"; then
                echo "  Opened in new terminal. Menu stays open."
                pause
            else
                $new_tab && echo "  (Could not find a terminal emulator — running here instead.)"
                docker start -ai "$sn"
            fi
        else
            echo "  Starting profile: $profile"
            if $new_tab && launch_new_terminal "$sn" "$profile" "false"; then
                echo "  Starting in new terminal. Menu stays open."
                pause
            else
                $new_tab && echo "  (Could not find a terminal emulator — running here instead.)"
                bash "$AID_DIR/aid.sh" start "$profile"
            fi
        fi
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -eq $((${#profiles[@]} + 1)) ]; then
        return
    else
        echo "  Invalid choice."; pause
    fi
}

# ── Stop container ────────────────────────────────────────────────────────────
stop_session() {
    title "Stop a Container"
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)

    if [ ${#profiles[@]} -eq 0 ]; then
        echo "  No profiles found."; pause; return
    fi

    echo "  Select a profile:"
    echo
    local i sn tag
    for i in "${!profiles[@]}"; do
        sn="$(get_profile_value "${profiles[$i]}" "SANDBOX_NAME")"
        if   container_running "$sn"; then tag="[RUNNING]"
        elif container_exists  "$sn"; then tag="[stopped]"
        else                               tag="[not created]"
        fi
        printf "  %d) %-20s  sandbox: %-22s  %s\n" $((i + 1)) "${profiles[$i]}" "$sn" "$tag"
    done
    echo "  $((${#profiles[@]} + 1))) Back"
    echo

    local choice
    read -r -p "  Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
        sn="$(get_profile_value "${profiles[$((choice - 1))]}" "SANDBOX_NAME")"
        echo
        docker stop "$sn" 2>/dev/null && echo "  Stopped '$sn'." || echo "  '$sn' is not running."
        echo; pause
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -eq $((${#profiles[@]} + 1)) ]; then
        return
    else
        echo "  Invalid choice."; pause
    fi
}

# ── Open shell ────────────────────────────────────────────────────────────────
open_shell() {
    title "Open Shell in Container"
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)

    echo "  Select a profile:"
    echo
    local i sn tag
    for i in "${!profiles[@]}"; do
        sn="$(get_profile_value "${profiles[$i]}" "SANDBOX_NAME")"
        tag="[not running]"; container_running "$sn" && tag="[RUNNING]"
        printf "  %d) %-20s  sandbox: %-22s  %s\n" $((i + 1)) "${profiles[$i]}" "$sn" "$tag"
    done
    echo "  $((${#profiles[@]} + 1))) Back"
    echo

    local choice
    read -r -p "  Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
        sn="$(get_profile_value "${profiles[$((choice - 1))]}" "SANDBOX_NAME")"
        if ! container_running "$sn"; then
            echo "  '$sn' is not running. Start it first."; pause; return
        fi
        docker exec -it -w /workspace "$sn" /bin/bash --login
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -eq $((${#profiles[@]} + 1)) ]; then
        return
    else
        echo "  Invalid choice."; pause
    fi
}

# ── View logs ─────────────────────────────────────────────────────────────────
view_logs() {
    title "View Container Logs"
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)

    echo "  Select a profile:"
    echo
    local i sn tag
    for i in "${!profiles[@]}"; do
        sn="$(get_profile_value "${profiles[$i]}" "SANDBOX_NAME")"
        if   container_running "$sn"; then tag="[RUNNING]"
        elif container_exists  "$sn"; then tag="[stopped]"
        else                               tag="[not created]"
        fi
        printf "  %d) %-20s  sandbox: %s  %s\n" $((i + 1)) "${profiles[$i]}" "$sn" "$tag"
    done
    echo "  $((${#profiles[@]} + 1))) Back"
    echo

    local choice
    read -r -p "  Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
        sn="$(get_profile_value "${profiles[$((choice - 1))]}" "SANDBOX_NAME")"
        if ! container_exists "$sn"; then
            echo "  Container '$sn' has not been created yet."; pause; return
        fi
        echo "  Tailing logs for '$sn' (Ctrl+C to stop)..."
        echo
        docker logs -f "$sn"
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -eq $((${#profiles[@]} + 1)) ]; then
        return
    else
        echo "  Invalid choice."; pause
    fi
}

# ── Running containers ────────────────────────────────────────────────────────
show_running() {
    title "Container Status"
    printf "  %-24s %-14s %-22s %s\n" "CONTAINER" "STATUS" "PROFILE" "HOST PORTS"
    printf "  %-24s %-14s %-22s %s\n" "---------" "------" "-------" "----------"

    local profile sn
    while IFS= read -r profile; do
        sn="$(get_profile_value "$profile" "SANDBOX_NAME")"
        [ -z "$sn" ] && continue
        if container_running "$sn"; then
            local ports
            ports=$(docker ps --filter "name=^${sn}$" --format "{{.Ports}}" 2>/dev/null | \
                sed 's/0\.0\.0\.0://g; s/:::.*->//g' || true)
            printf "  %-24s %-14s %-22s %s\n" "$sn" "RUNNING" "$profile" "${ports:-(none)}"
        elif container_exists "$sn"; then
            printf "  %-24s %-14s %-22s\n" "$sn" "stopped" "$profile"
        else
            printf "  %-24s %-14s %-22s\n" "$sn" "(not created)" "$profile"
        fi
    done < <(get_profiles)
    echo
    pause
}

# ── Ports & mounts ────────────────────────────────────────────────────────────
show_ports_mounts() {
    title "Ports & Mounts by Profile"
    echo "  Use this to spot host port conflicts before starting multiple sessions."
    echo

    local profile
    while IFS= read -r profile; do
        local sn ws cs chrom agent_cfg
        sn="$(get_profile_value "$profile" "SANDBOX_NAME")"
        ws="$(get_profile_value "$profile" "WORKSPACE_PATH")"
        cs="$(get_claude_state "$profile")"
        chrom="$(get_profile_value "$profile" "CHROMIUM_HOST_PORT")"
        agent_cfg="$(get_profile_value "$profile" "AGENT_CONFIG_PATH")"

        local running_tag=""
        container_running "$sn" && running_tag="  [RUNNING]"

        printf "  +-- Profile: %s%s\n" "$profile" "$running_tag"
        printf "  |   Sandbox:      %s\n" "$sn"
        printf "  |   Workspace:    %s  ->  /workspace\n" "$ws"

        # Show claude state, flagging shared ones
        local state_note=""
        local sharing=""
        while IFS= read -r other; do
            [ "$other" = "$profile" ] && continue
            local other_cs
            other_cs="$(get_claude_state "$other")"
            [ "$other_cs" = "$cs" ] && sharing+=" $other"
        done < <(get_profiles)
        [ -n "$sharing" ] && state_note="  (shared with:$sharing)"
        printf "  |   Claude state: %s%s\n" "$cs" "$state_note"

        local env_file="$SCRIPT_DIR/.env.$profile"
        local has_ports=0

        if [ -n "$chrom" ]; then
            [ $has_ports -eq 0 ] && printf "  |   Ports:\n"
            printf "  |     %s:9222  (Chromium)\n" "$chrom"
            has_ports=1
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^PORT_[^=]+=(.+)$ ]]; then
                [ $has_ports -eq 0 ] && printf "  |   Ports:\n"
                printf "  |     %s\n" "${BASH_REMATCH[1]}"
                has_ports=1
            fi
        done < "$env_file"
        [ $has_ports -eq 0 ] && printf "  |   Ports:     (none)\n"

        local has_mounts=0
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^MOUNT_[^=]+=(.+)$ ]]; then
                [ $has_mounts -eq 0 ] && printf "  |   Extra mounts:\n"
                printf "  |     %s\n" "${BASH_REMATCH[1]//\\/\/}"
                has_mounts=1
            fi
        done < "$env_file"
        [ -n "$agent_cfg" ] && {
            [ $has_mounts -eq 0 ] && printf "  |   Extra mounts:\n"
            printf "  |     %s  ->  /agent-config\n" "$agent_cfg"
            has_mounts=1
        }
        [ $has_mounts -eq 0 ] && printf "  |   Extra mounts: (none)\n"

        local flags=""
        local ed eb
        ed="$(get_profile_value "$profile" "ENABLE_DOCKER")"
        eb="$(get_profile_value "$profile" "ENABLE_BROWSER")"
        [ "$ed" = "true" ] && flags+=" Docker-in-Docker"
        [ "$eb" = "true" ] && flags+=" Browser(Playwright)"
        [ -n "$flags" ] && printf "  |   Features:  %s\n" "${flags# }"
        printf "  +--\n\n"
    done < <(get_profiles)

    pause
}

# ── Update AID ────────────────────────────────────────────────────────────────
update_aid() {
    title "Update AID to Latest Version"
    echo "  Pulling latest changes from origin into $SCRIPT_DIR..."
    echo
    if git -C "$SCRIPT_DIR" pull; then
        echo
        echo "  Update complete. Close and relaunch aid-container to pick up any changes."
    else
        echo
        echo "  Pull failed. Check the output above."
        echo "  If you have local changes you may need to resolve them first."
    fi
    echo; pause
}

# ── Profile: edit fields ──────────────────────────────────────────────────────
edit_profile_fields() {
    local profile="$1"
    title "Editing: .env.$profile"

    local sn ws cs git_name git_email git_token chrom
    sn="$(get_profile_value "$profile" "SANDBOX_NAME")"
    ws="$(get_profile_value "$profile" "WORKSPACE_PATH")"
    cs="$(get_profile_value "$profile" "CLAUDE_STATE_NAME")"
    git_name="$(get_profile_value "$profile" "GIT_AUTHOR_NAME")"
    git_email="$(get_profile_value "$profile" "GIT_AUTHOR_EMAIL")"
    git_token="$(get_profile_value "$profile" "GIT_TOKEN")"
    chrom="$(get_profile_value "$profile" "CHROMIUM_HOST_PORT")"

    echo "  (Press Enter to keep the current value shown in brackets.)"
    echo
    sn="$(prompt_default "Sandbox name" "$sn")"
    ws="$(prompt_default "Workspace path" "$ws")"
    echo
    echo "  Claude state name: leave blank to use sandbox name (current: $(get_claude_state "$profile"))"
    echo "  Set to a shared name to share credentials/MCPs/history across profiles."
    cs="$(prompt_default "Claude state name (blank = use sandbox name)" "$cs")"
    echo
    git_name="$(prompt_default "Git author name" "$git_name")"
    git_email="$(prompt_default "Git author email" "$git_email")"
    git_token="$(prompt_secret "Git token" "$git_token")"
    chrom="$(prompt_default "Chromium host port" "$chrom")"

    set_profile_value "$profile" "SANDBOX_NAME"      "$sn"
    set_profile_value "$profile" "WORKSPACE_PATH"    "$ws"
    set_profile_value "$profile" "CLAUDE_STATE_NAME" "$cs"
    [ -n "$git_name" ]  && set_profile_value "$profile" "GIT_AUTHOR_NAME"  "$git_name"
    [ -n "$git_email" ] && set_profile_value "$profile" "GIT_AUTHOR_EMAIL" "$git_email"
    [ -n "$git_token" ] && set_profile_value "$profile" "GIT_TOKEN"        "$git_token"
    [ -n "$chrom" ]     && set_profile_value "$profile" "CHROMIUM_HOST_PORT" "$chrom"

    echo
    echo "  Saved. Edit .env.$profile directly for PORT_*, MOUNT_*, and feature flags."
    echo; pause
}

# ── Profile: duplicate wizard ─────────────────────────────────────────────────
duplicate_profile() {
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)

    if [ ${#profiles[@]} -eq 0 ]; then
        echo "  No profiles to duplicate. Create one first."; pause; return 1
    fi

    title "Duplicate a Profile — pick source"
    echo "  Select the profile to copy from:"
    echo
    local i sn
    for i in "${!profiles[@]}"; do
        sn="$(get_profile_value "${profiles[$i]}" "SANDBOX_NAME")"
        printf "  %d) %-20s  (sandbox: %s)\n" $((i + 1)) "${profiles[$i]}" "$sn"
    done
    echo "  $((${#profiles[@]} + 1))) Cancel"
    echo

    local choice
    read -r -p "  Choose: " choice
    if ! { [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; }; then
        return 1
    fi

    local src="${profiles[$((choice - 1))]}"
    local src_sn src_cs
    src_sn="$(get_profile_value "$src" "SANDBOX_NAME")"
    src_cs="$(get_claude_state "$src")"

    # ── New profile name ──────────────────────────────────────────────────────
    title "Duplicate: new profile identity"
    local new_name
    new_name="$(prompt_default "New profile name (file: .env.<name>)" "")"
    if [ -z "$new_name" ]; then
        echo "  Cancelled."; pause; return 1
    fi
    new_name="${new_name// /-}"
    if [ -f "$SCRIPT_DIR/.env.$new_name" ]; then
        echo "  .env.$new_name already exists."
        prompt_yes_no "Overwrite it?" "n" || { pause; return 1; }
    fi

    local new_sn
    new_sn="$(prompt_default "New sandbox/container name" "aid-$new_name")"
    new_sn="${new_sn// /-}"

    # ── Workspace ─────────────────────────────────────────────────────────────
    title "Workspace"
    echo "  Source workspace: $(get_profile_value "$src" "WORKSPACE_PATH")"
    echo "  You likely want a different directory for this profile."
    echo
    local new_ws
    new_ws="$(prompt_default "New workspace path" "")"
    [ -z "$new_ws" ] && new_ws="$(get_profile_value "$src" "WORKSPACE_PATH")"

    # ── Claude state ──────────────────────────────────────────────────────────
    title "Claude state"
    cat <<EOF
  The Claude state directory holds credentials, MCPs, plugins, and session
  history. Choose how this new profile should get its Claude state:

  1) Fresh state for this profile  ($new_sn — starts empty)
  2) Share source state ($src_cs — same login, MCPs, history as '$src')
  3) Copy source state  ($src_cs → $new_sn — starts as a clone of '$src')
  4) Custom name (share with a different profile or enter a new name)

EOF
    local cs_choice cs_val
    read -r -p "  Choose [1]: " cs_choice
    cs_choice="${cs_choice:-1}"
    case "$cs_choice" in
        1) cs_val="" ;; # blank = use sandbox name
        2) cs_val="$src_cs" ;;
        3) cs_val="" ;; # blank = use sandbox name (we'll copy the dir)
        4) cs_val="$(prompt_default "Claude state name" "$src_cs")" ;;
        *) cs_val="" ;;
    esac

    # ── Ports ────────────────────────────────────────────────────────────────
    title "Port assignments"
    echo "  To run simultaneously with other profiles, each host port must be unique."
    echo
    local used_ports_info=""
    while IFS= read -r entry; do
        local p="${entry%%:*}"; entry="${entry#*:}"
        local prof="${entry%%:*}"; local lbl="${entry#*:}"
        [ "$prof" = "$src" ] && continue
        used_ports_info+="    port $p  used by '$prof' ($lbl)\n"
    done < <(get_all_host_ports)
    if [ -n "$used_ports_info" ]; then
        echo "  Host ports already in use by other profiles:"
        printf "%b" "$used_ports_info"
        echo
    fi

    # Copy the source .env file to get all PORT_*/MOUNT_* structure preserved
    cp "$SCRIPT_DIR/.env.$src" "$SCRIPT_DIR/.env.$new_name"

    # Update identity fields first
    set_profile_value "$new_name" "SANDBOX_NAME"      "$new_sn"
    set_profile_value "$new_name" "WORKSPACE_PATH"    "$new_ws"
    set_profile_value "$new_name" "CLAUDE_STATE_NAME" "$cs_val"

    # Walk through CHROMIUM_HOST_PORT
    local src_chrom
    src_chrom="$(get_profile_value "$src" "CHROMIUM_HOST_PORT")"
    if [ -n "$src_chrom" ]; then
        local new_chrom
        new_chrom="$(prompt_default "Chromium host port (source: $src_chrom)" "$src_chrom")"
        set_profile_value "$new_name" "CHROMIUM_HOST_PORT" "$new_chrom"
    fi

    # Walk through PORT_* entries
    local src_env="$SCRIPT_DIR/.env.$src"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^(PORT_[^=]+)=([0-9]+):(.+)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local h_port="${BASH_REMATCH[2]}"
            local c_port="${BASH_REMATCH[3]}"
            local new_h_port
            new_h_port="$(prompt_default "$var_name host port (source: $h_port → container: $c_port)" "$h_port")"
            set_profile_value "$new_name" "$var_name" "$new_h_port:$c_port"
        fi
    done < "$src_env"

    # ── Copy claude state if requested ───────────────────────────────────────
    if [ "$cs_choice" = "3" ]; then
        local src_state_dir="$STATE_DIR/$src_cs"
        local dst_state_dir="$STATE_DIR/$new_sn"
        if [ -d "$src_state_dir" ]; then
            echo
            echo "  Copying Claude state: $src_cs → $new_sn ..."
            cp -r "$src_state_dir" "$dst_state_dir"
            echo "  Done."
        else
            echo "  (Source state directory $src_cs not found — will start fresh.)"
        fi
    fi

    echo
    echo "  Profile .env.$new_name created."
    echo "  Edit it directly to adjust MOUNT_*, AGENT_CONFIG_PATH, and feature flags."
    echo; pause
    return 0
}

# ── Profile: new wizard ───────────────────────────────────────────────────────
new_profile() {
    title "Create a New Profile"

    # Offer to duplicate if any profiles exist
    local profiles=()
    while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)
    if [ ${#profiles[@]} -gt 0 ]; then
        cat <<'EOF'
  Options:
    1) Start from scratch
    2) Duplicate an existing profile

EOF
        local start_choice
        read -r -p "  Choose [1]: " start_choice
        start_choice="${start_choice:-1}"
        if [ "$start_choice" = "2" ]; then
            duplicate_profile
            return
        fi
    fi

    cat <<'EOF'
  A profile is a .env.<name> file defining one AID container instance.
  Multiple profiles can run simultaneously — each needs a unique sandbox name
  and non-overlapping host ports.

EOF
    local profile_name
    profile_name="$(prompt_default "Profile name (e.g. myproject, agent1)" "")"
    if [ -z "$profile_name" ]; then
        echo "  Cancelled."; pause; return
    fi
    profile_name="${profile_name// /-}"
    local env_file="$SCRIPT_DIR/.env.$profile_name"
    if [ -f "$env_file" ]; then
        echo "  .env.$profile_name already exists."
        prompt_yes_no "Overwrite it?" "n" || { pause; return; }
    fi

    title "Container identity"
    local sn
    sn="$(prompt_default "Sandbox/container name" "aid-$profile_name")"
    sn="${sn// /-}"

    title "Workspace"
    echo "  Host directory mounted as /workspace inside the container."
    echo
    local ws
    ws="$(prompt_default "Workspace path" "$HOME/aid/$profile_name")"

    title "Claude state"
    cat <<'EOF'
  The Claude state directory holds credentials, MCPs, plugins, and session
  history. Defaults to the sandbox name (each profile gets its own state).
  Set to a shared name to share credentials and MCPs across profiles.

EOF
    echo "  Existing state directories:"
    if [ -d "$STATE_DIR" ]; then
        ls "$STATE_DIR" 2>/dev/null | while read -r d; do printf "    %s\n" "$d"; done
    fi
    echo "  (Leave blank to use sandbox name as the state directory.)"
    echo
    local cs
    cs="$(prompt_default "Claude state name (blank = use sandbox name)" "")"

    title "Git identity"
    local git_name git_email git_token
    git_name="$(prompt_default "Your name (for git commits)" "")"
    git_email="$(prompt_default "Your email (for git commits)" "")"
    git_token="$(prompt_secret "Git token (GitHub/GitLab PAT, optional)" "")"

    title "Port forwarding"
    echo "  Format: host_port:container_port"
    echo "  Use different host ports per profile when running simultaneously."
    echo "  Leave blank to skip. Edit the .env file to add more later."
    echo
    local port1 port2
    port1="$(prompt_default "Port mapping 1 (e.g. 3000:3000, or blank to skip)" "")"
    [ -n "$port1" ] && port2="$(prompt_default "Port mapping 2 (or blank to skip)" "")" || port2=""

    title "Chromium / browser"
    echo "  Chromium runs inside the container for Playwright MCP browser testing."
    echo "  Must be unique per simultaneously running profile (default: 9222)."
    echo
    local chrom enable_browser
    if prompt_yes_no "Enable browser (Chromium + Playwright)?" "n"; then
        enable_browser="true"
        chrom="$(prompt_default "Chromium host port" "9222")"
    else
        enable_browser="false"
        chrom="9222"
    fi

    title "Features"
    local enable_docker disable_telemetry
    prompt_yes_no "Enable Docker-in-Docker?" "n" \
        && enable_docker="true" || enable_docker="false"
    prompt_yes_no "Disable Claude Code telemetry?" "y" \
        && disable_telemetry="1" || disable_telemetry=""

    title "Agent config"
    echo "  Optional path to a shared config repo (CLAUDE.md, skills, MCP configs)."
    echo "  Everything in that directory is copied into ~/.claude/ on container start."
    echo
    local agent_cfg
    agent_cfg="$(prompt_default "Agent config path (leave blank to skip)" "")"

    # Write profile from example template
    cp "$ENV_EXAMPLE" "$env_file"
    set_profile_value "$profile_name" "SANDBOX_NAME"      "$sn"
    set_profile_value "$profile_name" "WORKSPACE_PATH"    "$ws"
    set_profile_value "$profile_name" "CLAUDE_STATE_NAME" "$cs"
    [ -n "$git_name" ]      && set_profile_value "$profile_name" "GIT_AUTHOR_NAME"  "$git_name"
    [ -n "$git_email" ]     && set_profile_value "$profile_name" "GIT_AUTHOR_EMAIL" "$git_email"
    [ -n "$git_token" ]     && set_profile_value "$profile_name" "GIT_TOKEN"        "$git_token"
    [ -n "$port1" ]         && set_profile_value "$profile_name" "PORT_1"           "$port1"
    [ -n "$port2" ]         && set_profile_value "$profile_name" "PORT_2"           "$port2"
    set_profile_value "$profile_name" "CHROMIUM_HOST_PORT" "$chrom"
    [ "$enable_browser" = "true" ] && set_profile_value "$profile_name" "ENABLE_BROWSER"  "true"
    [ "$enable_docker"  = "true" ] && set_profile_value "$profile_name" "ENABLE_DOCKER"   "true"
    [ -n "$disable_telemetry" ]    && set_profile_value "$profile_name" \
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
    [ -n "$agent_cfg" ] && set_profile_value "$profile_name" "AGENT_CONFIG_PATH" "$agent_cfg"

    echo
    echo "  Profile saved to .env.$profile_name"
    echo "  Edit it directly to adjust MOUNT_* and AGENT_CONFIG_PATH."
    echo; pause
}

# ── Profile management menu ───────────────────────────────────────────────────
profile_menu() {
    while true; do
        title "Profile Management"
        local profiles=()
        while IFS= read -r p; do profiles+=("$p"); done < <(get_profiles)

        if [ ${#profiles[@]} -gt 0 ]; then
            echo "  Existing profiles:"
            local i sn cs
            for i in "${!profiles[@]}"; do
                sn="$(get_profile_value "${profiles[$i]}" "SANDBOX_NAME")"
                cs="$(get_claude_state "${profiles[$i]}")"
                printf "  %d) Edit: %-20s  sandbox: %-20s  state: %s\n" \
                    $((i + 1)) "${profiles[$i]}" "$sn" "$cs"
            done
            echo
        else
            echo "  No profiles yet."; echo
        fi

        local new_n back_n
        new_n=$((${#profiles[@]} + 1))
        back_n=$((${#profiles[@]} + 2))
        printf "  %d) New profile\n" "$new_n"
        printf "  %d) Back\n" "$back_n"
        echo

        local choice
        read -r -p "  Choose: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#profiles[@]}" ]; then
                edit_profile_fields "${profiles[$((choice - 1))]}"
            elif [ "$choice" -eq "$new_n" ]; then
                new_profile
            elif [ "$choice" -eq "$back_n" ]; then
                return
            else
                echo "  Invalid choice."; pause
            fi
        else
            echo "  Invalid choice."; pause
        fi
    done
}

# ── Main menu ─────────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        title "AID Container Manager"

        local running_count=0 profile sn
        while IFS= read -r profile; do
            sn="$(get_profile_value "$profile" "SANDBOX_NAME")"
            container_running "$sn" 2>/dev/null && running_count=$((running_count + 1)) || true
        done < <(get_profiles)
        local profile_count
        profile_count=$(get_profiles | wc -l | tr -d ' ')

        printf "  Profiles: %s    Active sessions: %s\n" "$profile_count" "$running_count"
        echo
        cat <<'EOF'
  1) Start a Claude session
  2) Stop a container
  3) Open shell in container
  4) View container logs
  5) Running containers & status
  6) Ports & mounts  (identify conflicts)
  7) Profile management
  8) Update AID to latest version
  9) Exit

EOF
        local choice
        read -r -p "  Choose: " choice
        case "$choice" in
            1) start_session ;;
            2) stop_session ;;
            3) open_shell ;;
            4) view_logs ;;
            5) show_running ;;
            6) show_ports_mounts ;;
            7) profile_menu ;;
            8) update_aid ;;
            9|q|Q|exit|Exit) echo "  Goodbye."; return ;;
            *) echo "  Invalid choice."; pause ;;
        esac
    done
}

main_menu
