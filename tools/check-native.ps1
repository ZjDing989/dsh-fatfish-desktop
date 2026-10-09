[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this check with: powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File tools\check-native.ps1'
}
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$NativeRoot = Join-Path $ProjectRoot 'plugin\native'
$CheckRoot = Join-Path $ProjectRoot '.data\native-check'
[IO.Directory]::CreateDirectory($CheckRoot) | Out-Null
$Results = New-Object Collections.ArrayList

function Assert-Native([bool] $Condition, [string] $Name) {
    if (-not $Condition) { throw "Native regression failed: $Name" }
    $Results.Add($Name) | Out-Null
    Write-Host "PASS $Name"
}

foreach ($FileName in @('pet.ps1', 'native-settings.ps1', 'native-theme.ps1')) {
    $FilePath = Join-Path $NativeRoot $FileName
    $Bytes = [IO.File]::ReadAllBytes($FilePath)
    Assert-Native ($Bytes.Length -gt 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) "$FileName UTF-8 BOM"
    $Tokens = $null; $ParseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$Tokens, [ref]$ParseErrors) | Out-Null
    Assert-Native ($ParseErrors.Count -eq 0) "$FileName PowerShell syntax"
}

# ValidateOnly constructs the WPF controls and HTTP client without showing a
# window, launching Harness, or connecting to a running profile.
. (Join-Path $NativeRoot 'pet.ps1') -DiscoveryPath (Join-Path $CheckRoot 'bridge.json') -Assets $NativeRoot -ValidateOnly
# A headless layout drain can still raise WPF Loaded and run the production
# handler. Isolate that timer before pumping the Dispatcher: this test has no
# real descriptor and must never clear its simulated rows as disconnected.
$script:Timer.Stop()
$script:Timer.Interval = [TimeSpan]::FromDays(1)

$LightTheme = [pscustomobject]@{ IsDark=$false; HighContrast=$false; Accent='#FF0078D4' }
$DarkTheme = [pscustomobject]@{ IsDark=$true; HighContrast=$false; Accent='#FF0078D4' }
Update-FatFishTheme -Target $script:Window -Theme $LightTheme | Out-Null
$LiveText = New-Object Windows.Controls.TextBlock
$LiveText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'FatFish.Text')
$script:Scene.Children.Add($LiveText) | Out-Null
$LightText = $LiveText.Foreground.Color.ToString()
Update-FatFishTheme -Target $script:Window -Theme $DarkTheme | Out-Null
Assert-Native ($LiveText.Foreground.Color.ToString() -ne $LightText -and -not (Update-FatFishTheme -Target $script:Window -Theme $DarkTheme)) 'existing controls follow theme changes without redundant updates'
$ChangedAccent = [pscustomobject]@{ IsDark=$true; HighContrast=$false; Accent='#FF9164C5' }
Update-FatFishTheme -Target $script:Window -Theme $ChangedAccent | Out-Null
Assert-Native ($script:Window.Resources['FatFish.Accent'].Color.ToString() -eq '#FF9164C5') 'system accent palette can update independently of app mode'
$ContrastTheme = [pscustomobject]@{ IsDark=$true; HighContrast=$true; Accent='#FF0078D4'; WindowColor='#FF000000'; WindowTextColor='#FFFFFFFF'; HighlightColor='#FFFFFF00'; HighlightTextColor='#FF000000' }
Update-FatFishTheme -Target $script:Window -Theme $ContrastTheme | Out-Null
Assert-Native ($LiveText.Foreground.Color.ToString() -eq '#FFFFFFFF' -and $script:Window.Resources['FatFish.Surface'] -is [Windows.Media.SolidColorBrush] -and $script:Window.Resources['FatFish.ShadowOpacity'] -eq 0) 'high contrast uses readable system colors without decorative shadows'
$script:Scene.Children.Remove($LiveText)
Update-FatFishTheme -Target $script:Window | Out-Null

