# AID Container Manager — interactive terminal UI for Claude AI-in-Docker sessions.
# Works in Windows PowerShell 5.1 and PowerShell 7+.
$ErrorActionPreference = "Stop"

$ScriptDir  = $PSScriptRoot
$AidDir     = Join-Path $ScriptDir "claude"
$EnvExample = Join-Path $ScriptDir ".env.example"
$StateDir   = Join-Path $ScriptDir "claude\.claude-state"

# ── Pretty output ─────────────────────────────────────────────────────────────
function Write-HR { Write-Host ("=" * 64) }
function Write-Title {
    param([string]$Text)
    Write-Host ""
    Write-HR
    Write-Host "  $Text"
    Write-HR
}
function Wait-ForEnter { Read-Host "  Press Enter to continue" | Out-Null }

# ── Prompts ───────────────────────────────────────────────────────────────────
function Read-Default {
    param([string]$Label, [string]$Default = "")
    if ($Default) {
        $reply = Read-Host "  $Label [$Default]"
        if ([string]::IsNullOrEmpty($reply)) { return $Default } else { return $reply }
    }
    return Read-Host "  $Label"
}

function Read-Secret {
    param([string]$Label, [string]$Default = "")
    $prompt = if ($Default) { "$Label [press Enter to keep current]" } else { $Label }
    $sec   = Read-Host "  $prompt" -AsSecureString
    $plain = [System.Net.NetworkCredential]::new('', $sec).Password
    if ([string]::IsNullOrEmpty($plain) -and $Default) { return $Default } else { return $plain }
}

function Read-YesNo {
    param([string]$Label, [string]$Default = "n")
    $hint  = if ($Default -eq "y") { "[Y/n]" } else { "[y/N]" }
    $reply = Read-Host "  $Label $hint"
    if ([string]::IsNullOrEmpty($reply)) { $reply = $Default }
    return ($reply -match '^[Yy]')
}

# ── Profile discovery ─────────────────────────────────────────────────────────
function Get-Profiles {
    Get-ChildItem (Join-Path $ScriptDir ".env.*") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ".env.example" } |
        ForEach-Object { $_.Name -replace '^\.env\.', '' }
}

function Get-ProfileValue {
    param([string]$Profile, [string]$Key)
    $envFile = Join-Path $ScriptDir ".env.$Profile"
    if (-not (Test-Path $envFile)) { return "" }
    $match = Select-String -Path $envFile -Pattern "^\s*$([regex]::Escape($Key))\s*=" |
        Select-Object -Last 1
    if (-not $match) { return "" }
    $val = ($match.Line -split '=', 2)[1].Trim()
    $val = $val -replace '^["\x27]|["\x27]$', ''
    $val = $val -replace '\\', '/'
    return $val
}

# Effective Claude state: CLAUDE_STATE_NAME if set, otherwise SANDBOX_NAME
function Get-ClaudeState {
    param([string]$Profile)
    $cs = Get-ProfileValue $Profile "CLAUDE_STATE_NAME"
    if ([string]::IsNullOrEmpty($cs)) { $cs = Get-ProfileValue $Profile "SANDBOX_NAME" }
    return $cs
}

function Set-ProfileValue {
    param([string]$Profile, [string]$Key, [string]$Value)
    $envFile = Join-Path $ScriptDir ".env.$Profile"
    $lines   = [System.Collections.Generic.List[string]]::new()
    $found   = $false
    $pattern = "^\s*$([regex]::Escape($Key))\s*="
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match $pattern) {
                $lines.Add("$Key=`"$Value`"")
                $found = $true
            } else {
                $lines.Add($line)
            }
        }
    }
    if (-not $found) { $lines.Add("$Key=`"$Value`"") }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($envFile, ($lines -join "`n") + "`n", $utf8NoBom)
}

# ── Docker helpers ────────────────────────────────────────────────────────────
function Test-ContainerRunning {
    param([string]$Name)
    $out = docker ps --filter "name=^${Name}$" --format "{{.Names}}" 2>$null
    return ($out -eq $Name)
}

function Test-ContainerExists {
    param([string]$Name)
    $out = docker ps -a --filter "name=^${Name}$" --format "{{.Names}}" 2>$null
    return ($out -eq $Name)
}

# ── Host port inventory (for conflict warnings) ───────────────────────────────
# Returns objects with Port, Profile, Label
function Get-AllHostPorts {
    $results = @()
    foreach ($profile in Get-Profiles) {
        $envFile = Join-Path $ScriptDir ".env.$profile"
        $chrom = Get-ProfileValue $profile "CHROMIUM_HOST_PORT"
        if ($chrom) { $results += [PSCustomObject]@{ Port=$chrom; Profile=$profile; Label="chromium" } }
        foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^(PORT_[^=]+)=(\d+):(.+)$') {
                $results += [PSCustomObject]@{ Port=$matches[2]; Profile=$profile; Label=$matches[1] }
            }
        }
    }
    return $results
}

