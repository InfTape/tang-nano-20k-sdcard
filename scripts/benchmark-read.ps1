[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path,

    [ValidateRange(4, 4096)]
    [int]$BufferKiB = 1024
)

$ErrorActionPreference = "Stop"
$Path = [System.IO.Path]::GetFullPath($Path)
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "File not found: $Path"
}

$file = Get-Item -LiteralPath $Path
$bufferBytes = $BufferKiB * 1KB
if (($file.Length % 512) -ne 0) {
    throw "Unbuffered reads require a file length divisible by 512 bytes."
}
if (($bufferBytes % 512) -ne 0) {
    throw "BufferKiB must produce a 512-byte-aligned buffer."
}

if (-not ("Tn20kNativeFile" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class Tn20kNativeFile
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
        SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
        string name, uint access, uint share, IntPtr security,
        uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadFile(
        SafeFileHandle handle, IntPtr buffer, uint count,
        out uint bytesRead, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr VirtualAlloc(
        IntPtr address, UIntPtr size, uint allocationType, uint protect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool VirtualFree(
        IntPtr address, UIntPtr size, uint freeType);
}
"@
}

$genericRead = [Convert]::ToUInt32("80000000", 16)
$shareAll = [uint32]0x00000007
$openExisting = [uint32]3
$noBuffering = [uint32]0x20000000
$sequentialScan = [uint32]0x08000000
$memCommitReserve = [uint32]0x00003000
$pageReadWrite = [uint32]0x00000004
$memRelease = [uint32]0x00008000
$bufferSizePointer = [UIntPtr]::new([uint64]$bufferBytes)

$handle = [Tn20kNativeFile]::CreateFile(
    $Path, $genericRead, $shareAll, [IntPtr]::Zero, $openExisting,
    ($noBuffering -bor $sequentialScan), [IntPtr]::Zero)
if ($handle.IsInvalid) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "CreateFile failed with Win32 error $errorCode."
}

$buffer = [Tn20kNativeFile]::VirtualAlloc(
    [IntPtr]::Zero, $bufferSizePointer,
    $memCommitReserve, $pageReadWrite)
if ($buffer -eq [IntPtr]::Zero) {
    $handle.Dispose()
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "VirtualAlloc failed with Win32 error $errorCode."
}

try {
    [long]$remaining = $file.Length
    [long]$totalRead = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($remaining -gt 0) {
        [uint32]$request = [Math]::Min(
            [long]$bufferBytes, $remaining)
        [uint32]$bytesRead = 0
        if (-not [Tn20kNativeFile]::ReadFile(
            $handle, $buffer, $request, [ref]$bytesRead,
            [IntPtr]::Zero)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "ReadFile failed with Win32 error $errorCode."
        }
        if ($bytesRead -eq 0) {
            throw "Unexpected end of file after $totalRead bytes."
        }
        $totalRead += $bytesRead
        $remaining -= $bytesRead
    }
    $timer.Stop()

    [pscustomobject]@{
        Path = $Path
        Bytes = $totalRead
        ReadSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        ReadKiBPerSecond = [Math]::Round(
            ($totalRead / 1KB) / $timer.Elapsed.TotalSeconds, 2)
        ReadMiBPerSecond = [Math]::Round(
            ($totalRead / 1MB) / $timer.Elapsed.TotalSeconds, 3)
        NoBuffering = $true
    }
}
finally {
    $handle.Dispose()
    [void][Tn20kNativeFile]::VirtualFree(
        $buffer, [UIntPtr]::Zero, $memRelease)
}
