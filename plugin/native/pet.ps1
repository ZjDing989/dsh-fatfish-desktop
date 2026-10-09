[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $DiscoveryPath,
    [string] $Assets = $PSScriptRoot,
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Net.Http
Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
public static class FatFishBridgeHttp {
    public static async Task<string> Get(HttpClient client, string uri, string token) {
        using (var request = new HttpRequestMessage(HttpMethod.Get, uri)) {
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
            using (var response = await client.SendAsync(request).ConfigureAwait(false)) {
                response.EnsureSuccessStatusCode();
                return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            }
        }
    }
    public static async Task<string> Post(HttpClient client, string uri, string token, string json) {
        using (var request = new HttpRequestMessage(HttpMethod.Post, uri)) {
            request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
            request.Content = new StringContent(json, Encoding.UTF8, "application/json");
            using (var response = await client.SendAsync(request).ConfigureAwait(false)) {
                response.EnsureSuccessStatusCode();
                return await response.Content.ReadAsStringAsync().ConfigureAwait(false);
            }
        }
    }
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
}
'@ -ReferencedAssemblies System.Net.Http

$DiscoveryPath = [IO.Path]::GetFullPath($DiscoveryPath)
$script:DataDirectory = Join-Path (Split-Path -Parent $DiscoveryPath) 'fatfish-pet'
[IO.Directory]::CreateDirectory($script:DataDirectory) | Out-Null
$script:SettingsPath = Join-Path $script:DataDirectory 'settings.json'
$script:LogPath = Join-Path $script:DataDirectory 'native.log'
. (Join-Path $PSScriptRoot 'native-settings.ps1')
. (Join-Path $PSScriptRoot 'native-theme.ps1')
$script:Settings = Get-FatFishSettings $script:SettingsPath
$script:Descriptor = $null
$script:LastDescriptorAt = [DateTime]::UtcNow
$script:LastSuccessAt = [DateTime]::MinValue
$script:NextPollAt = [DateTime]::MinValue
$script:NextPidCheckAt = [DateTime]::MinValue
$HttpHandler = New-Object Net.Http.HttpClientHandler
$HttpHandler.UseProxy = $false
$script:Http = New-Object Net.Http.HttpClient($HttpHandler)
$script:Http.Timeout = [TimeSpan]::FromSeconds(1.5)
$script:PollTask = $null
$script:ActionTasks = New-Object Collections.ArrayList
$script:PendingNavigation = @{}
$script:NavigationSerial = 0
$script:BubbleCardHeight = 63.0
$script:BubbleCardGap = 6.0
$script:ExecutionCount = 0
$script:Tasks = @()
$script:Snapshot = $null
$script:Expanded = $false
$script:BubbleSignature = ''
$script:CollapseAt = [DateTime]::MaxValue
$script:Dragging = $false
$script:Pressed = $false
$script:IdleResumeAt = [DateTime]::MinValue
$script:PetX = 0.0
$script:PetY = 0.0
$script:LastPetSize = [double]$script:Settings.size
$script:SettingsOpen = $false
$script:NextThemePollAt = [DateTime]::MinValue
$script:Closed = $false
$script:NextBlinkAt = [DateTime]::UtcNow.AddSeconds(5)
$script:BlinkUntil = [DateTime]::MinValue

function Write-NativeLog([string] $Message) {
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 524288) {
            [IO.File]::WriteAllText($script:LogPath, '', (New-Object Text.UTF8Encoding($false)))
        }
        [IO.File]::AppendAllText($script:LogPath, ([DateTime]::UtcNow.ToString('o') + ' ' + $Message + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

[xml] $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="大肥鱼 · DSH 插件" Width="420" Height="720" WindowStyle="None" AllowsTransparency="True" Background="{x:Null}"
 ResizeMode="NoResize" ShowInTaskbar="False" ShowActivated="False" Topmost="True" FontFamily="Microsoft YaHei UI">
 <Window.Resources>
  <Style x:Key="FatFish.MenuItemStyle" TargetType="{x:Type MenuItem}">
   <Setter Property="Foreground" Value="{DynamicResource FatFish.Text}"/>
   <Setter Property="FontSize" Value="12"/>
   <Setter Property="Padding" Value="13,10"/>
   <Setter Property="Margin" Value="2"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="{x:Type MenuItem}">
     <Border x:Name="ItemSurface" Background="Transparent" CornerRadius="12" Padding="{TemplateBinding Padding}">
      <ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemSurface" Property="Background" Value="{DynamicResource FatFish.SurfaceHover}"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value>
   </Setter>
  </Style>
  <Style x:Key="FatFish.ContextMenuStyle" TargetType="{x:Type ContextMenu}">
   <Setter Property="Background" Value="{DynamicResource FatFish.Surface}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource FatFish.Border}"/>
   <Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Padding" Value="6"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="{x:Type ContextMenu}">
     <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="18" Padding="{TemplateBinding Padding}">
      <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
     </Border>
    </ControlTemplate></Setter.Value>
   </Setter>
  </Style>
 </Window.Resources>
 <Canvas x:Name="Scene" Background="{x:Null}">
  <Grid x:Name="BubbleRegion" Width="336" Visibility="Collapsed" Background="{x:Null}">
   <Canvas x:Name="CollapsedBubbles" Background="{x:Null}"/>
   <Grid x:Name="ExpandedPanel" Visibility="Collapsed" HorizontalAlignment="Left" Width="326">
    <WrapPanel x:Name="ExpandedBubbles" Orientation="Vertical" ItemWidth="332" ItemHeight="69"/>
   </Grid>
  </Grid>
  <Grid x:Name="PetGroup" Background="{x:Null}" RenderTransformOrigin="0.5,0.7" Cursor="Hand">
   <Grid.RenderTransform><TransformGroup><ScaleTransform x:Name="PetScale" ScaleX="1" ScaleY="1"/><RotateTransform x:Name="PetRotate" Angle="0"/><TranslateTransform x:Name="PetTranslate" X="0" Y="0"/></TransformGroup></Grid.RenderTransform>
   <Image x:Name="PetImage" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" ToolTip="单击显示 DeepSeek Harness · 拖动移动 · 右键设置"/>
  </Grid>
 </Canvas>
</Window>
'@
$script:Window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $Xaml))
Update-FatFishTheme -Target $script:Window | Out-Null
foreach ($Name in @('Scene','BubbleRegion','CollapsedBubbles','ExpandedPanel','ExpandedBubbles','PetGroup','PetImage','PetScale','PetRotate','PetTranslate')) {
    Set-Variable -Name $Name -Scope Script -Value $script:Window.FindName($Name)
}
$ImagePath = Join-Path $Assets 'assets\fatfish.png'
if (-not (Test-Path -LiteralPath $ImagePath)) { throw "Pet image is missing: $ImagePath" }
$script:Sprites = @{}
foreach ($Sprite in @('idle', 'hover', 'drag', 'blink')) {
    $SpritePath = Join-Path $Assets ('assets\fatfish-' + $Sprite + '.png')
    if (-not (Test-Path -LiteralPath $SpritePath)) { $SpritePath = $ImagePath }
    $Bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $Bitmap.BeginInit()
    $Bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $Bitmap.UriSource = New-Object Uri([IO.Path]::GetFullPath($SpritePath))
    $Bitmap.EndInit()
    $Bitmap.Freeze()
    $script:Sprites[$Sprite] = $Bitmap
}
$script:SpriteAspect = [double]$script:Sprites.idle.PixelHeight / [double]$script:Sprites.idle.PixelWidth
$script:PetImage.Source = $script:Sprites.idle

function Set-PetSprite([string] $Name) {
    if ($script:Sprites.ContainsKey($Name)) { $script:PetImage.Source = $script:Sprites[$Name] }
}

function Get-WorkArea {
    $Source = [Windows.PresentationSource]::FromVisual($script:Window)
    if ($Source -and $Source.CompositionTarget) {
        $ScaleX = $Source.CompositionTarget.TransformToDevice.M11
        $ScaleY = $Source.CompositionTarget.TransformToDevice.M22
        $Screen = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position)
        $Area = $Screen.WorkingArea
        return New-Object Windows.Rect(($Area.Left / $ScaleX), ($Area.Top / $ScaleY), ($Area.Width / $ScaleX), ($Area.Height / $ScaleY))
    }
    return [Windows.SystemParameters]::WorkArea
}

