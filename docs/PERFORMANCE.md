# Performance notes

## Validated configuration

- Tang Nano 20K v3923
- 125 GB SDXC card formatted as exFAT
- Windows USB Mass Storage host
- FPGA system clock: 48 MHz
- Native SD bus: 4-bit at 24 MHz
- BL616 private link: hardware SPI0, mode 0, 6 MHz, polling
- FPGA private-link frontend: SCLK clock domain, mode 0
- Transfer batch: up to 32 512-byte sectors (16 KiB)
- Read buffering: two 16 KiB dual-clock banks
- FPGA writes disabled during high-speed read validation

## Measured results

| Stage | Sequential read | Buffered sequential write |
| --- | ---: | ---: |
| Original single-sector bit-banged link | about 45 KiB/s | 32.37 KiB/s |
| 4 KiB batched bit-banged link | 128.55–142.37 KiB/s | 124.39 KiB/s |
| 4 KiB batched 4 MHz hardware SPI link | 265.17–289.75 KiB/s | 255.62 KiB/s |
| 16 KiB batched 4 MHz SCLK-domain link | 349.15-350.17 KiB/s steady | not tested |
| 16 KiB batched 6 MHz SCLK-domain link | 466.13-468.08 KiB/s | disabled |

The validated 6 MHz result averaged 467.34 KiB/s across three unbuffered reads
of the 3,190,784-byte aligned prefix of an existing file. This is about 68
percent above the previous 277.46 KiB/s average and about 10.4 times the
original read speed. The older results used a disposable aligned 4 MiB file,
so the two generations are not a perfectly identical benchmark.

Writes are intentionally rejected by the current FPGA image while high-speed
read correctness is being established. The older 4 MHz image completed a
4 MiB write at 255.62 KiB/s and matched its SHA-256 hash after readback.

These figures describe one card and host. USB caching, file-system allocation,
SD-card behavior, and request size can change the result.

## Running the benchmarks

Create and write a test file with the existing read/write benchmark:

```powershell
.\scripts\benchmark-reader.ps1 -DriveLetter D -SizeMiB 4
```

Measure a file without the Windows file cache:

```powershell
.\scripts\benchmark-read.ps1 -Path D:\tn20k-benchmark.bin
```

The unbuffered reader requires a file whose length is divisible by 512 bytes.
Use a disposable test file and verify its hash before and after hardware or
timing changes.

## Current limits

The FPGA still performs batched reads as consecutive CMD17 operations. It does
not yet use CMD18 multi-block read. The two read banks and ownership state
machine are present, but the protocol still finishes the SD read before the
host retrieves that batch. SD access, SPI return, and USB service are not yet
fully overlapped.

The SPI shift logic now runs directly in the SCLK domain. Only request
descriptors, response descriptors, bank selection, and ownership state cross
to the 48 MHz system-clock domain; payload data uses dual-clock block RAM.

A 10 MHz private-link test enumerated with the correct capacity, but a
read-only file-system scan later observed inconsistent metadata and Windows
removed the volume. The FPGA image rejected all writes. Returning to the
validated 6 MHz firmware restored a clean file-system scan and all three
recorded file SHA-256 hashes, proving that the 10 MHz result was a link read
error rather than on-card corruption.

An experimental DMA transport was also rejected because it prevented normal
startup. The published path intentionally uses hardware SPI polling only.
Future DMA work should wait until the 10 MHz timing boundary is understood.
It should retain polling for short protocol messages or move all messages to
a consistently managed DMA path.

## Next optimization order

1. Diagnose the 10 MHz signal/timing boundary and optionally characterize an
   intermediate 8 MHz setting.
2. Replace repeated CMD17 reads with CMD18 plus CMD12 termination.
3. Schedule the second buffer as an actual prefetch target so SD reads,
   private-link return, and USB service overlap.
4. Remove or coalesce private-link status exchanges.
5. Re-evaluate DMA only after the polling transport is stable above 6 MHz.
