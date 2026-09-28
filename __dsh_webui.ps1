<#
.SYNOPSIS
    dsh webui lifecycle + fork sync manager.

.DESCRIPTION
    Interactive menu to:
      - sync upstream changes into the local fork (origin=fork, upstream=deepseek-ai),
      - install deps and rebuild artifacts,
      - start / stop / restart the dsh web server in the background,
      - inspect git and webui status, tail the webui log.

    Targets PowerShell 7+ (pwsh) on Windows.

.PARAMETER UpstreamRemote
    Upstream remote name (default: upstream).

.PARAMETER OriginRemote
    Origin remote name (default: origin).

.PARAMETER TargetBranch
    Branch to sync upstream into (default: master).

.PARAMETER Port
    Web server port for status / open-browser hints (default: 3080).

.PARAMETER Command
    Skip the menu and run one action: sync | update | start | stop | restart | status | logs | open.

.EXAMPLE
    .\webui-manager.ps1

.EXAMPLE
    .\webui-manager.ps1 -Command sync -DryRun

.EXAMPLE
    .\webui-manager.ps1 -Command restart -Port 3080
#>

param(
    [string]$UpstreamRemote = "upstream",
    [string]$OriginRemote   = "origin",
    [string]$TargetBranch   = "master",
    [int]   $Port           = 3080,
    [ValidateSet("","sync","update","start","stop","restart","status","logs","open")]
    [string]$Command        = "",
    [switch]$DryRun,
    [switch]$NoClear
)

$ErrorActionPreference = "Stop"
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding          = [System.Text.Encoding]::UTF8
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
} catch {}

# ── Paths ─────────────────────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }
$RepoRoot  = $ScriptDir
$PidFile    = Join-Path $RepoRoot ".dsh-webui.pid"
$StdoutLog  = Join-Path $RepoRoot ".dsh-webui.out.log"
$StderrLog  = Join-Path $RepoRoot ".dsh-webui.err.log"
$LogFile    = $StdoutLog  # backwards-compat alias used by tests / docs

# ── Logging helpers ──────────────────────────────────────────────────────────
function Write-Banner {
        # Clear-Host throws SetValueInvocationException when stdout is piped/redirected
        # (the cursor-position write has no real terminal to talk to). Swallow it.
        try { Clear-Host } catch { }

        Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  dsh webui manager" -ForegroundColor Cyan -NoNewline

        $proc = Get-WebuiPid
        $runningPort = if ($proc) { Find-WebuiPort -WebuiPid $proc.Id } else { $null }
        $isRunning = $proc -and $runningPort -and (Test-PortOpen -TestPort $runningPort)
        if ($isRunning) {
            Write-Host "   ·   " -ForegroundColor DarkGray -NoNewline
            Write-Host "http://127.0.0.1:$runningPort/" -ForegroundColor Green -NoNewline
            Write-Host "   (pid $($proc.Id))" -ForegroundColor DarkGray
        } else {
            Write-Host "   ·   $RepoRoot" -ForegroundColor DarkGray
        }
        Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray

        # Status line mirrors Start-Webui's "Port N is listening. Open: …" output,
        # so the URL/pid stays visible on every menu render — including the very
        # first one after a double-click launch.
        if ($isRunning) {
            Write-Host "  webui: (" -ForegroundColor DarkGray -NoNewline
            Write-Host "http://127.0.0.1:$runningPort/" -ForegroundColor Green -NoNewline
            Write-Host ")   pid $($proc.Id)" -ForegroundColor DarkGray
        } else {
            Write-Host "  webui: (not running)" -ForegroundColor DarkGray
        }
}

