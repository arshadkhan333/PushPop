# Tiny test harness: no framework, so the tests run on any Windows PC as-is.
$script:Passed = 0
$script:Failed = @()

function Test([string]$Name, [scriptblock]$Body) {
    # Set PUSHPOP_ONLY to a word to run just the matching tests.
    if ($env:PUSHPOP_ONLY -and $Name -notmatch $env:PUSHPOP_ONLY) { return }
    try {
        & $Body
        $script:Passed++
        Write-Host "  ok    $Name"
    } catch {
        $script:Failed += $Name
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-Equal($Expected, $Actual, [string]$What = 'value') {
    if ("$Expected" -cne "$Actual") { throw "${What}: expected [$Expected], got [$Actual]" }
}

function Assert-True($Condition, [string]$What) {
    if (-not $Condition) { throw "expected: $What" }
}

function Complete-Tests {
    Write-Host ""
    Write-Host "$script:Passed passed, $($script:Failed.Count) failed"
    if ($script:Failed.Count) { exit 1 }
    exit 0
}

# Fake people, so tests never depend on real names.
function New-TestConfig([string]$Url = 'https://github.com/acme/G.git') {
    [pscustomobject]@{
        pollSeconds      = 1
        idleLimitSeconds = 100000
        figureHeight     = 320
        showSeconds      = 1
        volume           = 0
        people           = [pscustomobject]@{
            arshad = [pscustomobject]@{
                display = 'Arshad'; names = @('Arshad'); emails = @('arshad@example.com')
                figure = 'assets/figure-on-arshads-screen.png'; sound = 'assets/sound.wav'
            }
            aamir = [pscustomobject]@{
                display = 'Aamir'; names = @('Aamir Khan', ('Zo' + [char]0x00EB)); emails = @('aamir@example.com')
                figure = 'assets/figure-on-aamirs-screen.png'; sound = 'assets/sound.wav'
            }
        }
        repos = @([pscustomobject]@{ name = 'G'; url = $Url })
    }
}

function G {
    # Run git quietly. Native stderr must not count as a script error here.
    $ErrorActionPreference = 'Continue'
    & git @args 2>&1 | Out-Null
}

# A real git "GitHub" on disk: a bare remote plus a working clone that pushes to it.
function New-Sandbox {
    $root = Join-Path $env:TEMP ('pushpop-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:PUSHPOP_HOME = Join-Path $root 'home dir'
    New-Item -ItemType Directory -Path $env:PUSHPOP_HOME | Out-Null
    $remote = Join-Path $root 'remote.git'
    $work = Join-Path $root 'work'
    G init -q --bare -b main $remote
    G -C $remote config uploadpack.allowFilter true
    G -C $remote config uploadpack.allowAnySHA1InWant true
    G init -q -b main $work
    G -C $work remote add origin $remote
    [pscustomobject]@{
        Root = $root; Remote = $remote; Work = $work
        Url  = 'file:///' + ($remote -replace '\\', '/')
    }
}

function Remove-Sandbox($Sandbox) {
    Remove-Item -Recurse -Force $Sandbox.Root -ErrorAction SilentlyContinue
    Remove-Item Env:\PUSHPOP_HOME -ErrorAction SilentlyContinue
}

function Push-As($Sandbox, [string]$Who, [int]$Count = 1, [string]$Branch = 'main') {
    $id = @{
        arshad = @('Arshad', 'arshad@example.com')
        aamir  = @('Aamir Khan', 'aamir@example.com')
        hamza  = @('Hamza', 'hamza@example.com')
        zoe    = @(('Zo' + [char]0x00EB), 'zoe@example.com')
    }[$Who]
    G -C $Sandbox.Work checkout -q $Branch
    if ($LASTEXITCODE) { G -C $Sandbox.Work checkout -q -b $Branch }
    for ($i = 0; $i -lt $Count; $i++) {
        G -C $Sandbox.Work -c "user.name=$($id[0])" -c "user.email=$($id[1])" commit -q --allow-empty -m "work $i"
    }
    G -C $Sandbox.Work push -q origin $Branch
}
