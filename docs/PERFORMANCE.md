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
- BL616 prefetch cache: three 16 KiB slots
- CherryUSB MSC callbacks: dedicated thread
- SD reads: CMD17 for one block, CMD18 plus CMD12 for multiple blocks
- SD writes: CMD24 or ACMD23 plus CMD25/CMD12, up to 32 blocks
- SD programming-busy deadline: 5 seconds

## Measured results

| Stage | Sequential read | Buffered sequential write |
| --- | ---: | ---: |
| Original single-sector bit-banged link | about 45 KiB/s | 32.37 KiB/s |
| 4 KiB batched bit-banged link | 128.55–142.37 KiB/s | 124.39 KiB/s |
| 4 KiB batched 4 MHz hardware SPI link | 265.17–289.75 KiB/s | 255.62 KiB/s |
| 16 KiB batched 4 MHz SCLK-domain link | 349.15-350.17 KiB/s steady | not tested |
| 16 KiB batched 6 MHz SCLK-domain link | 466.13-468.08 KiB/s | disabled |
| 16 KiB batched 6 MHz link with CMD18 | 555.48-557.05 KiB/s | disabled |
| 16 KiB 6 MHz CMD18 with background prefetch | 597.91-599.35 KiB/s steady | 416.96-425.79 KiB/s (16 MiB) |
| Same configuration, 64 MiB sustained test | not repeated | 534.64 KiB/s |

The validated 6 MHz CMD18 result averaged 556.51 KiB/s across three unbuffered
reads of the 3,190,784-byte aligned prefix of an existing file. CMD18 improved
the same 6 MHz path by about 19 percent over its 467.34 KiB/s CMD17 result. It
is about twice the previous 277.46 KiB/s stable average and about 12.4 times
the original read speed. The older results used a disposable aligned 4 MiB
file, so the generations are not a perfectly identical benchmark.

Five unbuffered reads of a 16 MiB disposable file measured 560.81, 598.99,
599.35, 597.91, and 598.79 KiB/s. The four steady runs average 598.76 KiB/s,
about 7.6 percent above the non-prefetched CMD18 result and about 13.3 times
the original read speed. At 6 MHz, the private SPI link is now the dominant
limit, so overlap mainly removes SD and USB idle gaps rather than producing a
multi-megabyte result.

Writes are enabled. Two 16 MiB forced-flush tests measured 425.79 and
416.96 KiB/s; a 64 MiB forced-flush test measured 534.64 KiB/s. Every file
matched its source SHA-256 after readback. The final exFAT scan found no
problems and zero bad sectors.

These figures describe one card and host. USB caching, file-system allocation,
SD-card behavior, and request size can change the result.

## Running the benchmarks

Create and write a test file with the existing read/write benchmark:

```powershell
.\scripts\benchmark-reader.ps1 -DriveLetter D -SizeMiB 4
```

Write, verify, run five unbuffered reads, and then automatically remove the
same disposable file:

```powershell
.\scripts\benchmark-reader.ps1 -DriveLetter D -SizeMiB 16 -ReadRuns 5
```

Measure a file without the Windows file cache:

```powershell
.\scripts\benchmark-read.ps1 -Path D:\tn20k-benchmark.bin
```

The unbuffered reader requires a file whose length is divisible by 512 bytes.
Use a disposable test file and verify its hash before and after hardware or
timing changes.

## Current limits

Single-block reads use CMD17. Multi-block reads issue one CMD18, receive up to
32 consecutive sectors with per-lane CRC16, then issue CMD12 and wait for DAT0
to leave busy. The two FPGA banks, three BL616 prefetch slots, and MSC thread
now overlap SD fill, SPI return, and USB endpoint service for sequential
16 KiB requests. Random or short I/O cancels prediction and uses a synchronous
transfer.

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
2. Remove or coalesce private-link status exchanges.
3. Re-evaluate DMA only after the polling transport is stable above 6 MHz.
