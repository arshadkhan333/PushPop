# End-to-end: install, the real scheduled task, pause and uninstall.
# Each test uses its own throwaway task name, and temp folders stand in for Startup and Desktop.
. "$PSScriptRoot\_harness.ps1"
. "$PSScriptRoot\_windows.ps1"
Import-Module "$PSScriptRoot\..\PushPop.psm1" -Force -DisableNameChecking

$tool = Split-Path $PSScriptRoot

function Start-Case {
    $sb = New-Sandbox
    Push-As $sb 'arshad'
    Write-TestConfig $sb
    $startup = Join-Path $sb.Root 'Startup'
    $desktop = Join-Path $sb.Root 'Desktop'
    New-Item -ItemType Directory -Path $startup, $desktop | Out-Null
    $task = 'PushPopTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    [pscustomobject]@{ Sb = $sb; Startup = $startup; Desktop = $desktop; Task = $task }
}

function Invoke-Script([string]$Name, [string[]]$Arguments) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tool $Name)) + $Arguments
    Invoke-Tool 'powershell.exe' $all 120
}

function Install-Case($Case, [string]$Me = 'arshad', [int]$RepeatMinutes = 5) {
    Invoke-Script 'install.ps1' @(
        '-Me', $Me, '-TaskName', $Case.Task, '-RepeatMinutes', "$RepeatMinutes",
        '-StartupDir', $Case.Startup, '-DesktopDir', $Case.Desktop, '-Quiet'
    )
}

function Uninstall-Case($Case) {
    Invoke-Script 'uninstall.ps1' @('-TaskName', $Case.Task, '-StartupDir', $Case.Startup, '-DesktopDir', $Case.Desktop) | Out-Null
}

function End-Case($Case) {
    Stop-ScheduledTask -TaskName $Case.Task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Case.Task -Confirm:$false -ErrorAction SilentlyContinue
    Stop-RunningWatcher
    Remove-Sandbox $Case.Sb
    Remove-Item Env:\PUSHPOP_CONFIG -ErrorAction SilentlyContinue
}

function Get-WatcherProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains("$tool\watcher.ps1") }
}

function Get-Task($Case) { Get-ScheduledTask -TaskName $Case.Task -ErrorAction SilentlyContinue }

Write-Host 'Install'
Test 'saves who this PC belongs to, the scheduled task and the pause shortcut' {
    $c = Start-Case
    $r = Install-Case $c 'Aamir'
    Assert-Equal 0 $r.Code "exit code, output: $($r.Out) $($r.Err)"
    Assert-Equal 'aamir' ([IO.File]::ReadAllText((Join-Path $env:PUSHPOP_HOME 'me.txt'))) 'name saved in config spelling'
    Assert-True (Get-Task $c) 'scheduled task exists'
    Assert-True (Test-Path (Join-Path $c.Desktop 'PushPop pause.lnk')) 'pause shortcut'
    End-Case $c
}
Test 'only says it is running after the watcher confirms it really started' {
    $c = Start-Case
    $r = Install-Case $c
    Assert-True ($r.Out -match 'confirmed running') "says confirmed, output: $($r.Out)"
    Assert-True ((Get-Content -Raw (Join-Path $env:PUSHPOP_HOME 'log.txt')) -match 'watcher started for arshad') 'and it really had'
    End-Case $c
}
Test 'says so loudly if the watcher does not start' {
    $c = Start-Case
    $r = Invoke-Script 'install.ps1' @(
        '-Me', 'arshad', '-TaskName', $c.Task, '-StartupDir', $c.Startup, '-DesktopDir', $c.Desktop, '-Quiet', '-StartWaitSeconds', '0'
    )
    Assert-True ($r.Code -ne 0) "install reports failure, exit code $($r.Code)"
    Assert-True ($r.Out -match 'FAIL' -and $r.Out -notmatch 'confirmed running') "output: $($r.Out)"
    End-Case $c
}
Test 'upgrading removes the old startup shortcut' {
    $c = Start-Case
    $old = Join-Path $c.Startup 'PushPop.lnk'
    Set-Content $old 'old shortcut'
    Install-Case $c | Out-Null
    Assert-True (-not (Test-Path $old)) 'old shortcut gone'
    End-Case $c
}
Test 'old commits never cause a popup after installing' {
    $c = Start-Case
    Install-Case $c | Out-Null
    Assert-True ((Read-State).heads.ContainsKey($c.Sb.Url)) 'repo saved during install'
    Assert-Equal 0 @((Read-State).pending).Count 'pending'
    End-Case $c
}
Test 'an unknown name is refused and nothing is installed' {
    $c = Start-Case
    $r = Install-Case $c 'nobody'
    Assert-True ($r.Code -ne 0) 'install failed'
    Assert-True ($r.Out -match 'arshad' -and $r.Out -match 'aamir') "lists the valid names, output: $($r.Out)"
    Assert-True (-not (Get-Task $c)) 'no task made'
    End-Case $c
}
Test 'a repo it cannot read is named clearly, and install still finishes' {
    $c = Start-Case
    $config = Get-Content -Raw $env:PUSHPOP_CONFIG | ConvertFrom-Json
    $config.repos = @($config.repos) + [pscustomobject]@{ name = 'NoAccess'; url = 'file:///C:/does/not/exist.git' }
    [IO.File]::WriteAllText($env:PUSHPOP_CONFIG, ($config | ConvertTo-Json -Depth 6))
    $r = Install-Case $c
    Assert-Equal 0 $r.Code 'exit code'
    Assert-True ($r.Out -match 'NoAccess' -and $r.Out -match 'git ls-remote') "explains the fix, output: $($r.Out)"
    End-Case $c
}
Test 'installing twice leaves one watcher running' {
    $c = Start-Case
    Install-Case $c | Out-Null
    Install-Case $c | Out-Null
    Wait-Until { @(Get-WatcherProcess).Count -eq 1 } 15 'exactly one watcher'
    Start-Sleep -Seconds 2
    Assert-Equal 1 @(Get-WatcherProcess).Count 'watchers'
    End-Case $c
}
Test 'a normal install ends with a welcome popup, worded correctly for one repo' {
    $c = Start-Case
    $script = Join-Path $tool 'install.ps1'
    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-Me', 'arshad', '-TaskName', $c.Task,
        '-StartupDir', "`"$($c.Startup)`"", '-DesktopDir', "`"$($c.Desktop)`""
    )
    Assert-Popup 'PushPop is watching 1 repo' 40
    Assert-True ($process.WaitForExit(30000)) 'install finished'
    End-Case $c
}

