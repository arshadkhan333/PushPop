# The desktop pause switch. Pushes are still noticed while paused and show on resume.
Import-Module "$PSScriptRoot\PushPop.psm1" -DisableNameChecking

$caption = if (Switch-Pause) { 'PushPop paused for up to 2 hours' } else { 'PushPop is back on' }
$popup = [pscustomobject]@{ caption = $caption; figure = ''; sound = '' }
Show-Popup $popup ([pscustomobject]@{ figureHeight = 0; showSeconds = 1.5; volume = 0 }) | Out-Null