function Place-Pet([double] $ScreenX, [double] $ScreenY) {
    $Area = Get-WorkArea
    $Size = [double]$script:Settings.size
    $PetHeight = $Size * $script:SpriteAspect
    $script:Window.Width = [Math]::Min(420, $Area.Width)
    $script:Window.Height = [Math]::Min(720, $Area.Height)
    $ScreenX = [Math]::Max($Area.Left + 4, [Math]::Min($Area.Right - $Size - 4, $ScreenX))
    $ScreenY = [Math]::Max($Area.Top + 4, [Math]::Min($Area.Bottom - $PetHeight - 4, $ScreenY))
    $script:Window.Left = [Math]::Max($Area.Left, [Math]::Min($Area.Right - $script:Window.Width, $ScreenX + $Size / 2 - $script:Window.Width / 2))
    $script:Window.Top = [Math]::Max($Area.Top, [Math]::Min($Area.Bottom - $script:Window.Height, $ScreenY + $PetHeight + 16 - $script:Window.Height))
    $script:PetX = $ScreenX - $script:Window.Left
    $script:PetY = $ScreenY - $script:Window.Top
    $script:PetGroup.Width = $Size
    $script:PetGroup.Height = $PetHeight
    [Windows.Controls.Canvas]::SetLeft($script:PetGroup, $script:PetX)
    [Windows.Controls.Canvas]::SetTop($script:PetGroup, $script:PetY)
    Layout-Bubbles
}

function Stop-PetAnimation {
    $script:PetScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $script:PetScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $script:PetRotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null)
    $script:PetTranslate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $null)
    $script:PetScale.ScaleX = 1
    $script:PetScale.ScaleY = 1
    $script:PetRotate.Angle = 0
    $script:PetTranslate.Y = 0
}