# ── New terminal launcher ─────────────────────────────────────────────────────
# Opens a Claude session in a new terminal tab/window.
# Uses EncodedCommand to avoid quoting issues on any input.
function Open-NewTerminal {
    param(
        [string]$ContainerName,
        [string]$Profile,
        [bool]$IsRunning = $false
    )
    $title = "AID: $ContainerName"
    $aidPs1 = Join-Path $AidDir "aid.ps1"

    $code = if ($IsRunning) {
        "Write-Host '[aid] Attaching to ''$ContainerName''...'; docker start -ai $ContainerName; Write-Host ''; Read-Host 'Session ended -- press Enter to close'"
    } else {
        "& '$aidPs1' -Command start -Profile '$Profile'; Write-Host ''; Read-Host 'Session ended -- press Enter to close'"
    }
    # EncodedCommand avoids all quoting/escaping headaches
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))

    # Windows Terminal
    if (Get-Command wt -ErrorAction SilentlyContinue) {
        Start-Process wt -ArgumentList @(
            "new-tab", "--title", $title, "--",
            "pwsh", "-NoProfile", "-NoLogo", "-EncodedCommand", $encoded
        )
        return $true
    }

    # Fallback: new PowerShell window (works everywhere on Windows)
    Start-Process pwsh -ArgumentList @("-NoProfile", "-NoLogo", "-EncodedCommand", $encoded)
    return $true
}

# ── Start session ─────────────────────────────────────────────────────────────
function Start-Session {
    Write-Title "Start a Claude Session"
    $profiles = @(Get-Profiles)

    if ($profiles.Count -eq 0) {
        Write-Host "  No profiles found. Use 'Profile management -> New profile' to create one."
        Wait-ForEnter; return
    }

    Write-Host "  Select a profile:"
    Write-Host ""
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $sn  = Get-ProfileValue $profiles[$i] "SANDBOX_NAME"
        $ws  = Get-ProfileValue $profiles[$i] "WORKSPACE_PATH"
        $tag = if (Test-ContainerRunning $sn) { "  [RUNNING -- will attach]" } else { "" }
        Write-Host ("  {0}) {1,-20}  sandbox: {2,-22}  {3}{4}" -f ($i+1), $profiles[$i], $sn, $ws, $tag)
    }
    Write-Host "  $($profiles.Count + 1)) Back"
    Write-Host ""

    $choice = Read-Host "  Choose"
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) {
        $profile = $profiles[$n - 1]
        $sn = Get-ProfileValue $profile "SANDBOX_NAME"
        Write-Host ""

        $newTab = Read-YesNo "Open in a new tab/window (keep this menu open)?" "y"
        Write-Host ""

        if (Test-ContainerRunning $sn) {
            Write-Host "  Container '$sn' already running -- attaching to existing session..."
            if ($newTab) {
                Open-NewTerminal -ContainerName $sn -Profile $profile -IsRunning $true | Out-Null
                Write-Host "  Opened in new terminal. Menu stays open."
                Wait-ForEnter
            } else {
                docker start -ai $sn
            }
        } else {
            Write-Host "  Starting profile: $profile"
            if ($newTab) {
                Open-NewTerminal -ContainerName $sn -Profile $profile -IsRunning $false | Out-Null
                Write-Host "  Starting in new terminal. Menu stays open."
                Wait-ForEnter
            } else {
                & (Join-Path $AidDir "aid.ps1") -Command start -Profile $profile
            }
        }
    } elseif ([int]::TryParse($choice, [ref]$n) -and $n -eq ($profiles.Count + 1)) {
        return
    } else {
        Write-Host "  Invalid choice."; Wait-ForEnter
    }
}