$LongText = 'actual stream ' * 170
$Rows = @(
    [pscustomobject]@{ id='agent:a'; sessionId='a'; title='Chat A'; label='Thinking'; action='正在检查代码'; kind='turn'; status='running'; textKind='cot'; reasoning=$LongText; output=''; detail=''; updatedAt=1 },
    [pscustomobject]@{ id='job:1'; sessionId='a'; title='Chat A'; label='Tool'; action='正在读取文件'; kind='job'; status='running'; textKind='tool'; detail='read_file'; updatedAt=2 },
    [pscustomobject]@{ id='agent:b'; sessionId='b'; title='Chat B'; label='Waiting'; action='正在生成回复'; kind='turn'; status='waiting'; textKind='output'; output='Answer'; updatedAt=3 }
)
$Display = @(Get-FatFishDisplayRows $Rows)
Assert-Native ($Display.Count -eq 2 -and $Display[0].activityCount -eq 2 -and $Display[1].activityCount -eq 1) 'one bubble per chat with execution counts'
$ExpandedCard = New-BubbleCard $Display[0] $false
Assert-Native ($ExpandedCard.Child.Children.Count -eq 2 -and $ExpandedCard.Child.Children[1] -is [Windows.Controls.TextBlock] -and $ExpandedCard.Child.Children[0].Text -eq 'Chat A' -and $ExpandedCard.Child.Children[1].Text -match '^正在') 'expanded bubble retains its title and shows a one-line action without a scrolling body'

function Get-BubbleVisibleText($Element) {
    if (-not $Element -or $Element.Visibility -eq [Windows.Visibility]::Collapsed) { return }
    if ($Element -is [Windows.Controls.TextBlock]) { return $Element.Text }
    if ($Element -is [Windows.Controls.Border]) { Get-BubbleVisibleText $Element.Child }
    elseif ($Element -is [Windows.Controls.Panel]) { foreach ($Child in $Element.Children) { Get-BubbleVisibleText $Child } }
}
$EmptyRow = [pscustomobject]@{ sessionId='empty'; title='你好'; label='思考中'; kind='turn'; status='running'; textKind='cot'; reasoning=''; output=''; detail=''; text=''; activity=''; activityKind='' }
$EmptyCard = New-BubbleCard $EmptyRow $true
$EmptyCard.Width = 326
$EmptyCard.Measure((New-Object Windows.Size(326, [double]::PositiveInfinity)))
$EmptyCard.Arrange((New-Object Windows.Rect(0,0,326,$EmptyCard.DesiredSize.Height)))
$EmptyTexts = @(Get-BubbleVisibleText $EmptyCard)
Assert-Native ($EmptyTexts.Count -eq 2 -and $EmptyTexts[0] -eq '你好' -and $EmptyCard.ActualHeight -eq 63) 'empty stream has a title and one action line at fixed height'
$ToolRow = [pscustomobject]@{ sessionId='tool'; title='工具测试'; label='正在执行工具'; action='正在运行命令 · npm run build'; kind='turn'; status='running'; textKind='tool'; reasoning=''; output=''; detail='执行命令：npm run build'; text=''; activity='执行命令：npm run build'; activityKind='tool' }
$ToolCard = New-BubbleCard $ToolRow $true
Assert-Native ((@(Get-BubbleVisibleText $ToolCard) -join ' ') -match 'npm run build') 'compact bubble contains actual tool activity'
foreach ($Compact in @($true, $false)) {
    $ShortCard = New-BubbleCard $EmptyRow $Compact
    $LongCard = New-BubbleCard ([pscustomobject]@{ sessionId='long'; title=('Long title ' * 60); label='思考中'; action=("正在读取文件`n" * 60); kind='turn'; status='running'; textKind='cot'; reasoning=("one line`n" * 500); output=''; detail=''; activity=''; activityKind='cot' }) $Compact
    foreach ($Card in @($ShortCard, $LongCard)) {
        $Card.Measure((New-Object Windows.Size(326, [double]::PositiveInfinity)))
        $Card.Arrange((New-Object Windows.Rect(0,0,326,$Card.DesiredSize.Height)))
    }
    Assert-Native ($ShortCard.ActualHeight -eq 63 -and $LongCard.ActualHeight -eq $ShortCard.ActualHeight -and $LongCard.ActualWidth -eq $ShortCard.ActualWidth -and $LongCard.Child.Children[1].Text -notmatch '[\r\n]') ('short and multiline input have identical single-line card dimensions in compact=' + $Compact)
}
foreach ($Kind in @('cot','output')) {
    $HiddenRow = [pscustomobject]@{ sessionId='hidden'; title='正文隔离'; label='思考中'; action='正在生成回复'; kind='turn'; status='running'; textKind=$Kind; reasoning='hidden reasoning text'; output='answer body text'; detail=''; text='hidden reasoning text'; activity='hidden reasoning text'; activityKind=$Kind }
    foreach ($Compact in @($true,$false)) {
        $HiddenCard = New-BubbleCard $HiddenRow $Compact
        Assert-Native ((@(Get-BubbleVisibleText $HiddenCard) -join ' ') -notmatch 'hidden reasoning text|answer body text' -and $HiddenCard.Child.Children[1].Text -eq '正在生成回复') ('cards display actions instead of cot or answer bodies for kind=' + $Kind + ', compact=' + $Compact)
    }
}
$script:Tasks = $Display
$script:ExecutionCount = 3
Render-Bubbles $true
$script:Expanded = $true
Render-Bubbles $true
Render-Bubbles $true
Assert-Native ($script:ExpandedBubbles.Children.Count -eq 2) 'collapsed, expanded and live rebuild controls'

