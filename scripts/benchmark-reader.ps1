[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z]$")]
    [string]$DriveLetter,

    [ValidateRange(1, 64)]
    [int]$SizeMiB = 1,

    [ValidateRange(0, 20)]
    [int]$ReadRuns = 0,

    [ValidateRange(4, 4096)]
    [int]$ReadBufferKiB = 1024,

    [switch]$Keep
)

$ErrorActionPreference = "Stop"
$root = "$($DriveLetter.ToUpper()):\"
if (-not (Test-Path -LiteralPath $root)) {
    throw "Drive not found: $root"
}

$path = Join-Path $root ("tn20k-benchmark-{0}.bin" -f $PID)
if (Test-Path -LiteralPath $path) {
    throw "Refusing to overwrite: $path"
}

$data = New-Object byte[] ($SizeMiB * 1MB)
$random = [System.Random]::new(3923)
$random.NextBytes($data)
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $expected = [BitConverter]::ToString(
        $sha.ComputeHash($data)).Replace("-", "")
} finally {
    $sha.Dispose()
}

try {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stream = [IO.FileStream]::new(
        $path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        262144,
        [IO.FileOptions]::SequentialScan)
    try {
        $stream.Write($data, 0, $data.Length)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    $timer.Stop()

    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $writeResult = [pscustomobject]@{
        Phase = "Write"
        Path = $path
        Bytes = $data.Length
        WriteSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        WriteKiBPerSecond = [Math]::Round(
            ($data.Length / 1KB) / $timer.Elapsed.TotalSeconds, 2)
        SHA256 = $actual
        HashMatch = ($expected -eq $actual)
    }
    $writeResult

    if (-not $writeResult.HashMatch) {
        throw "Written file SHA-256 did not match the source buffer."
    }

    if ($ReadRuns -gt 0) {
        $readScript = Join-Path $PSScriptRoot "benchmark-read.ps1"
        for ($run = 1; $run -le $ReadRuns; $run++) {
            $readResult = & $readScript -Path $path `
                -BufferKiB $ReadBufferKiB
            [pscustomobject]@{
                Phase = "Read"
                Run = $run
                Path = $path
                Bytes = $readResult.Bytes
                ReadSeconds = $readResult.ReadSeconds
                ReadKiBPerSecond = $readResult.ReadKiBPerSecond
                ReadMiBPerSecond = $readResult.ReadMiBPerSecond
                NoBuffering = $readResult.NoBuffering
            }
        }
    }
} finally {
    if (-not $Keep -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force
    }
}
