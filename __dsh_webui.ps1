<#
.SYNOPSIS
    dsh webui lifecycle + fork sync manager.

.DESCRIPTION
    Interactive menu to:
      - start / stop / restart the dsh web server in the background,
      - update + rebuild: sync upstream changes into the local fork
        (origin=fork, upstream=deepseek-ai), clean ghosts, install deps, build,
      - permanently delete every dsh session ($DSH_HOME/sessions/**/session-*).

    Status / logs / open-in-browser are not on the menu but stay reachable
    via -Command status | logs | open.

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
    Skip the menu and run one action: sync | update | start | stop | restart | status | logs | open | clean-sessions.

.PARAMETER ReleaseTag
    For -Command update in non-interactive mode, pin a specific dsh-v* tag
    (e.g. dsh-v0.2.0-rc.2). In interactive menu mode, leave empty to show the
    picker.

.EXAMPLE
    .\webui-manager.ps1

.EXAMPLE
    .\webui-manager.ps1 -Command update -ReleaseTag dsh-v0.2.0-rc.2

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
    [ValidateSet("","sync","update","start","stop","restart","status","logs","open","clean-sessions")]
    [string]$Command        = "",
    [switch]$DryRun,
    [switch]$NoClear,
    [string]$ReleaseTag     = ""
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
        if ($isRunning) { $authUrl = Get-WebuiAuthUrl -WebuiPort $runningPort }
        Write-Host "   ·   $RepoRoot" -ForegroundColor DarkGray
        Write-Host "════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray

        # Status line mirrors Start-Webui's "Port N is listening. Open: …" output,
        # so the URL/pid stays visible on every menu render — including the very
        # first one after a double-click launch.
        if ($isRunning) {
            Write-Host "  webui: (" -ForegroundColor DarkGray -NoNewline
            Write-Host "$authUrl" -ForegroundColor Green -NoNewline
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

function Get-WebuiAuthUrl {
    # dsh web prints an authenticated URL (?token=...) to stdout on every boot.
    # Start-Process truncates the log per start, so the LAST match in the log
    # belongs to the currently running process. Fall back to the bare URL when
    # no token line is found (e.g. log rotated or wiped).
    param([int]$WebuiPort)
    $fallback = "http://127.0.0.1:$WebuiPort/"
    if (-not (Test-Path $StdoutLog)) { return $fallback }
    try {
        $hits = Select-String -Path $StdoutLog -Pattern 'http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9._-]+' -AllMatches
        if ($hits) { return $hits[-1].Matches[-1].Value }
    } catch {}
    return $fallback
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

# ── Stable release picker ────────────────────────────────────────────────────
# Upstream has no true stable tags yet — only dsh-v*-alpha.* and dsh-v*-rc.*.
# Treat -rc.* as the "stable" surface (closest-to-shipped); filter out -alpha.
function Get-StableReleaseTags {
    param([string]$Remote = $UpstreamRemote)
    $raw = git ls-remote --tags $Remote 2>$null
    if (-not $raw) { return @() }
    $tags = @()
    foreach ($line in $raw) {
        # Strip peeled-tag refs (^{}); keep only dsh-v* that are NOT alpha.
        if ($line -match '\s+refs/tags/(dsh-v\S+?)(?:\^\{\})?$') {
            $name = $Matches[1]
            if ($name -notmatch '-alpha\.') { $tags += $name }
        }
    }
    # Sort descending by base version, then by rc.N as tiebreaker.
    $sorted = $tags | Sort-Object @{Expression={
        if ($_ -match 'dsh-v(\d+)\.(\d+)\.(\d+)') {
            [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
        } else { [version]'0.0.0' }
    }}, @{Expression={
        if ($_ -match '-rc\.(\d+)') { [int]$Matches[1] } else { 0 }
    }} -Descending
    return ,@($sorted)
}

function Get-TagOneLine {
    # One-line "YYYY-MM-DD  subject" for a tag that exists locally (post fetch --tags).
    param([string]$Tag)
    $sha = git rev-list -n 1 $Tag 2>$null
    if (-not $sha) { return "(unknown)" }
    $info = git log -1 --format='%ci %s' $sha 2>$null
    if (-not $info) { return "(unknown)" }
    # %ci = "YYYY-MM-DD HH:MM:SS ±HHMM". Keep just the date + subject.
    if ($info -match '^(\d{4}-\d{2}-\d{2})\s+\S+\s+\S+\s+(.*)$') {
        return ("{0}  {1}" -f $Matches[1], $Matches[2])
    }
    return $info
}

function Select-StableRelease {
    # The picker opens right after "Phase 1/4 — fetching upstream tags..." in
    # the menu flow, which has already printed the banner + several info lines.
    # Clear before the list so the choice rows sit alone on a clean screen.
    if (-not $NoClear) { Clear-Host }
    $tags = Get-StableReleaseTags
    if (-not $tags -or $tags.Count -eq 0) {
        Write-ErrorMsg "No stable (non-alpha) release tags found on $UpstreamRemote."
        return $null
    }
    $currentHead = (git rev-parse HEAD 2>$null).Trim()
    $maxWidth = 89
    # "Current" = the most recent stable (non-alpha) dsh-v* tag reachable from HEAD.
    # Resolves the version the local tree is on, even when HEAD sits past a tag.
    $currentTag = $null
    $merged = @(git tag --merged HEAD 2>$null)
    $stableMerged = @($merged | Where-Object { $_ -match '^dsh-v' -and $_ -notmatch '-alpha\.' })
    if ($stableMerged.Count -gt 0) {
        $currentTag = ($stableMerged | Sort-Object @{Expression={
                    if ($_ -match 'dsh-v(\d+)\.(\d+)\.(\d+)') { [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])") } else { [version]'0.0.0' }
                }}, @{Expression={
                    if ($_ -match '-rc\.(\d+)') { [int]$Matches[1] } else { 0 }
                }} -Descending)[0]
    }
    $headerSuffix = if ($currentTag) { "(current: $currentTag)" } else { "(newest first)" }
    Write-Host ""
    Write-Host "  Available stable releases ${headerSuffix}:" -ForegroundColor White
    for ($i = 0; $i -lt $tags.Count; $i++) {
        $tag    = $tags[$i]
        $desc   = Get-TagOneLine -Tag $tag
        $tagSha = (git rev-list -n 1 $tag 2>$null).Trim()
        $isCur  = ($tagSha -and $currentHead -and ($tagSha -eq $currentHead))
        $marker = if ($isCur) { "  [current]" } else { "" }
        $color  = if ($isCur) { "Green" } else { "Gray" }
        # One row = prefix + description + marker, hard-capped at $maxWidth
        # columns; overflow in the description becomes "...".
        $prefix  = "  {0,2}.  {1,-22}  " -f ($i + 1), $tag
        $budget  = $maxWidth - $prefix.Length - $marker.Length
        if ($budget -gt 3 -and $desc.Length -gt $budget) {
            $desc = $desc.Substring(0, $budget - 3) + "..."
        }
        Write-Host ($prefix + $desc + $marker) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "   0.  Cancel" -ForegroundColor DarkGray
    Write-Host ""
    $defaultIdx = "1"
    $raw = Read-Host "  Select [$defaultIdx]"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultIdx }
    if ($raw -eq "0") { return $null }
    $idx = 0
    if (-not [int]::TryParse($raw, [ref]$idx)) {
        Write-ErrorMsg "Invalid selection: '$raw'"
        return $null
    }
    if ($idx -lt 1 -or $idx -gt $tags.Count) {
        Write-ErrorMsg "Out of range: $idx"
        return $null
    }
    return $tags[$idx - 1]
}

# ── Reset local master to a chosen ref ───────────────────────────────────────
# Moves $TargetBranch to $Ref WITHOUT switching branches whenever possible:
# `git update-ref` rewrites the branch pointer without touching the worktree,
# so a dirty worktree file (e.g. the script itself, open in an editor) can
# never abort the move the way `git checkout` can. A real `git reset --hard`
# only happens when the user is sitting ON $TargetBranch.
function Reset-MasterToRef {
    param([string]$Ref)
    # Peel annotated tags to their commit — a raw tag-object SHA would make the
    # branch point at the tag object instead of a commit.
    $tagSha = (git rev-parse "$Ref`^{commit}" 2>$null)
    if (-not $tagSha) {
        Write-ErrorMsg "Ref '$Ref' not found locally. Did 'git fetch --tags' run?"
        return 1
    }
    $tagSha = $tagSha.Trim()

    # Ensure local $TargetBranch exists (create tracking upstream if missing).
    $localExists = $true
    try { $null = git show-ref --verify --quiet "refs/heads/$TargetBranch" 2>$null; if ($LASTEXITCODE -ne 0) { $localExists = $false } } catch { $localExists = $false }
    if (-not $localExists) {
        Write-Info "Creating local $TargetBranch from $UpstreamRemote/$TargetBranch..."
        git branch $TargetBranch "$UpstreamRemote/$TargetBranch" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "Failed to create local $TargetBranch."
            return 1
        }
    }

    $currentBranch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
    $oldTip = (git rev-parse $TargetBranch 2>$null).Trim()

    if ($tagSha -ne $oldTip) {
        # git merge-base --is-ancestor returns 0/1 by semantics, not success.
        git merge-base --is-ancestor $tagSha $oldTip 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Warn "Selected ref is older than current $TargetBranch tip — moving $TargetBranch backwards (downgrade)."
        } else {
            git merge-base --is-ancestor $oldTip $tagSha 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Selected ref is on a different line — moving $TargetBranch anyway."
            }
        }
        if ($currentBranch -eq $TargetBranch) {
            # Sitting on the branch: reset --hard moves it and the worktree.
            git reset --hard $tagSha | Out-Null
        } else {
            # On another branch: move the ref directly, worktree untouched.
            git update-ref "refs/heads/$TargetBranch" $tagSha | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorMsg "Failed to move $TargetBranch to $Ref."
            return 1
        }
        $short = $tagSha.Substring(0, [Math]::Min(7, $tagSha.Length))
        Write-Ok "$TargetBranch is now at $Ref ($short)."
    } else {
        Write-Info "$TargetBranch is already at $Ref."
    }

    # Push unconditionally — even on "already at": an earlier run may have moved
    # master locally but died before pushing. --force-with-lease because a reset
    # can move master backwards (plain push would be rejected), and -with-lease
    # still refuses if the fork moved under us between fetch and push. The lease
    # compares against our remote-tracking ref for origin/master, so refresh it
    # first — otherwise a stale tracking ref makes the lease refuse forever.
    Write-Info "Pushing $TargetBranch to $OriginRemote (--force-with-lease)..."
    git fetch $OriginRemote $TargetBranch 2>$null | Out-Null
    git push --force-with-lease $OriginRemote $TargetBranch
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMsg "Push to $OriginRemote/$TargetBranch failed (exit $LASTEXITCODE). Local $TargetBranch is at $Ref — re-run to retry the push."
        return 1
    }
    return 0
}