function Write-Info    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn    { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-ErrorMsg { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Ok      { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Step    { param($n,$msg) Write-Host "[$n/4]   $msg" -ForegroundColor Cyan }

function Pause-IfInteractive {
    if ($Command -eq "") {
        Write-Host ""
        Write-Host "Press Enter to return to menu..." -ForegroundColor DarkGray -NoNewline
        [void][Console]::ReadLine()
    }
}

# ── Process helpers ──────────────────────────────────────────────────────────
function Get-WebuiPid {
    if (-not (Test-Path $PidFile)) { return $null }
    $raw = Get-Content $PidFile -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $pidValue = 0
    if (-not [int]::TryParse(($raw | Select-Object -First 1), [ref]$pidValue)) { return $null }
    $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    return $proc
}

function Remove-PidFile {
    if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
}

function Test-PortOpen {
    param([int]$TestPort)
    $conn = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $conn.BeginConnect("127.0.0.1", $TestPort, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
        if (-not $ok) { return $false }
        $conn.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $conn.Close()
    }
}

function Find-WebuiPort {
    # Return the port the running webui is actually listening on (from netstat), or $null.
    param([int]$WebuiPid)
    if (-not $WebuiPid) { return $null }
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.OwningProcess -eq $WebuiPid }
        if ($conns) { return ($conns | Select-Object -First 1).LocalPort }
    } catch {
        # Fallback for older PowerShell without Get-NetTCPConnection — parse netstat.
        $line = netstat -ano 2>$null | Select-String "LISTENING\s+$WebuiPid$" | Select-Object -First 1
        if ($line) {
            $tokens = ($line -split '\s+') | Where-Object { $_ -ne '' }
            # Local address is column 2: "127.0.0.1:3299" or "[::]:3299"
            $local = $tokens[1]
            if ($local -match ':(\d+)$') { return [int]$Matches[1] }
        }
    }
    return $null
}

# ── Sync upstream (fetch → merge → push → rebase) ───────────────────────────
function Invoke-SyncUpstream {
    if (-not (git rev-parse --git-dir 2>$null)) {
        Write-ErrorMsg "Not a git repository: $RepoRoot"
        return 1
    }
    $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if ($currentBranch -eq "HEAD") {
        Write-ErrorMsg "Detached HEAD. Checkout a branch first."
        return 1
    }

    $upExists = $true
    try { $null = git remote get-url $UpstreamRemote 2>$null; if ($LASTEXITCODE -ne 0) { $upExists = $false } } catch { $upExists = $false }
    if (-not $upExists) {
        Write-ErrorMsg "Remote '$UpstreamRemote' not found. Add it first (e.g. git remote add $UpstreamRemote git@github.com:deepseek-ai/deepseek-harness.git)."
        return 1
    }
    try { $null = git remote get-url $OriginRemote 2>$null; if ($LASTEXITCODE -ne 0) { throw "missing" } } catch {
        Write-ErrorMsg "Remote '$OriginRemote' not found."
        return 1
    }

    $stashed = $false
    $dirty = (git status --porcelain --untracked-files=no 2>$null | Out-String).Trim()
    if ($dirty) {
        $msg = "sync-upstream: auto stash $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Warn "Worktree dirty — stashing changes..."
        if (-not $DryRun) { git stash push -m $msg | Out-Null }
        $stashed = $true
    }

    try {
        Write-Step 1 "Fetching $UpstreamRemote..."
        if (-not $DryRun) { git fetch $UpstreamRemote }

        Write-Step 2 "Merging $UpstreamRemote/$TargetBranch into $TargetBranch..."
        if (-not $DryRun) {
            $localExists = $true
            try { $null = git show-ref --verify --quiet "refs/heads/$TargetBranch" 2>$null; if ($LASTEXITCODE -ne 0) { $localExists = $false } } catch { $localExists = $false }
            if ($localExists) { git checkout $TargetBranch } else { git checkout -b $TargetBranch "$UpstreamRemote/$TargetBranch" }
            git merge "$UpstreamRemote/$TargetBranch" --no-edit | Out-Null
        }

        Write-Step 3 "Pushing $TargetBranch to $OriginRemote..."
        if (-not $DryRun) { git push $OriginRemote $TargetBranch }

        if ($currentBranch -ne $TargetBranch) {
            Write-Step 4 "Rebasing $currentBranch onto $TargetBranch..."
            if (-not $DryRun) {
                git checkout $currentBranch | Out-Null
                git rebase $TargetBranch | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-ErrorMsg "Rebase conflict. Resolve, then: git rebase --continue  (and git stash pop if changes were stashed)."
                    return 2
                }
            }
        } else {
            Write-Step 4 "Already on $TargetBranch — skipping rebase."
        }

        if ($stashed) {
            Write-Info "Restoring stashed changes..."
            if (-not $DryRun) { git stash pop | Out-Null }
        }
        Write-Ok "Sync complete: $TargetBranch is up-to-date with $UpstreamRemote/$TargetBranch."
        return 0
    } finally {
        # If we stashed and a later step errored before stash pop, leave the stash for the user.
        if ($stashed -and -not $DryRun) {
            $stillStashed = (git stash list 2>$null | Out-String).Trim()
            if ($stillStashed -and ($LASTEXITCODE -ne 0)) {
                Write-Warn "A stash is still present — run 'git stash list' to inspect, 'git stash pop' to restore."
            }
        }
    }
}