$script:PendingNavigation['ack-fail'] = [DateTime]::UtcNow
Complete-NavigationAck ([pscustomobject]@{ id='ack-fail'; ok=$false; reason='client-timeout' })
Assert-Native ($script:PendingNavigation.Count -eq 0 -and $null -eq $script:Window.FindName('ActionNotice')) 'navigation failure acknowledgement without a popup'
$script:PendingNavigation['ack-ok'] = [DateTime]::UtcNow
Complete-NavigationAck ([pscustomobject]@{ id='ack-ok'; ok=$true })
Assert-Native ($script:PendingNavigation.Count -eq 0) 'final navigation success acknowledgement'

$MalformedPath = Join-Path $CheckRoot 'malformed-settings.json'
[IO.File]::WriteAllText($MalformedPath, '{"size":"NaN","opacity":"Infinity","position":{"x":"NaN","y":1}}', (New-Object Text.UTF8Encoding($false)))
$Safe = Get-FatFishSettings $MalformedPath
Assert-Native ($Safe.size -eq 180 -and $Safe.opacity -eq 1 -and $null -eq $Safe.position) 'invalid settings fall back to finite defaults'

$SavedPath = Join-Path $CheckRoot 'saved-settings.json'
$Dialog = Show-FatFishSettings -Settings $script:Settings -Path $SavedPath -OnChanged { Apply-Settings } -BuildOnly
$Dialog.FindName('SizeSlider').Value = 208
$Dialog.FindName('OpacitySlider').Value = 88
$Dialog.FindName('AnimationsCheck').IsChecked = $false
$Dialog.FindName('AnimationsCheck').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
$Saved = Get-Content -LiteralPath $SavedPath -Raw | ConvertFrom-Json
Assert-Native ($Saved.size -eq 208 -and $Saved.opacity -eq .88 -and $Saved.animations -eq $false -and $null -ne $Saved.position.windowLeft -and $null -ne $Saved.position.windowTop -and $null -eq $Dialog.FindName('ReasoningCheck')) 'settings controls persist changes without an obsolete reasoning display option'

# Render the actual, unshown native control tree. These are explicitly simulated
# session rows; this is a WPF layout preview, never a desktop screenshot.
$PreviewRows = @(
    [pscustomobject]@{ id='preview:agent-a'; sessionId='preview-a'; title='示例：代码检查（模拟）'; label='思考中'; action='正在检查工作区'; kind='turn'; status='running'; textKind='cot'; reasoning="正在核对 DeepSeek Harness 的任务状态。`n这是模拟思考内容，不会进入动作摘要。"; output=''; detail=''; updatedAt=1 },
    [pscustomobject]@{ id='preview:job-a'; sessionId='preview-a'; title='示例：代码检查（模拟）'; label='后台任务'; action='正在读取项目文件'; kind='job'; status='running'; textKind='tool'; detail='读取文件'; updatedAt=2 },
    [pscustomobject]@{ id='preview:agent-b'; sessionId='preview-b'; title='示例：整理结果（模拟）'; label='正在回答'; action='正在生成回复'; kind='turn'; status='running'; textKind='output'; output="已整理当前进度。`n不会直接显示回答正文。"; reasoning=''; detail=''; updatedAt=3 },
    [pscustomobject]@{ id='preview:agent-c'; sessionId='preview-c'; title='示例：等待确认（模拟）'; label='等待确认'; action='等待你确认下一步操作'; kind='turn'; status='waiting'; textKind='tool'; detail='等待用户确认下一步操作'; reasoning=''; output=''; updatedAt=4 }
)
$script:Settings.size = 180
$script:Settings.opacity = 1
$script:Settings.animations = $false
$script:Settings.showReasoning = $true
Apply-Settings
$script:Tasks = @(Get-FatFishDisplayRows $PreviewRows)
$script:ExecutionCount = 4
$PreviewWidth = [double]$script:Window.Width
$PreviewHeight = [double]$script:Window.Height
$PreviewEvidence = New-Object Collections.ArrayList
foreach ($ResourceKey in @($script:Window.Resources.Keys)) { $script:Scene.Resources[$ResourceKey] = $script:Window.Resources[$ResourceKey] }
$script:Window.Content = $null
$script:Scene.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, $script:Window.FontFamily)
# Give the existing controls a presentation source without showing a window.
# An unshown Window otherwise leaves child render caches dependent on timing.
$SourceParameters = New-Object Windows.Interop.HwndSourceParameters('FatFish headless layout renderer')
$SourceParameters.WindowStyle = -2147483648
$SourceParameters.ExtendedWindowStyle = 0x08000080
$SourceParameters.Width = [int]$PreviewWidth
$SourceParameters.Height = [int]$PreviewHeight
$SourceParameters.PositionX = -32000
$SourceParameters.PositionY = -32000
$PreviewSource = New-Object Windows.Interop.HwndSource($SourceParameters)
$PreviewSource.CompositionTarget.RenderMode = [Windows.Interop.RenderMode]::SoftwareOnly
$PreviewSource.RootVisual = $script:Scene