function Start-PetIdle {
    Stop-PetAnimation
    if ($script:PetGroup.IsMouseOver) { Set-PetSprite 'hover' } else { Set-PetSprite 'idle' }
    if (-not $script:Settings.animations -or $script:Dragging) { return }
    $Breath = New-Object Windows.Media.Animation.DoubleAnimation
    $Breath.From = 0; $Breath.To = -4; $Breath.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(1.8))
    $Breath.AutoReverse = $true; $Breath.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $Breath.EasingFunction = New-Object Windows.Media.Animation.SineEase
    $script:PetTranslate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $Breath)
    $Scale = New-Object Windows.Media.Animation.DoubleAnimation
    $Scale.From = 1; $Scale.To = 1.015; $Scale.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(1.8))
    $Scale.AutoReverse = $true; $Scale.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $script:PetScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $Scale)
}

function Start-PetGreeting {
    Set-PetSprite 'hover'
    if (-not $script:Settings.animations -or $script:Dragging) { return }
    Stop-PetAnimation
    $Wave = New-Object Windows.Media.Animation.DoubleAnimation
    $Wave.From = -4; $Wave.To = 4; $Wave.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(.17))
    $Wave.AutoReverse = $true; $Wave.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::new(2)
    $script:PetRotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $Wave)
    $Bounce = New-Object Windows.Media.Animation.DoubleAnimation
    $Bounce.From = 0; $Bounce.To = -11; $Bounce.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(.22)); $Bounce.AutoReverse = $true
    $Bounce.EasingFunction = New-Object Windows.Media.Animation.SineEase
    $script:PetTranslate.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $Bounce)
    $script:IdleResumeAt = [DateTime]::UtcNow.AddMilliseconds(750)
}

function Start-PetDrop {
    Set-PetSprite 'idle'
    $Angle = $script:PetRotate.Angle
    Stop-PetAnimation
    if (-not $script:Settings.animations) { return }
    $Spring = New-Object Windows.Media.Animation.ElasticEase
    $Spring.Oscillations = 2; $Spring.Springiness = 4; $Spring.EasingMode = 'EaseOut'
    $Swing = New-Object Windows.Media.Animation.DoubleAnimation
    $Swing.From = $Angle; $Swing.To = 0; $Swing.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(.65)); $Swing.EasingFunction = $Spring
    $script:PetRotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $Swing)
    $Drop = New-Object Windows.Media.Animation.DoubleAnimation
    $Drop.From = .9; $Drop.To = 1; $Drop.Duration = [Windows.Duration]::new([TimeSpan]::FromSeconds(.5)); $Drop.EasingFunction = $Spring
    $script:PetScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $Drop)
    $script:IdleResumeAt = [DateTime]::UtcNow.AddMilliseconds(750)
}

function Show-Harness {
    try {
        $Install = Join-Path $env:USERPROFILE 'AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'
        if (-not (Test-Path -LiteralPath $Install)) { $Install = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe' }
        if (-not (Test-Path -LiteralPath $Install)) { throw 'DeepSeek Harness executable was not found.' }
        $Info = New-Object Diagnostics.ProcessStartInfo
        $Info.FileName = $Install
        $Info.UseShellExecute = $false; $Info.CreateNoWindow = $true; $Info.WindowStyle = 'Hidden'
        $Info.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
        [Diagnostics.Process]::Start($Info) | Out-Null
        foreach ($Process in @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero -and $Process.Path -eq $Install) {
                [FatFishBridgeHttp]::ShowWindowAsync($Process.MainWindowHandle, 9) | Out-Null
                [FatFishBridgeHttp]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
            }
        }
    } catch { Write-NativeLog ('Focus failed: ' + $_.Exception.GetType().Name) }
}

function Open-Session([string] $SessionId) {
    $script:NavigationSerial++
    $script:PendingNavigation.Clear()
    Show-Harness
    if (-not $script:Descriptor -or -not $SessionId) { Write-NativeLog 'Navigation is unavailable while the bridge is disconnected.'; return }
    try {
        $Body = @{ type = 'open-session'; sessionId = $SessionId } | ConvertTo-Json -Compress
        $Task = [FatFishBridgeHttp]::Post($script:Http, ('http://127.0.0.1:' + $script:Descriptor.port + '/v1/action'), $script:Descriptor.token, $Body)
        $script:ActionTasks.Add([pscustomobject]@{ task = $Task; sessionId = $SessionId; serial = $script:NavigationSerial; requestedAt = [DateTime]::UtcNow }) | Out-Null
    } catch { Write-NativeLog 'Navigation could not be queued.' }
}

function Get-NavigationFailureText([string] $Reason) {
    switch ($Reason) {
        'no-client' { return '已显示 DSH；聊天界面连接后可再次点击。' }
        'client-timeout' { return 'DSH 尚未响应跳转，请再次点击气泡。' }
        'unknown-session' { return '此聊天已关闭，请在 DSH 中查看。' }
        'queue-full' { return '跳转请求较多，请稍后再试。' }
        default { return '暂时无法跳转到聊天，请在 DSH 中查看。' }
    }
}

