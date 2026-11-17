# Unit tests: each small piece on its own. No network, no windows.
. "$PSScriptRoot\_harness.ps1"
Import-Module "$PSScriptRoot\..\PushPop.psm1" -Force -DisableNameChecking

$config = New-TestConfig

Write-Host 'Who wrote a commit'
Test 'finds a person by email, ignoring case' {
    Assert-Equal 'aamir' (Resolve-Person $config 'Someone Else' 'AAMIR@EXAMPLE.COM')
}
Test 'finds a person by name when the email is unknown' {
    Assert-Equal 'aamir' (Resolve-Person $config 'aamir khan' 'other@example.com')
}
Test 'email beats name when they disagree' {
    Assert-Equal 'arshad' (Resolve-Person $config 'Aamir Khan' 'arshad@example.com')
}
Test 'returns nothing for someone not on the list' {
    Assert-True ($null -eq (Resolve-Person $config 'Hamza' 'hamza@example.com')) 'unknown person gives null'
}

Write-Host 'Hidden emails'
function Get-TestHash([string]$Text) {
    # Worked out here, separately from the code being tested.
    $sha = [Security.Cryptography.SHA256]::Create()
    'sha256:' + (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') }) -join '')
}
Test 'finds a person by a hidden email' {
    $hidden = New-TestConfig
    $hidden.people.aamir.emails = @(Get-TestHash 'aamir@example.com')
    Assert-Equal 'aamir' (Resolve-Person $hidden 'Someone Else' 'aamir@example.com')
}
Test 'a hidden email still ignores upper and lower case' {
    $hidden = New-TestConfig
    $hidden.people.aamir.emails = @(Get-TestHash 'aamir@example.com')
    Assert-Equal 'aamir' (Resolve-Person $hidden 'Someone Else' 'AAMIR@Example.COM')
}
Test 'Get-EmailHash gives the hidden form config.json uses' {
    Assert-Equal (Get-TestHash 'a@b.com') (Get-EmailHash ' A@B.com ') 'hidden form'
}
Test 'an empty email matches nobody' {
    Assert-True ($null -eq (Resolve-Person $config 'Hamza' '')) 'no match'
}

Write-Host 'Real identities in config.json'
$real = Read-PushPopConfig
Test 'config.json shows no readable email address' {
    $text = [IO.File]::ReadAllText((Get-ToolPath 'config.json'))
    Assert-True ($text -notmatch '[\w.+-]+@[\w-]+\.[\w.]+') 'no address anywhere in the file'
    foreach ($person in $real.people.PSObject.Properties) {
        foreach ($email in @($person.Value.emails)) { Assert-True ($email -like 'sha256:*') "$($person.Name) has only hidden emails" }
    }
}
$cases = @(
    @('Mohmed Aamir Ali Khan', 'unknown@example.com', 'aamir'),
    @('Arshad', 'unknown@example.com', 'arshad'),
    @('Mohammed Arshad Zareef Khan', 'unknown@example.com', 'arshad'),
    @('MohdHamza2', 'unknown@example.com', ''),
    @('Claude Opus 5', 'noreply@anthropic.com', '')
)
# Checks that need the real addresses read them from a file that never goes to GitHub.
$private = Join-Path $PSScriptRoot 'identities.local.csv'
if (Test-Path $private) {
    foreach ($row in Import-Csv $private) { $cases += , @($row.name, $row.email, $row.expected) }
} else {
    Write-Host '  (real-address checks skipped: tests\identities.local.csv is not on this PC)'
}
foreach ($c in $cases) {
    Test "$($c[0]) is [$($c[2])]" {
        Assert-Equal $c[2] (Resolve-Person $real $c[0] $c[1])
    }
}
Test 'shipped config.json passes validation' {
    Assert-Equal 0 @(Test-PushPopConfig $real).Count 'error count'
}
Test 'every file named in config.json exists' {
    foreach ($person in $real.people.PSObject.Properties) {
        foreach ($key in 'figure', 'sound', 'video') {
            $file = $person.Value.$key
            Assert-True ($file) "$($person.Name) has a $key"
            Assert-True (Test-Path -LiteralPath (Get-ToolPath $file)) "$file exists"
        }
    }
}

Write-Host 'Popup caption'
Test 'one commit' {
    Assert-Equal 'Aamir pushed to G' (Format-Caption 'Aamir' @(@{ repo = 'G'; count = 1 }))
}
Test 'many commits' {
    Assert-Equal 'Aamir pushed 5 commits to G' (Format-Caption 'Aamir' @(@{ repo = 'G'; count = 5 }))
}
Test 'two repos' {
    Assert-Equal 'Aamir pushed 3 commits to G and Sb' (Format-Caption 'Aamir' @(@{ repo = 'G'; count = 2 }, @{ repo = 'Sb'; count = 1 }))
}
Test 'three repos' {
    Assert-Equal 'Aamir pushed 4 commits to G, Sb and Web' (Format-Caption 'Aamir' @(@{ repo = 'G'; count = 2 }, @{ repo = 'Sb'; count = 1 }, @{ repo = 'Web'; count = 1 }))
}

Write-Host 'Waiting popups'
Test 'pushes to the same repo merge into one entry' {
    $s = New-EmptyState
    Add-Pending $s 'G' 'aamir' 2
    Add-Pending $s 'G' 'aamir' 3
    Assert-Equal 1 @($s.pending).Count 'entries'
    Assert-Equal 5 $s.pending[0].count 'count'
}
Test 'different repos stay separate entries' {
    $s = New-EmptyState
    Add-Pending $s 'G' 'aamir' 1
    Add-Pending $s 'Sb' 'aamir' 1
    Assert-Equal 2 @($s.pending).Count 'entries'
}
Test 'one popup per person, using the figure for MY screen' {
    $s = New-EmptyState
    Add-Pending $s 'G' 'aamir' 1
    Add-Pending $s 'Sb' 'aamir' 2
    $plan = @(Get-PopupPlan $s $config 'arshad')
    Assert-Equal 1 $plan.Count 'popups'
    Assert-Equal 'Aamir pushed 3 commits to G and Sb' $plan[0].caption
    Assert-True ($plan[0].figure -like '*figure-on-arshads-screen.png') 'figure belongs to the person watching'
    Assert-True ([IO.Path]::IsPathRooted($plan[0].figure)) 'figure path is absolute'
}

Test 'the popup uses the video set for MY screen' {
    $withVideo = New-TestConfig
    $withVideo.people.arshad | Add-Member -NotePropertyName video -NotePropertyValue 'assets/cat.mp4'
    $s = New-EmptyState
    Add-Pending $s 'G' 'aamir' 1
    Assert-True (@(Get-PopupPlan $s $withVideo 'arshad')[0].video -like '*cat.mp4') 'video path passed along'
    Assert-Equal '' @(Get-PopupPlan $s $config 'arshad')[0].video 'no video set means none'
}

Write-Host 'Config checks'
Test 'a good config has no errors' {
    Assert-Equal 0 @(Test-PushPopConfig $config).Count 'errors'
}
Test 'rejects a url that is not https or file' {
    $bad = New-TestConfig '--upload-pack=calc.exe'
    Assert-True (@(Test-PushPopConfig $bad).Count -gt 0) 'bad url is reported'
}
Test 'rejects a password or token inside a url' {
    $bad = New-TestConfig 'https://user:token@github.com/acme/G.git'
    Assert-True (@(Test-PushPopConfig $bad).Count -gt 0) 'url with login is reported'
}
Test 'rejects a poll time below one second' {
    $bad = New-TestConfig; $bad.pollSeconds = 0
    Assert-True (@(Test-PushPopConfig $bad).Count -gt 0) 'zero poll time is reported'
}
Test 'rejects a person with no figure' {
    $bad = New-TestConfig; $bad.people.aamir.figure = ''
    Assert-True (@(Test-PushPopConfig $bad).Count -gt 0) 'missing figure is reported'
}

foreach ($key in 'pollSeconds', 'idleLimitSeconds', 'figureHeight', 'showSeconds', 'volume') {
    Test "rejects a config where $key was deleted by accident" {
        $bad = New-TestConfig
        $bad.PSObject.Properties.Remove($key)
        Assert-True (@(Test-PushPopConfig $bad).Count -gt 0) "missing $key is reported"
    }
}
Test 'a config saved by Notepad with a byte-order mark still loads' {
    $path = Join-Path $env:TEMP "pushpop-bom-$PID.json"
    [IO.File]::WriteAllText($path, '{ "pollSeconds": 60 }', (New-Object Text.UTF8Encoding $true))
    $env:PUSHPOP_CONFIG = $path
    try { Assert-Equal 60 (Read-PushPopConfig).pollSeconds 'pollSeconds' }
    finally { Remove-Item Env:\PUSHPOP_CONFIG; Remove-Item $path }
}

Write-Host 'Where data lives'
Test 'data lives in the tool folder, never in AppData' {
    # AppData is not the same place for every program: the Claude app has a private copy of it.
    $tool = Split-Path $PSScriptRoot
    Assert-Equal (Join-Path $tool 'data') (Get-PushPopHome) 'default data folder'
}

Write-Host 'Saved state'
$root = Join-Path $env:TEMP ('pushpop-unit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$env:PUSHPOP_HOME = $root
Test 'no saved file gives an empty state' {
    $s = Read-State
    Assert-Equal 0 $s.heads.Count 'heads'
    Assert-Equal 0 @($s.pending).Count 'pending'
}
Test 'state survives a save and load, one head stays a list' {
    $s = New-EmptyState
    $s.heads['u'] = @('abc')
    Add-Pending $s 'G' 'aamir' 2
    Save-State $s
    $back = Read-State
    Assert-Equal 1 @($back.heads['u']).Count 'heads'
    Assert-Equal 'abc' @($back.heads['u'])[0] 'head'
    Assert-Equal 2 $back.pending[0].count 'count'
}
Test 'saving leaves no temp file behind' {
    Assert-Equal 0 @(Get-ChildItem $root -Filter '*.tmp').Count 'temp files'
}
Test 'a corrupt file is set aside, not fatal' {
    Set-Content (Join-Path $root 'state.json') '{ not json'
    $s = Read-State
    Assert-Equal 0 $s.heads.Count 'heads'
    Assert-True (Test-Path (Join-Path $root 'state.json.bad')) 'bad file kept for inspection'
}
Test 'a briefly locked file is not mistaken for a corrupt one' {
    $path = Join-Path $root 'state.json'
    Remove-Item (Join-Path $root 'state.json.bad') -ErrorAction SilentlyContinue
    Save-State (New-EmptyState)
    $lock = [IO.File]::Open($path, 'Open', 'Read', 'None')
    try {
        $threw = $false
        try { Read-State | Out-Null } catch { $threw = $true }
        Assert-True $threw 'reading a locked file reports the problem'
    } finally { $lock.Close() }
    Assert-True (Test-Path $path) 'state file still in place'
    Assert-True (-not (Test-Path "$path.bad")) 'not set aside as corrupt'
}
Test 'two repos with the same name get different mirrors' {
    Assert-True ((Get-MirrorPath 'https://github.com/a/G.git') -ne (Get-MirrorPath 'https://github.com/b/G.git')) 'paths differ'
}

Write-Host 'Pause switch'
Test 'not paused by default' {
    Assert-True (-not (Test-Paused)) 'not paused'
}
Test 'switching pauses, switching again resumes' {
    Assert-True (Switch-Pause) 'first switch pauses'
    Assert-True (Test-Paused) 'paused'
    Assert-True (-not (Switch-Pause)) 'second switch resumes'
    Assert-True (-not (Test-Paused)) 'resumed'
}
Test 'a forgotten pause ends by itself after 2 hours' {
    Switch-Pause | Out-Null
    (Get-Item (Join-Path $root 'paused')).LastWriteTime = (Get-Date).AddHours(-3)
    Assert-True (-not (Test-Paused)) 'old pause has expired'
}

Write-Host 'Is the person at the screen'
Test 'idle time is a sane number' {
    $idle = Get-IdleSeconds
    Assert-True ($idle -ge 0) 'idle seconds not negative'
}
Test 'an idle limit of zero always means away' {
    Assert-True (-not (Test-UserPresent 0)) 'away'
}

Remove-Item -Recurse -Force $root
Remove-Item Env:\PUSHPOP_HOME
Complete-Tests