# ── Ghost package cleanup ─────────────────────────────────────────────────────
# Upstream "remove package" refactors delete a package's sources but leave its
# git-ignored lib/ + node_modules/ behind. tsdown's workspace glob (packages/*/*)
# matches directories, not package.json files, so those stale artifacts get built
# as if the package still existed — and fail when their lib references exports
# that upstream has since removed. A directory with lib/ but no package.json is
# such a ghost: safe to delete (git-ignored, regenerable).
function Clear-GhostPackages {
    $ghosts = @()
    foreach ($pattern in @("$RepoRoot\packages\*\*", "$RepoRoot\apps\*")) {
        foreach ($dir in (Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue)) {
            if ((Test-Path (Join-Path $dir.FullName "lib")) -and -not (Test-Path (Join-Path $dir.FullName "package.json"))) {
                $ghosts += $dir.FullName
            }
        }
    }
    if ($ghosts.Count -eq 0) {
        Write-Info "No ghost packages (lib/ without package.json) found."
        return 0
    }
    foreach ($g in $ghosts) {
        if ($DryRun) { Write-Info "  (dry-run: would remove $g)" }
        else {
            Write-Host "    removing ghost: $g" -ForegroundColor DarkGray
            Remove-Item -Recurse -Force $g -ErrorAction SilentlyContinue
        }
    }
    if (-not $DryRun) { Write-Ok "Removed $($ghosts.Count) ghost package dir(s)." }
    return 0
}

# ── Update + rebuild ────────────────────────────────────────────────────────
function Invoke-UpdateAndRebuild {
    Write-Info "Phase 1/4 — syncing upstream..."
    $rc = Invoke-SyncUpstream
    if ($rc -ne 0) { return $rc }

    Write-Info "Phase 2/4 — removing ghost package artifacts (stale lib/ of upstream-deleted packages)..."
    Clear-GhostPackages | Out-Null

    Write-Info "Phase 3/4 — pnpm install..."
    if ($DryRun) { Write-Info "  (dry-run: skipped pnpm install)" }
    else { & pnpm install --frozen-lockfile }

    Write-Info "Phase 4/4 — pnpm run build (full monorepo build)..."
    if ($DryRun) { Write-Info "  (dry-run: skipped pnpm run build)" }
    else { & pnpm run build }

    Write-Ok "Update + rebuild complete. Restart the webui to pick up new artifacts."
    return 0
}

# ── Webui start / stop / restart ─────────────────────────────────────────────

