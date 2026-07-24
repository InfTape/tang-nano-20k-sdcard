[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Port,

    [string]$Output,

    [string]$Length = "0x400000"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot `
    ".deps\bouffalo_sdk\tools\bflb_tools\bouffalo_flash_cube\BLFlashCommand.exe"

if (-not (Test-Path -LiteralPath $tool)) {
    throw "BLFlashCommand not found: $tool"
}

if (-not $Output) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Output = Join-Path $repoRoot "backup\bl616-flash-$stamp.bin"
}
$Output = [System.IO.Path]::GetFullPath($Output)
$outputDir = Split-Path -Parent $Output
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}
if (Test-Path -LiteralPath $Output) {
    throw "Refusing to overwrite existing backup: $Output"
}

& $tool `
    --interface uart `
    --port $Port `
    --chipname bl616 `
    --baudrate 2000000 `
    --flash --read `
    --start 0x0 `
    --len $Length `
    --file $Output

if ($LASTEXITCODE -ne 0) {
    throw "BL616 flash read failed."
}
if (-not (Test-Path -LiteralPath $Output)) {
    throw "Flash tool succeeded without creating $Output"
}

$file = Get-Item -LiteralPath $Output
$hash = Get-FileHash -LiteralPath $Output -Algorithm SHA256
Write-Host "Backup: $($file.FullName)"
Write-Host "Bytes : $($file.Length)"
Write-Host "SHA256: $($hash.Hash)"
