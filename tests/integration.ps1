# Integration tests: the pieces working together against a real git remote on disk.
. "$PSScriptRoot\_harness.ps1"
Import-Module "$PSScriptRoot\..\PushPop.psm1" -Force -DisableNameChecking

function Start-Case {
    # Remote with one commit, watcher already caught up, running as Arshad.
    $sb = New-Sandbox
    Push-As $sb 'arshad'
    $config = New-TestConfig $sb.Url
    $state = New-EmptyState
    Sync-Repo $config.repos[0] $state $config 'arshad' | Out-Null
    [pscustomobject]@{ Sb = $sb; Config = $config; State = $state; Repo = $config.repos[0] }
}
function Sync($c) { Sync-Repo $c.Repo $c.State $c.Config 'arshad' }
function PendingCount($c) { (@($c.State.pending) | Measure-Object -Property count -Sum).Sum + 0 }

Write-Host 'Detecting pushes'
Test 'first look at a repo saves it without any popup' {
    $c = Start-Case
    Assert-Equal 0 (PendingCount $c) 'pending'
    Assert-Equal 1 @($c.State.heads[$c.Sb.Url]).Count 'heads saved'
    Remove-Sandbox $c.Sb
}
Test 'a push by the other person is detected' {
    $c = Start-Case
    Push-As $c.Sb 'aamir'
    Assert-True (Sync $c) 'remote reached'
    Assert-Equal 1 (PendingCount $c) 'pending'
    Assert-Equal 'aamir' $c.State.pending[0].person 'person'
    Assert-Equal 'G' $c.State.pending[0].repo 'repo'
    Remove-Sandbox $c.Sb
}
Test 'my own push gives no popup' {
    $c = Start-Case
    Push-As $c.Sb 'arshad'
    Sync $c | Out-Null
    Assert-Equal 0 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'a push by someone not on the list gives no popup' {
    $c = Start-Case
    Push-As $c.Sb 'hamza'
    Sync $c | Out-Null
    Assert-Equal 0 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'pushes to a branch other than main are detected' {
    $c = Start-Case
    Push-As $c.Sb 'aamir' 1 'arsh'
    Sync $c | Out-Null
    Assert-Equal 1 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'the same commit landing on a second branch is not counted twice' {
    $c = Start-Case
    Push-As $c.Sb 'aamir' 1 'main'
    Sync $c | Out-Null
    G -C $c.Sb.Work checkout -q -b arsh
    G -C $c.Sb.Work push -q origin arsh
    Sync $c | Out-Null
    Assert-Equal 1 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'merging main into arsh and pushing does not recount commits already seen' {
    $c = Start-Case
    Push-As $c.Sb 'aamir' 2 'main'
    Sync $c | Out-Null
    # The everyday routine on G: a branch with its own work, then merge main into it.
    G -C $c.Sb.Work checkout -q -b arsh HEAD~2
    G -C $c.Sb.Work -c user.name=Arshad -c 'user.email=arshad@example.com' commit -q --allow-empty -m 'own work'
    G -C $c.Sb.Work -c user.name=Arshad -c 'user.email=arshad@example.com' merge -q --no-edit main
    G -C $c.Sb.Work push -q origin arsh
    Sync $c | Out-Null
    Assert-Equal 2 (PendingCount $c) 'still only the two commits from the first push'
    Remove-Sandbox $c.Sb
}
Test 'many pushes while away add up in one entry' {
    $c = Start-Case
    Push-As $c.Sb 'aamir' 2
    Push-As $c.Sb 'aamir' 3
    Sync $c | Out-Null
    Assert-Equal 1 @($c.State.pending).Count 'entries'
    Assert-Equal 5 (PendingCount $c) 'commits'
    Remove-Sandbox $c.Sb
}
Test 'nothing new means nothing happens' {
    $c = Start-Case
    Sync $c | Out-Null
    Sync $c | Out-Null
    Assert-Equal 0 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'a name with non-English letters still matches' {
    $c = Start-Case
    Push-As $c.Sb 'zoe'
    Sync $c | Out-Null
    Assert-Equal 1 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}

Write-Host 'Two people at once'
Test 'when both push, only the other person''s commits count' {
    $c = Start-Case
    Push-As $c.Sb 'aamir' 2
    Push-As $c.Sb 'arshad' 3
    Push-As $c.Sb 'aamir' 1
    Sync $c | Out-Null
    Assert-Equal 3 (PendingCount $c) 'only Aamir''s commits'
    Remove-Sandbox $c.Sb
}
Test 'watching from both sides, each person sees only the other' {
    $c = Start-Case
    $theirState = New-EmptyState
    Sync-Repo $c.Repo $theirState $c.Config 'aamir' | Out-Null
    Push-As $c.Sb 'aamir' 2
    Push-As $c.Sb 'arshad' 1
    # Same remote, separate mirrors, as on two real PCs.
    $mine = $env:PUSHPOP_HOME
    Sync $c | Out-Null
    $env:PUSHPOP_HOME = "$mine-aamir"
    Sync-Repo $c.Repo $theirState $c.Config 'aamir' | Out-Null
    $env:PUSHPOP_HOME = $mine
    Assert-Equal 'aamir' $c.State.pending[0].person 'Arshad sees Aamir'
    Assert-Equal 2 $c.State.pending[0].count 'Aamir''s commits'
    Assert-Equal 'arshad' $theirState.pending[0].person 'Aamir sees Arshad'
    Assert-Equal 1 $theirState.pending[0].count 'Arshad''s commits'
    Remove-Sandbox $c.Sb
}

Write-Host 'Awkward text'
$echoScript = Join-Path $env:TEMP "pushpop-echo-$PID.ps1"
Set-Content $echoScript 'param([string]$Text) [Console]::Out.Write($Text)'
foreach ($text in @('Web "beta" site', 'ends in a backslash\', 'two\\"mixed\"', '$(calc.exe); & | ` %PATH%', 'has  two   spaces')) {
    Test "reaches a script unchanged: $text" {
        $r = Invoke-Tool 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $echoScript, '-Text', $text) 30
        Assert-Equal $text $r.Out 'text'
    }
}
Remove-Item $echoScript

Write-Host 'Going wrong'
Test 'no internet: no crash, and the push is caught after reconnecting' {
    $c = Start-Case
    Push-As $c.Sb 'aamir'
    $hidden = "$($c.Sb.Remote).away"
    Rename-Item $c.Sb.Remote $hidden
    Assert-True (-not (Sync $c)) 'remote unreachable is reported'
    Assert-Equal 0 (PendingCount $c) 'pending while offline'
    Rename-Item $hidden $c.Sb.Remote
    Assert-True (Sync $c) 'remote reachable again'
    Assert-Equal 1 (PendingCount $c) 'pending after reconnect'
    Remove-Sandbox $c.Sb
}
Test 'a force push does not break checking' {
    $c = Start-Case
    Push-As $c.Sb 'aamir'
    Sync $c | Out-Null
    G -C $c.Sb.Work reset -q --hard HEAD~1
    G -C $c.Sb.Work -c user.name=Aamir -c 'user.email=aamir@example.com' commit -q --allow-empty -m rewritten
    G -C $c.Sb.Work push -q -f origin main
    Assert-True (Sync $c) 'still working'
    Assert-Equal 2 (PendingCount $c) 'old plus rewritten commit'
    Remove-Sandbox $c.Sb
}
Test 'a deleted branch gives no popup' {
    $c = Start-Case
    Push-As $c.Sb 'arshad' 1 'temp'
    Sync $c | Out-Null
    G -C $c.Sb.Work push -q origin --delete temp
    Assert-True (Sync $c) 'still working'
    Assert-Equal 0 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'an empty repo that gets its first push is detected' {
    $sb = New-Sandbox
    $config = New-TestConfig $sb.Url
    $state = New-EmptyState
    $repo = $config.repos[0]
    Assert-True (Sync-Repo $repo $state $config 'arshad') 'empty repo is fine'
    Push-As $sb 'aamir'
    Sync-Repo $repo $state $config 'arshad' | Out-Null
    Assert-Equal 1 $state.pending[0].count 'first push'
    Remove-Sandbox $sb
}
Test 'a deleted mirror is rebuilt and the push is still caught' {
    $c = Start-Case
    Remove-Item -Recurse -Force (Get-MirrorPath $c.Sb.Url)
    Push-As $c.Sb 'aamir'
    Sync $c | Out-Null
    Assert-Equal 1 (PendingCount $c) 'pending'
    Remove-Sandbox $c.Sb
}
Test 'a mirror stuck on a stale lock heals itself' {
    $c = Start-Case
    $mirror = Get-MirrorPath $c.Sb.Url
    New-Item -ItemType File -Force -Path "$mirror\refs\heads\main.lock" | Out-Null
    Push-As $c.Sb 'aamir'
    Sync $c | Out-Null
    Sync $c | Out-Null
    Assert-Equal 1 (PendingCount $c) 'pending after healing'
    Remove-Sandbox $c.Sb
}
Test 'a stuck program is killed at its time limit' {
    $start = Get-Date
    $r = Invoke-Tool 'ping' @('-n', '30', '127.0.0.1') 1
    Assert-True (((Get-Date) - $start).TotalSeconds -lt 6) 'returned quickly'
    Assert-True ($r.Code -ne 0) 'reported as failed'
}
Test 'paths with spaces reach git intact' {
    $sb = New-Sandbox
    Push-As $sb 'arshad'
    $r = Invoke-Tool 'git' @('clone', '-q', '--bare', $sb.Url, "$env:PUSHPOP_HOME\a mirror.git") 30
    Assert-Equal 0 $r.Code 'exit code'
    Assert-True (Test-Path "$env:PUSHPOP_HOME\a mirror.git\HEAD") 'cloned under a spaced path'
    Remove-Sandbox $sb
}

Complete-Tests
