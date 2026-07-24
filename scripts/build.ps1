[CmdletBinding()]
param(
    [string]$GowinRoot = "C:\Gowin\Gowin_V1.9.11.03_Education_x64"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$gwsh = Join-Path $GowinRoot "IDE\bin\gw_sh.exe"
$buildScript = Join-Path $PSScriptRoot "build.tcl"
$bitstream = Join-Path $repoRoot "impl\pnr\tang_nano_20k_sdcard.fs"

if (-not (Test-Path -LiteralPath $gwsh)) {
    throw "Gowin shell not found: $gwsh. Pass -GowinRoot with your install path."
}

Push-Location $repoRoot
try {
    & $gwsh $buildScript
    if ($LASTEXITCODE -ne 0) {
        throw "Gowin synthesis/place-and-route failed."
    }
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $bitstream)) {
    throw "Build completed without the expected bitstream: $bitstream"
}

Write-Host "Bitstream: $bitstream"
