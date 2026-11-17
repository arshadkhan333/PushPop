# The background loop. A scheduled task starts it after login and restarts it if it ever stops.
# Every few seconds: is a check due, and is there a waiting popup that can show now?
param([string]$HomeDir, [string]$ConfigPath)
if ($HomeDir) { $env:PUSHPOP_HOME = $HomeDir }
if ($ConfigPath) { $env:PUSHPOP_CONFIG = $ConfigPath }

# Written by hand, before anything that could fail, so a failed start can never be silent.
$logHome = if ($env:PUSHPOP_HOME) { $env:PUSHPOP_HOME } else { Join-Path $PSScriptRoot 'data' }
[void][IO.Directory]::CreateDirectory($logHome)
$logFile = Join-Path $logHome 'log.txt'
Add-Content -Path $logFile -Value "$(Get-Date -Format s) watcher launching (pid $PID)" -ErrorAction SilentlyContinue

try {
    Import-Module "$PSScriptRoot\PushPop.psm1" -DisableNameChecking
    Write-Log 'module loaded'

    # One copy per login. A killed copy leaves the mutex "abandoned", which still counts as ours.
    $mutexName = 'Local\PushPop-' + ((Get-PushPopHome) -replace '[\\:/ ]', '_')
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $owned = try { $mutex.WaitOne(0) } catch { $true }
    if (-not $owned) {
        Write-Log 'another copy is already running, leaving'
        exit 0
    }

    $mePath = Get-HomeFile 'me.txt'
    if (-not (Test-Path $mePath)) {
        Write-Log 'watcher stopped: me.txt is missing, run install.ps1'
        exit 1
    }
    $me = ([IO.File]::ReadAllText($mePath)).Trim()
    Write-Log "watcher started for $me"

    # UTC, so a clock change cannot pause checking for an hour.
    $nextCheck = [datetime]::MinValue
    $nextPopup = [datetime]::MinValue
    $config = $null
    $tick = 5

    while ($true) {
        try {
            # Read every time, so a repo added to config.json works without a restart.
            # A bad edit must not silently stop popups: keep using the last good version.
            try {
                $latest = Read-PushPopConfig
                $problems = @(Test-PushPopConfig $latest)
                if (-not $latest.people.$me) { $problems += "'$me' is not in config.json" }
                if ($problems) { throw ($problems -join '; ') }
                $config = $latest
            } catch {
                if (-not $config) { throw }
                Write-Log "config.json has a problem, using the last good version: $_"
            }
            $tick = [Math]::Min(5, [double]$config.pollSeconds)
            $state = Read-State

            if ([datetime]::UtcNow -ge $nextCheck) {
                foreach ($repo in @($config.repos)) {
                    if (Sync-Repo $repo $state $config $me) { Save-State $state }
                }
                $nextCheck = [datetime]::UtcNow.AddSeconds($config.pollSeconds)
            }

            $waiting = @($state.pending).Count -gt 0
            if ($waiting -and [datetime]::UtcNow -ge $nextPopup -and -not (Test-Paused) -and (Test-UserPresent $config.idleLimitSeconds)) {
                $allShown = $true
                foreach ($popup in @(Get-PopupPlan $state $config $me)) {
                    $result = Show-Popup $popup $config
                    Write-Log "popup: $($popup.caption) (exit $($result.Code))"
                    if ($result.Code -ne 0) {
                        Write-Log "popup failed: $($result.Err)"
                        $allShown = $false
                    }
                }
                if ($allShown) {
                    $state.pending = @()
                    Save-State $state
                } else {
                    $nextPopup = [datetime]::UtcNow.AddMinutes(1)
                }
            }
        } catch {
            # A half-saved config or a brief file lock must never stop the loop.
            Write-Log "watcher error: $_"
        }
        Start-Sleep -Seconds $tick
    }
} finally {
    # Runs on a normal exit and when PowerShell is asked to stop. Only a hard kill skips it.
    Add-Content -Path $logFile -Value "$(Get-Date -Format s) watcher exiting (pid $PID)" -ErrorAction SilentlyContinue
}
