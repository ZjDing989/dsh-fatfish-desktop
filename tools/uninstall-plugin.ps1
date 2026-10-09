[CmdletBinding()]
param([string]$Profile = 'desktop')
$ErrorActionPreference = 'Stop'
if ($Profile -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Invalid profile name.' }
. (Join-Path $PSScriptRoot 'desktop-cli.ps1')
Invoke-HarnessDesktopCli -CliArguments @('plugin', '--profile', $Profile, 'remove', 'dsh-plugin-fatfish-desktop')