# ── Update + rebuild ────────────────────────────────────────────────────────
function Invoke-UpdateAndRebuild {
    $originalBranch = (git rev-parse --abbrev-ref HEAD 2>$null).Trim()
    # Capture the local master tip BEFORE the reset — the rebase later needs it
    # as --onto base so only the user's own commits (not upstream release
    # commits) get replayed onto the new master.
    $oldTip = (git rev-parse --verify --quiet "$TargetBranch" 2>$null)
    if ($oldTip) { $oldTip = $oldTip.Trim() }

    # Stash helper: rebase (and reset --hard when sitting on master) require a
    # clean worktree. Stash up front only in those cases — moving master via
    # update-ref touches no worktree file, so a dirty tree must never block it.
    # NOTE: $script:stashed (not a function-local) — nested functions in pwsh
    # are dynamically scoped, and a local here would shadow the script-scope
    # variable the helpers read and write.
    $script:stashed = $false
    function Test-WorktreeDirty {
        return [bool]((git status --porcelain --untracked-files=no 2>$null | Out-String).Trim())
    }
    function Push-StashIfDirty {
        param([string]$Reason)
        if (-not (Test-WorktreeDirty)) { return }
        $msg = "update-and-rebuild: auto stash $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ($Reason)"
        Write-Warn "Worktree dirty — stashing changes ($Reason)..."
        if (-not $DryRun) { git stash push -m $msg | Out-Null; $script:stashed = $true }
    }
    function Pop-StashIfAny {
        if (-not $script:stashed) { return }
        Write-Info "Restoring stashed changes..."
        git stash pop | Out-Null
        if ($LASTEXITCODE -eq 0) { $script:stashed = $false }
        else { Write-Warn "stash pop reported conflicts — resolve manually (git stash list / pop)." }
    }

    try {
        Write-Info "Phase 1/4 — fetching $UpstreamRemote tags..."
        if (-not $DryRun) {
            git fetch $UpstreamRemote --tags
            if ($LASTEXITCODE -ne 0) {
                Write-ErrorMsg "git fetch --tags failed (exit $LASTEXITCODE)."
                return $LASTEXITCODE
            }
        }

        # Resolve target tag: explicit -ReleaseTag wins, else show picker, else dry-run picks highest.
        $selectedTag = $ReleaseTag
        if (-not $selectedTag -and -not $DryRun) {
            $selectedTag = Select-StableRelease
            if (-not $selectedTag) {
                Write-Warn "Update cancelled."
                return 1
            }
        } elseif (-not $selectedTag -and $DryRun) {
            $all = Get-StableReleaseTags
            $selectedTag = if ($all.Count -gt 0) { $all[0] } else { "" }
            if ($selectedTag) { Write-Info "  (dry-run: picker skipped, would use $selectedTag)" }
        }
        if (-not $selectedTag) {
            Write-ErrorMsg "No stable release tag resolved."
            return 1
        }

        Write-Info "Phase 2/4 — moving $TargetBranch to $selectedTag, pushing, rebasing back..."
        if (-not $DryRun) {
            # reset --hard (only used when sitting on master) destroys dirty
            # worktree changes — protect them first.
            if ($originalBranch -eq $TargetBranch) { Push-StashIfDirty "reset on $TargetBranch" }

            $rc = Reset-MasterToRef -Ref $selectedTag
            if ($rc -ne 0) { return $rc }

            if ($originalBranch -eq $TargetBranch) {
                Pop-StashIfAny
            } elseif ($originalBranch -and $originalBranch -ne "HEAD" -and $oldTip) {
                # Replay the current branch's own commits onto the new master.
                # Stay on the current branch the whole time — no checkouts, so
                # a dirty worktree can never abort a branch switch. Do NOT use
                # plain `git rebase master`: on downgrade the branch still
                # contains the newer release commits, and a plain rebase would
                # replay those onto the older tag. --onto with the pre-reset
                # tip replays only the user's own commits.
                Write-Info "Rebasing $originalBranch onto $TargetBranch (--onto base $($oldTip.Substring(0,[Math]::Min(7,$oldTip.Length))))..."
                Push-StashIfDirty "rebase $originalBranch"
                git rebase --onto $TargetBranch $oldTip
                if ($LASTEXITCODE -ne 0) {
                    Write-ErrorMsg "Rebase conflict on $originalBranch. Resolve, then: git rebase --continue  (and git stash pop if changes were stashed)."
                    return 2
                }
                Pop-StashIfAny
            } elseif ($originalBranch -eq "HEAD") {
                Write-Info "Detached HEAD — skipping rebase; checked-out commit unchanged."
            }
        } else {
            Write-Info "  (dry-run: would move $TargetBranch to $selectedTag, push, rebase $originalBranch back)"
        }

        Write-Info "Phase 3/4 — removing ghost package artifacts..."
        if (-not $DryRun) { Clear-GhostPackages | Out-Null }

        Write-Info "Phase 4/4 — pnpm install + pnpm run build..."
        if ($DryRun) {
            Write-Info "  (dry-run: skipped pnpm install / build)"
        } else {
            # A node_modules that predates the just-merged lockfile makes pnpm want
            # to purge-and-reinstall, which it only does after an interactive TTY
            # confirmation. Nobody is there to answer during a menu run: pnpm then
            # aborts with ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY and leaves
            # node_modules half-stale (the classic "Cannot find package 'semver'"
            # crash on the next webui boot). Answer programmatically.
            & pnpm install --frozen-lockfile --config.confirmModulesPurge=false
            if ($LASTEXITCODE -ne 0) {
                Write-ErrorMsg "pnpm install failed (exit $LASTEXITCODE). Fix the error above, then re-run option 4."
                return $LASTEXITCODE
            }
            # Native command failures don't honor $ErrorActionPreference = "Stop",
            # so an exit code must be checked explicitly — otherwise a failed build
            # still prints "Update + rebuild complete." downstream.
            & pnpm run build
            if ($LASTEXITCODE -ne 0) {
                Write-ErrorMsg "pnpm run build failed (exit $LASTEXITCODE). Fix the error above, then re-run option 4."
                return $LASTEXITCODE
            }
        }

        Write-Ok "Update + rebuild complete at $selectedTag. Restart the webui to pick up new artifacts."
        return 0
    } finally {
        # If a stash is still held at this point (rebase conflict path), leave
        # it for the user and say so (mirrors Invoke-SyncUpstream's behaviour).
        if ($script:stashed -and -not $DryRun) {
            $stillStashed = (git stash list 2>$null | Out-String).Trim()
            if ($stillStashed -and ($LASTEXITCODE -ne 0)) {
                Write-Warn "A stash is still present — run 'git stash list' to inspect, 'git stash pop' to restore."
            }
        }
    }
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
        $authUrl = Get-WebuiAuthUrl -WebuiPort $Port
        Write-Ok "Port $Port is listening. Open: $authUrl"
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
            Write-Host "  url    : $(Get-WebuiAuthUrl -WebuiPort $actualPort)"
        } else {
            Write-Host "  port   : $actualPort — closed (process exists but socket gone)" -ForegroundColor Yellow
        }
    } elseif ($proc) {
        Write-Host "  port   : (could not detect; assuming -Port $Port)" -ForegroundColor DarkGray
        if (Test-PortOpen -TestPort $Port) { Write-Host "  url    : $(Get-WebuiAuthUrl -WebuiPort $Port)" -ForegroundColor Green }
    } else {
        Write-Host "  port   : $Port — closed" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "── artifacts ──────────────────────────────────────" -ForegroundColor DarkGray
    $cliBin   = Join-Path $RepoRoot "apps/cli/lib/bin.js"
    $webDist  = Join-Path $RepoRoot "apps/web/dist/index.html"
    foreach ($pair in @(@($cliBin, "cli bin"), @($webDist, "web dist"))) {
        if (Test-Path $pair[0]) { Write-Host "  $($pair[1])  : present" -ForegroundColor Green }
        else                    { Write-Host "  $($pair[1])  : MISSING — run option 4 (update + rebuild)" -ForegroundColor Yellow }
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
    $authUrl = Get-WebuiAuthUrl -WebuiPort $targetPort
    if ($authUrl -notmatch '\?token=') {
        Write-Warn "No ?token= URL found in $StdoutLog — the bare URL will fail auth."
    }
    Start-Process $authUrl
    Write-Ok "Opened $authUrl"
    return 0
}

# ── Session cleanup ────────────────────────────────────────────────────────────
# A dsh Session is one directory: $DSH_HOME/sessions/<workspace-slug>/session-<uuid>/.
# The host has no batch-delete API, and "archive" only hides a session, so a real
# cleanup removes those directories on disk. Deleting while the webui holds a
# session open risks tearing a file mid-write — Stop-Webui runs first.
function Get-DshSessionsRoot {
    $dshHome = $env:DSH_HOME
    if (-not $dshHome) { $dshHome = Join-Path $HOME ".dsh" }
    return Join-Path $dshHome "sessions"
}

function Remove-AllSessions {
    $root = Get-DshSessionsRoot
    if (-not (Test-Path $root)) {
        Write-Info "No sessions directory at $root — nothing to delete."
        return 0
    }
    # Piped into Remove-Item later: pipeline binding sidesteps PowerShell parsing
    # workspace-slug names like "--E-__work--" as switch tokens.
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Filter "session-*" -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 0) {
        Write-Info "No sessions found under $root."
        return 0
    }

    $totalBytes = 0
    foreach ($d in $dirs) {
        $sum = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($sum) { $totalBytes += $sum }
    }
    $sizeMB = [Math]::Round($totalBytes / 1MB, 1)

    Write-Host ""
    Write-Warn "This permanently deletes ALL dsh sessions (every workspace):"
    foreach ($group in ($dirs | Group-Object { $_.Parent.Name } | Sort-Object Name)) {
        Write-Host "    $($group.Name): $($group.Count) session(s)" -ForegroundColor DarkGray
    }
    Write-Host "    ── total: $($dirs.Count) session(s), ~$sizeMB MB" -ForegroundColor DarkGray

    if ($DryRun) {
        Write-Info "(dry-run: nothing deleted)"
        return 0
    }
    Write-Host ""
    $answer = Read-Host "  Type 'yes' to confirm permanent deletion"
    if ($answer -ne "yes") {
        Write-Warn "Cancelled — no sessions deleted."
        return 1
    }

    $proc = Get-WebuiPid
    if ($proc) {
        Write-Warn "Webui is running (pid $($proc.Id)) — stopping it first so no session is mid-write..."
        Stop-Webui | Out-Null
    }

    $dirs | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $left = @(Get-ChildItem -LiteralPath $root -Directory -Recurse -Filter "session-*" -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        Write-Ok "Deleted $($dirs.Count) session(s), freed ~$sizeMB MB."
        Write-Info "Restart the webui (menu option 1) — the session list rescans from disk."
    } else {
        Write-Warn "$($left.Count) session dir(s) resisted deletion — check permissions under $root."
        return 1
    }
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
        "clean-sessions" { Remove-AllSessions; return }
    }
}