# ── Stop container ────────────────────────────────────────────────────────────
function Stop-Session {
    Write-Title "Stop a Container"
    $profiles = @(Get-Profiles)
    if ($profiles.Count -eq 0) { Write-Host "  No profiles found."; Wait-ForEnter; return }

    Write-Host "  Select a profile:"
    Write-Host ""
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $sn = Get-ProfileValue $profiles[$i] "SANDBOX_NAME"
        $tag = if     (Test-ContainerRunning $sn) { "[RUNNING]" }
               elseif (Test-ContainerExists  $sn) { "[stopped]" }
               else                               { "[not created]" }
        Write-Host ("  {0}) {1,-20}  sandbox: {2,-22}  {3}" -f ($i+1), $profiles[$i], $sn, $tag)
    }
    Write-Host "  $($profiles.Count + 1)) Back"
    Write-Host ""

    $choice = Read-Host "  Choose"
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) {
        $sn = Get-ProfileValue $profiles[$n - 1] "SANDBOX_NAME"
        Write-Host ""
        docker stop $sn 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "  Stopped '$sn'." } else { Write-Host "  '$sn' is not running." }
        Write-Host ""
        Wait-ForEnter
    } elseif ([int]::TryParse($choice, [ref]$n) -and $n -eq ($profiles.Count + 1)) {
        return
    } else {
        Write-Host "  Invalid choice."; Wait-ForEnter
    }
}

# ── Open shell ────────────────────────────────────────────────────────────────
function Open-Shell {
    Write-Title "Open Shell in Container"
    $profiles = @(Get-Profiles)

    Write-Host "  Select a profile:"
    Write-Host ""
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $sn  = Get-ProfileValue $profiles[$i] "SANDBOX_NAME"
        $tag = if (Test-ContainerRunning $sn) { "[RUNNING]" } else { "[not running]" }
        Write-Host ("  {0}) {1,-20}  sandbox: {2,-22}  {3}" -f ($i+1), $profiles[$i], $sn, $tag)
    }
    Write-Host "  $($profiles.Count + 1)) Back"
    Write-Host ""

    $choice = Read-Host "  Choose"
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) {
        $sn = Get-ProfileValue $profiles[$n - 1] "SANDBOX_NAME"
        if (-not (Test-ContainerRunning $sn)) {
            Write-Host "  '$sn' is not running. Start it first."; Wait-ForEnter; return
        }
        docker exec -it -w /workspace $sn /bin/bash --login
    } elseif ([int]::TryParse($choice, [ref]$n) -and $n -eq ($profiles.Count + 1)) {
        return
    } else {
        Write-Host "  Invalid choice."; Wait-ForEnter
    }
}

# ── View logs ─────────────────────────────────────────────────────────────────
function View-Logs {
    Write-Title "View Container Logs"
    $profiles = @(Get-Profiles)

    Write-Host "  Select a profile:"
    Write-Host ""
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $sn = Get-ProfileValue $profiles[$i] "SANDBOX_NAME"
        $tag = if     (Test-ContainerRunning $sn) { "[RUNNING]" }
               elseif (Test-ContainerExists  $sn) { "[stopped]" }
               else                               { "[not created]" }
        Write-Host ("  {0}) {1,-20}  sandbox: {2,-22}  {3}" -f ($i+1), $profiles[$i], $sn, $tag)
    }
    Write-Host "  $($profiles.Count + 1)) Back"
    Write-Host ""

    $choice = Read-Host "  Choose"
    $n = 0
    if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $profiles.Count) {
        $sn = Get-ProfileValue $profiles[$n - 1] "SANDBOX_NAME"
        if (-not (Test-ContainerExists $sn)) {
            Write-Host "  Container '$sn' has not been created yet."; Wait-ForEnter; return
        }
        Write-Host "  Tailing logs for '$sn' (Ctrl+C to stop)..."; Write-Host ""
        docker logs -f $sn
    } elseif ([int]::TryParse($choice, [ref]$n) -and $n -eq ($profiles.Count + 1)) {
        return
    } else {
        Write-Host "  Invalid choice."; Wait-ForEnter
    }
}

