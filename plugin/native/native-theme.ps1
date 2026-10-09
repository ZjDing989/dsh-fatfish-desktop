Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function ConvertTo-FatFishColor($Value, [Windows.Media.Color] $Fallback = [Windows.Media.Colors]::Transparent) {
    if ($Value -is [Windows.Media.Color]) { return $Value }
    try { return [Windows.Media.ColorConverter]::ConvertFromString([string]$Value) } catch { return $Fallback }
}

function Mix-FatFishColor([Windows.Media.Color] $Base, [Windows.Media.Color] $Tint, [double] $Amount) {
    $Amount = [Math]::Max([double]0, [Math]::Min([double]1, $Amount))
    return [Windows.Media.Color]::FromArgb(255,
        [byte][Math]::Round($Base.R * (1 - $Amount) + $Tint.R * $Amount),
        [byte][Math]::Round($Base.G * (1 - $Amount) + $Tint.G * $Amount),
        [byte][Math]::Round($Base.B * (1 - $Amount) + $Tint.B * $Amount))
}

function New-FatFishBrush([Windows.Media.Color] $Color) {
    $Brush = New-Object Windows.Media.SolidColorBrush($Color)
    $Brush.Freeze()
    return $Brush
}

function Get-FatFishThemeSignature($Theme) {
    $Accent = ConvertTo-FatFishColor $Theme.Accent ([Windows.Media.Color]::FromRgb(54, 126, 220))
    $Parts = @([bool]$Theme.IsDark, [bool]$Theme.HighContrast, $Accent.ToString())
    if ($Theme.HighContrast) {
        $Parts += @(
            (ConvertTo-FatFishColor $Theme.WindowColor ([Windows.SystemColors]::WindowColor)).ToString(),
            (ConvertTo-FatFishColor $Theme.WindowTextColor ([Windows.SystemColors]::WindowTextColor)).ToString(),
            (ConvertTo-FatFishColor $Theme.HighlightColor ([Windows.SystemColors]::HighlightColor)).ToString(),
            (ConvertTo-FatFishColor $Theme.HighlightTextColor ([Windows.SystemColors]::HighlightTextColor)).ToString()
        )
    }
    return ($Parts -join '|')
}

function Get-FatFishSystemTheme {
    $Light = $null
    $Accent = [Windows.Media.Color]::FromRgb(54, 126, 220)
    $Foreground = $null
    try {
        $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize')
        if ($Key) {
            try { $Value = $Key.GetValue('AppsUseLightTheme', $null); if ($null -ne $Value) { $Light = [int]$Value -ne 0 } }
            finally { $Key.Dispose() }
        }
    } catch {}
    $GotAccent = $false
    try {
        $Ui = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType=WindowsRuntime]::new()
        $NativeAccent = $Ui.GetColorValue([Windows.UI.ViewManagement.UIColorType, Windows.UI.ViewManagement, ContentType=WindowsRuntime]::Accent)
        $Accent = [Windows.Media.Color]::FromRgb($NativeAccent.R, $NativeAccent.G, $NativeAccent.B)
        $Foreground = $Ui.GetColorValue([Windows.UI.ViewManagement.UIColorType, Windows.UI.ViewManagement, ContentType=WindowsRuntime]::Foreground)
        $GotAccent = $true
    } catch {}
    if (-not $GotAccent) {
        try {
            $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\Accent')
            if ($Key) {
                try {
                    $Value = $Key.GetValue('AccentColorMenu', $null)
                    if ($null -ne $Value) {
                        # AccentColorMenu is a Windows COLORREF-style ABGR DWORD.
                        $Bytes = [BitConverter]::GetBytes([int]$Value)
                        $Accent = [Windows.Media.Color]::FromRgb($Bytes[0], $Bytes[1], $Bytes[2])
                    }
                } finally { $Key.Dispose() }
            }
        } catch {}
    }
    if ($null -eq $Light) {
        if ($Foreground) { $Light = ((5 * [int]$Foreground.G) + (2 * [int]$Foreground.R) + [int]$Foreground.B) -le (8 * 128) }
        else { $Light = $true }
    }
    $Theme = [pscustomobject]@{
        IsDark = -not $Light
        HighContrast = [Windows.SystemParameters]::HighContrast
        Accent = $Accent
        WindowColor = [Windows.SystemColors]::WindowColor
        WindowTextColor = [Windows.SystemColors]::WindowTextColor
        HighlightColor = [Windows.SystemColors]::HighlightColor
        HighlightTextColor = [Windows.SystemColors]::HighlightTextColor
        Signature = ''
    }
    $Theme.Signature = Get-FatFishThemeSignature $Theme
    return $Theme
}

