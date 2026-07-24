[CmdletBinding()]
param(
    [ValidateSet("Detect", "Sram", "Flash")]
    [string]$Mode = "Detect",

    [string]$Bitstream,

    [string]$OpenFPGALoader,

    [switch]$ConfirmFlash
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

$loaderDir = Split-Path -Parent $OpenFPGALoader
$env:PATH = "$loaderDir;$env:PATH"

if ($Mode -eq "Detect") {
    & $OpenFPGALoader -c dirtyJtag --detect
    if ($LASTEXITCODE -ne 0) {
        throw "DirtyJTAG detection failed."
    }
    exit 0
}

if (-not $Bitstream) {
    $Bitstream = Join-Path $repoRoot "impl\pnr\tang_nano_20k_sdcard.fs"
}
$Bitstream = [System.IO.Path]::GetFullPath($Bitstream)
if (-not (Test-Path -LiteralPath $Bitstream)) {
    throw "Bitstream not found: $Bitstream"
}

$hash = (Get-FileHash -LiteralPath $Bitstream -Algorithm SHA256).Hash
Write-Host "Bitstream SHA256: $hash"

if ($Mode -eq "Sram") {
    & $OpenFPGALoader -c dirtyJtag -m $Bitstream
} else {
    if (-not $ConfirmFlash) {
        throw "Flash mode is non-volatile. Re-run with -ConfirmFlash."
    }
    & $OpenFPGALoader -c dirtyJtag -f --verify $Bitstream
}
if ($LASTEXITCODE -ne 0) {
    throw "FPGA $Mode programming failed."
}
