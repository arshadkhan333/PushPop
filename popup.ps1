# Shows one popup, then exits.
# With a video: plays it with the green screen removed and its own sound, for its full length.
# Otherwise, or if the video cannot play: shows the still figure with Sound for ShowSeconds.
# Runs as its own short process so a popup problem can never take the watcher down.
param(
    [string]$Caption = 'PushPop',
    [string]$Figure = '',
    [string]$Sound = '',
    [string]$Video = '',
    [double]$FigureHeight = 320,
    [double]$ShowSeconds = 4.5,
    [double]$Volume = 0.8
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Namespace PushPop -Name Style -MemberDefinition @'
[DllImport("user32.dll")]
public static extern int GetWindowLong(IntPtr handle, int index);
[DllImport("user32.dll")]
public static extern int SetWindowLong(IntPtr handle, int index, int value);
'@

$fadeInMs = 500
$fadeOutMs = 350
# Opacity gets the gentle "ease" curve. The strong curve hit 90% in about 125ms,
# which looks like a pop, not a fade. Movement keeps the strong curve to settle crisply.
$fadeCurve = 0.25, 0.1, 0.25, 1
$moveCurve = 0.23, 1, 0.32, 1
$margin = 24
$longestVideoSeconds = 60
$workArea = [Windows.SystemParameters]::WorkArea
$height = [Math]::Min($FigureHeight, $workArea.Height * 0.7)

# Windows' video player cannot show a transparent video, so the green is removed live, on
# the graphics card, by a tiny shader. d3dcompiler_47.dll ships with Windows 10 and 11.
$greenKeyShader = @'
sampler2D input : register(s0);
float4 main(float2 uv : TEXCOORD) : COLOR {
    float4 c = tex2D(input, uv);
    float other = max(c.r, c.b);
    float a = 1 - smoothstep(0.05, 0.20, c.g - other);
    c.g = min(c.g, other);
    return float4(c.rgb * a, a);
}
'@
$greenKeySource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;

[ComImport, Guid("8BA5FB08-5195-40e2-AC58-0D989C3A0102"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ID3DBlob {
    [PreserveSig] IntPtr GetBufferPointer();
    [PreserveSig] IntPtr GetBufferSize();
}

public class GreenKey : ShaderEffect {
    [DllImport("d3dcompiler_47.dll")]
    static extern int D3DCompile(byte[] source, IntPtr size, string name, IntPtr defines, IntPtr include,
        [MarshalAs(UnmanagedType.LPStr)] string entry, [MarshalAs(UnmanagedType.LPStr)] string target,
        uint flags1, uint flags2, out ID3DBlob code, out ID3DBlob errors);

    public static readonly DependencyProperty InputProperty =
        ShaderEffect.RegisterPixelShaderSamplerProperty("Input", typeof(GreenKey), 0);
    public Brush Input { get { return (Brush)GetValue(InputProperty); } set { SetValue(InputProperty, value); } }

    public GreenKey(string hlsl) {
        byte[] source = Encoding.ASCII.GetBytes(hlsl);
        ID3DBlob code, errors;
        int result = D3DCompile(source, (IntPtr)source.Length, null, IntPtr.Zero, IntPtr.Zero, "main", "ps_2_0", 0, 0, out code, out errors);
        if (result != 0) throw new InvalidOperationException("shader did not compile: " + result);
        byte[] bytes = new byte[(int)code.GetBufferSize()];
        Marshal.Copy(code.GetBufferPointer(), bytes, 0, bytes.Length);
        PixelShader shader = new PixelShader();
        shader.SetStreamSource(new MemoryStream(bytes));
        PixelShader = shader;
        UpdateShaderValue(InputProperty);
    }
}
'@

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" Focusable="False"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" IsHitTestVisible="False">
  <StackPanel Name="Root" Opacity="0" RenderTransformOrigin="0.5,1">
    <Image Name="Picture" Stretch="Uniform" HorizontalAlignment="Center" />
    <MediaElement Name="Clip" LoadedBehavior="Manual" UnloadedBehavior="Manual" Stretch="Uniform"
                  HorizontalAlignment="Center" Visibility="Collapsed" />
    <Border Name="Pill" Background="#E6181818" CornerRadius="14" Padding="14,7" Margin="0,8,0,0"
            HorizontalAlignment="Center">
      <TextBlock Name="Label" Foreground="White" FontFamily="Segoe UI Semibold" FontSize="15"
                 TextWrapping="Wrap" TextAlignment="Center" MaxWidth="360" />
    </Border>
  </StackPanel>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$root = $window.FindName('Root')
$picture = $window.FindName('Picture')
$clip = $window.FindName('Clip')

# Set as plain text on purpose: nothing here is ever parsed as markup.
$window.Title = "PushPop: $Caption"
$window.FindName('Label').Text = $Caption

# A bad or missing figure must not stop the popup: the caption still shows.
if ($Figure -and (Test-Path -LiteralPath $Figure)) {
    try {
        $bitmap = New-Object Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.UriSource = New-Object Uri $Figure
        $bitmap.CacheOption = 'OnLoad'
        $bitmap.DecodePixelHeight = [int]($height * 2)
        $bitmap.EndInit()
        $picture.Source = $bitmap
        $picture.Height = $height
        $picture.MaxWidth = $workArea.Width / 2
    } catch {
        [Console]::Out.WriteLine("figure failed: $_")
    }
}

# Without the green key the video must not play at all: it would be a big green box.
$useVideo = [bool]($Video -and (Test-Path -LiteralPath $Video))
if ($useVideo) {
    try {
        Add-Type -ReferencedAssemblies PresentationCore, WindowsBase, PresentationFramework, System.Xaml -TypeDefinition $greenKeySource
        $clip.Effect = New-Object GreenKey $greenKeyShader
        $clip.Volume = $Volume
        $clip.Height = $height
        $clip.Source = New-Object Uri $Video
        $clip.Visibility = 'Visible'
        $picture.Visibility = 'Collapsed'
        # The bottom strip of the cat video is always empty, so the caption sits inside it.
        $window.FindName('Pill').Margin = '0,-48,0,0'
    } catch {
        [Console]::Out.WriteLine("video failed: $_")
        $useVideo = $false
    }
}

$player = New-Object Windows.Media.MediaPlayer
$player.add_MediaOpened({ [Console]::Out.WriteLine('sound opened') })
$player.add_MediaFailed({ [Console]::Out.WriteLine("sound failed: $($_.ErrorException.Message)") })
$hasSound = [bool]($Sound -and (Test-Path -LiteralPath $Sound))
if ($hasSound -and -not $useVideo) {
    $player.Volume = $Volume
    $player.Open((New-Object Uri $Sound))
}

function New-Timeline([double]$From, [double]$To, [int]$Ms, [double[]]$Spline) {
    $timeline = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $start = [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)
    $end = [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($Ms))
    $curve = New-Object Windows.Media.Animation.KeySpline $Spline[0], $Spline[1], $Spline[2], $Spline[3]
    [void]$timeline.KeyFrames.Add((New-Object Windows.Media.Animation.DiscreteDoubleKeyFrame $From, $start))
    [void]$timeline.KeyFrames.Add((New-Object Windows.Media.Animation.SplineDoubleKeyFrame $To, $end, $curve))
    $timeline
}

# Reduced motion: keep the fade, drop the extra movement.
$animated = [Windows.SystemParameters]::ClientAreaAnimation
$rise = if ($animated) { 24.0 } else { 0.0 }
$startScale = if ($animated) { 0.96 } else { 1.0 }

$slide = New-Object Windows.Media.TranslateTransform
$grow = New-Object Windows.Media.ScaleTransform
$transforms = New-Object Windows.Media.TransformGroup
$transforms.Children.Add($grow)
$transforms.Children.Add($slide)
$root.RenderTransform = $transforms

# Built before the window opens: this is slow in PowerShell, and doing it during
# the first draw used up the whole fade-in before anything reached the screen.
$fadeIn = New-Timeline 0 1 $fadeInMs $fadeCurve
$fadeOut = New-Timeline 1 0 $fadeOutMs $fadeCurve
$fadeOut.add_Completed({ $window.Close() })
$slideIn = New-Timeline $rise 0 $fadeInMs $moveCurve
$slideOut = New-Timeline 0 $rise $fadeOutMs $moveCurve
$growIn = New-Timeline $startScale 1 $fadeInMs $moveCurve
$growOut = New-Timeline 1 $startScale $fadeOutMs $moveCurve

function Start-Motion($Fade, $Slide, $Grow) {
    $root.BeginAnimation([Windows.UIElement]::OpacityProperty, $Fade)
    $script:slide.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $Slide)
    $script:grow.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $Grow)
    $script:grow.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $Grow)
}