# ── Running containers ────────────────────────────────────────────────────────
function Show-Running {
    Write-Title "Container Status"
    $fmt = "  {0,-24} {1,-14} {2,-22} {3}"
    Write-Host ($fmt -f "CONTAINER", "STATUS", "PROFILE", "HOST PORTS")
    Write-Host ($fmt -f "---------", "------", "-------", "----------")

    foreach ($profile in Get-Profiles) {
        $sn = Get-ProfileValue $profile "SANDBOX_NAME"
        if ([string]::IsNullOrEmpty($sn)) { continue }
        if (Test-ContainerRunning $sn) {
            $ports = (docker ps --filter "name=^${sn}$" --format "{{.Ports}}" 2>$null) -replace '0\.0\.0\.0:', ''
            Write-Host ($fmt -f $sn, "RUNNING", $profile, $(if ($ports) { $ports } else { "(none)" }))
        } elseif (Test-ContainerExists $sn) {
            Write-Host ($fmt -f $sn, "stopped", $profile, "")
        } else {
            Write-Host ($fmt -f $sn, "(not created)", $profile, "")
        }
    }
    Write-Host ""; Wait-ForEnter
}

# ── Ports & mounts ────────────────────────────────────────────────────────────
function Show-PortsMounts {
    Write-Title "Ports & Mounts by Profile"
    Write-Host "  Use this to spot host port conflicts before starting multiple sessions."
    Write-Host ""

    foreach ($profile in Get-Profiles) {
        $sn       = Get-ProfileValue $profile "SANDBOX_NAME"
        $ws       = Get-ProfileValue $profile "WORKSPACE_PATH"
        $cs       = Get-ClaudeState $profile
        $chrom    = Get-ProfileValue $profile "CHROMIUM_HOST_PORT"
        $agentCfg = Get-ProfileValue $profile "AGENT_CONFIG_PATH"
        $runTag   = if (Test-ContainerRunning $sn) { "  [RUNNING]" } else { "" }

        Write-Host "  +-- Profile: $profile$runTag"
        Write-Host "  |   Sandbox:      $sn"
        Write-Host "  |   Workspace:    $ws  ->  /workspace"

        # Show claude state with sharing note
        $sharing = @()
        foreach ($other in Get-Profiles) {
            if ($other -eq $profile) { continue }
            if ((Get-ClaudeState $other) -eq $cs) { $sharing += $other }
        }
        $stateNote = if ($sharing.Count -gt 0) { "  (shared with: $($sharing -join ', '))" } else { "" }
        Write-Host "  |   Claude state: $cs$stateNote"

        $envFile  = Join-Path $ScriptDir ".env.$profile"
        $hasPorts = $false

        if ($chrom) {
            if (-not $hasPorts) { Write-Host "  |   Ports:" }
            Write-Host "  |     ${chrom}:9222  (Chromium)"
            $hasPorts = $true
        }
        foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^PORT_[^=]+=(.+)$') {
                if (-not $hasPorts) { Write-Host "  |   Ports:" }
                Write-Host "  |     $($matches[1])"
                $hasPorts = $true
            }
        }
        if (-not $hasPorts) { Write-Host "  |   Ports:     (none)" }

        $hasMounts = $false
        foreach ($line in Get-Content $envFile -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*#') { continue }
            if ($line -match '^MOUNT_[^=]+=(.+)$') {
                if (-not $hasMounts) { Write-Host "  |   Extra mounts:" }
                Write-Host "  |     $($matches[1] -replace '\\', '/')"
                $hasMounts = $true
            }
        }
        if ($agentCfg) {
            if (-not $hasMounts) { Write-Host "  |   Extra mounts:" }
            Write-Host "  |     $agentCfg  ->  /agent-config"
            $hasMounts = $true
        }
        if (-not $hasMounts) { Write-Host "  |   Extra mounts: (none)" }

        $flags = @()
        if ((Get-ProfileValue $profile "ENABLE_DOCKER")  -eq "true") { $flags += "Docker-in-Docker" }
        if ((Get-ProfileValue $profile "ENABLE_BROWSER") -eq "true") { $flags += "Browser(Playwright)" }
        if ($flags.Count -gt 0) { Write-Host "  |   Features:  $($flags -join ', ')" }

        Write-Host "  +--"; Write-Host ""
    }
    Wait-ForEnter
}