function Complete-NavigationAck($Ack) {
    if (-not $Ack -or -not $Ack.id -or -not $script:PendingNavigation.ContainsKey([string]$Ack.id)) { return }
    $script:PendingNavigation.Remove([string]$Ack.id)
    if ($Ack.ok -ne $true) { Write-NativeLog (Get-NavigationFailureText ([string]$Ack.reason)) }
}

function Get-FatFishDisplayRows($Rows) {
    # A chat has one bubble even when its Agent also owns background jobs.
    # Keep execution counts separately so no live work disappears from the badge.
    $Groups = [ordered]@{}
    $Seen = @{}
    foreach ($Row in @($Rows)) {
        if (-not $Row -or -not $Row.sessionId -or $Row.status -notin @('running', 'waiting')) { continue }
        $SessionId = [string]$Row.sessionId
        $Identity = if ($Row.id) { [string]$Row.id } else { $SessionId + '/' + [string]$Row.kind + '/' + [string]$Row.startedAt }
        if ($Seen.ContainsKey($Identity)) { continue }
        $Seen[$Identity] = $true
        if (-not $Groups.Contains($SessionId)) { $Groups[$SessionId] = New-Object Collections.ArrayList }
        $Groups[$SessionId].Add($Row) | Out-Null
    }
    foreach ($SessionId in $Groups.Keys) {
        $Items = @($Groups[$SessionId])
        $Primary = $Items | Where-Object { $_.kind -eq 'turn' } | Select-Object -First 1
        if (-not $Primary) { $Primary = $Items | Sort-Object updatedAt -Descending | Select-Object -First 1 }
        $Copy = [ordered]@{}
        foreach ($Property in $Primary.PSObject.Properties) { $Copy[$Property.Name] = $Property.Value }
        $Copy['activityCount'] = $Items.Count
        $PrimaryAction = Get-BubbleAction $Primary
        $Copy['action'] = $PrimaryAction
        # A registry poll refreshes job.updatedAt even when its work did not
        # change. Preserve the turn's specific action; only a generic turn
        # status may borrow a more useful owned-job action.
        if ($PrimaryAction -in @('正在思考下一步', '正在生成回复', '正在执行', '正在执行…', '正在执行工具', '思考中', '正在回答')) {
            foreach ($Item in @($Items | Where-Object { $_.kind -eq 'job' } | Sort-Object updatedAt -Descending)) {
                $JobAction = Get-BubbleAction $Item
                if ($JobAction -and $JobAction -notin @('正在执行', '正在执行…', '正在执行后台任务')) { $Copy['action'] = $JobAction; break }
            }
        }
        if (@($Items | Where-Object { $_.status -eq 'waiting' }).Count -gt 0) { $Copy['status'] = 'waiting'; $Copy['label'] = '等待确认'; $Copy['action'] = '等待确认' }
        [pscustomobject]$Copy
    }
}

function Get-BubbleAction($Row) {
    # `action` is a dedicated backend field derived from public execution
    # metadata. Never turn reasoning, answer text or old activity into a label.
    if ($Row.status -eq 'waiting') { return '等待确认' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.action)) {
        return [Text.RegularExpressions.Regex]::Replace(([string]$Row.action).Trim(), '\s+', ' ')
    }
    if ($Row.textKind -in @('cot', 'reasoning', 'thinking')) { return '正在思考下一步' }
    if ($Row.textKind -eq 'output') { return '正在生成回复' }
    if ($Row.kind -eq 'job') { return '正在执行后台任务' }
    if ($Row.textKind -eq 'tool') {
        # Older bridges expose only the tool name in detail. Take its leading
        # name token, never raw arguments, JSON, code or result text.
        $Name = [Text.RegularExpressions.Regex]::Match(([string]$Row.detail), '^[\p{L}\p{N}_.-]{1,48}(?=\s|$)').Value
        if ($Name) { return '正在执行工具 · ' + $Name }
        return '正在执行工具'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.label)) { return [Text.RegularExpressions.Regex]::Replace(([string]$Row.label).Trim(), '\s+', ' ') }
    return '正在执行'
}

