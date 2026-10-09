function Get-FatFishSettings {
    param([string] $Path)
    $Model = @{ size = 180; opacity = 1.0; showReasoning = $true; animations = $true; position = $null }
    if (Test-Path -LiteralPath $Path) {
        try {
            $Raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($Key in @('size', 'opacity', 'showReasoning', 'animations', 'position')) {
                if ($null -ne $Raw.$Key) { $Model[$Key] = $Raw.$Key }
            }
        } catch {}
    }
    try {
        $Value = [double]$Model.size
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw 'Invalid size.' }
        $Model.size = [Math]::Round([Math]::Max(96, [Math]::Min(280, $Value)))
    } catch { $Model.size = 180 }
    try {
        $Value = [double]$Model.opacity
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw 'Invalid opacity.' }
        $Model.opacity = [Math]::Max([double].3, [Math]::Min([double]1, $Value))
    } catch { $Model.opacity = 1.0 }
    if ($Model.position) {
        try {
            $X = [double]$Model.position.x; $Y = [double]$Model.position.y
            if ($null -eq $Model.position.x -or $null -eq $Model.position.y -or [double]::IsNaN($X) -or [double]::IsNaN($Y) -or [double]::IsInfinity($X) -or [double]::IsInfinity($Y)) { throw 'Invalid position.' }
            $Model.position = @{ x = $X; y = $Y }
        } catch { $Model.position = $null }
    }
    $Model.showReasoning = $Model.showReasoning -ne $false
    $Model.animations = $Model.animations -ne $false
    return $Model
}

. (Join-Path $PSScriptRoot 'native-theme.ps1')