# ── Update AID ────────────────────────────────────────────────────────────────
function Update-AID {
    Write-Title "Update AID to Latest Version"
    Write-Host "  Pulling latest changes from origin into $ScriptDir ..."
    Write-Host ""
    git -C $ScriptDir pull
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "  Update complete. Close and relaunch aid-container to pick up any changes."
    } else {
        Write-Host ""
        Write-Host "  Pull failed. Check the output above."
        Write-Host "  If you have local changes you may need to resolve them first."
    }
    Write-Host ""; Wait-ForEnter
}

# ── Profile: edit fields ──────────────────────────────────────────────────────
function Edit-ProfileFields {
    param([string]$Profile)
    Write-Title "Editing: .env.$Profile"

    Write-Host "  (Press Enter to keep the current value shown in brackets.)"
    Write-Host ""
    $sn       = Read-Default "Sandbox name"       (Get-ProfileValue $Profile "SANDBOX_NAME")
    $ws       = Read-Default "Workspace path"     (Get-ProfileValue $Profile "WORKSPACE_PATH")
    Write-Host ""
    $effective = Get-ClaudeState $Profile
    Write-Host "  Claude state name: leave blank to use sandbox name (current: $effective)"
    Write-Host "  Set to a shared name to share credentials/MCPs/history across profiles."
    $cs       = Read-Default "Claude state name (blank = use sandbox name)" (Get-ProfileValue $Profile "CLAUDE_STATE_NAME")
    Write-Host ""
    $gitName  = Read-Default "Git author name"    (Get-ProfileValue $Profile "GIT_AUTHOR_NAME")
    $gitEmail = Read-Default "Git author email"   (Get-ProfileValue $Profile "GIT_AUTHOR_EMAIL")
    $gitToken = Read-Secret  "Git token"          (Get-ProfileValue $Profile "GIT_TOKEN")
    $chrom    = Read-Default "Chromium host port" (Get-ProfileValue $Profile "CHROMIUM_HOST_PORT")

    Set-ProfileValue $Profile "SANDBOX_NAME"      $sn
    Set-ProfileValue $Profile "WORKSPACE_PATH"    ($ws -replace '\\', '/')
    Set-ProfileValue $Profile "CLAUDE_STATE_NAME" $cs
    if ($gitName)  { Set-ProfileValue $Profile "GIT_AUTHOR_NAME"  $gitName }
    if ($gitEmail) { Set-ProfileValue $Profile "GIT_AUTHOR_EMAIL" $gitEmail }
    if ($gitToken) { Set-ProfileValue $Profile "GIT_TOKEN"        $gitToken }
    if ($chrom)    { Set-ProfileValue $Profile "CHROMIUM_HOST_PORT" $chrom }

    Write-Host ""
    Write-Host "  Saved. Edit .env.$Profile directly for PORT_*, MOUNT_*, and feature flags."
    Write-Host ""; Wait-ForEnter
}

# ── Profile: duplicate wizard ─────────────────────────────────────────────────
function Invoke-DuplicateProfile {
    $profiles = @(Get-Profiles)
    if ($profiles.Count -eq 0) {
        Write-Host "  No profiles to duplicate. Create one first."; Wait-ForEnter; return $false
    }

    Write-Title "Duplicate a Profile -- pick source"
    Write-Host "  Select the profile to copy from:"; Write-Host ""
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        $sn = Get-ProfileValue $profiles[$i] "SANDBOX_NAME"
        Write-Host ("  {0}) {1,-20}  (sandbox: {2})" -f ($i+1), $profiles[$i], $sn)
    }
    Write-Host "  $($profiles.Count + 1)) Cancel"; Write-Host ""

    $choice = Read-Host "  Choose"
    $n = 0
    if (-not ([int]::TryParse($choice, [ref]$n)) -or $n -lt 1 -or $n -gt $profiles.Count) {
        return $false
    }

    $src   = $profiles[$n - 1]
    $srcSn = Get-ProfileValue $src "SANDBOX_NAME"
    $srcCs = Get-ClaudeState $src

    # ── New profile name ──────────────────────────────────────────────────────
    Write-Title "Duplicate: new profile identity"
    $newName = Read-Default "New profile name (file: .env.<name>)"
    if ([string]::IsNullOrEmpty($newName)) { Write-Host "  Cancelled."; Wait-ForEnter; return $false }
    $newName = $newName -replace ' ', '-'
    $newEnvFile = Join-Path $ScriptDir ".env.$newName"
    if (Test-Path $newEnvFile) {
        Write-Host "  .env.$newName already exists."
        if (-not (Read-YesNo "Overwrite it?" "n")) { Wait-ForEnter; return $false }
    }

    $newSn = Read-Default "New sandbox/container name" "aid-$newName"
    $newSn = $newSn -replace ' ', '-'

    # ── Workspace ─────────────────────────────────────────────────────────────
    Write-Title "Workspace"
    Write-Host "  Source workspace: $(Get-ProfileValue $src 'WORKSPACE_PATH')"
    Write-Host "  You likely want a different directory for this profile."; Write-Host ""
    $newWs = Read-Default "New workspace path"
    if ([string]::IsNullOrEmpty($newWs)) { $newWs = Get-ProfileValue $src "WORKSPACE_PATH" }

    # ── Claude state ──────────────────────────────────────────────────────────
    Write-Title "Claude state"
    Write-Host @"
  The Claude state directory holds credentials, MCPs, plugins, and session
  history. Choose how this new profile should get its Claude state:

  1) Fresh state for this profile  ($newSn -- starts empty)
  2) Share source state ($srcCs -- same login, MCPs, history as '$src')
  3) Copy source state  ($srcCs -> $newSn -- starts as a clone of '$src')
  4) Custom name (share with a different profile or enter a new name)

