[CmdletBinding()]
param([string]$Profile = 'desktop', [switch]$DryRun, [switch]$Reinstall)
$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
if ($Profile -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid profile name.' }
. (Join-Path $PSScriptRoot 'desktop-cli.ps1')
& (Join-Path $PSScriptRoot 'pack-plugin.ps1')
$Manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'plugin\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Archive = Join-Path $ProjectRoot ("dist\{0}-{1}.tgz" -f $Manifest.name,$Manifest.version)
if (-not (Test-Path -LiteralPath $Archive)) { throw "Plugin archive not found: $Archive" }
Write-Host "Installable DSH plugin: $Archive"
Write-Host "Target profile: $Profile"
if ($DryRun) { Write-Host 'Dry run; the Harness profile has not been changed.'; return }
$BackupDir = Join-Path $ProjectRoot ('.data\backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$ProfileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $Profile)
foreach ($Name in @('package.json','cordis.patch.yml','cordis.yml','pnpm-lock.yaml')) {
    $Source = Join-Path $ProfileDir $Name
    if (Test-Path -LiteralPath $Source -PathType Leaf) { Copy-Item -LiteralPath $Source -Destination (Join-Path $BackupDir $Name) }
}
$ExistingManifestPath = Join-Path $ProfileDir 'package.json'
$ReplacingExisting = $false
if (Test-Path -LiteralPath $ExistingManifestPath) {
    $ExistingManifest = Get-Content -LiteralPath $ExistingManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($ExistingManifest.dependencies.PSObject.Properties[$Manifest.name]) {
        if (-not $Reinstall) { throw 'This plugin is already installed. Use -Reinstall to replace its installed copy; settings are retained.' }
        $ReplacingExisting = $true
        Invoke-HarnessDesktopCli -CliArguments @('plugin', '--profile', $Profile, 'remove', $Manifest.name)
    }
}
Invoke-HarnessDesktopCli -CliArguments @('plugin', '--profile', $Profile, 'add', $Archive)
$InstalledManifest = Get-Content -LiteralPath (Join-Path $ProfileDir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $InstalledManifest.dependencies.PSObject.Properties[$Manifest.name]) { throw "Installation finished but the profile has no registered dependency. Backup: $BackupDir" }
if ($InstalledManifest.dsh.profile.bundles -notcontains $Manifest.name) { throw "Dependency installed but its bundle is not enabled. Backup: $BackupDir" }
Write-Host 'Plugin dependency registered and bundle enabled. Harness loads it through its normal plugin lifecycle.'
if ($Profile -eq 'desktop') {
    $DiscoveryPath = Join-Path $env:USERPROFILE '.dsh\fatfish-bridge.json'
    $Ready = $false
    for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
        try {
            $Discovery = Get-Content -LiteralPath $DiscoveryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $Health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Discovery.port + '/v1/health') -Headers @{Authorization=('Bearer ' + $Discovery.token)} -TimeoutSec 1
            if ($Health.ok -and $Health.pid -eq $Discovery.pid) { $Ready = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 300
    }
    if ($Ready -and $ReplacingExisting) { Write-Host 'Runtime health is live. Restart Harness after current tasks finish to load the updated modules; a live endpoint alone does not prove an update was loaded.' }
    elseif ($Ready) { Write-Host 'Running Desktop Host confirmed the plugin health endpoint.' }
    else { Write-Host 'Runtime not yet confirmed. Open Harness, then check that the pet appears or inspect the plugin status.' }
}
Write-Host "Backup: $BackupDir"
