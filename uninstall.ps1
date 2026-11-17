# Removes PushPop from this PC: stops it, deletes its scheduled task, shortcut and data folder.
# Your repos and project folders are never touched.
param(
    [string]$TaskName = 'PushPop',
    [string]$StartupDir = [Environment]::GetFolderPath('Startup'),
    [string]$DesktopDir = [Environment]::GetFolderPath('Desktop')
)
Import-Module "$PSScriptRoot\PushPop.psm1" -DisableNameChecking

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Stop-RunningWatcher
Remove-Item (Join-Path $StartupDir 'PushPop.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path $DesktopDir 'PushPop pause.lnk') -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Get-PushPopHome) -ErrorAction SilentlyContinue
Write-Host 'PushPop removed.'