# Kill every node process whose command line looks like a dsh web boot. Used as a
# pre-start cleanup so Start-Webui is idempotent, and as the orphan sweep inside Stop-Webui.
function Stop-OrphanWebuis {
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match 'apps\.cli\.src\.bin\.ts' -or $_.CommandLine -match 'tsx/esm.*apps/cli')
    } | ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        } catch {}
    }
    return $killed
}

function Stop-Webui {
    $proc = Get-WebuiPid
    if ($proc) {
        Write-Info "Stopping webui (pid $($proc.Id))..."
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch {
            Write-Warn "Stop-Process failed: $($_.Exception.Message)"
        }
    } else {
        Write-Info "Webui is not tracked (no live pid file)."
    }
    $orphanCount = Stop-OrphanWebuis
    if ($orphanCount -gt 0) {
        Write-Host "    killed $orphanCount orphan node process(es)" -ForegroundColor DarkGray
    }
    Remove-PidFile
    if ($proc -or $orphanCount -gt 0) { Write-Ok "Stopped." }
    return 0
}

function Start-Webui {
    # Pre-cleanup so Start-Webui is idempotent: any prior webui (tracked or orphan)
    # gets killed before we boot a fresh one. Avoids port-in-use and stale-artifact surprises.
    $existing = Get-WebuiPid
    $orphanCount = 0
    if ($existing) {
        Write-Info "Pre-start cleanup: stopping existing webui (pid $($existing.Id))..."
        try { Stop-Process -Id $existing.Id -Force -ErrorAction Stop } catch {
            Write-Warn "Stop-Process failed: $($_.Exception.Message)"
        }
        $orphanCount = Stop-OrphanWebuis
        Start-Sleep -Seconds 1
    } else {
        $orphanCount = Stop-OrphanWebuis
        if ($orphanCount -gt 0) {
            Write-Info "Pre-start cleanup: killed $orphanCount orphan webui process(es)..."
            Start-Sleep -Seconds 1
        }
    }
    Remove-PidFile

    if (-not (Test-Path (Join-Path $RepoRoot "apps/cli/src/bin.ts"))) {
        Write-ErrorMsg "Cannot find apps/cli/src/bin.ts. Run from the dsh repo root."
        return 1
    }

    Write-Info "Starting dsh web (output -> $StdoutLog, errors -> $StderrLog)..."
    $args = @("--import","tsx/esm","apps/cli/src/bin.ts","web")
    # Forward the script's port into the booted web app so -Port actually moves the listener.
    if ($Port -ne 3080) { $args += @("--port", "$Port") }
    # Don't have dsh web open the system browser on every start — we run it as a daemon.
    $args += "--no-open"
    # Start-Process rejects RedirectStandardOutput == RedirectStandardError, so split them.
    # -WindowStyle Hidden (not -NoNewWindow): the node process gets its own hidden console,
    # so it survives when this pwsh session exits (menu option 0 / terminal close).
    $proc = Start-Process -FilePath "node" -ArgumentList $args -WorkingDirectory $RepoRoot `
                          -WindowStyle Hidden -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog `
                          -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -Encoding ASCII
    Write-Ok "Webui started — pid $($proc.Id), out: $StdoutLog, err: $StderrLog"
    Write-Info "Waiting for port $Port to open (cold start can take 30-60s)..."

    # Cold start loads every cordis bundle, plugin, and frontend dist — empirically
    # 5-15s on a warm tree, longer after a fresh build or with many plugins.
    $ready = $false
    $maxTicks = 120  # 120 * 500ms = 60s
    for ($i = 0; $i -lt $maxTicks; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-PortOpen -TestPort $Port) { $ready = $true; break }
        if ($proc.HasExited) { break }
        if (($i % 10) -eq 0 -and $i -gt 0) {
            Write-Host "    ...still starting ($(([int]($i/2)))s elapsed)" -ForegroundColor DarkGray
        }
    }
    if ($ready) {
        Write-Ok "Port $Port is listening. Open: http://127.0.0.1:$Port/"
    } elseif ($proc.HasExited) {
        Write-ErrorMsg "Process exited before port $Port opened. Tail of log:"
        if (Test-Path $StdoutLog) { Write-Host "── stdout ──" -ForegroundColor DarkGray; Get-Content $StdoutLog -Tail 20 }
        if (Test-Path $StderrLog) { Write-Host "── stderr ──" -ForegroundColor DarkGray; Get-Content $StderrLog -Tail 20 }
        Remove-PidFile
        return 1
    } else {
        Write-Warn "Port $Port not yet open (still starting). Check '$StdoutLog' / '$StderrLog'."
    }
    return 0
}

