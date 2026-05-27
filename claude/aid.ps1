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
        # Strip surrounding quotes so values like "My Name" work on both bash and PS
        if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
        $value = $value -replace '\\', '/'   # normalise Windows paths so Docker/YAML accept them
        [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
}

# ── Validate ──────────────────────────────────────────────────────────────────
if (-not $env:SANDBOX_NAME)   { Write-Error "SANDBOX_NAME not set in $EnvFile";   exit 1 }
if (-not $env:WORKSPACE_PATH) { Write-Error "WORKSPACE_PATH not set in $EnvFile"; exit 1 }

$Container = $env:SANDBOX_NAME

# Resolve Claude state directory — defaults to SANDBOX_NAME if CLAUDE_STATE_NAME unset.
# Exporting ensures docker-compose.yml picks it up as ${CLAUDE_STATE_NAME}.
$ClaudeState = if ($env:CLAUDE_STATE_NAME) { $env:CLAUDE_STATE_NAME } else { $env:SANDBOX_NAME }
[System.Environment]::SetEnvironmentVariable("CLAUDE_STATE_NAME", $ClaudeState, "Process")

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

    # ENABLE_DOCKER — Windows/Docker Desktop requires privileged mode because the
    # WSL2 kernel blocks newuidmap (user namespace nesting) without it. The Docker
    # Desktop VM is the security boundary here, not the container privilege level.
    if ($env:ENABLE_DOCKER -eq "true") {
        $lines.Add("    privileged: true")
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
        # Ensure bind-mount host dirs exist
        New-Item -ItemType Directory -Force (Join-Path $ScriptDir ".claude-state\$ClaudeState") | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $RepoRoot ".mise-cache")               | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $RepoRoot ".gradle-cache")             | Out-Null

        # Ensure .claude.json host file exists (Docker requires file mounts to pre-exist)
        $claudeJsonPath = Join-Path $ScriptDir ".claude-state\$ClaudeState\.claude.json"
        if (-not (Test-Path $claudeJsonPath)) {
            '{}' | Set-Content $claudeJsonPath -Encoding UTF8
        }

        New-Override

        Write-Host "[aid] Building image (uses layer cache)..."
        docker compose -f "$ScriptDir\docker-compose.yml" -f "$ScriptDir\docker-compose.override.yml" -p $env:SANDBOX_NAME build

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
            docker compose -f "$ScriptDir\docker-compose.yml" -f "$ScriptDir\docker-compose.override.yml" -p $env:SANDBOX_NAME up --no-start
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
        docker exec -it -w /workspace $Container /bin/bash --login
    }

    "logs" {
        docker logs -f $Container
    }

    default {
        Write-Host "Unknown command: $Command"
        Show-Usage
    }
}
