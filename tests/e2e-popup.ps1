# End-to-end: the real popup window on the real desktop. Volume is 0 so tests stay silent.
. "$PSScriptRoot\_harness.ps1"
. "$PSScriptRoot\_windows.ps1"

$tool = Split-Path $PSScriptRoot
$figure = Join-Path $tool 'assets\cat-still.png'
$sound = Join-Path $tool 'assets\sound.wav'
$video = Join-Path $tool 'assets\cat.mp4'

Write-Host 'The popup window'
Test 'appears with its caption, on top, click-through, and closes itself' {
    $before = [PushPopTest.Win]::GetForegroundWindow()
    $run = Start-Popup -Caption 'Aamir pushed to G' -Figure $figure -Sound $sound -ShowSeconds 1
    $window = Wait-Window 'PushPop: Aamir pushed to G' 15
    Assert-True ($window -ne [IntPtr]::Zero) 'window appeared'
    $style = [PushPopTest.Win]::GetWindowLong($window, -20)
    Assert-True ($style -band 0x8) 'always on top'
    Assert-True ($style -band 0x20) 'clicks pass through'
    Assert-True ($style -band 0x80) 'hidden from alt-tab'
    Assert-True ($style -band 0x8000000) 'never takes focus'
    Assert-Equal $before ([PushPopTest.Win]::GetForegroundWindow()) 'foreground window'
    Assert-Equal 0 (Wait-Popup $run 15).Code 'exit code'
    Assert-Equal ([IntPtr]::Zero) ([PushPopTest.Win]::FindWindow([NullString]::Value, 'PushPop: Aamir pushed to G')) 'window gone afterwards'
}
Test 'sits inside the screen, in the bottom right corner' {
    $run = Start-Popup -Caption 'Position check' -Figure $figure -ShowSeconds 1
    $window = Wait-Window 'PushPop: Position check' 15
    Start-Sleep -Milliseconds 300
    $rect = New-Object PushPopTest.Win+RECT
    [void][PushPopTest.Win]::GetWindowRect($window, [ref]$rect)
    Add-Type -AssemblyName System.Windows.Forms
    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    Assert-True ($rect.Right -le $area.Right -and $rect.Bottom -le $area.Bottom) "inside the screen, got $($rect.Right),$($rect.Bottom) in $($area.Right),$($area.Bottom)"
    Assert-True ($rect.Left -gt $area.Left + $area.Width / 2) 'on the right half'
    Assert-True ($rect.Top -gt $area.Top) 'below the top edge'
    Wait-Popup $run 15 | Out-Null
}
Test 'the sound file really loads' {
    $run = Start-Popup -Caption 'Sound check' -Figure $figure -Sound $sound -ShowSeconds 1
    $result = Wait-Popup $run 15
    Assert-True ($result.Out -match 'sound opened') "sound opened, output was: $($result.Out)"
}

