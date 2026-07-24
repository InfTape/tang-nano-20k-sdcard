[CmdletBinding()]
param(
    [string]$Output,
    [int]$SizeBytes = 0x800000,
    [string]$OpenFPGALoader
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $OpenFPGALoader) {
    $command = Get-Command openFPGALoader.exe -ErrorAction SilentlyContinue
    if ($command) {
        $OpenFPGALoader = $command.Source
    } else {
        $candidate = Get-ChildItem `
            -Path (Join-Path $repoRoot ".deps") `
            -Filter openFPGALoader.exe `
            -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) {
            $OpenFPGALoader = $candidate.FullName
        }
    }
}
if (-not $OpenFPGALoader -or
    -not (Test-Path -LiteralPath $OpenFPGALoader)) {
    throw "openFPGALoader.exe was not found. Install it or pass -OpenFPGALoader."
}
if ($SizeBytes -le 0) {
    throw "SizeBytes must be positive."
}

if (-not $Output) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Output = Join-Path $repoRoot "backup\fpga-flash-$stamp.bin"
}
$Output = [System.IO.Path]::GetFullPath($Output)
$outputDir = Split-Path -Parent $Output
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}
if (Test-Path -LiteralPath $Output) {
    throw "Refusing to overwrite existing backup: $Output"
}

$loaderDir = Split-Path -Parent $OpenFPGALoader
$env:PATH = "$loaderDir;$env:PATH"
& $OpenFPGALoader -c dirtyJtag --dump-flash `
    --file-size $SizeBytes $Output
if ($LASTEXITCODE -ne 0) {
    throw "FPGA flash backup failed."
}

$file = Get-Item -LiteralPath $Output
if ($file.Length -ne $SizeBytes) {
    throw "Unexpected backup size: $($file.Length), expected $SizeBytes."
}
$hash = (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash
Write-Host "Backup: $($file.FullName)"
Write-Host "Bytes : $($file.Length)"
Write-Host "SHA256: $hash"
