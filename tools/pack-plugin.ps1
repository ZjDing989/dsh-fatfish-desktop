[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$PluginRoot = Join-Path $ProjectRoot 'plugin'
$DistRoot = Join-Path $ProjectRoot 'dist'
New-Item -ItemType Directory -Path $DistRoot -Force | Out-Null
$Npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $Npm) {
    $Candidate = Join-Path $env:ProgramFiles 'nodejs\npm.cmd'
    if (Test-Path -LiteralPath $Candidate) { $NpmPath = $Candidate } else {
        throw 'npm.cmd is required for packaging. Install Node.js or add its directory to PATH.'
    }
} else { $NpmPath = $Npm.Source }

if (-not (Test-Path -LiteralPath (Join-Path $PluginRoot 'package.json') -PathType Leaf)) {
    throw 'Missing plugin\package.json. Run packaging from a complete project checkout.'
}
Push-Location -LiteralPath $PluginRoot
try {
    & $NpmPath pack --pack-destination $DistRoot --cache (Join-Path $ProjectRoot '.data\npm-cache')
    if ($LASTEXITCODE -ne 0) { throw "npm pack failed with exit code $LASTEXITCODE." }
} finally { Pop-Location }