"@
    $csChoice = Read-Host "  Choose [1]"
    if ([string]::IsNullOrEmpty($csChoice)) { $csChoice = "1" }
    $csVal = switch ($csChoice) {
        "1" { "" }
        "2" { $srcCs }
        "3" { "" }
        "4" { Read-Default "Claude state name" $srcCs }
        default { "" }
    }

    # ── Ports ─────────────────────────────────────────────────────────────────
    Write-Title "Port assignments"
    Write-Host "  To run simultaneously with other profiles, each host port must be unique."
    Write-Host ""
    $allPorts = @(Get-AllHostPorts | Where-Object { $_.Profile -ne $src })
    if ($allPorts.Count -gt 0) {
        Write-Host "  Host ports already in use by other profiles:"
        foreach ($p in $allPorts) { Write-Host "    port $($p.Port)  used by '$($p.Profile)' ($($p.Label))" }
        Write-Host ""
    }

    # Copy source .env to new file (preserves PORT_*/MOUNT_*/comment structure)
    Copy-Item -Force (Join-Path $ScriptDir ".env.$src") $newEnvFile

    # Update identity fields
    Set-ProfileValue $newName "SANDBOX_NAME"      $newSn
    Set-ProfileValue $newName "WORKSPACE_PATH"    ($newWs -replace '\\', '/')
    Set-ProfileValue $newName "CLAUDE_STATE_NAME" $csVal

    # Walk through CHROMIUM_HOST_PORT
    $srcChrom = Get-ProfileValue $src "CHROMIUM_HOST_PORT"
    if ($srcChrom) {
        $newChrom = Read-Default "Chromium host port (source: $srcChrom)" $srcChrom
        Set-ProfileValue $newName "CHROMIUM_HOST_PORT" $newChrom
    }

    # Walk through PORT_* entries
    $srcEnvFile = Join-Path $ScriptDir ".env.$src"
    foreach ($line in Get-Content $srcEnvFile) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^(PORT_[^=]+)=(\d+):(.+)$') {
            $varName = $matches[1]; $hPort = $matches[2]; $cPort = $matches[3]
            $newHPort = Read-Default "$varName host port (source: $hPort -> container: $cPort)" $hPort
            Set-ProfileValue $newName $varName "$newHPort`:$cPort"
        }
    }

    # ── Copy claude state if requested ───────────────────────────────────────
    if ($csChoice -eq "3") {
        $srcStateDir = Join-Path $StateDir $srcCs
        $dstStateDir = Join-Path $StateDir $newSn
        if (Test-Path $srcStateDir) {
            Write-Host ""
            Write-Host "  Copying Claude state: $srcCs -> $newSn ..."
            Copy-Item -Recurse -Force $srcStateDir $dstStateDir
            Write-Host "  Done."
        } else {
            Write-Host "  (Source state directory '$srcCs' not found -- will start fresh.)"
        }
    }

    Write-Host ""
    Write-Host "  Profile .env.$newName created."
    Write-Host "  Edit it directly to adjust MOUNT_*, AGENT_CONFIG_PATH, and feature flags."
    Write-Host ""; Wait-ForEnter
    return $true
}

