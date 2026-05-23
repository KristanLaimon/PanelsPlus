param(
    [string]$PluginName = "panels_plus"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutDir = Join-Path $ScriptDir "dist"
$PluginDir = Join-Path $OutDir "$PluginName.koplugin"

if (Test-Path $PluginDir) {
    Remove-Item -LiteralPath $PluginDir -Recurse -Force
}

New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null

Get-ChildItem -LiteralPath $ScriptDir -File |
    Where-Object { $_.Extension -eq ".lua" -or $_.Name -eq "_meta.lua" } |
    Copy-Item -Destination $PluginDir -Force

Copy-Item -LiteralPath (Join-Path $ScriptDir "src") -Destination $PluginDir -Recurse -Force

Write-Host "Created: $PluginDir"
Write-Host "Copy this folder to your KOReader plugins folder:"
Write-Host "  <koreader plugins directory>/$PluginName.koplugin"