function New-BubbleCard($Row, [bool] $Compact) {
    $Card = New-Object Windows.Controls.Border
    $Card.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, $script:Window.FontFamily)
    $Card.CornerRadius = New-Object Windows.CornerRadius(32)
    $Card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'FatFish.BubbleSurface')
    $Card.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'FatFish.BubbleBorder')
    $Card.BorderThickness = New-Object Windows.Thickness(1)
    $Card.Width = 326
    $Card.Height = $script:BubbleCardHeight
    $Card.Padding = New-Object Windows.Thickness(17, 11, 17, 12)
    $Card.Margin = New-Object Windows.Thickness(0)
    $Card.Cursor = [Windows.Input.Cursors]::Hand
    $Card.Tag = [string]$Row.sessionId
    $Card.ToolTip = if ($Compact -and $script:Tasks.Count -gt 1) { '单击打开此聊天 · 悬停展开 ' + $script:Tasks.Count + ' 个聊天' } else { '单击打开此聊天' }
    $Effect = New-Object Windows.Media.Effects.DropShadowEffect
    $Effect.BlurRadius = 14; $Effect.ShadowDepth = 3; $Effect.Opacity = [double]$script:Window.Resources['FatFish.ShadowOpacity'] * .7; $Effect.Color = $script:Window.Resources['FatFish.ShadowColor']
    $Card.Effect = $Effect
    $Stack = New-Object Windows.Controls.StackPanel
    $Heading = New-Object Windows.Controls.TextBlock
    $Title = if ($Row.title) { [string]$Row.title } elseif ($Row.kind -eq 'job') { '后台任务' } else { '正在执行的聊天' }
    $Heading.Text = $Title
    $Heading.FontSize = 12.5; $Heading.LineHeight = 18; $Heading.FontWeight = 'SemiBold'; $Heading.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'FatFish.BubbleText')
    $Heading.Height = 18; $Heading.TextWrapping = 'NoWrap'; $Heading.TextTrimming = 'CharacterEllipsis'; $Heading.Margin = New-Object Windows.Thickness(0, 0, 0, 3)
    $Stack.Children.Add($Heading) | Out-Null
    $Body = New-Object Windows.Controls.TextBlock
    $Body.FontSize = 12; $Body.LineHeight = 17; $Body.Height = 17
    $Body.TextWrapping = 'NoWrap'; $Body.TextTrimming = 'CharacterEllipsis'; $Body.ClipToBounds = $true
    $Body.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'FatFish.BubbleTextMuted')
    $Body.Text = Get-BubbleAction $Row
    $Stack.Children.Add($Body) | Out-Null
    $Card.Child = $Stack
    $Card.Add_MouseEnter({
        param($Sender, $Event)
        $Sender.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'FatFish.BubbleHover')
        if ($Sender.FindResource('FatFish.IsHighContrast')) {
            $Sender.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'FatFish.BubbleBorder')
        } else {
            $Sender.BorderBrush = $Sender.FindResource('FatFish.Highlight').Clone()
        }
    })
    $Card.Add_MouseMove({
        param($Sender, $Event)
        if ($Sender.BorderBrush -is [Windows.Media.RadialGradientBrush] -and -not $Sender.BorderBrush.IsFrozen -and $Sender.ActualWidth -gt 0 -and $Sender.ActualHeight -gt 0) {
            $Point = $Event.GetPosition($Sender)
            $LightPosition = New-Object Windows.Point(($Point.X / $Sender.ActualWidth), ($Point.Y / $Sender.ActualHeight))
            $Sender.BorderBrush.Center = $LightPosition
            $Sender.BorderBrush.GradientOrigin = $LightPosition
        }
    })
    $Card.Add_MouseLeave({
        param($Sender, $Event)
        $Sender.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'FatFish.BubbleSurface')
        $Sender.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'FatFish.BubbleBorder')
    })
    $Card.Add_MouseLeftButtonUp({ param($Sender, $Event); Open-Session ([string]$Sender.Tag); $Event.Handled = $true })
    return $Card
}

function Layout-Bubbles {
    if (-not $script:BubbleRegion) { return }
    $Area = Get-WorkArea
    $ScreenPetX = $script:Window.Left + $script:PetX
    $ScreenPetY = $script:Window.Top + $script:PetY
    $PetHeight = $script:PetGroup.Height
    $Count = [Math]::Max(1, $script:Tasks.Count)
    $Step = $script:BubbleCardHeight + $script:BubbleCardGap
    $AvailableAbove = [Math]::Max(0, $ScreenPetY - $Area.Top - 16)
    $AvailableBelow = [Math]::Max(0, $Area.Bottom - $ScreenPetY - $PetHeight - 15)
    $Below = $AvailableBelow -gt $AvailableAbove
    $Available = [Math]::Max($AvailableAbove, $AvailableBelow)
    $RowCapacity = [Math]::Max(1, [int][Math]::Floor(([Math]::Min(500, $Available) + $script:BubbleCardGap) / $Step))
    $Rows = [Math]::Min($Count, $RowCapacity)
    $Columns = [int][Math]::Ceiling($Count / [double]$Rows)
    $ExpandedWidth = $Columns * 332 - $script:BubbleCardGap
    $CardsHeight = $Rows * $Step - $script:BubbleCardGap
    # Reserve the layout for all cards in both states. Only chat count or the
    # pet's placement affects geometry; description length cannot resize it.
    $WindowWidth = [Math]::Min($Area.Width, [Math]::Max(420, $ExpandedWidth + 30))
    $WindowHeight = [Math]::Min($Area.Height, [Math]::Max(720, $CardsHeight + $PetHeight + 35))
    if ($script:Window.Width -ne $WindowWidth -or $script:Window.Height -ne $WindowHeight) {
        $script:Window.Width = $WindowWidth; $script:Window.Height = $WindowHeight
    }
    $NewLeft = [Math]::Max($Area.Left, [Math]::Min($Area.Right - $WindowWidth, $ScreenPetX + $script:Settings.size / 2 - $WindowWidth / 2))
    $DesiredTop = if ($Below) { $ScreenPetY - 16 } else { $ScreenPetY + $PetHeight + 16 - $WindowHeight }
    $NewTop = [Math]::Max($Area.Top, [Math]::Min($Area.Bottom - $WindowHeight, $DesiredTop))
    $script:Window.Left = $NewLeft; $script:Window.Top = $NewTop
    $script:PetX = $ScreenPetX - $NewLeft; $script:PetY = $ScreenPetY - $NewTop
    [Windows.Controls.Canvas]::SetLeft($script:PetGroup, $script:PetX)
    [Windows.Controls.Canvas]::SetTop($script:PetGroup, $script:PetY)
    $Width = if ($script:Expanded) { $ExpandedWidth + 10 } else { 336 }
    $script:BubbleRegion.Width = $Width
    $script:ExpandedPanel.Width = $ExpandedWidth
    $script:ExpandedPanel.Height = $CardsHeight
    $script:ExpandedBubbles.Width = $Columns * 332
    $script:ExpandedBubbles.Height = $Rows * $Step
    $Left = [Math]::Max(10, [Math]::Min($script:Window.Width - $Width - 10, $script:PetX + $script:Settings.size / 2 - $Width / 2))
    [Windows.Controls.Canvas]::SetLeft($script:BubbleRegion, $Left)
    $script:BubbleBelow = $Below
    $Layers = [Math]::Min(3, [Math]::Max(1, $script:Tasks.Count))
    $CompactHeight = $script:BubbleCardHeight + ($Layers - 1) * 4
    $Height = if ($script:Expanded) { $CardsHeight } else { $CompactHeight }
    $script:BubbleRegion.Height = $Height
    $Top = if ($Below) { $script:PetY + $script:PetGroup.Height + 8 } else { $script:PetY - $Height - 11 }
    [Windows.Controls.Canvas]::SetTop($script:BubbleRegion, [Math]::Max(4, $Top))
}