Write-Host 'The scheduled task'
Test 'is safe for a laptop: runs on battery, never times out, never doubles up' {
    $c = Start-Case
    Install-Case $c | Out-Null
    $settings = (Get-Task $c).Settings
    Assert-Equal 'False' $settings.DisallowStartIfOnBatteries 'may start on battery'
    Assert-Equal 'False' $settings.StopIfGoingOnBatteries 'keeps running on battery'
    Assert-Equal 'PT0S' $settings.ExecutionTimeLimit 'no time limit'
    Assert-Equal 'IgnoreNew' $settings.MultipleInstances 'one at a time'
    End-Case $c
}
Test 'starts after login, then checks every 5 minutes with no end date' {
    $c = Start-Case
    Install-Case $c | Out-Null
    $triggers = @((Get-Task $c).Triggers)
    $login = @($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
    $timer = @($triggers | Where-Object { $_.Repetition.Interval })
    Assert-Equal 1 $login.Count 'login triggers'
    Assert-Equal 'PT30S' $login[0].Delay 'wait after login'
    Assert-True ($login[0].UserId -match [regex]::Escape($env:USERNAME)) "only for this user, got $($login[0].UserId)"
    Assert-Equal 1 $timer.Count 'repeating triggers'
    Assert-Equal 'PT5M' $timer[0].Repetition.Interval 'how often'
    Assert-True (-not $timer[0].Repetition.Duration) "no end date, got [$($timer[0].Repetition.Duration)]"
    End-Case $c
}
Test 'starts the watcher with no visible window, and a push then pops up' {
    $c = Start-Case
    Install-Case $c | Out-Null
    Stop-ScheduledTask -TaskName $c.Task
    Stop-RunningWatcher
    Wait-Until { @(Get-WatcherProcess).Count -eq 0 } 15 'watcher stopped'
    $terminals = @(Get-Process WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue).Count
    Start-ScheduledTask -TaskName $c.Task
    Wait-Until { @(Get-WatcherProcess).Count -eq 1 } 15 'watcher started by the task'
    $process = Get-Process -Id @(Get-WatcherProcess)[0].ProcessId
    Assert-Equal 0 $process.MainWindowHandle 'watcher window handle'
    Assert-Equal $terminals @(Get-Process WindowsTerminal, OpenConsole -ErrorAction SilentlyContinue).Count 'terminal processes'
    Push-As $c.Sb 'aamir'
    Assert-Popup 'Aamir pushed to G'
    End-Case $c
}
Test 'the watcher dies, Aamir pushes: it comes back by itself and shows what was missed' {
    $c = Start-Case
    $r = Install-Case $c 'arshad' 1
    Assert-Equal 0 $r.Code "install exit code, output: $($r.Out)"
    try {
        Wait-Until { @(Get-WatcherProcess).Count -eq 1 } 15 'watcher running'
    } catch {
        $found = @(Get-WatcherProcess | ForEach-Object { "pid $($_.ProcessId) from $($_.CreationDate.ToString('HH:mm:ss')): $($_.CommandLine)" })
        throw "expected 1 watcher, found $($found.Count): $($found -join ' || ')"
    }
    # Only the PowerShell process, exactly as when something shut the real one down at login.
    foreach ($p in @(Get-WatcherProcess)) { Stop-Process -Id $p.ProcessId -Force }
    Wait-Until { @(Get-WatcherProcess).Count -eq 0 } 15 'watcher really dead'
    Push-As $c.Sb 'aamir' 3
    # Nothing here starts it. Windows has to bring it back on its own.
    Assert-Popup 'Aamir pushed 3 commits to G' 150
    End-Case $c
}

Test 'started by Windows with no test settings, it finds what install saved' {
    # The bug this guards: install ran inside the Claude app, whose writes to AppData go to a
    # private copy. Windows then started the watcher outside the app, it found no me.txt, and
    # it quit. Every other test passes a home folder, which hid this. So: a real copy of the
    # tool, real defaults, no settings passed in, and Task Scheduler doing the starting.
    $c = Start-Case
    $copy = Join-Path $c.Sb.Root 'tool copy'
    New-Item -ItemType Directory -Path $copy | Out-Null
    Get-ChildItem $tool -Force | Where-Object { $_.Name -ne 'data' -and $_.Extension -ne '.zip' } |
        Copy-Item -Destination $copy -Recurse
    Copy-Item $env:PUSHPOP_CONFIG (Join-Path $copy 'config.json') -Force
    Remove-Item Env:\PUSHPOP_HOME, Env:\PUSHPOP_CONFIG
    try {
        $r = Invoke-Tool 'powershell.exe' @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $copy 'install.ps1'), '-Me', 'arshad',
            '-TaskName', $c.Task, '-StartupDir', $c.Startup, '-DesktopDir', $c.Desktop, '-Quiet'
        ) 120
        Assert-Equal 0 $r.Code "install exit code, output: $($r.Out) $($r.Err)"
        $log = Join-Path $copy 'data\log.txt'
        Wait-Until { (Get-Content -Raw $log) -match 'watcher started for arshad' } 25 'watcher started, reading the data install saved'
        $env:PUSHPOP_HOME = Join-Path $copy 'data'
        Push-As $c.Sb 'aamir'
        Assert-Popup 'Aamir pushed to G'
    } finally {
        $env:PUSHPOP_HOME = Join-Path $copy 'data'
        Stop-ScheduledTask -TaskName $c.Task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $c.Task -Confirm:$false -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($copy) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 500
        Remove-Sandbox $c.Sb
    }
}

