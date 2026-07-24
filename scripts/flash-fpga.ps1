[CmdletBinding()]
param(
    [string]$GowinRoot = "C:\Gowin\Gowin_V1.9.11.03_Education_x64",
    [int]$CableIndex = 1
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$programmer = Join-Path $GowinRoot "Programmer\bin\programmer_cli.exe"
$bitstream = Join-Path $repoRoot "impl\pnr\tang_nano_20k_sdcard.fs"

if (-not (Test-Path -LiteralPath $programmer)) {
    throw "Gowin programmer not found: $programmer"
}
if (-not (Test-Path -LiteralPath $bitstream)) {
    throw "Bitstream not found. Run scripts\build.ps1 first."
}

$hash = Get-FileHash -LiteralPath $bitstream -Algorithm SHA256
Write-Host "Programming Tang Nano 20K external configuration Flash through GAO-Bridge."
Write-Host "Bitstream SHA256: $($hash.Hash)"

& $programmer `
    --device GW2AR-18C `
    --run 37 `
    --fsFile $bitstream `
    --frequency "2.5MHz" `
    --cable "Gowin USB Cable(FT2CH)" `
    --cable-index $CableIndex

if ($LASTEXITCODE -ne 0) {
    throw "FPGA external Flash programming or verification failed."
}