function Render-Bubbles([bool] $Force = $false) {
    Layout-Bubbles
    $Signature = ($script:Tasks | ConvertTo-Json -Depth 5 -Compress) + ':' + $script:Expanded
    if (-not $Force -and $Signature -eq $script:BubbleSignature) { return }
    $script:BubbleSignature = $Signature
    if ($script:Tasks.Count -eq 0) { $script:BubbleRegion.Visibility = 'Collapsed'; $script:Expanded = $false; return }
    $script:BubbleRegion.Visibility = 'Visible'
    $script:CollapsedBubbles.Children.Clear()
    $script:ExpandedBubbles.Children.Clear()
    if ($script:Expanded) {
        $script:CollapsedBubbles.Visibility = 'Collapsed'; $script:ExpandedPanel.Visibility = 'Visible'
        for ($Index = 0; $Index -lt $script:Tasks.Count; $Index++) {
            $Card = New-BubbleCard $script:Tasks[$Index] $false
            $Card.Margin = New-Object Windows.Thickness(0, 0, $script:BubbleCardGap, $script:BubbleCardGap)
            $script:ExpandedBubbles.Children.Add($Card) | Out-Null
        }
    } else {
        $script:CollapsedBubbles.Visibility = 'Visible'; $script:ExpandedPanel.Visibility = 'Collapsed'
        $Layers = [Math]::Min(3, $script:Tasks.Count)
        $Card = New-BubbleCard $script:Tasks[0] $true
        for ($Index = $Layers - 1; $Index -ge 1; $Index--) {
            $Back = New-Object Windows.Controls.Border
            $Back.Width = $Card.Width - $Index * 8; $Back.Height = $script:BubbleCardHeight
            $Back.CornerRadius = New-Object Windows.CornerRadius(32)
            $Back.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $(if ($Index -eq 1) { 'FatFish.BubbleLayerNear' } else { 'FatFish.BubbleLayerFar' }))
            $Back.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'FatFish.BubbleBorder'); $Back.BorderThickness = New-Object Windows.Thickness(1)
            $Back.IsHitTestVisible = $false
            [Windows.Controls.Canvas]::SetLeft($Back, $Index * 4); [Windows.Controls.Canvas]::SetTop($Back, $Index * 4)
            $script:CollapsedBubbles.Children.Add($Back) | Out-Null
        }
        $script:CollapsedBubbles.Children.Add($Card) | Out-Null
    }
    Layout-Bubbles
}

function Set-Disconnected {
    $script:Tasks = @()
    Render-Bubbles $true
    $script:PetImage.ToolTip = '正在连接 DSH 插件 · 单击显示 DSH'
}

function Apply-Settings {
    $OldSize = $script:LastPetSize
    $ScreenX = $script:Window.Left + $script:PetX + ($OldSize - $script:Settings.size) / 2
    $ScreenY = $script:Window.Top + $script:PetY + ($OldSize - $script:Settings.size) * $script:SpriteAspect
    $script:Window.Opacity = $script:Settings.opacity
    Place-Pet $ScreenX $ScreenY
    Update-SavedPosition
    $script:LastPetSize = [double]$script:Settings.size
    Start-PetIdle
    Render-Bubbles $true
}