Write-Host 'Pause shortcut'
Test 'it switches pause on with a message, then off with a message' {
    $c = Start-Case
    Install-Case $c | Out-Null
    $link = Join-Path $c.Desktop 'PushPop pause.lnk'
    Start-Process $link
    Assert-Popup 'PushPop paused for up to 2 hours'
    Assert-True (Test-Paused) 'paused'
    Wait-Until { [PushPopTest.Win]::FindWindow([NullString]::Value, 'PushPop: PushPop paused for up to 2 hours') -eq [IntPtr]::Zero } 15 'message closed'
    Start-Process $link
    Assert-Popup 'PushPop is back on'
    Assert-True (-not (Test-Paused)) 'resumed'
    End-Case $c
}

Write-Host 'Uninstall'
Test 'it stops the watcher and removes everything it made' {
    $c = Start-Case
    Install-Case $c | Out-Null
    $homeDir = $env:PUSHPOP_HOME
    Uninstall-Case $c
    Wait-Until { @(Get-WatcherProcess).Count -eq 0 } 15 'watcher stopped'
    Assert-True (-not (Get-Task $c)) 'task gone'
    Assert-True (-not (Test-Path (Join-Path $c.Desktop 'PushPop pause.lnk'))) 'pause shortcut gone'
    Assert-True (-not (Test-Path $homeDir)) 'data folder gone'
    End-Case $c
}

Complete-Tests
