function Invoke-HarnessDesktopCli {
    param([Parameter(Mandatory=$true)][string[]]$CliArguments)
    $DesktopExe = Join-Path $env:USERPROFILE 'AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe'
    if (-not (Test-Path -LiteralPath $DesktopExe -PathType Leaf)) { throw 'DeepSeek Harness Desktop is not installed at the expected location.' }
    $CliFile = Join-Path (Split-Path -Parent $DesktopExe) 'resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js'
    # Electron is a GUI executable: wait for its actual process, not PowerShell's stale LASTEXITCODE.
    $Info = New-Object System.Diagnostics.ProcessStartInfo
    $Info.FileName = $DesktopExe
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    $Info.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $AllArguments = @('--expose-internals', $CliFile) + $CliArguments
    # Windows command-line escaping for PS 5.1, including paths with spaces and Chinese characters.
    $Info.Arguments = (($AllArguments | ForEach-Object {
        '"' + ([regex]::Replace([regex]::Replace($_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
    }) -join ' ')
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $Info
    try {
        if (-not $Process.Start()) { throw 'Could not start the official Harness Desktop CLI.' }
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        $Process.WaitForExit()
        $OutputText = $OutputTask.GetAwaiter().GetResult()
        $ErrorText = $ErrorTask.GetAwaiter().GetResult()
        if ($OutputText) { Write-Host $OutputText.TrimEnd() }
        if ($ErrorText) { Write-Host $ErrorText.TrimEnd() }
        if ($Process.ExitCode -ne 0) { throw "Harness Desktop CLI returned exit code $($Process.ExitCode)." }
    } finally { $Process.Dispose() }
}