function Get-RenderedAlphaCount([byte[]] $Pixels, [int] $Width, [int] $Height, [Windows.Rect] $Region) {
    $Left = [Math]::Max(0, [int][Math]::Floor($Region.Left))
    $Top = [Math]::Max(0, [int][Math]::Floor($Region.Top))
    $Right = [Math]::Min($Width, [int][Math]::Ceiling($Region.Right))
    $Bottom = [Math]::Min($Height, [int][Math]::Ceiling($Region.Bottom))
    $Count = 0
    for ($Y = $Top; $Y -lt $Bottom; $Y++) {
        for ($X = $Left; $X -lt $Right; $X++) {
            if ($Pixels[(($Y * $Width + $X) * 4) + 3] -gt 24) { $Count++ }
        }
    }
    return $Count
}

function Save-NativeLayoutPreview([string] $Path, [switch] $Warmup) {
    $script:Scene.Width = $PreviewWidth
    $script:Scene.Height = $PreviewHeight
    $script:ExpandedBubbles.InvalidateMeasure()
    $script:ExpandedPanel.InvalidateMeasure()
    $script:ExpandedPanel.InvalidateArrange()
    if ($script:Expanded) {
        $script:ExpandedBubbles.Measure((New-Object Windows.Size($script:ExpandedPanel.Width, [double]::PositiveInfinity)))
        $script:ExpandedPanel.Measure((New-Object Windows.Size($script:BubbleRegion.Width, $script:BubbleRegion.Height)))
    }
    $script:BubbleRegion.InvalidateMeasure()
    $script:BubbleRegion.InvalidateArrange()
    $script:Scene.InvalidateMeasure()
    $script:Scene.InvalidateArrange()
    $script:Scene.Measure((New-Object Windows.Size($PreviewWidth, $PreviewHeight)))
    $script:Scene.Arrange((New-Object Windows.Rect(0, 0, $PreviewWidth, $PreviewHeight)))
    $script:Scene.UpdateLayout()
    # Drain deferred WPF layout/render work without opening a window.
    $script:Scene.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    $script:Timer.Stop()
    $Bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap(([int]$PreviewWidth), ([int]$PreviewHeight), 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $Bitmap.Render($script:Scene)
    $script:Scene.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    $script:Timer.Stop()
    $Bitmap.Clear()
    $Bitmap.Render($script:Scene)
    $Pixels = New-Object byte[](([int]$PreviewWidth) * ([int]$PreviewHeight) * 4)
    $Bitmap.CopyPixels($Pixels, (([int]$PreviewWidth) * 4), 0)
    $PetRect = New-Object Windows.Rect($script:PetX, $script:PetY, $script:PetGroup.Width, $script:PetGroup.Height)
    $BubbleRect = New-Object Windows.Rect(([Windows.Controls.Canvas]::GetLeft($script:BubbleRegion)), ([Windows.Controls.Canvas]::GetTop($script:BubbleRegion)), $script:BubbleRegion.Width, $script:BubbleRegion.Height)
    $PetPixels = Get-RenderedAlphaCount $Pixels ([int]$PreviewWidth) ([int]$PreviewHeight) $PetRect
    $BubblePixels = Get-RenderedAlphaCount $Pixels ([int]$PreviewWidth) ([int]$PreviewHeight) $BubbleRect
    if (-not $Warmup -and ($PetPixels -lt 1000 -or $BubblePixels -lt 2000)) {
        throw "Headless WPF preview is missing visible content: pet=$PetPixels, bubbles=$BubblePixels. No preview was accepted."
    }
    $Encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $Encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $Stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
    try { $Encoder.Save($Stream) } finally { $Stream.Dispose() }
    $PreviewEvidence.Add([ordered]@{ path=$Path; petVisiblePixels=$PetPixels; bubbleVisiblePixels=$BubblePixels }) | Out-Null
}

$script:Expanded = $true
Render-Bubbles $true
Save-NativeLayoutPreview (Join-Path $CheckRoot 'preview-warmup.png') -Warmup
$script:Expanded = $false
Render-Bubbles $true
$CollapsedPreviewPath = Join-Path $ProjectRoot '.data\native-preview-collapsed.png'
Save-NativeLayoutPreview $CollapsedPreviewPath
$script:Expanded = $true
Render-Bubbles $true
$PreviewPath = Join-Path $ProjectRoot '.data\native-preview.png'
Save-NativeLayoutPreview $PreviewPath

foreach ($ThemeCase in @(@{ name='light'; theme=$LightTheme }, @{ name='dark'; theme=$DarkTheme })) {
    Update-FatFishTheme -Target $script:Window -Theme $ThemeCase.theme | Out-Null
    foreach ($ResourceKey in @($script:Window.Resources.Keys)) { $script:Scene.Resources[$ResourceKey] = $script:Window.Resources[$ResourceKey] }
    Render-Bubbles $true
    Save-NativeLayoutPreview (Join-Path $CheckRoot ('bubbles-' + $ThemeCase.name + '.png'))
}
$BeforeHeight = $script:BubbleRegion.Height
$BeforeTop = [Windows.Controls.Canvas]::GetTop($script:BubbleRegion)
$script:Tasks[0].action = ("正在检查工作区中的项目文件`n" * 60)
$script:Tasks[0].reasoning = ("思考正文不可出现在卡片中。`n" * 150)
Render-Bubbles $true
Save-NativeLayoutPreview (Join-Path $CheckRoot 'single-line-long-content.png')
Assert-Native ($script:BubbleRegion.Height -eq $BeforeHeight -and [Windows.Controls.Canvas]::GetTop($script:BubbleRegion) -eq $BeforeTop -and $script:ExpandedBubbles.Children[0].Height -eq 63) 'action text growth leaves the bubble region size and position unchanged'
Update-FatFishTheme -Target $script:Window -Theme $LightTheme | Out-Null
foreach ($ResourceKey in @($script:Window.Resources.Keys)) { $script:Scene.Resources[$ResourceKey] = $script:Window.Resources[$ResourceKey] }
Render-Bubbles $true
Save-NativeLayoutPreview (Join-Path $CheckRoot 'single-line-after-theme.png')
Assert-Native ($script:BubbleRegion.Height -eq $BeforeHeight -and [Windows.Controls.Canvas]::GetTop($script:BubbleRegion) -eq $BeforeTop) 'theme changes preserve the fixed bubble layout'

$script:Tasks = @(0..19 | ForEach-Object { [pscustomobject]@{ id=('card:' + $_); sessionId=('card-' + $_); title=('Action chat ' + $_); label='思考中'; action='正在生成回复'; kind='turn'; status='running'; textKind='output'; output=('Public output ' + $_); activity=('Public output ' + $_); activityKind='output'; updatedAt=$_ } })
Render-Bubbles $true
$NativeSource = Get-Content -LiteralPath (Join-Path $NativeRoot 'pet.ps1') -Raw -Encoding UTF8
Assert-Native ($script:ExpandedBubbles.Children.Count -eq 20 -and @($script:ExpandedBubbles.Children | Where-Object { $_.Height -ne 63 -or $_.Width -ne 326 }).Count -eq 0 -and $NativeSource -notmatch 'ScrollViewer|BubblePager|BubblePageCount') 'all expanded cards are created at the same size without scroll or pagination controls'
$script:Tasks = @($script:Tasks[0])
Render-Bubbles $true
Assert-Native ($script:ExpandedBubbles.Children.Count -eq 1 -and $script:ExpandedBubbles.Children[0].Height -eq 63) 'task removal keeps the remaining card size unchanged'
$PreviewSource.Dispose()

# Render the actual settings tree in both simulated modes. No system theme is
# written and no visible settings window is opened.
$SettingsRoot = $Dialog.Content
$Dialog.Content = $null
$SettingsWidth = [int]$Dialog.Width
$SettingsHeight = [int]$Dialog.Height
$SettingsParameters = New-Object Windows.Interop.HwndSourceParameters('FatFish settings layout renderer')
$SettingsParameters.WindowStyle = -2147483648
$SettingsParameters.ExtendedWindowStyle = 0x08000080
$SettingsParameters.Width = $SettingsWidth; $SettingsParameters.Height = $SettingsHeight
$SettingsParameters.PositionX = -32000; $SettingsParameters.PositionY = -32000
$SettingsSource = New-Object Windows.Interop.HwndSource($SettingsParameters)
$SettingsSource.CompositionTarget.RenderMode = [Windows.Interop.RenderMode]::SoftwareOnly
$SettingsSource.RootVisual = $SettingsRoot
foreach ($ThemeCase in @(@{ name='light'; theme=$LightTheme }, @{ name='dark'; theme=$DarkTheme })) {
    Update-FatFishTheme -Target $Dialog -Theme $ThemeCase.theme | Out-Null
    foreach ($ResourceKey in @($Dialog.Resources.Keys)) { $SettingsRoot.Resources[$ResourceKey] = $Dialog.Resources[$ResourceKey] }
    $SettingsRoot.SetValue([Windows.Documents.TextElement]::FontFamilyProperty, $Dialog.FontFamily)
    $SettingsRoot.SetValue([Windows.Documents.TextElement]::ForegroundProperty, $Dialog.Resources['FatFish.Text'])
    $SettingsRoot.Measure((New-Object Windows.Size($SettingsWidth, $SettingsHeight)))
    $SettingsRoot.Arrange((New-Object Windows.Rect(0,0,$SettingsWidth,$SettingsHeight)))
    $SettingsRoot.UpdateLayout()
    $SettingsRoot.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
    $SettingsBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($SettingsWidth,$SettingsHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $SettingsBitmap.Render($SettingsRoot)
    $SettingsPixels = New-Object byte[]($SettingsWidth * $SettingsHeight * 4)
    $SettingsBitmap.CopyPixels($SettingsPixels, ($SettingsWidth * 4), 0)
    $SettingsPixelCount = Get-RenderedAlphaCount $SettingsPixels $SettingsWidth $SettingsHeight (New-Object Windows.Rect(0,0,$SettingsWidth,$SettingsHeight))
    Assert-Native ($SettingsPixelCount -gt 10000 -and $SettingsPixels[3] -eq 0) ('rounded settings layout renders in ' + $ThemeCase.name + ' mode')
    $SettingsEncoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $SettingsEncoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($SettingsBitmap))
    $SettingsPreviewPath = Join-Path $CheckRoot ('settings-' + $ThemeCase.name + '.png')
    $SettingsStream = [IO.File]::Open($SettingsPreviewPath, [IO.FileMode]::Create)
    try { $SettingsEncoder.Save($SettingsStream) } finally { $SettingsStream.Dispose() }
    $PreviewEvidence.Add([ordered]@{ path=$SettingsPreviewPath; visiblePixels=$SettingsPixelCount }) | Out-Null
}
$SettingsSource.Dispose()

$Result = [ordered]@{ passed=$true; checkedAt=[DateTime]::UtcNow.ToString('o'); powershellVersion=$PSVersionTable.PSVersion.ToString(); tests=@($Results); windowsShown=0; liveProfileAccessed=$false; previewIsSimulated=$true; preview=$PreviewPath; collapsedPreview=$CollapsedPreviewPath; previewEvidence=@($PreviewEvidence) }
[IO.File]::WriteAllText((Join-Path $CheckRoot 'result.json'), ($Result | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
Write-Host "Native regression checks passed: $($Results.Count). Evidence: $(Join-Path $CheckRoot 'result.json')"
Write-Host "Simulated WPF layout previews (not desktop screenshots): $PreviewPath; $CollapsedPreviewPath"
