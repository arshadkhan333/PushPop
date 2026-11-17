# Runs every test suite. Add -Live to also read the real GitHub repos (read-only).
# Popups will flash in the bottom right corner while this runs. Tests are silent.
# Note: the install tests stop any running PushPop watcher. Its task brings it back within 5 minutes.
param([switch]$Live)

$suites = 'unit', 'integration', 'e2e-popup', 'e2e-watcher', 'e2e-install'
if ($Live) { $suites += 'live-github' }

$failed = @()
foreach ($suite in $suites) {
    Write-Host "`n===== $suite ====="
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\$suite.ps1"
    if ($LASTEXITCODE -ne 0) { $failed += $suite }
}
Get-ScheduledTask -TaskName 'PushPopTest-*' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP -Filter 'pushpop-*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failed) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "All $($suites.Count) suites passed." -ForegroundColor Green
