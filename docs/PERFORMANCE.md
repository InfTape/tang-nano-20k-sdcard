# Performance notes

## Validated configuration

- Tang Nano 20K v3923
- 125 GB SDXC card formatted as exFAT
- Windows USB Mass Storage host
- FPGA system clock: 48 MHz
- Native SD bus: 4-bit at 24 MHz
- BL616 private link: hardware SPI0, mode 0, 4 MHz, polling
- Transfer batch: up to eight 512-byte sectors (4 KiB)

## Measured results

| Stage | Sequential read | Buffered sequential write |
| --- | ---: | ---: |
| Original single-sector bit-banged link | about 45 KiB/s | 32.37 KiB/s |
| 4 KiB batched bit-banged link | 128.55–142.37 KiB/s | 124.39 KiB/s |
| 4 KiB batched 4 MHz hardware SPI link | 265.17–289.75 KiB/s | 255.62 KiB/s |

The final read average from two unbuffered 4 MiB runs was 277.46 KiB/s.
The 4 MiB write completed at 255.62 KiB/s and its SHA-256 hash matched after
reading the file back.

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
not yet use CMD18 multi-block read. Every private-link transfer also uses
status polling, and the FPGA receives SPI through a synchronizer in the 48 MHz
system-clock domain.

A 6 MHz private-link test was not reliable: USB enumerated, but the reported
card capacity was corrupt. No write was attempted at that setting. Returning
to 4 MHz restored the correct capacity and the file system passed a read-only
check.

An experimental DMA transport was also rejected because it prevented normal
startup. The published path intentionally uses hardware SPI polling only.
Future DMA work should be attempted after the FPGA SPI clock-domain boundary
is made robust and should retain polling for short protocol messages or move
all messages to a consistently managed DMA path.

## Next optimization order

1. Replace repeated CMD17 reads with CMD18 plus CMD12 termination.
2. Remove or coalesce private-link status exchanges.
3. Redesign the FPGA SPI receive path around SCLK with explicit CDC at block
   boundaries.
4. Increase the batch size and add double buffering.
5. Re-evaluate DMA after the transport is stable above 4 MHz.