# Re-show the banner at the end of command-line invocations so the running URL
# is visible after start / restart without dropping into the menu loop.
function Show-FinalBanner {
    if ($NoClear) { return }
    Write-Banner
}

if ($Command -eq "update" -and -not $ReleaseTag) {
    Write-ErrorMsg "Non-interactive 'update' requires -ReleaseTag (e.g. -ReleaseTag dsh-v0.2.0-rc.2). Run without -Command for an interactive picker."
    exit 1
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
    Write-Host "  1. Start webui"     "(background)" -ForegroundColor White
    Write-Host "  2. Stop webui"                     -ForegroundColor White
    Write-Host "  3. Restart webui"   "(stop + start)" -ForegroundColor White
    Write-Host "  4. Update + rebuild" "(sync + clean ghosts + pnpm i + build)" -ForegroundColor White
    Write-Host "  5. Delete ALL sessions" "(permanent, every workspace)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  0. Exit"                           -ForegroundColor DarkGray
    Write-Host ""
    $choice = Read-Host "  Select"

    switch ($choice) {
        # Auto-return to menu on success; pause only on failure so the error stays visible.
        "1" { Write-Banner; $rc = Start-Webui; if ($rc -ne 0) { Pause-IfInteractive } }
        "2" { Write-Banner; Stop-Webui              | Out-Null; Pause-IfInteractive }
        "3" { Write-Banner; Restart-Webui           | Out-Null; Pause-IfInteractive }
        "4" { Write-Banner; Invoke-UpdateAndRebuild | Out-Null; Pause-IfInteractive }
        "5" { Write-Banner; Remove-AllSessions      | Out-Null; Pause-IfInteractive }
        "0" { exit 0 }
        default {
            Write-Warn "Unknown selection: '$choice'"
            Start-Sleep -Milliseconds 600
        }
    }
}