# ── Profile: new wizard ───────────────────────────────────────────────────────
function New-Profile {
    Write-Title "Create a New Profile"

    $profiles = @(Get-Profiles)
    if ($profiles.Count -gt 0) {
        Write-Host "  Options:"
        Write-Host "    1) Start from scratch"
        Write-Host "    2) Duplicate an existing profile"
        Write-Host ""
        $startChoice = Read-Host "  Choose [1]"
        if ([string]::IsNullOrEmpty($startChoice)) { $startChoice = "1" }
        if ($startChoice -eq "2") { Invoke-DuplicateProfile; return }
    }

    Write-Host @"
  A profile is a .env.<name> file defining one AID container instance.
  Multiple profiles can run simultaneously -- each needs a unique sandbox name
  and non-overlapping host ports.

"@
    $profileName = Read-Default "Profile name (e.g. myproject, agent1)"
    if ([string]::IsNullOrEmpty($profileName)) { Write-Host "  Cancelled."; Wait-ForEnter; return }
    $profileName = $profileName -replace ' ', '-'
    $envFile = Join-Path $ScriptDir ".env.$profileName"
    if (Test-Path $envFile) {
        Write-Host "  .env.$profileName already exists."
        if (-not (Read-YesNo "Overwrite it?" "n")) { Wait-ForEnter; return }
    }

    Write-Title "Container identity"
    $sn = (Read-Default "Sandbox/container name" "aid-$profileName") -replace ' ', '-'

    Write-Title "Workspace"
    Write-Host "  Host directory mounted as /workspace inside the container."; Write-Host ""
    $ws = Read-Default "Workspace path" "$HOME\aid\$profileName"

    Write-Title "Claude state"
    Write-Host @"
  The Claude state directory holds credentials, MCPs, plugins, and session
  history. Defaults to the sandbox name (each profile gets its own state).
  Set to a shared name to share credentials and MCPs across profiles.

"@
    $existingStates = @(Get-ChildItem $StateDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    if ($existingStates.Count -gt 0) {
        Write-Host "  Existing state directories:  $($existingStates -join ', ')"
    }
    Write-Host "  (Leave blank to use sandbox name as the state directory.)"; Write-Host ""
    $cs = Read-Default "Claude state name (blank = use sandbox name)"

    Write-Title "Git identity"
    $gitName  = Read-Default "Your name (for git commits)"
    $gitEmail = Read-Default "Your email (for git commits)"
    $gitToken = Read-Secret  "Git token (GitHub/GitLab PAT, optional)"

    Write-Title "Port forwarding"
    Write-Host "  Format: host_port:container_port"
    Write-Host "  Use different host ports per profile when running simultaneously."
    Write-Host "  Leave blank to skip. Edit the .env file to add more later."
    Write-Host ""
    $port1 = Read-Default "Port mapping 1 (e.g. 3000:3000, or blank to skip)"
    $port2 = ""
    if ($port1) { $port2 = Read-Default "Port mapping 2 (or blank to skip)" }

    Write-Title "Chromium / browser"
    Write-Host "  Chromium runs inside the container for Playwright MCP browser testing."
    Write-Host "  Must be unique per simultaneously running profile (default: 9222)."
    Write-Host ""
    $enableBrowser = Read-YesNo "Enable browser (Chromium + Playwright)?" "n"
    $chromPort = if ($enableBrowser) { Read-Default "Chromium host port" "9222" } else { "9222" }

    Write-Title "Features"
    $enableDocker     = Read-YesNo "Enable Docker-in-Docker?" "n"
    $disableTelemetry = Read-YesNo "Disable Claude Code telemetry?" "y"

    Write-Title "Agent config"
    Write-Host "  Optional path to a shared config repo (CLAUDE.md, skills, MCP configs)."
    Write-Host "  Everything in that directory is copied into ~/.claude/ on container start."
    Write-Host ""
    $agentCfg = Read-Default "Agent config path (leave blank to skip)"

    Copy-Item -Force $EnvExample $envFile
    Set-ProfileValue $profileName "SANDBOX_NAME"      $sn
    Set-ProfileValue $profileName "WORKSPACE_PATH"    ($ws -replace '\\', '/')
    Set-ProfileValue $profileName "CLAUDE_STATE_NAME" $cs
    if ($gitName)  { Set-ProfileValue $profileName "GIT_AUTHOR_NAME"  $gitName }
    if ($gitEmail) { Set-ProfileValue $profileName "GIT_AUTHOR_EMAIL" $gitEmail }
    if ($gitToken) { Set-ProfileValue $profileName "GIT_TOKEN"        $gitToken }
    if ($port1)    { Set-ProfileValue $profileName "PORT_1"           $port1 }
    if ($port2)    { Set-ProfileValue $profileName "PORT_2"           $port2 }
    Set-ProfileValue $profileName "CHROMIUM_HOST_PORT" $chromPort
    if ($enableBrowser)     { Set-ProfileValue $profileName "ENABLE_BROWSER"  "true" }
    if ($enableDocker)      { Set-ProfileValue $profileName "ENABLE_DOCKER"   "true" }
    if ($disableTelemetry)  { Set-ProfileValue $profileName "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1" }
    if ($agentCfg)          { Set-ProfileValue $profileName "AGENT_CONFIG_PATH" ($agentCfg -replace '\\', '/') }

    Write-Host ""
    Write-Host "  Profile saved to .env.$profileName"
    Write-Host "  Edit it directly to adjust MOUNT_* and AGENT_CONFIG_PATH."
    Write-Host ""; Wait-ForEnter
}

# ── Profile management menu ───────────────────────────────────────────────────
function Show-ProfileMenu {
    while ($true) {
        Write-Title "Profile Management"
        $profiles = @(Get-Profiles)

        if ($profiles.Count -gt 0) {
            Write-Host "  Existing profiles:"
            for ($i = 0; $i -lt $profiles.Count; $i++) {
                $sn = Get-ProfileValue $profiles[$i] "SANDBOX_NAME"
                $cs = Get-ClaudeState $profiles[$i]
                Write-Host ("  {0}) Edit: {1,-20}  sandbox: {2,-20}  state: {3}" -f ($i+1), $profiles[$i], $sn, $cs)
            }
            Write-Host ""
        } else {
            Write-Host "  No profiles yet."; Write-Host ""
        }

        $newN  = $profiles.Count + 1
        $backN = $profiles.Count + 2
        Write-Host "  $newN) New profile"
        Write-Host "  $backN) Back"
        Write-Host ""

        $choice = Read-Host "  Choose"
        $n = 0
        if ([int]::TryParse($choice, [ref]$n)) {
            if ($n -ge 1 -and $n -le $profiles.Count) {
                Edit-ProfileFields $profiles[$n - 1]
            } elseif ($n -eq $newN) {
                New-Profile
            } elseif ($n -eq $backN) {
                return
            } else {
                Write-Host "  Invalid choice."; Wait-ForEnter
            }
        } else {
            Write-Host "  Invalid choice."; Wait-ForEnter
        }
    }
}

# ── Main menu ─────────────────────────────────────────────────────────────────
function Show-MainMenu {
    while ($true) {
        Write-Title "AID Container Manager"

        $profiles     = @(Get-Profiles)
        $runningCount = 0
        foreach ($p in $profiles) {
            $sn = Get-ProfileValue $p "SANDBOX_NAME"
            if (Test-ContainerRunning $sn) { $runningCount++ }
        }

        Write-Host "  Profiles: $($profiles.Count)    Active sessions: $runningCount"
        Write-Host ""
        Write-Host "  1) Start a Claude session"
        Write-Host "  2) Stop a container"
        Write-Host "  3) Open shell in container"
        Write-Host "  4) View container logs"
        Write-Host "  5) Running containers & status"
        Write-Host "  6) Ports & mounts  (identify conflicts)"
        Write-Host "  7) Profile management"
        Write-Host "  8) Update AID to latest version"
        Write-Host "  9) Exit"
        Write-Host ""

        $choice = Read-Host "  Choose"
        switch ($choice) {
            "1" { Start-Session }
            "2" { Stop-Session }
            "3" { Open-Shell }
            "4" { View-Logs }
            "5" { Show-Running }
            "6" { Show-PortsMounts }
            "7" { Show-ProfileMenu }
            "8" { Update-AID }
            { $_ -in "9","q","Q","exit","Exit" } { Write-Host "  Goodbye."; return }
            default { Write-Host "  Invalid choice."; Wait-ForEnter }
        }
    }
}

Show-MainMenu