function Update-SavedPosition([bool] $Persist = $false) {
    $script:Settings.position = @{
        x = [Math]::Round($script:Window.Left + $script:PetX)
        y = [Math]::Round($script:Window.Top + $script:PetY)
        windowLeft = [Math]::Round($script:Window.Left)
        windowTop = [Math]::Round($script:Window.Top)
    }
    if ($Persist) { Save-FatFishSettings $script:Settings $script:SettingsPath }
}

function Open-Settings {
    if ($script:SettingsOpen) { return }
    $script:SettingsOpen = $true
    try { Show-FatFishSettings -Owner $script:Window -Settings $script:Settings -Path $script:SettingsPath -OnChanged { Apply-Settings } }
    finally { $script:SettingsOpen = $false }
}

$Context = New-Object Windows.Controls.ContextMenu
$Context.Style = $script:Window.FindResource('FatFish.ContextMenuStyle')
Update-FatFishTheme -Target $Context | Out-Null
$SettingsItem = New-Object Windows.Controls.MenuItem
$SettingsItem.Style = $script:Window.FindResource('FatFish.MenuItemStyle')
$SettingsItem.Header = '宠物设置'; $SettingsItem.Add_Click({ Open-Settings })
$FocusItem = New-Object Windows.Controls.MenuItem
$FocusItem.Style = $script:Window.FindResource('FatFish.MenuItemStyle')
$FocusItem.Header = '显示DSH'; $FocusItem.Add_Click({ Show-Harness })
$Context.Items.Add($SettingsItem) | Out-Null; $Context.Items.Add($FocusItem) | Out-Null
$script:PetGroup.ContextMenu = $Context
$script:PetGroup.Add_MouseEnter({ Start-PetGreeting })
$script:PetGroup.Add_MouseLeave({ if (-not $script:Pressed) { Set-PetSprite 'idle' } })
$script:PetGroup.Add_MouseLeftButtonDown({
    param($Sender, $Event)
    $script:Pressed = $true; $script:Dragging = $false
    $script:DownCursor = [Windows.Forms.Cursor]::Position
    $script:DownLeft = $script:Window.Left; $script:DownTop = $script:Window.Top
    $Source = [Windows.PresentationSource]::FromVisual($script:Window)
    $script:DragScaleX = $Source.CompositionTarget.TransformToDevice.M11; $script:DragScaleY = $Source.CompositionTarget.TransformToDevice.M22
    $script:PetGroup.CaptureMouse() | Out-Null
    $Event.Handled = $true
})
$script:PetGroup.Add_MouseMove({
    if (-not $script:Pressed) { return }
    $Point = [Windows.Forms.Cursor]::Position
    $Dx = ($Point.X - $script:DownCursor.X) / $script:DragScaleX
    $Dy = ($Point.Y - $script:DownCursor.Y) / $script:DragScaleY
    if (-not $script:Dragging -and ([Math]::Abs($Dx) -ge 5 -or [Math]::Abs($Dy) -ge 5)) { $script:Dragging = $true; Stop-PetAnimation; Set-PetSprite 'drag' }
    if ($script:Dragging) {
        $script:Window.Left = $script:DownLeft + $Dx; $script:Window.Top = $script:DownTop + $Dy
        if ($script:Settings.animations) { $script:PetRotate.Angle = [Math]::Max(-13, [Math]::Min(13, $Dx * .13)) }
    }
})
$script:PetGroup.Add_MouseLeftButtonUp({
    param($Sender, $Event)
    if (-not $script:Pressed) { return }
    $WasDragging = $script:Dragging
    $script:Pressed = $false; $script:Dragging = $false
    $script:PetGroup.ReleaseMouseCapture()
    if ($WasDragging) {
        Place-Pet ($script:Window.Left + $script:PetX) ($script:Window.Top + $script:PetY)
        Update-SavedPosition $true
        Start-PetDrop
    } else { Show-Harness; Start-PetGreeting }
    $Event.Handled = $true
})
$script:PetGroup.Add_LostMouseCapture({
    if ($script:Pressed) { $script:Pressed = $false; $script:Dragging = $false; Start-PetIdle }
})
$script:BubbleRegion.Add_MouseEnter({
    $script:CollapseAt = [DateTime]::MaxValue
    if (-not $script:Expanded) { $script:Expanded = $true; Render-Bubbles $true }
})
$script:BubbleRegion.Add_MouseLeave({ $script:CollapseAt = [DateTime]::UtcNow.AddMilliseconds(250) })