$closer = New-Object Windows.Threading.DispatcherTimer
$closer.add_Tick({
    $closer.Stop()
    Start-Motion $fadeOut $slideOut $growOut
})

$script:started = $false
function Start-Show([double]$Seconds) {
    $script:started = $true
    $closer.Interval = [TimeSpan]::FromSeconds($Seconds) - [TimeSpan]::FromMilliseconds($fadeOutMs)
    $closer.Start()
    Start-Motion $fadeIn $slideIn $growIn
}

function Show-Still {
    if ($script:started) { return }
    $watchdog.Stop()
    $clip.Stop()
    $clip.Visibility = 'Collapsed'
    $picture.Visibility = 'Visible'
    $window.FindName('Pill').Margin = '0,8,0,0'
    if ($hasSound) {
        if ($useVideo) {
            $player.Volume = $Volume
            $player.Open((New-Object Uri $Sound))
        }
        $player.Play()
    }
    Start-Show (($fadeInMs + $fadeOutMs) / 1000 + $ShowSeconds)
}

# A video that never opens must not leave the popup waiting forever.
$watchdog = New-Object Windows.Threading.DispatcherTimer
$watchdog.Interval = [TimeSpan]::FromSeconds(8)
$watchdog.add_Tick({
    [Console]::Out.WriteLine('video failed: did not open in time')
    Show-Still
})

