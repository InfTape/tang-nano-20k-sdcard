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

# SRAM programming is volatile and does not modify the BL616 firmware.
& $programmer `
    --device GW2AR-18C `
    --run 2 `
    --fsFile $bitstream `
    --cable "Gowin USB Cable(FT2CH)" `
    --cable-index $CableIndex

if ($LASTEXITCODE -ne 0) {
    throw "FPGA SRAM programming failed."
}