function Restart-Webui {
    Stop-Webui
    Start-Sleep -Seconds 1
    return Start-Webui
}

function Show-Status {
    Write-Host ""
    Write-Host "── git ─────────────────────────────────────────────" -ForegroundColor DarkGray
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    $dirty  = git status --porcelain --untracked-files=no 2>$null
    Write-Host "  branch : $branch"
    if ($dirty) { Write-Host "  state  : dirty ($(($dirty | Measure-Object).Count) tracked changes)" -ForegroundColor Yellow }
    else { Write-Host "  state  : clean" -ForegroundColor Green }

    $behind = git rev-list --count "HEAD..$UpstreamRemote/$TargetBranch" 2>$null
    $ahead  = git rev-list --count "$UpstreamRemote/$TargetBranch..HEAD" 2>$null
    if ($null -eq $behind) { $behind = 0 }
    if ($null -eq $ahead)  { $ahead  = 0 }
    if ($behind -gt 0) { Write-Host "  remote : $behind commit(s) behind $UpstreamRemote/$TargetBranch" -ForegroundColor Yellow }
    else { Write-Host "  remote : up to date with $UpstreamRemote/$TargetBranch" -ForegroundColor Green }

    Write-Host ""
    Write-Host "── webui ───────────────────────────────────────────" -ForegroundColor DarkGray
    $proc = Get-WebuiPid
    $actualPort = $null
    if ($proc) {
        Write-Host "  pid    : $($proc.Id)" -ForegroundColor Green
        Write-Host "  started: $($proc.StartTime)"
        $actualPort = Find-WebuiPort -WebuiPid $proc.Id
    } else {
        Write-Host "  pid    : (not running)" -ForegroundColor DarkGray
    }
    if ($actualPort) {
        $open = Test-PortOpen -TestPort $actualPort
        if ($open) {
            Write-Host "  port   : $actualPort — LISTENING" -ForegroundColor Green
            Write-Host "  url    : http://127.0.0.1:$actualPort/"
        } else {
            Write-Host "  port   : $actualPort — closed (process exists but socket gone)" -ForegroundColor Yellow
        }
    } elseif ($proc) {
        Write-Host "  port   : (could not detect; assuming -Port $Port)" -ForegroundColor DarkGray
        if (Test-PortOpen -TestPort $Port) { Write-Host "  url    : http://127.0.0.1:$Port/" -ForegroundColor Green }
    } else {
        Write-Host "  port   : $Port — closed" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "── artifacts ──────────────────────────────────────" -ForegroundColor DarkGray
    $cliBin   = Join-Path $RepoRoot "apps/cli/lib/bin.js"
    $webDist  = Join-Path $RepoRoot "apps/web/dist/index.html"
    foreach ($pair in @(@($cliBin, "cli bin"), @($webDist, "web dist"))) {
        if (Test-Path $pair[0]) { Write-Host "  $($pair[1])  : present" -ForegroundColor Green }
        else                    { Write-Host "  $($pair[1])  : MISSING — run option 1 (update + rebuild)" -ForegroundColor Yellow }
    }
}

function Show-Logs {
    $hasOut = Test-Path $StdoutLog
    $hasErr = Test-Path $StderrLog
    if (-not ($hasOut -or $hasErr)) {
        Write-Info "No log files yet (looked for $StdoutLog / $StderrLog)."
        return
    }
    if ($hasOut) {
        Write-Host "── last 30 lines of stdout ($StdoutLog) ──" -ForegroundColor DarkGray
        Get-Content $StdoutLog -Tail 30
    }
    if ($hasErr) {
        Write-Host ""
        Write-Host "── last 30 lines of stderr ($StderrLog) ──" -ForegroundColor DarkGray
        Get-Content $StderrLog -Tail 30
    }
}

function Open-Browser {
    $proc = Get-WebuiPid
    $targetPort = if ($proc) { Find-WebuiPort -WebuiPid $proc.Id } else { $null }
    if (-not $targetPort) { $targetPort = $Port }
    if (-not (Test-PortOpen -TestPort $targetPort)) {
        Write-Warn "Port $targetPort is not open. Start the webui first."
        return 1
    }
    Start-Process "http://127.0.0.1:$targetPort/"
    Write-Ok "Opened http://127.0.0.1:$targetPort/"
    return 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
function Invoke-Action {
    param($Action)
    if (-not $NoClear) { Write-Banner }
    switch ($Action) {
        "sync"    { Invoke-SyncUpstream;     return }
        "update"  { Invoke-UpdateAndRebuild; return }
        "start"   { Start-Webui;             return }
        "stop"    { Stop-Webui;              return }
        "restart" { Restart-Webui;            return }
        "status"  { Show-Status;             return }
        "logs"    { Show-Logs;               return }
        "open"    { Open-Browser;            return }
    }
}

# Re-show the banner at the end of command-line invocations so the running URL
# is visible after start / restart without dropping into the menu loop.
function Show-FinalBanner {
    if ($NoClear) { return }
    Write-Banner
}

if ($Command -ne "") {
    Invoke-Action $Command
    if ($Command -in @("start","restart","stop")) {
        Write-Host ""
        Show-FinalBanner
    }
    exit $LASTEXITCODE
}

# ── Interactive menu ─────────────────────────────────────────────────────────
while ($true) {
    if (-not $NoClear) { Clear-Host }
    Write-Banner
    Write-Host ""
    Write-Host "  0. Exit"                                                       -ForegroundColor DarkGray
    Write-Host "  1. Update + rebuild"               "(sync + clean ghosts + pnpm i + build)" -ForegroundColor White
    Write-Host "  2. Start webui"                    "(background)"             -ForegroundColor White
    Write-Host "  3. Stop webui"                                                -ForegroundColor White
    Write-Host "  4. Restart webui"                   "(stop + start)"          -ForegroundColor White
    Write-Host "  5. Status"                          "(git + webui + artifacts)" -ForegroundColor White
    Write-Host "  6. Logs"                            "(tail .dsh-webui.out.log + .dsh-webui.err.log)" -ForegroundColor DarkGray
    Write-Host "  7. Open in browser"                                           -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Select"

    switch ($choice) {
        "0" { exit 0 }
        "1" { Write-Banner; Invoke-UpdateAndRebuild | Out-Null; Pause-IfInteractive }
        # Auto-return to menu on success; pause only on failure so the error stays visible.
        "2" { Write-Banner; $rc = Start-Webui; if ($rc -ne 0) { Pause-IfInteractive } }
        "3" { Write-Banner; Stop-Webui              | Out-Null; Pause-IfInteractive }
        "4" { Write-Banner; Restart-Webui           | Out-Null; Pause-IfInteractive }
        "5" { Write-Banner; Show-Status             ; Pause-IfInteractive }
        "6" { Write-Banner; Show-Logs               ; Pause-IfInteractive }
        "7" { Write-Banner; Open-Browser    | Out-Null; Pause-IfInteractive }
        default {
            Write-Warn "Unknown selection: '$choice'"
            Start-Sleep -Milliseconds 600
        }
    }
}