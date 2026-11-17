# Live check against the real GitHub repos in config.json. Read-only: nothing is pushed.
# It pretends the last look was just before a real commit, then checks that commit is found.
. "$PSScriptRoot\_harness.ps1"
Import-Module "$PSScriptRoot\..\PushPop.psm1" -Force -DisableNameChecking

$root = Join-Path $env:TEMP ('pushpop-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$env:PUSHPOP_HOME = $root
$config = Read-PushPopConfig
$state = New-EmptyState

Write-Host 'Reading the real repos'
foreach ($repo in @($config.repos)) {
    Test "can read $($repo.name) over https with this PC's git login" {
        Assert-True (Sync-Repo $repo $state $config 'arshad') 'remote reached'
        Assert-True (@($state.heads[$repo.url]).Count -gt 0) 'branches found'
    }
}

function Get-ParentOfNewestCommitBy([string]$Url, [string]$Author) {
    $log = Invoke-Git @('-C', (Get-MirrorPath $Url), 'log', '--all', "--author=$Author", '-n', '1', '--format=%P') 30
    ($log.Out.Trim() -split ' ')[0]
}

Write-Host 'Spotting real people'
$g = @($config.repos | Where-Object { $_.name -eq 'G' })[0]
Test 'running as Arshad, a real Aamir commit on G counts as Aamir' {
    $s = New-EmptyState
    $s.heads[$g.url] = @(Get-ParentOfNewestCommitBy $g.url $config.people.aamir.names[0])
    Assert-True (Sync-Repo $g $s $config 'arshad') 'check ran'
    Assert-Equal 'aamir' @($s.pending)[0].person 'person'
    Assert-True (@($s.pending)[0].count -ge 1) 'at least one commit found'
    Write-Host "        found $(@($s.pending)[0].count) commit(s): $(@(Get-PopupPlan $s $config 'arshad')[0].caption)"
}
Test 'running as Aamir, a real Arshad commit on G counts as Arshad' {
    $s = New-EmptyState
    $s.heads[$g.url] = @(Get-ParentOfNewestCommitBy $g.url $config.people.arshad.names[0])
    Assert-True (Sync-Repo $g $s $config 'aamir') 'check ran'
    Assert-Equal 'arshad' @($s.pending)[0].person 'person'
    Write-Host "        found $(@($s.pending)[0].count) commit(s): $(@(Get-PopupPlan $s $config 'aamir')[0].caption)"
}
Test 'with nothing new on the real repos, nothing is flagged' {
    $s = New-EmptyState
    foreach ($repo in @($config.repos)) { $s.heads[$repo.url] = $state.heads[$repo.url] }
    foreach ($repo in @($config.repos)) { Sync-Repo $repo $s $config 'arshad' | Out-Null }
    Assert-Equal 0 @($s.pending).Count 'pending'
}

Remove-Item -Recurse -Force $root
Remove-Item Env:\PUSHPOP_HOME
Complete-Tests