function New-FatFishThemeResources($Theme) {
    if (-not $Theme) { $Theme = Get-FatFishSystemTheme }
    $Dark = $Theme.IsDark -eq $true
    $Contrast = $Theme.HighContrast -eq $true
    $Accent = ConvertTo-FatFishColor $Theme.Accent ([Windows.Media.Color]::FromRgb(54, 126, 220))
    $White = [Windows.Media.Colors]::White
    $Black = [Windows.Media.Colors]::Black
    if ($Contrast) {
        $Surface = ConvertTo-FatFishColor $Theme.WindowColor ([Windows.SystemColors]::WindowColor)
        $Text = ConvertTo-FatFishColor $Theme.WindowTextColor ([Windows.SystemColors]::WindowTextColor)
        $Accent = ConvertTo-FatFishColor $Theme.HighlightColor ([Windows.SystemColors]::HighlightColor)
        $OnAccent = ConvertTo-FatFishColor $Theme.HighlightTextColor ([Windows.SystemColors]::HighlightTextColor)
        $SurfaceBrush = New-FatFishBrush $Surface
        $Raised = $Surface; $Hover = $Surface; $Border = $Text; $Muted = $Text; $AccentText = $Accent
        $Soft = $Surface; $Thumb = $Surface; $Highlight = New-FatFishBrush ([Windows.Media.Colors]::Transparent)
        $Shadow = $Black; $ShadowOpacity = 0.0
    } else {
        $Surface = ConvertTo-FatFishColor $(if ($Dark) { '#202936' } else { '#F8FBFF' })
        $SurfaceTop = Mix-FatFishColor $Surface $Accent $(if ($Dark) { .075 } else { .035 })
        $SurfaceBottom = Mix-FatFishColor $Surface $(if ($Dark) { $Black } else { $White }) .07
        $SurfaceBrush = New-Object Windows.Media.LinearGradientBrush
        $SurfaceBrush.StartPoint = New-Object Windows.Point(0, 0)
        $SurfaceBrush.EndPoint = New-Object Windows.Point(1, 1)
        $SurfaceBrush.GradientStops.Add((New-Object Windows.Media.GradientStop($SurfaceTop, 0)))
        $SurfaceBrush.GradientStops.Add((New-Object Windows.Media.GradientStop($Surface, .48)))
        $SurfaceBrush.GradientStops.Add((New-Object Windows.Media.GradientStop($SurfaceBottom, 1)))
        $SurfaceBrush.Freeze()
        $Raised = Mix-FatFishColor $Surface $(if ($Dark) { $White } else { $Accent }) $(if ($Dark) { .055 } else { .06 })
        $Hover = Mix-FatFishColor $Surface $Accent $(if ($Dark) { .16 } else { .1 })
        $Border = Mix-FatFishColor $Surface $Accent $(if ($Dark) { .28 } else { .19 })
        $Text = ConvertTo-FatFishColor $(if ($Dark) { '#EEF4FE' } else { '#263B56' })
        $Muted = ConvertTo-FatFishColor $(if ($Dark) { '#AAB9CD' } else { '#6F8098' })
        $AccentText = Mix-FatFishColor $Accent $(if ($Dark) { $White } else { $Text }) $(if ($Dark) { .3 } else { .21 })
        $Soft = Mix-FatFishColor $Surface $Accent $(if ($Dark) { .2 } else { .13 })
        $Thumb = ConvertTo-FatFishColor $(if ($Dark) { '#DDE7F5' } else { '#FFFFFF' })
        $Brightness = (299 * [int]$Accent.R + 587 * [int]$Accent.G + 114 * [int]$Accent.B) / 1000
        $OnAccent = if ($Brightness -gt 160) { [Windows.Media.Color]::FromRgb(20, 30, 45) } else { $White }
        $GlowColor = [Windows.Media.Color]::FromArgb($(if ($Dark) { 23 } else { 135 }), 255, 255, 255)
        $Highlight = New-Object Windows.Media.RadialGradientBrush
        $Highlight.Center = New-Object Windows.Point(.18, 0)
        $Highlight.GradientOrigin = New-Object Windows.Point(.16, 0)
        $Highlight.RadiusX = .95; $Highlight.RadiusY = 1.1
        $Highlight.GradientStops.Add((New-Object Windows.Media.GradientStop($GlowColor, 0)))
        $Highlight.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Colors]::Transparent, 1)))
        $Highlight.Freeze()
        $Shadow = ConvertTo-FatFishColor $(if ($Dark) { '#000000' } else { '#365471' })
        $ShadowOpacity = if ($Dark) { .32 } else { .15 }
    }
    if ($Contrast) {
        $BubbleSurface = $Surface
        $BubbleBrush = $SurfaceBrush
        $BubbleBorder = $Text
        $BubbleHover = $Surface
        $BubbleNear = $Surface; $BubbleFar = $Surface
        $BubbleText = $Text; $BubbleMuted = $Text
    } else {
        $BubbleSurface = ConvertTo-FatFishColor $(if ($Dark) { '#242424' } else { '#FDFDFD' })
        $BubbleBrush = New-Object Windows.Media.LinearGradientBrush
        $BubbleBrush.StartPoint = New-Object Windows.Point(0, 0)
        $BubbleBrush.EndPoint = New-Object Windows.Point(0, 1)
        $BubbleBrush.GradientStops.Add((New-Object Windows.Media.GradientStop((Mix-FatFishColor $BubbleSurface $White .018), 0)))
        $BubbleBrush.GradientStops.Add((New-Object Windows.Media.GradientStop($BubbleSurface, 1)))
        $BubbleBrush.Freeze()
        $BubbleBorder = ConvertTo-FatFishColor $(if ($Dark) { '#4D4D4D' } else { '#D3D5D8' })
        $BubbleHover = ConvertTo-FatFishColor $(if ($Dark) { '#2A2A2A' } else { '#F5F6F7' })
        $BubbleNear = ConvertTo-FatFishColor $(if ($Dark) { '#2B2B2B' } else { '#F1F3F5' })
        $BubbleFar = ConvertTo-FatFishColor $(if ($Dark) { '#313131' } else { '#E7EAEE' })
        $BubbleText = ConvertTo-FatFishColor $(if ($Dark) { '#F3F3F3' } else { '#202124' })
        $BubbleMuted = ConvertTo-FatFishColor $(if ($Dark) { '#B4B4B4' } else { '#66707B' })
    }
    return @{
        'FatFish.BubbleSurface' = $BubbleBrush
        'FatFish.BubbleSurfaceSolid' = (New-FatFishBrush $BubbleSurface)
        'FatFish.BubbleLayerNear' = (New-FatFishBrush $BubbleNear)
        'FatFish.BubbleLayerFar' = (New-FatFishBrush $BubbleFar)
        'FatFish.BubbleBorder' = (New-FatFishBrush $BubbleBorder)
        'FatFish.BubbleHover' = (New-FatFishBrush $BubbleHover)
        'FatFish.BubbleText' = (New-FatFishBrush $BubbleText)
        'FatFish.BubbleTextMuted' = (New-FatFishBrush $BubbleMuted)
        'FatFish.Surface' = $SurfaceBrush
        'FatFish.SurfaceSolid' = (New-FatFishBrush $Surface)
        'FatFish.SurfaceRaised' = (New-FatFishBrush $Raised)
        'FatFish.SurfaceHover' = (New-FatFishBrush $Hover)
        'FatFish.Border' = (New-FatFishBrush $Border)
        'FatFish.Text' = (New-FatFishBrush $Text)
        'FatFish.TextMuted' = (New-FatFishBrush $Muted)
        'FatFish.Accent' = (New-FatFishBrush $Accent)
        'FatFish.AccentText' = (New-FatFishBrush $AccentText)
        'FatFish.AccentSoft' = (New-FatFishBrush $Soft)
        'FatFish.OnAccent' = (New-FatFishBrush $OnAccent)
        'FatFish.Highlight' = $Highlight
        'FatFish.ShadowColor' = $Shadow
        'FatFish.ShadowOpacity' = [double]$ShadowOpacity
        'FatFish.SliderTrack' = (New-FatFishBrush $Border)
        'FatFish.Thumb' = (New-FatFishBrush $Thumb)
        'FatFish.IsHighContrast' = $Contrast
        'FatFish.CornerLarge' = (New-Object Windows.CornerRadius(28))
        'FatFish.CornerMedium' = (New-Object Windows.CornerRadius(24))
        'FatFish.CornerSmall' = (New-Object Windows.CornerRadius(12))
        'FatFish.ThemeSignature' = (Get-FatFishThemeSignature $Theme)
    }
}

function Update-FatFishTheme {
    param([Parameter(Mandatory=$true)][Windows.FrameworkElement] $Target, $Theme)
    if (-not $Theme) { $Theme = Get-FatFishSystemTheme }
    $Signature = Get-FatFishThemeSignature $Theme
    if ($Target.Resources['FatFish.ThemeSignature'] -eq $Signature) { return $false }
    $Resources = New-FatFishThemeResources $Theme
    # WPF dependency-property validation sees PSObject wrappers as incompatible
    # values when they enter the untyped ResourceDictionary indexer.
    foreach ($Key in $Resources.Keys) { $Target.Resources[$Key] = $Resources[$Key].psobject.BaseObject }
    return $true
}
