# PushPop core logic. Plain Windows PowerShell 5.1, so there is nothing to install.

$script:ToolRoot = $PSScriptRoot
$script:FieldSeparator = [char]0x1f

Add-Type -Namespace PushPop -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")]
public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
[DllImport("shell32.dll")]
public static extern int SHQueryUserNotificationState(out int state);
'@

# ---------- files and folders ----------

function Get-PushPopHome {
    if ($env:PUSHPOP_HOME) { return $env:PUSHPOP_HOME }
    # Beside the scripts, never in AppData. The Claude app keeps a private copy of AppData, so
    # an install run from inside it was invisible to the watcher Windows starts at login.
    Join-Path $script:ToolRoot 'data'
}

function Get-HomeFile([string]$Name) {
    $dir = Get-PushPopHome
    [void][IO.Directory]::CreateDirectory($dir)
    Join-Path $dir $Name
}

function Get-MirrorPath([string]$Url) {
    $safe = ($Url -replace '^\w+://', '') -replace '[^\w.-]', '_'
    Join-Path (Join-Path (Get-PushPopHome) 'mirrors') $safe
}

function Write-Log([string]$Message) {
    $path = Get-HomeFile 'log.txt'
    # ponytail: restart the log at 1 MB, rotate properly if old logs ever matter
    if ((Test-Path $path) -and (Get-Item $path).Length -gt 1MB) { Remove-Item $path }
    Add-Content -Path $path -Value "$(Get-Date -Format s) $Message"
}

# ---------- config ----------

function Read-PushPopConfig {
    $path = if ($env:PUSHPOP_CONFIG) { $env:PUSHPOP_CONFIG } else { Join-Path $script:ToolRoot 'config.json' }
    [IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
}

function Test-PushPopConfig($Config) {
    $errors = @()
    if (-not (($Config.pollSeconds -as [double]) -ge 1)) { $errors += 'pollSeconds must be 1 or more' }
    # A deleted idleLimitSeconds would read as 0, and popups would silently never show.
    foreach ($key in 'idleLimitSeconds', 'figureHeight', 'showSeconds', 'volume') {
        $value = $Config.$key
        if ($null -eq $value -or -not (($value -as [double]) -ge 0)) { $errors += "$key must be a number" }
    }
    foreach ($person in $Config.people.PSObject.Properties) {
        foreach ($key in 'display', 'figure') {
            if (-not $person.Value.$key) { $errors += "$($person.Name) is missing '$key'" }
        }
    }
    foreach ($repo in @($Config.repos)) {
        if (-not $repo.name) { $errors += "a repo is missing its name: $($repo.url)" }
        if ($repo.url -notmatch '^(https://|file:///)') {
            $errors += "$($repo.name): url must start with https://"
        } elseif ($repo.url -match '^https://[^/]*@') {
            $errors += "$($repo.name): url must not contain a login or token"
        }
    }
    $errors
}

# The fingerprint of an address. config.json stores these, so it can be shared publicly
# without showing anyone's email, yet a commit's email can still be matched.
function Get-EmailHash([string]$Email) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Email.Trim().ToLowerInvariant()))
    'sha256:' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Resolve-Person($Config, [string]$Name, [string]$Email) {
    $people = $Config.people.PSObject.Properties
    if ($Email) {
        $hidden = Get-EmailHash $Email
        foreach ($person in $people) {
            $known = @($person.Value.emails)
            if ($known -contains $Email -or $known -contains $hidden) { return $person.Name }
        }
    }
    foreach ($person in $people) { if (@($person.Value.names) -contains $Name) { return $person.Name } }
    $null
}

# ---------- saved state ----------

function New-EmptyState { @{ heads = @{}; pending = @() } }

function Read-State {
    $path = Get-HomeFile 'state.json'
    $state = New-EmptyState
    if (-not (Test-Path $path)) { return $state }
    # Outside the try: a locked file is a passing problem, not a corrupt one.
    $text = [IO.File]::ReadAllText($path)
    try {
        $json = $text | ConvertFrom-Json -ErrorAction Stop
        foreach ($entry in $json.heads.PSObject.Properties) { $state.heads[$entry.Name] = @($entry.Value) }
        $state.pending = @($json.pending | Where-Object { $_ })
        return $state
    } catch {
        Move-Item -Force $path "$path.bad"
        Write-Log "state file was corrupt, starting fresh: $_"
        return New-EmptyState
    }
}

function Save-State($State) {
    $path = Get-HomeFile 'state.json'
    $temp = "$path.tmp"
    $json = @{ heads = $State.heads; pending = @($State.pending) } | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($temp, $json)
    # Swapped in one step, so a power cut leaves the old file or the new one, never half of each.
    if (Test-Path $path) { [IO.File]::Replace($temp, $path, [NullString]::Value) } else { [IO.File]::Move($temp, $path) }
}

