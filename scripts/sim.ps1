[CmdletBinding()]
param(
    [string]$Iverilog = "iverilog",
    [string]$Vvp = "vvp"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

$iverilogCommand = Get-Command $Iverilog -ErrorAction SilentlyContinue
if ($iverilogCommand) {
    $Iverilog = $iverilogCommand.Source
} else {
    $Iverilog = Join-Path $repoRoot ".deps\iverilog\bin\iverilog.exe"
}
$vvpCommand = Get-Command $Vvp -ErrorAction SilentlyContinue
if ($vvpCommand) {
    $Vvp = $vvpCommand.Source
} else {
    $Vvp = Join-Path $repoRoot ".deps\iverilog\bin\vvp.exe"
}
if (-not (Test-Path -LiteralPath $Iverilog)) {
    throw "iverilog not found: $Iverilog"
}
if (-not (Test-Path -LiteralPath $Vvp)) {
    throw "vvp not found: $Vvp"
}

function Invoke-VerilogTest {
    param(
        [Parameter(Mandatory)][string]$Top,
        [Parameter(Mandatory)][string]$Output,
        [Parameter(Mandatory)][string[]]$Sources
    )

    & $Iverilog -g2005-sv -Wall -s $Top -o $Output @Sources
    if ($LASTEXITCODE -ne 0) {
        throw "Icarus compilation failed for $Top."
    }
    & $Vvp $Output
    if ($LASTEXITCODE -ne 0) {
        throw "Simulation failed for $Top."
    }
}

Push-Location $repoRoot
try {
    Invoke-VerilogTest -Top "tb_sd_native_data_tx" `
        -Output "sim\sd_native_data_tx.vvp" `
        -Sources @(
            "src\sd_native_data_tx.v",
            "sim\tb_sd_native_data_tx.sv"
        )

    Invoke-VerilogTest -Top "tb_fpga_spi_block_bridge" `
        -Output "sim\fpga_spi_block_bridge.vvp" `
        -Sources @(
            "src\fpga_spi_block_bridge.v",
            "sim\tb_fpga_spi_block_bridge.sv"
        )

    Invoke-VerilogTest -Top "tb_sd_native_block_device_read_batch" `
        -Output "sim\sd_native_block_device_read_batch.vvp" `
        -Sources @(
            "src\sd_native_clock.v",
            "src\sd_native_command.v",
            "src\sd_native_data_rx.v",
            "src\sd_native_data_tx.v",
            "src\sd_native_block_device.v",
            "sim\tb_sd_native_block_device_read_batch.sv"
        )

    & $Iverilog -g2005-sv -Wall -s sd_native_block_device `
        -o "sim\sd_native_block_device_compile.vvp" `
        "src\sd_native_clock.v" `
        "src\sd_native_command.v" `
        "src\sd_native_data_rx.v" `
        "src\sd_native_data_tx.v" `
        "src\sd_native_block_device.v"
    if ($LASTEXITCODE -ne 0) {
        throw "Icarus compile check failed for sd_native_block_device."
    }
}
finally {
    Pop-Location
}