function Save-FatFishSettings {
    param([hashtable] $Settings, [string] $Path)
    $Directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Directory)) { [IO.Directory]::CreateDirectory($Directory) | Out-Null }
    [IO.File]::WriteAllText($Path, ($Settings | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Show-FatFishSettings {
    param([Windows.Window] $Owner, [hashtable] $Settings, [string] $Path, [scriptblock] $OnChanged, [switch] $BuildOnly)
    [xml] $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="大肥鱼设置" Width="410" Height="426" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
 WindowStyle="None" AllowsTransparency="True" Background="{x:Null}" FontFamily="Microsoft YaHei UI" Topmost="True" Foreground="{DynamicResource FatFish.Text}">
 <Window.Resources>
  <Style x:Key="FatFishButton" TargetType="Button">
   <Setter Property="Background" Value="{DynamicResource FatFish.SurfaceRaised}"/><Setter Property="Foreground" Value="{DynamicResource FatFish.Text}"/>
   <Setter Property="BorderBrush" Value="{DynamicResource FatFish.Border}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="16,7"/>
   <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ButtonShell" CornerRadius="{DynamicResource FatFish.CornerMedium}" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/></Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonShell" Property="Opacity" Value="0.88"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonShell" Property="Opacity" Value="0.7"/></Trigger>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="ButtonShell" Property="BorderBrush" Value="{DynamicResource FatFish.AccentText}"/><Setter TargetName="ButtonShell" Property="BorderThickness" Value="2"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonShell" Property="Opacity" Value="0.45"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="FatFishCheckBox" TargetType="CheckBox">
   <Setter Property="Foreground" Value="{DynamicResource FatFish.Text}"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="30"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
     <Border x:Name="CheckShell" Width="20" Height="20" HorizontalAlignment="Left" VerticalAlignment="Center" CornerRadius="7" Background="{DynamicResource FatFish.SurfaceRaised}" BorderBrush="{DynamicResource FatFish.Border}" BorderThickness="1.2"><Path x:Name="CheckMark" Data="M 4,9 L 8,13 L 15,5" Stroke="{DynamicResource FatFish.OnAccent}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Visibility="Collapsed"/></Border>
     <ContentPresenter Grid.Column="1" VerticalAlignment="Center" RecognizesAccessKey="True"/>
    </Grid>
    <ControlTemplate.Triggers>
     <Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckShell" Property="Background" Value="{DynamicResource FatFish.Accent}"/><Setter TargetName="CheckShell" Property="BorderBrush" Value="{DynamicResource FatFish.Accent}"/><Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/></Trigger>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CheckShell" Property="BorderBrush" Value="{DynamicResource FatFish.AccentText}"/></Trigger>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="CheckShell" Property="BorderBrush" Value="{DynamicResource FatFish.AccentText}"/><Setter TargetName="CheckShell" Property="BorderThickness" Value="2"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="FatFishSlider" TargetType="Slider">
   <Setter Property="Height" Value="26"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Slider"><Grid Margin="2,0">
    <Track x:Name="PART_Track" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" VerticalAlignment="Center">
     <Track.DecreaseRepeatButton><RepeatButton Command="{x:Static Slider.DecreaseLarge}" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="4" CornerRadius="2" Background="{DynamicResource FatFish.Accent}"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
     <Track.IncreaseRepeatButton><RepeatButton Command="{x:Static Slider.IncreaseLarge}" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Height="4" CornerRadius="2" Background="{DynamicResource FatFish.SliderTrack}"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
     <Track.Thumb><Thumb Width="19" Height="19" Cursor="Hand"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="10" Background="{DynamicResource FatFish.Thumb}" BorderBrush="{DynamicResource FatFish.Accent}" BorderThickness="1.5"><Ellipse Width="5" Height="5" Fill="{DynamicResource FatFish.AccentSoft}"/></Border></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
    </Track>
   </Grid></ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Border Margin="12" CornerRadius="{DynamicResource FatFish.CornerLarge}" Background="{DynamicResource FatFish.Surface}" BorderBrush="{DynamicResource FatFish.Border}" BorderThickness="1">
  <Border.Effect><DropShadowEffect Color="{DynamicResource FatFish.ShadowColor}" BlurRadius="24" ShadowDepth="6" Opacity="{DynamicResource FatFish.ShadowOpacity}"/></Border.Effect>
  <Grid>
   <Border CornerRadius="{DynamicResource FatFish.CornerLarge}" Background="{DynamicResource FatFish.Highlight}" IsHitTestVisible="False"/>
   <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Grid x:Name="TitleBar" Margin="23,18,18,17" Background="Transparent">
     <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="32"/></Grid.ColumnDefinitions>
     <StackPanel><TextBlock Text="大肥鱼" FontSize="22" FontWeight="SemiBold" Foreground="{DynamicResource FatFish.Text}"/><TextBlock Text="让陪伴刚好合你心意" FontSize="12" Foreground="{DynamicResource FatFish.TextMuted}" Margin="1,4,0,0"/></StackPanel>
     <Button x:Name="CloseButton" Grid.Column="1" Width="29" Height="29" VerticalAlignment="Top" Padding="0" Content="×" FontSize="20" Style="{StaticResource FatFishButton}" Foreground="{DynamicResource FatFish.TextMuted}" ToolTip="关闭设置"/>
    </Grid>
    <StackPanel Grid.Row="1" Margin="23,0,23,22">
     <DockPanel><TextBlock Text="宠物尺寸" FontSize="13" Foreground="{DynamicResource FatFish.Text}"/><TextBlock x:Name="SizeValue" HorizontalAlignment="Right" Foreground="{DynamicResource FatFish.AccentText}" FontSize="12" FontWeight="SemiBold"/></DockPanel>
     <Slider x:Name="SizeSlider" Minimum="96" Maximum="280" TickFrequency="1" IsSnapToTickEnabled="True" Margin="0,7,0,15" Style="{StaticResource FatFishSlider}"/>
     <DockPanel><TextBlock Text="透明度" FontSize="13" Foreground="{DynamicResource FatFish.Text}"/><TextBlock x:Name="OpacityValue" HorizontalAlignment="Right" Foreground="{DynamicResource FatFish.AccentText}" FontSize="12" FontWeight="SemiBold"/></DockPanel>
     <Slider x:Name="OpacitySlider" Minimum="30" Maximum="100" TickFrequency="1" IsSnapToTickEnabled="True" Margin="0,7,0,15" Style="{StaticResource FatFishSlider}"/>
     <CheckBox x:Name="AnimationsCheck" Margin="0,0,0,17" Style="{StaticResource FatFishCheckBox}"><TextBlock Text="启用待机与鼠标互动动画" TextWrapping="Wrap"/></CheckBox>
     <TextBlock Text="单击回到 DSH，拖动移动，右键打开设置。&#xA;悬停展开任务，单击气泡打开对应聊天。" Foreground="{DynamicResource FatFish.TextMuted}" FontSize="11" LineHeight="19" Margin="0,0,0,15"/>
     <Button x:Name="DoneButton" Content="完成" Height="37" FontSize="13" Style="{StaticResource FatFishButton}" Background="{DynamicResource FatFish.Accent}" Foreground="{DynamicResource FatFish.OnAccent}" BorderBrush="{DynamicResource FatFish.Accent}"/>
    </StackPanel>
   </Grid>
  </Grid>
 </Border>
</Window>
'@
    $Dialog = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $Xaml))
    Update-FatFishTheme -Target $Dialog | Out-Null
    if ($Owner) { $Dialog.Owner = $Owner }
    $SizeSlider = $Dialog.FindName('SizeSlider')
    $OpacitySlider = $Dialog.FindName('OpacitySlider')
    $AnimationsCheck = $Dialog.FindName('AnimationsCheck')
    $SizeValue = $Dialog.FindName('SizeValue')
    $OpacityValue = $Dialog.FindName('OpacityValue')
    $SizeSlider.Value = $Settings.size
    $OpacitySlider.Value = $Settings.opacity * 100
    $AnimationsCheck.IsChecked = $Settings.animations
    $SizeValue.Text = "$($Settings.size) px"
    $OpacityValue.Text = "$([Math]::Round($Settings.opacity * 100))%"
    $Update = {
        $Settings.size = [Math]::Round($SizeSlider.Value)
        $Settings.opacity = $OpacitySlider.Value / 100.0
        $Settings.animations = $AnimationsCheck.IsChecked -eq $true
        $SizeValue.Text = "$($Settings.size) px"
        $OpacityValue.Text = "$([Math]::Round($Settings.opacity * 100))%"
        & $OnChanged
        Save-FatFishSettings -Settings $Settings -Path $Path
    }.GetNewClosure()
    $SizeSlider.Add_ValueChanged($Update)
    $OpacitySlider.Add_ValueChanged($Update)
    $AnimationsCheck.Add_Click($Update)
    $Dialog.FindName('DoneButton').Add_Click({ $Dialog.Close() }.GetNewClosure())
    $Dialog.FindName('CloseButton').Add_Click({ $Dialog.Close() }.GetNewClosure())
    $Dialog.FindName('TitleBar').Add_MouseLeftButtonDown({ try { $Dialog.DragMove() } catch {} }.GetNewClosure())
    if ($BuildOnly) { return $Dialog }
    $ThemeTimer = New-Object Windows.Threading.DispatcherTimer
    $ThemeTimer.Interval = [TimeSpan]::FromSeconds(1)
    $ThemeTimer.Add_Tick({ try { Update-FatFishTheme -Target $Dialog | Out-Null } catch {} }.GetNewClosure())
    $Dialog.Add_Closed({ $ThemeTimer.Stop() }.GetNewClosure())
    $ThemeTimer.Start()
    try { $Dialog.ShowDialog() | Out-Null } finally { $ThemeTimer.Stop() }
}