function Add-Pending($State, [string]$Repo, [string]$Person, [int]$Count) {
    $entry = @($State.pending) | Where-Object { $_.repo -eq $Repo -and $_.person -eq $Person } | Select-Object -First 1
    if ($entry) { $entry.count += $Count; return }
    $State.pending = @($State.pending) + [pscustomobject]@{ repo = $Repo; person = $Person; count = $Count }
}

# ---------- what the popup says ----------

function Format-Caption([string]$Who, $Items) {
    $total = 0
    $names = @()
    foreach ($item in @($Items)) { $total += $item.count; $names += $item.repo }
    $where = $names[-1]
    if ($names.Count -gt 1) { $where = ($names[0..($names.Count - 2)] -join ', ') + " and $where" }
    if ($total -eq 1) { return "$Who pushed to $where" }
    "$Who pushed $total commits to $where"
}

function Get-ToolPath([string]$Path) {
    [IO.Path]::GetFullPath([IO.Path]::Combine($script:ToolRoot, $Path))
}

function New-Popup($Config, [string]$Me, [string]$Caption) {
    $mine = $Config.people.$Me
    [pscustomobject]@{
        caption = $Caption
        figure  = Get-ToolPath $mine.figure
        sound   = if ($mine.sound) { Get-ToolPath $mine.sound } else { '' }
        video   = if ($mine.video) { Get-ToolPath $mine.video } else { '' }
    }
}

function Get-PopupPlan($State, $Config, [string]$Me) {
    foreach ($group in @($State.pending) | Group-Object person) {
        $who = $Config.people.($group.Name).display
        if (-not $who) { $who = $group.Name }
        New-Popup $Config $Me (Format-Caption $who $group.Group)
    }
}

# ---------- running other programs ----------