$clip.add_MediaFailed({
    [Console]::Out.WriteLine("video failed: $($_.ErrorException.Message)")
    Show-Still
})
$clip.add_MediaOpened({
    if (-not $clip.HasVideo) {
        [Console]::Out.WriteLine('video failed: the file has no picture')
        Show-Still
        return
    }
    $watchdog.Stop()
    [Console]::Out.WriteLine("video opened audio=$($clip.HasAudio)")
    $clip.Width = $clip.Height * $clip.NaturalVideoWidth / $clip.NaturalVideoHeight
    $length = $ShowSeconds
    if ($clip.NaturalDuration.HasTimeSpan) { $length = $clip.NaturalDuration.TimeSpan.TotalSeconds }
    Start-Show ([Math]::Min($length, $longestVideoSeconds))
})

$window.add_SourceInitialized({
    # Clicks pass through, never takes focus, stays out of alt-tab.
    $handle = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    $style = [PushPop.Style]::GetWindowLong($handle, -20)
    [void][PushPop.Style]::SetWindowLong($handle, -20, ($style -bor 0x20 -bor 0x80 -bor 0x8000000))
})

# The window changes size once the video opens, so stay anchored to the corner.
$window.add_SizeChanged({
    $window.Left = $workArea.Right - $window.ActualWidth - $margin
    $window.Top = $workArea.Bottom - $window.ActualHeight - $margin
})

# ContentRendered, not Loaded: the first frame is really on screen (at opacity 0),
# so the fade starts from there and the sound lands with it.
$window.add_ContentRendered({
    if ($useVideo) {
        $watchdog.Start()
        $clip.Play()
    } else {
        Show-Still
    }
})

[void]$window.ShowDialog()
$clip.Close()
$player.Close()