$Area = [Windows.SystemParameters]::WorkArea
$StartX = $Area.Right - $script:Settings.size - 35
$StartY = $Area.Bottom - $script:Settings.size * $script:SpriteAspect - 23
if ($script:Settings.position -and $null -ne $script:Settings.position.x -and $null -ne $script:Settings.position.y) {
    $StartX = [double]$script:Settings.position.x; $StartY = [double]$script:Settings.position.y
}
Place-Pet $StartX $StartY
$script:Window.Opacity = $script:Settings.opacity

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:Timer.Add_Tick({
    $Now = [DateTime]::UtcNow
    try {
        if ($Now -ge $script:NextThemePollAt) {
            $script:NextThemePollAt = $Now.AddSeconds(1)
            if (Update-FatFishTheme -Target $script:Window) { Render-Bubbles $true }
            Update-FatFishTheme -Target $Context | Out-Null
        }
        if ($script:IdleResumeAt -ne [DateTime]::MinValue -and $Now -ge $script:IdleResumeAt) { $script:IdleResumeAt = [DateTime]::MinValue; Start-PetIdle }
        if ($script:Settings.animations -and -not $script:Pressed -and -not $script:PetGroup.IsMouseOver) {
            if ($script:BlinkUntil -ne [DateTime]::MinValue -and $Now -ge $script:BlinkUntil) { $script:BlinkUntil = [DateTime]::MinValue; Set-PetSprite 'idle' }
            if ($Now -ge $script:NextBlinkAt) { Set-PetSprite 'blink'; $script:BlinkUntil = $Now.AddMilliseconds(160); $script:NextBlinkAt = $Now.AddSeconds(5.4) }
        }
        if ($script:Expanded -and $Now -ge $script:CollapseAt -and -not $script:BubbleRegion.IsMouseOver) { $script:Expanded = $false; $script:CollapseAt = [DateTime]::MaxValue; Render-Bubbles $true }
        foreach ($Action in @($script:ActionTasks)) {
            if ($Action.task.IsCompleted) {
                try {
                    $Result = $Action.task.GetAwaiter().GetResult() | ConvertFrom-Json
                    if ($Action.serial -eq $script:NavigationSerial) {
                        if (-not $Result.ok) { Write-NativeLog (Get-NavigationFailureText ([string]$Result.reason)) }
                        elseif ($Result.commandId) { $script:PendingNavigation[[string]$Result.commandId] = $Now }
                    }
                } catch { Write-NativeLog 'Navigation request failed.' }
                $script:ActionTasks.Remove($Action)
            }
        }
        foreach ($CommandId in @($script:PendingNavigation.Keys)) {
            if (($Now - $script:PendingNavigation[$CommandId]).TotalSeconds -gt 17) { $script:PendingNavigation.Remove($CommandId); Write-NativeLog (Get-NavigationFailureText 'client-timeout') }
        }
        if ($script:PollTask -and $script:PollTask.IsCompleted) {
            try {
                $script:Snapshot = $script:PollTask.GetAwaiter().GetResult() | ConvertFrom-Json
                $script:LastSuccessAt = $Now
                $script:Tasks = @(Get-FatFishDisplayRows $script:Snapshot.tasks)
                $script:ExecutionCount = 0
                foreach ($Row in $script:Tasks) { $script:ExecutionCount += [int]$Row.activityCount }
                Render-Bubbles
                Complete-NavigationAck $script:Snapshot.lastAction
                $script:PetImage.ToolTip = [string]$script:Snapshot.pet.label + ' · 单击显示 DSH · 拖动移动 · 右键设置'
            } catch { if (($Now - $script:LastSuccessAt).TotalSeconds -gt 2) { Set-Disconnected } }
            $script:PollTask = $null
        }
        if ($Now -ge $script:NextPollAt -and -not $script:PollTask) {
            $script:NextPollAt = $Now.AddMilliseconds(500)
            try {
                $NewDescriptor = [IO.File]::ReadAllText($DiscoveryPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($NewDescriptor.host -ne '127.0.0.1' -or [int]$NewDescriptor.port -lt 1 -or [int]$NewDescriptor.port -gt 65535 -or [int]$NewDescriptor.pid -lt 1 -or [string]$NewDescriptor.token -notmatch '^[0-9a-f]{64}$') { throw 'Invalid descriptor.' }
                $script:Descriptor = $NewDescriptor; $script:LastDescriptorAt = $Now
                $script:PollTask = [FatFishBridgeHttp]::Get($script:Http, ('http://127.0.0.1:' + $script:Descriptor.port + '/v1/state'), $script:Descriptor.token)
            } catch {
                Set-Disconnected
                if (($Now - $script:LastDescriptorAt).TotalSeconds -gt 8) { $script:Window.Close(); return }
            }
        }
        if ($Now -ge $script:NextPidCheckAt -and $script:Descriptor) {
            $script:NextPidCheckAt = $Now.AddSeconds(1)
            try { $HostProcess = [Diagnostics.Process]::GetProcessById([int]$script:Descriptor.pid); if ($HostProcess.HasExited) { $script:Window.Close(); return }; $HostProcess.Dispose() }
            catch { $script:Window.Close(); return }
        }
    } catch { Write-NativeLog ('UI update failed: ' + $_.Exception.GetType().Name) }
})
$script:Window.Add_Loaded({ Start-PetIdle; $script:Timer.Start() })
$script:Window.Add_Closed({
    $script:Closed = $true
    $script:Timer.Stop()
    $script:Http.Dispose()
    Write-NativeLog 'Native pet stopped.'
})
if ($ValidateOnly) {
    $script:Http.Dispose()
    Write-Output 'Native WPF XAML, assets, bridge HTTP client, settings and event registration are valid.'
    return
}
Write-NativeLog 'Native pet started.'
$script:Window.ShowDialog() | Out-Null