function Invoke-Tool([string]$File, [string[]]$Arguments, [int]$TimeoutSec = 60) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $quoted = foreach ($arg in $Arguments) { '"' + (($arg -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    $info.Arguments = $quoted -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    # Running in the background: fail quietly rather than open a login window.
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $info.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
    try {
        $process = [Diagnostics.Process]::Start($info)
    } catch {
        return [pscustomobject]@{ Code = -1; Out = ''; Err = "could not start ${File}: $_" }
    }
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        & taskkill.exe /T /F /PID $process.Id 2>$null | Out-Null
        return [pscustomobject]@{ Code = -1; Out = ''; Err = "$File timed out after ${TimeoutSec}s" }
    }
    $process.WaitForExit()
    [pscustomobject]@{ Code = $process.ExitCode; Out = $out.Result; Err = $err.Result }
}

function Invoke-Git([string[]]$Arguments, [int]$TimeoutSec = 60) {
    # No background clean-up jobs: they would leave stray processes and could drop old commits.
    Invoke-Tool 'git' (@('-c', 'gc.auto=0', '-c', 'maintenance.auto=false') + $Arguments) $TimeoutSec
}

# ---------- checking a repo ----------

function ConvertTo-Heads([string]$Text) {
    , @($Text -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
}

function Update-Mirror([string]$Url, [string]$Mirror) {
    if (Test-Path $Mirror) {
        $result = Invoke-Git @('-C', $Mirror, 'fetch', '--quiet', '--prune', '--no-tags', 'origin', '+refs/heads/*:refs/heads/*') 120
    } else {
        [void][IO.Directory]::CreateDirectory((Split-Path $Mirror))
        # History only, no file contents: about 100 KB per repo.
        $result = Invoke-Git @('clone', '--quiet', '--bare', '--filter=tree:0', '--no-tags', $Url, $Mirror) 300
    }
    if ($result.Code -eq 0) { return $true }
    Write-Log "mirror update failed for ${Url}: $($result.Err)"
    # Also clears stale locks left by a power cut. It is rebuilt on the next check.
    Remove-Item -Recurse -Force $Mirror -ErrorAction SilentlyContinue
    $false
}

# Returns $true if the remote could be read and the state is up to date.
function Sync-Repo($Repo, $State, $Config, [string]$Me) {
    $url = $Repo.url
    $listing = Invoke-Git @('ls-remote', '--heads', $url) 30
    if ($listing.Code -ne 0) {
        Write-Log "cannot reach ${url}: $($listing.Err)"
        return $false
    }
    $remote = ConvertTo-Heads $listing.Out
    $known = $State.heads.ContainsKey($url)
    $saved = if ($known) { @($State.heads[$url]) } else { @() }
    $mirror = Get-MirrorPath $url
    if ($known -and (Test-Path $mirror) -and (($saved -join ' ') -ceq ($remote -join ' '))) { return $true }

    if (-not (Update-Mirror $url $mirror)) { return $false }
    $refs = Invoke-Git @('-C', $mirror, 'for-each-ref', '--format=%(objectname)', 'refs/heads') 30
    if ($refs.Code -ne 0) { return $false }
    $now = ConvertTo-Heads $refs.Out

    if ($known -and $now.Count) {
        # Everything reachable from the new heads that was not reachable from the saved ones.
        # This is why a commit landing on a second branch is not counted twice.
        $log = Invoke-Git (@('-C', $mirror, 'log', '-n', '500', '--ignore-missing', '--format=%ae%x1f%an') + $now + '--not' + $saved) 30
        if ($log.Code -ne 0) {
            Write-Log "log failed for ${url}: $($log.Err)"
            return $false
        }
        $counts = @{}
        foreach ($line in $log.Out -split "`n" | Where-Object { $_ }) {
            $email, $name = $line.Trim().Split($script:FieldSeparator)
            $person = Resolve-Person $Config $name $email
            if ($person -and $person -ne $Me) { $counts[$person] += 1 }
        }
        foreach ($person in $counts.Keys) { Add-Pending $State $Repo.name $person $counts[$person] }
    }
    $State.heads[$url] = $now
    $true
}

# ---------- is anyone at the screen ----------

function Get-IdleSeconds {
    $info = New-Object PushPop.Native+LASTINPUTINFO
    $info.cbSize = 8
    [void][PushPop.Native]::GetLastInputInfo([ref]$info)
    # Both clocks wrap around, so do the subtraction in unsigned 32-bit space.
    $now = ([int64][Environment]::TickCount) -band 4294967295L
    ((($now - $info.dwTime) + 4294967296L) % 4294967296L) / 1000
}

function Test-UserPresent([double]$IdleLimitSeconds) {
    if ((Get-IdleSeconds) -ge $IdleLimitSeconds) { return $false }
    # Windows' own answer to "can I show something now?". It says no when the
    # screen is locked, the screensaver is on, or something is running full screen.
    $state = 0
    if ([PushPop.Native]::SHQueryUserNotificationState([ref]$state) -ne 0) { return $true }
    $state -in 5, 6, 7
}

# ---------- pause switch ----------

function Test-Paused {
    $file = Get-Item (Get-HomeFile 'paused') -ErrorAction SilentlyContinue
    # A forgotten pause must not silently kill popups forever.
    [bool]($file -and ((Get-Date) - $file.LastWriteTime).TotalHours -lt 2)
}

function Switch-Pause {
    $path = Get-HomeFile 'paused'
    if (Test-Paused) { Remove-Item $path; return $false }
    [IO.File]::WriteAllText($path, '')
    $true
}

# ---------- showing a popup ----------

function Show-Popup($Popup, $Config) {
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (Get-ToolPath 'popup.ps1'),
        '-Caption', $Popup.caption, '-Figure', $Popup.figure, '-Sound', $Popup.sound, '-Video', "$($Popup.video)",
        '-FigureHeight', "$($Config.figureHeight)", '-ShowSeconds', "$($Config.showSeconds)", '-Volume', "$($Config.volume)"
    )
    # Must outlast the longest video popup.ps1 will play, or it would be killed and retried forever.
    Invoke-Tool 'powershell.exe' $arguments 120
}

# ---------- install helpers ----------

# conhost --headless: truly no window. PowerShell's own -WindowStyle Hidden opened terminal
# windows when tested from a scheduled task, and VBScript launchers are being retired.
function Get-HiddenHost { "$env:WINDIR\System32\conhost.exe" }

function Get-HiddenArguments([string]$Script) {
    "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Get-ToolPath $Script)`""
}

function New-HiddenShortcut([string]$Path, [string]$Script, [string]$Description) {
    $link = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $link.TargetPath = Get-HiddenHost
    $link.Arguments = Get-HiddenArguments $Script
    $link.WindowStyle = 7
    $link.Description = $Description
    $link.Save()
}

function Register-PushPopTask([string]$Name, [int]$RepeatMinutes) {
    $arguments = Get-HiddenArguments 'watcher.ps1'
    # A task does not inherit settings from this window, so a test sandbox has to be passed on.
    if ($env:PUSHPOP_HOME) { $arguments += " -HomeDir `"$env:PUSHPOP_HOME`"" }
    if ($env:PUSHPOP_CONFIG) { $arguments += " -ConfigPath `"$env:PUSHPOP_CONFIG`"" }
    $action = New-ScheduledTaskAction -Execute (Get-HiddenHost) -Argument $arguments

    $user = "$env:USERDOMAIN\$env:USERNAME"
    # Shortly after login, so the network has had a moment to come up.
    $afterLogin = New-ScheduledTaskTrigger -AtLogOn -User $user
    $afterLogin.Delay = 'PT30S'
    # And every few minutes, forever. While the watcher runs these do nothing, because of
    # IgnoreNew below. If it ever stops, for any reason, this is what brings it back.
    $always = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes)

    # The defaults would stop it on battery and after 3 days, which is no use on a laptop.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    # Interactive: runs inside your own session, so popups can reach the screen. Needs no admin.
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $afterLogin, $always `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
}

function Stop-RunningWatcher {
    $path = Get-ToolPath 'watcher.ps1'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($path) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function *
