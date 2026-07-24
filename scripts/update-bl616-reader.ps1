[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Port
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot `
    ".deps\bouffalo_sdk\tools\bflb_tools\bouffalo_flash_cube\BLFlashCommand.exe"
$firmware = Join-Path $repoRoot `
    "bl616\build\build_out\bl616_dirtyjtag_bl616.bin"

if (-not (Test-Path -LiteralPath $tool)) {
    throw "BLFlashCommand not found: $tool"
}
if (-not (Test-Path -LiteralPath $firmware)) {
    throw "Reader firmware not found: $firmware"
}

$firmwareFile = Get-Item -LiteralPath $firmware
if ($firmwareFile.Length -le 0 -or $firmwareFile.Length -gt 0x20000) {
    throw "Reader firmware is outside its 0x20000..0x3FFFF slot."
}
$firmwareHash = (Get-FileHash -LiteralPath $firmware -Algorithm SHA256).Hash

$backups = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "backup") `
    -Filter "bl616-flash-*.bin" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -eq 0x400000 } |
    Sort-Object LastWriteTime)
if ($backups.Count -lt 2) {
    throw "Two complete 4 MiB factory backups are required."
}
$backupHashA = (Get-FileHash -LiteralPath $backups[-2].FullName -Algorithm SHA256).Hash
$backupHashB = (Get-FileHash -LiteralPath $backups[-1].FullName -Algorithm SHA256).Hash
if ($backupHashA -ne $backupHashB) {
    throw "The two newest factory backups do not match."
}

Write-Host ("Updating reader only: {0} bytes at 0x20000." -f $firmwareFile.Length)
Write-Host "Reader SHA256 : $firmwareHash"
Write-Host "Backup SHA256 : $backupHashA"

# BLFlashCommand performs a device-side XIP SHA-256 verification.
& $tool `
    --interface uart `
    --port $Port `
    --chipname bl616 `
    --baudrate 2000000 `
    --flash --write `
    --start 0x20000 `
    --file $firmware

if ($LASTEXITCODE -ne 0) {
    throw "Reader update or device-side SHA-256 verification failed."
}

Write-Host "Reader update programmed and device-verified; signed loader untouched."
