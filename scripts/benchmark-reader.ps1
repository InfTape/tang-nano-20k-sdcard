[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z]$")]
    [string]$DriveLetter,

    [ValidateRange(1, 64)]
    [int]$SizeMiB = 1,

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
    [pscustomobject]@{
        Path = $path
        Bytes = $data.Length
        WriteSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        WriteKiBPerSecond = [Math]::Round(
            ($data.Length / 1KB) / $timer.Elapsed.TotalSeconds, 2)
        SHA256 = $actual
        HashMatch = ($expected -eq $actual)
    }
} finally {
    if (-not $Keep -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force
    }
}
