# One-time setup for this PC:  powershell -ExecutionPolicy Bypass -File install.ps1 -Me arshad
param(
    [Parameter(Mandatory = $true)][string]$Me,
    [string]$TaskName = 'PushPop',
    [int]$RepeatMinutes = 5,
    [int]$StartWaitSeconds = 30,
    [string]$StartupDir = [Environment]::GetFolderPath('Startup'),
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop'),
    [switch]$Quiet
)
Import-Module "$PSScriptRoot\PushPop.psm1" -DisableNameChecking

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Git was not found. Install Git for Windows, then run this again.'
    exit 1
}

$config = Read-PushPopConfig
$problems = @(Test-PushPopConfig $config)
$person = $config.people.PSObject.Properties | Where-Object { $_.Name -eq $Me }
if (-not $person) {
    $names = ($config.people.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
    $problems += "'$Me' is not in config.json. Use one of: $names"
}
if ($problems) {
    foreach ($problem in $problems) { Write-Host $problem }
    exit 1
}

foreach ($file in $person.Value.figure, $person.Value.video) {
    if ($file -and -not (Test-Path -LiteralPath (Get-ToolPath $file))) { Write-Host "Warning: file not found: $file" }
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Stop-RunningWatcher
[IO.File]::WriteAllText((Get-HomeFile 'me.txt'), $person.Name)

# Looks at each repo now, so commits from before today never cause a popup.
$state = Read-State
$watching = 0
foreach ($repo in @($config.repos)) {
    if (Sync-Repo $repo $state $config $person.Name) {
        $watching++
        Write-Host "  ok    $($repo.name)"
    } else {
        Write-Host "  FAIL  $($repo.name): cannot read it from this PC."
        Write-Host "        Check you have access, then run this once and sign in:"
        Write-Host "        git ls-remote $($repo.url)"
    }
}
Save-State $state

# Older versions started from a shortcut here. The task replaces it, and also restarts the
# watcher if it ever stops.
Remove-Item (Join-Path $StartupDir 'PushPop.lnk') -ErrorAction SilentlyContinue
try {
    Register-PushPopTask $TaskName $RepeatMinutes
} catch {
    Write-Host "FAIL: Windows would not create the scheduled task: $_"
    exit 1
}
New-HiddenShortcut (Join-Path $DesktopDir 'PushPop pause.lnk') 'pause.ps1' 'Pause or resume PushPop popups'
$logPath = Get-HomeFile 'log.txt'
$linesBefore = @(Get-Content $logPath -ErrorAction SilentlyContinue).Count
Start-ScheduledTask -TaskName $TaskName

# Check, never assume. This used to say "running" straight after asking Windows to start it,
# which hid a watcher that was quitting the moment it launched.
$confirmed = $false
$deadline = (Get-Date).AddSeconds($StartWaitSeconds)
while (-not $confirmed -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $newLines = @(Get-Content $logPath -ErrorAction SilentlyContinue | Select-Object -Skip $linesBefore)
    $confirmed = [bool]($newLines -match 'watcher started for')
}
if (-not $confirmed) {
    Write-Host "FAIL: the watcher did not start. Check its log: $logPath"
    exit 1
}

Write-Host "PushPop confirmed running for $($person.Name), watching $watching of $(@($config.repos).Count) repos."
if (-not $Quiet) {
    $noun = if ($watching -eq 1) { 'repo' } else { 'repos' }
    Show-Popup (New-Popup $config $person.Name "PushPop is watching $watching $noun") $config | Out-Null
}