Write-Host 'The fade, measured from real screen pixels'
Test 'the fade in and out can actually be seen' {
    Add-Type -AssemblyName System.Drawing
    $solid = Join-Path $env:TEMP "pushpop-solid-$PID.png"
    $bitmap = New-Object Drawing.Bitmap 64, 64
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([Drawing.Color]::Magenta)
    $graphics.Dispose()
    $bitmap.Save($solid, [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()

    $run = Start-Popup -Caption 'Fade check' -Figure $solid -ShowSeconds 1
    $window = Wait-Window 'PushPop: Fade check' 15
    $screen = [PushPopTest.Win]::GetDC([IntPtr]::Zero)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $samples = New-Object Collections.ArrayList
    while (-not $run.Process.HasExited -and $clock.ElapsedMilliseconds -lt 8000) {
        $rect = New-Object PushPopTest.Win+RECT
        if (-not [PushPopTest.Win]::GetWindowRect($window, [ref]$rect)) { break }
        $x = [int](($rect.Left + $rect.Right) / 2)
        $y = [int]($rect.Top + ($rect.Bottom - $rect.Top) * 0.4)
        $color = [PushPopTest.Win]::GetPixel($screen, $x, $y)
        [void]$samples.Add([pscustomobject]@{
            T = $clock.ElapsedMilliseconds
            R = $color -band 255; G = ($color -shr 8) -band 255; B = ($color -shr 16) -band 255
        })
    }
    Wait-Popup $run 15 | Out-Null
    Remove-Item $solid

    # Magenta has the biggest possible red-minus-green gap. Neutral greys have none, so
    # text changing in a window behind the popup does not disturb this measurement.
    function Get-Gap($s) { $s.R - $s.G }
    $first = $samples[0]
    $background = Get-Gap $first
    Assert-True ($background -lt 100) "still invisible when the window first appears, but the first sample was already $($first.R),$($first.G),$($first.B)"
    $levels = foreach ($s in $samples) { [pscustomobject]@{ T = $s.T; Level = ((Get-Gap $s) - $background) / (255 - $background) } }

    # A real fade: going from 10% to 90% takes long enough for the eye to see it.
    $tenPercent = @($levels | Where-Object { $_.Level -ge 0.1 })[0].T
    $ninetyPercent = @($levels | Where-Object { $_.Level -ge 0.9 })[0].T
    $fadeIn = $ninetyPercent - $tenPercent
    Assert-True ($fadeIn -ge 170) "fade-in takes at least 170ms from 10% to 90%, got ${fadeIn}ms"

    # Fully visible for the hold time, and gone by the end.
    $seen = @($levels | Where-Object { $_.Level -gt 0.05 })
    $duration = $seen[-1].T - $seen[0].T
    Assert-True ($duration -ge 1500 -and $duration -le 2300) "visible for fade + 1s + fade, got ${duration}ms"
    Assert-True ($levels[-1].Level -lt 0.15) "faded out before closing, last level was $($levels[-1].Level)"
}

Write-Host 'The video popup'
Test 'plays with the green gone, the cat moving, sound present, for the full length' {
    $run = Start-Popup -Caption 'Cat check' -Figure $figure -Video $video
    $window = Wait-Window 'PushPop: Cat check' 15
    Assert-True ($window -ne [IntPtr]::Zero) 'window appeared'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 3
    $first = Get-WindowShot $window
    Start-Sleep -Milliseconds 1500
    $second = Get-WindowShot $window
    $green = [PushPopPixels]::GreenShare($second, 60)
    $moved = [PushPopPixels]::ChangedShare($first, $second)
    Assert-True ($green -lt 0.002) "no visible green left, got $([math]::Round($green * 100, 2))% of pixels"
    Assert-True ($moved -gt 0.01) "the cat moved between shots, $([math]::Round($moved * 100, 2))% of pixels changed"
    $result = Wait-Popup $run 20
    $lasted = $clock.Elapsed.TotalSeconds
    Assert-Equal 0 $result.Code 'exit code'
    Assert-True ($result.Out -match 'video opened audio=True') "video has sound, output: $($result.Out)"
    Assert-True ($lasted -ge 6.5 -and $lasted -le 10.5) "lasted about the 7s video, got $([math]::Round($lasted, 1))s"
}
Test 'never flashes green, not even for one frame' {
    $run = Start-Popup -Caption 'Flash check' -Figure $figure -Video $video
    $window = Wait-Window 'PushPop: Flash check' 15
    $screen = [PushPopTest.Win]::GetDC([IntPtr]::Zero)
    $rect = New-Object PushPopTest.Win+RECT
    $checks = 0
    $flashes = 0
    while (-not $run.Process.HasExited) {
        if (-not [PushPopTest.Win]::GetWindowRect($window, [ref]$rect)) { break }
        # Spots that are pure green in every frame of the source video.
        foreach ($spot in @(@(0.1, 0.05), @(0.9, 0.05), @(0.1, 0.5), @(0.9, 0.7))) {
            $x = [int]($rect.Left + ($rect.Right - $rect.Left) * $spot[0])
            $y = [int]($rect.Top + ($rect.Bottom - $rect.Top) * $spot[1])
            $color = [PushPopTest.Win]::GetPixel($screen, $x, $y)
            $r = $color -band 255; $g = ($color -shr 8) -band 255; $b = ($color -shr 16) -band 255
            $checks++
            if ($g -gt [Math]::Max($r, $b) + 60) { $flashes++ }
        }
    }
    Wait-Popup $run 20 | Out-Null
    Assert-True ($checks -gt 200) "watched the whole run, made $checks checks"
    Assert-Equal 0 $flashes "green flashes in $checks checks"
}

Write-Host 'Bad files never stop the popup'
Test 'a damaged video falls back to the still figure' {
    $bad = Join-Path $env:TEMP "pushpop-bad-$PID.mp4"
    Set-Content $bad 'this is not a video'
    $run = Start-Popup -Caption 'Bad video' -Figure $figure -Video $bad -ShowSeconds 1
    Assert-True ((Wait-Window 'PushPop: Bad video' 15) -ne [IntPtr]::Zero) 'window appeared'
    $result = Wait-Popup $run 20
    Remove-Item $bad
    Assert-Equal 0 $result.Code 'exit code'
    Assert-True ($result.Out -match 'video failed') "reported the failure, output: $($result.Out)"
}
Test 'a folder with spaces and a # in its name still plays the video' {
    $dir = Join-Path $env:TEMP "pushpop odd #1 $PID"
    New-Item -ItemType Directory -Path $dir | Out-Null
    Copy-Item $video, $figure, $sound $dir
    $run = Start-Popup -Caption 'Odd folder' -Figure (Join-Path $dir 'cat-still.png') -Video (Join-Path $dir 'cat.mp4')
    $result = Wait-Popup $run 20
    Remove-Item -Recurse -Force $dir
    Assert-True ($result.Out -match 'video opened') "video played from the odd folder, output: $($result.Out)"
}
Test 'the still figure and sound also load from a folder with a #' {
    $dir = Join-Path $env:TEMP "pushpop odd #2 $PID"
    New-Item -ItemType Directory -Path $dir | Out-Null
    Copy-Item $figure, $sound $dir
    $run = Start-Popup -Caption 'Odd still' -Figure (Join-Path $dir 'cat-still.png') -Sound (Join-Path $dir 'sound.wav')
    $window = Wait-Window 'PushPop: Odd still' 15
    Start-Sleep -Milliseconds 900
    $shot = Get-WindowShot $window
    $tall = $shot.Height
    $result = Wait-Popup $run 15
    Remove-Item -Recurse -Force $dir
    Assert-True ($result.Out -match 'sound opened') "sound loaded, output: $($result.Out)"
    Assert-True ($tall -gt 200) "figure loaded, window was ${tall}px tall"
}
Test 'a sound file set as the video falls back to the still figure' {
    $run = Start-Popup -Caption 'Sound as video' -Figure $figure -Video $sound -ShowSeconds 1
    Assert-True ((Wait-Window 'PushPop: Sound as video' 15) -ne [IntPtr]::Zero) 'window appeared'
    $result = Wait-Popup $run 20
    Assert-Equal 0 $result.Code 'exit code'
    Assert-True ($result.Out -match 'no picture') "explained the problem, output: $($result.Out)"
}
Test 'a missing video uses the still figure' {
    $run = Start-Popup -Caption 'No video' -Figure $figure -Video 'C:\nope\missing.mp4' -ShowSeconds 1
    Assert-True ((Wait-Window 'PushPop: No video' 15) -ne [IntPtr]::Zero) 'window appeared'
    Assert-Equal 0 (Wait-Popup $run 15).Code 'exit code'
}
Test 'a missing figure and sound still show the caption' {
    $run = Start-Popup -Caption 'No files' -Figure 'C:\nope\missing.png' -Sound 'C:\nope\missing.wav' -ShowSeconds 1
    Assert-True ((Wait-Window 'PushPop: No files' 15) -ne [IntPtr]::Zero) 'window appeared'
    Assert-Equal 0 (Wait-Popup $run 15).Code 'exit code'
}
Test 'a corrupt image still shows the caption' {
    $bad = Join-Path $env:TEMP "pushpop-bad-$PID.png"
    Set-Content $bad 'this is not a png'
    $run = Start-Popup -Caption 'Bad image' -Figure $bad -ShowSeconds 1
    Assert-True ((Wait-Window 'PushPop: Bad image' 15) -ne [IntPtr]::Zero) 'window appeared'
    Assert-Equal 0 (Wait-Popup $run 15).Code 'exit code'
    Remove-Item $bad
}
Test 'a caption that looks like markup is shown as plain text' {
    $run = Start-Popup -Caption '<Button/> & "quotes"' -Figure $figure -ShowSeconds 1
    Assert-True ((Wait-Window 'PushPop: <Button/> & "quotes"' 15) -ne [IntPtr]::Zero) 'window appeared'
    Assert-Equal 0 (Wait-Popup $run 15).Code 'exit code'
}

Complete-Tests
