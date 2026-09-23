param(
    [string]$PluginName = "panelsplus"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutDir = Join-Path $ScriptDir "dist"
$BundledDir = Join-Path $OutDir "${PluginName}_with_ocrmodels.koplugin"
$ManualDir = Join-Path $OutDir "$PluginName.koplugin"
$OcrDir = Join-Path $ScriptDir "data/ocr"

Get-Content -LiteralPath (Join-Path $OcrDir "SHA256SUMS") | ForEach-Object {
    if ($_ -notmatch '^([0-9a-f]{64})  (.+)$') {
        throw "Invalid OCR checksum entry: $_"
    }
    $Expected = $Matches[1]
    $ModelPath = Join-Path $OcrDir $Matches[2]
    if (-not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
        throw "Missing bundled OCR model: $ModelPath"
    }
    $Actual = (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) {
        throw "OCR checksum mismatch: $ModelPath"
    }
}

foreach ($PackageDir in @($BundledDir, $ManualDir, (Join-Path $OutDir "$PluginName-manual-ocr.koplugin"))) {
    if (Test-Path $PackageDir) {
        Remove-Item -LiteralPath $PackageDir -Recurse -Force
    }
}

function Copy-PluginFiles([string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $ScriptDir -File |
        Where-Object { $_.Extension -eq ".lua" -or $_.Name -eq "_meta.lua" } |
        Copy-Item -Destination $Destination -Force

    Copy-Item -LiteralPath (Join-Path $ScriptDir "src") -Destination $Destination -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $ScriptDir "locales") -Destination $Destination -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $ScriptDir "data") -Destination $Destination -Recurse -Force
}

Copy-PluginFiles $BundledDir
Copy-PluginFiles $ManualDir
Remove-Item -LiteralPath (Join-Path $ManualDir "data/ocr") -Recurse -Force

Write-Host "Bundled OCR: $BundledDir"
Write-Host "Manual OCR:  $ManualDir"
Write-Host "Install only one of these folders in KOReader's plugins directory."
