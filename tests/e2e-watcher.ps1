# End-to-end: the real watcher process, a real git remote, the real popup window.
# Each test plays out one of the real-life stories: a push arrives, the PC was off,
# the internet dropped, the person is away. Volume is 0 so tests stay silent.
. "$PSScriptRoot\_harness.ps1"
. "$PSScriptRoot\_windows.ps1"
Import-Module "$PSScriptRoot\..\PushPop.psm1" -Force -DisableNameChecking

$tool = Split-Path $PSScriptRoot
$script:Watchers = @()

function Start-Watcher {
    # Environment variables pass down to the child, so it uses the sandbox home and config.
    $process = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tool\watcher.ps1`""
    )
    $script:Watchers += $process
    $process
}

function Stop-Watcher($Process) {
    if (-not $Process.HasExited) { Stop-Process -Id $Process.Id -Force }
    $Process.WaitForExit()
}

function Start-Story {
    # Remote with one commit and a running watcher that has finished its first look.
    param([int]$IdleLimit = 100000)
    $sb = New-Sandbox
    Push-As $sb 'arshad'
    Write-TestConfig $sb $IdleLimit
    [IO.File]::WriteAllText((Join-Path $env:PUSHPOP_HOME 'me.txt'), 'arshad')
    $watcher = Start-Watcher
    Wait-Until { (Read-State).heads.ContainsKey($sb.Url) } 30 'watcher saved its first look'
    [pscustomobject]@{ Sb = $sb; Watcher = $watcher }
}

function End-Story($Story) {
    Stop-Watcher $Story.Watcher
    Remove-Sandbox $Story.Sb
    Remove-Item Env:\PUSHPOP_CONFIG -ErrorAction SilentlyContinue
}

Write-Host 'A push arrives'
Test 'Aamir pushes: the popup appears on Arshad''s screen' {
    $s = Start-Story
    Push-As $s.Sb 'aamir'
    Assert-Popup 'Aamir pushed to G'
    End-Story $s
}
Test 'Arshad pushes: nothing appears on Arshad''s own screen' {
    $s = Start-Story
    Push-As $s.Sb 'arshad'
    Assert-NoPopup 'Arshad pushed to G' 5
    Assert-Equal 0 @((Read-State).pending).Count 'pending'
    End-Story $s
}
Test 'after showing once it does not show again' {
    $s = Start-Story
    Push-As $s.Sb 'aamir'
    Assert-Popup 'Aamir pushed to G'
    Wait-Until { @((Read-State).pending).Count -eq 0 } 15 'pending cleared after showing'
    Assert-NoPopup 'Aamir pushed to G' 5
    End-Story $s
}

Test 'with a video set, a real push plays it through to the end' {
    $s = Start-Story
    $config = Get-Content -Raw $env:PUSHPOP_CONFIG | ConvertFrom-Json
    $config.people.arshad | Add-Member -NotePropertyName video -NotePropertyValue 'assets/cat.mp4'
    $config.people.arshad.figure = 'assets/cat-still.png'
    [IO.File]::WriteAllText($env:PUSHPOP_CONFIG, ($config | ConvertTo-Json -Depth 6))
    Start-Sleep -Seconds 2
    Push-As $s.Sb 'aamir'
    Assert-Popup 'Aamir pushed to G'
    Wait-Until { @((Read-State).pending).Count -eq 0 } 25 'video finished and the popup was cleared'
    Assert-True ((Get-Content -Raw (Join-Path $env:PUSHPOP_HOME 'log.txt')) -match 'exit 0') 'popup finished cleanly'
    End-Story $s
}

Write-Host 'The PC was off'
Test 'pushes made while the PC was off pop up at startup, as one popup' {
    $s = Start-Story
    Stop-Watcher $s.Watcher
    Push-As $s.Sb 'aamir' 3
    Push-As $s.Sb 'aamir' 2
    $s.Watcher = Start-Watcher
    Assert-Popup 'Aamir pushed 5 commits to G'
    End-Story $s
}

Write-Host 'The internet dropped'
Test 'a push during an outage pops up once the internet is back' {
    $s = Start-Story
    Push-As $s.Sb 'aamir'
    $away = "$($s.Sb.Remote).away"
    # Moving the remote away is the same to git as having no connection.
    Rename-Item $s.Sb.Remote $away
    Assert-NoPopup 'Aamir pushed to G' 4
    Assert-True (-not $s.Watcher.HasExited) 'watcher survived the outage'
    Rename-Item $away $s.Sb.Remote
    Assert-Popup 'Aamir pushed to G'
    End-Story $s
}

Write-Host 'The person is away'
Test 'while away the popup waits, then shows on return' {
    # An idle limit of 0 means "away" whatever the real mouse is doing.
    $s = Start-Story -IdleLimit 0
    Push-As $s.Sb 'aamir'
    Wait-Until { @((Read-State).pending).Count -eq 1 } 20 'push noticed while away'
    Assert-NoPopup 'Aamir pushed to G' 4
    Write-TestConfig $s.Sb 100000
    Assert-Popup 'Aamir pushed to G'
    End-Story $s
}

Write-Host 'The pause switch'
Test 'while paused the popup waits, then shows on resume' {
    $s = Start-Story
    Assert-True (Switch-Pause) 'paused'
    Push-As $s.Sb 'aamir'
    Wait-Until { @((Read-State).pending).Count -eq 1 } 20 'push noticed while paused'
    Assert-NoPopup 'Aamir pushed to G' 4
    Assert-True (-not (Switch-Pause)) 'resumed'
    Assert-Popup 'Aamir pushed to G'
    End-Story $s
}

Write-Host 'Going wrong'
Test 'a second copy of the watcher exits straight away' {
    $s = Start-Story
    $second = Start-Watcher
    Assert-True ($second.WaitForExit(10000)) 'second copy exited'
    Assert-True (-not $s.Watcher.HasExited) 'first copy still running'
    $log = Get-Content -Raw (Join-Path $env:PUSHPOP_HOME 'log.txt')
    Assert-True ($log -match 'another copy is already running') "the exit reason is logged, log: $log"
    End-Story $s
}
Test 'every stage of starting up is logged, so a failed start can never be silent again' {
    $s = Start-Story
    $lines = @(Get-Content (Join-Path $env:PUSHPOP_HOME 'log.txt'))
    Assert-True ($lines[0] -match 'watcher launching') "first line is written before anything can fail, got: $($lines[0])"
    Assert-True ($lines[1] -match 'module loaded') "second stage logged, got: $($lines[1])"
    Assert-True ($lines[2] -match 'watcher started') "third stage logged, got: $($lines[2])"
    End-Story $s
}
Test 'a clean exit is logged' {
    $s = Start-Story
    $second = Start-Watcher
    Assert-True ($second.WaitForExit(10000)) 'second copy exited'
    $log = Get-Content -Raw (Join-Path $env:PUSHPOP_HOME 'log.txt')
    Assert-True ($log -match 'watcher exiting') "the exit itself is logged, log: $log"
    End-Story $s
}
Test 'a config file broken mid-edit does not kill the watcher' {
    $s = Start-Story
    $good = [IO.File]::ReadAllText($env:PUSHPOP_CONFIG)
    [IO.File]::WriteAllText($env:PUSHPOP_CONFIG, '{ "pollSeconds": ')
    Start-Sleep -Seconds 3
    Assert-True (-not $s.Watcher.HasExited) 'watcher survived'
    [IO.File]::WriteAllText($env:PUSHPOP_CONFIG, $good)
    Push-As $s.Sb 'aamir'
    Assert-Popup 'Aamir pushed to G'
    End-Story $s
}
Test 'a config left broken keeps working on the last good version' {
    $s = Start-Story
    [IO.File]::WriteAllText($env:PUSHPOP_CONFIG, '{ "pollSeconds": ')
    Start-Sleep -Seconds 2
    Push-As $s.Sb 'aamir'
    Assert-Popup 'Aamir pushed to G'
    End-Story $s
}
Test 'a repo added to config.json is picked up without a restart' {
    $s = Start-Story
    $other = New-Sandbox
    $env:PUSHPOP_HOME = Join-Path $s.Sb.Root 'home dir'
    Push-As $other 'arshad'
    $config = Get-Content -Raw $env:PUSHPOP_CONFIG | ConvertFrom-Json
    $config.repos = @($config.repos) + [pscustomobject]@{ name = 'Sb'; url = $other.Url }
    [IO.File]::WriteAllText($env:PUSHPOP_CONFIG, ($config | ConvertTo-Json -Depth 6))
    Wait-Until { (Read-State).heads.ContainsKey($other.Url) } 20 'new repo saved'
    Push-As $other 'aamir'
    Assert-Popup 'Aamir pushed to Sb'
    Remove-Item -Recurse -Force $other.Root -ErrorAction SilentlyContinue
    End-Story $s
}

foreach ($process in $script:Watchers) { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force } }
Complete-Tests
