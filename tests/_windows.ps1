# Helpers for tests that look at real windows on the desktop.
Add-Type -Namespace PushPopTest -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")]
public static extern int GetWindowLong(IntPtr handle, int index);
[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr handle, out RECT rect);
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr handle);
[DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")]
public static extern IntPtr GetDC(IntPtr handle);
[DllImport("gdi32.dll")]
public static extern uint GetPixel(IntPtr dc, int x, int y);
'@
[void][PushPopTest.Win]::SetProcessDPIAware()

function Wait-Window([string]$Title, [int]$TimeoutSec) {
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        $window = [PushPopTest.Win]::FindWindow([NullString]::Value, $Title)
        if ($window -ne [IntPtr]::Zero -and [PushPopTest.Win]::IsWindowVisible($window)) { return $window }
        Start-Sleep -Milliseconds 15
    }
    [IntPtr]::Zero
}

function Start-Popup {
    param([string]$Caption, [string]$Figure, [string]$Sound = '', [string]$Video = '', [double]$ShowSeconds = 1)
    $popup = Join-Path (Split-Path $PSScriptRoot) 'popup.ps1'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $safe = $Caption -replace '"', '\"'
    $info.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$popup`" -Caption `"$safe`" -Figure `"$Figure`" -Sound `"$Sound`" -Video `"$Video`" -ShowSeconds $ShowSeconds -Volume 0"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    [pscustomobject]@{
        Process = $process
        Out     = $process.StandardOutput.ReadToEndAsync()
        Err     = $process.StandardError.ReadToEndAsync()
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
public static class PushPopPixels {
    // Share of pixels that are clearly green.
    public static double GreenShare(Bitmap image, int margin) {
        int hits = 0;
        for (int y = 0; y < image.Height; y++)
            for (int x = 0; x < image.Width; x++) {
                Color c = image.GetPixel(x, y);
                if (c.G > Math.Max(c.R, c.B) + margin) hits++;
            }
        return (double)hits / (image.Width * image.Height);
    }
    // Share of pixels that differ between two shots.
    public static double ChangedShare(Bitmap a, Bitmap b) {
        int hits = 0;
        int w = Math.Min(a.Width, b.Width), h = Math.Min(a.Height, b.Height);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                Color p = a.GetPixel(x, y), q = b.GetPixel(x, y);
                if (Math.Abs(p.R - q.R) + Math.Abs(p.G - q.G) + Math.Abs(p.B - q.B) > 60) hits++;
            }
        return (double)hits / (w * h);
    }
}
'@

# Captures only the popup's own rectangle, never the rest of the screen.
function Get-WindowShot($Window) {
    $rect = New-Object PushPopTest.Win+RECT
    if (-not [PushPopTest.Win]::GetWindowRect($Window, [ref]$rect)) { throw 'window has gone' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    $bitmap = New-Object Drawing.Bitmap $width, $height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object Drawing.Size $width, $height))
    $graphics.Dispose()
    $bitmap
}

function Wait-Popup($Run, [int]$TimeoutSec) {
    if (-not $Run.Process.WaitForExit($TimeoutSec * 1000)) {
        $Run.Process.Kill()
        throw "popup did not close itself within ${TimeoutSec}s"
    }
    $Run.Process.WaitForExit()
    [pscustomobject]@{ Code = $Run.Process.ExitCode; Out = $Run.Out.Result + $Run.Err.Result }
}

function Write-TestConfig($Sandbox, [int]$IdleLimit = 100000) {
    $config = New-TestConfig $Sandbox.Url
    $config.idleLimitSeconds = $IdleLimit
    $path = Join-Path $Sandbox.Root 'config.json'
    [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 6))
    $env:PUSHPOP_CONFIG = $path
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSec, [string]$What) {
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        # The watcher may be mid-save when the test peeks at the file: just look again.
        try { if (& $Condition) { return } } catch { }
        Start-Sleep -Milliseconds 200
    }
    throw "timed out waiting: $What"
}

function Assert-Popup([string]$Caption, [int]$TimeoutSec = 20) {
    $window = Wait-Window "PushPop: $Caption" $TimeoutSec
    if ($window -ne [IntPtr]::Zero) { return }
    # Say why, so an intermittent failure can be diagnosed from one sighting.
    $windows = 0
    [void][PushPop.Native]::SHQueryUserNotificationState([ref]$windows)
    $logPath = Join-Path $env:PUSHPOP_HOME 'log.txt'
    $log = (Get-Content $logPath -Tail 12 -ErrorAction SilentlyContinue) -join ' | '
    $state = (Get-Content (Join-Path $env:PUSHPOP_HOME 'state.json') -Raw -ErrorAction SilentlyContinue) -replace '\s+', ' '
    throw "popup '$Caption' did not appear. windows state=$windows, paused=$(Test-Paused), state=[$state] log=[$log]"
}

function Assert-NoPopup([string]$Caption, [int]$Seconds) {
    $window = Wait-Window "PushPop: $Caption" $Seconds
    Assert-True ($window -eq [IntPtr]::Zero) "no popup '$Caption' yet"
}
