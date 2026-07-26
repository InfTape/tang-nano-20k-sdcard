# Tang Nano 20K native 4-bit SD card reader

This repository turns the onboard microSD socket of a Tang Nano 20K v3923
into a USB Mass Storage device. The FPGA talks to the card in native SD 4-bit
mode; the onboard BL616 exposes either the card reader or a DirtyJTAG recovery
interface over the board's existing USB connector.

## What works

- SDHC/SDXC initialization at a 24 MHz SD clock
- Native 4-bit reads with per-lane CRC16
- Up to 32 sectors (16 KiB) per private-link read
- CMD17 single-block reads and CMD18/CMD12 multi-block reads
- Native 4-bit write datapath with CMD24 and CMD25 (disabled in the current
  read-only validation image)
- Up to eight sectors (4 KiB) per multi-block write when enabled
- SCLK-domain mode-0 SPI slave with descriptor-based clock-domain crossing
- Two 16 KiB dual-clock read buffers with explicit ownership tracking
- BL616 hardware SPI0 transport at a validated 6 MHz
- USB Mass Storage on Windows
- DirtyJTAG v2 recovery through the same USB connector
- Automatic WinUSB binding for DirtyJTAG; Zadig is not required
- Full FPGA and BL616 backup scripts
- Icarus Verilog simulation and Gowin synthesis scripts

The default FPGA image never reads or writes a card sector by itself. Sector
access happens only in response to a USB Mass Storage request.

## Measured performance

Hardware: Tang Nano 20K v3923, 125 GB SDXC card, Windows, exFAT.

| Operation | Result |
| --- | ---: |
| Sequential read before batching and hardware SPI | about 45 KiB/s |
| 4 MiB no-buffering read after 4 KiB batching | 128.55–142.37 KiB/s |
| 4 MiB no-buffering read with 4 MHz hardware SPI | 265.17–289.75 KiB/s |
| 4 MiB buffered write with 4 MHz hardware SPI | 255.62 KiB/s |
| 3.04 MiB no-buffering read with 6 MHz SPI and 16 KiB batches | 466.13-468.08 KiB/s |
| 3.04 MiB no-buffering read with 6 MHz SPI and CMD18 | 555.48-557.05 KiB/s |

The current read-only validation configuration averages 556.51 KiB/s for
repeated unbuffered reads, about 12.4 times the original read speed. It uses
BL616 SPI0 in polling mode with software-controlled chip select; DMA is
deliberately not enabled. Single-block reads use CMD17; multi-block reads use
one CMD18 followed by CMD12 while collecting up to 32 sectors in a 16 KiB
buffer. Actual SD/SPI/USB overlap remains future optimization work. A 10 MHz
hardware test returned inconsistent read data, so 6 MHz is the validated
limit.

See [Performance notes](docs/PERFORMANCE.md) for benchmark commands, tested
configurations, and current limits.

## Boot modes

The BL616 selects one USB personality at power-up:

| Action | USB device |
| --- | --- |
| Insert SD card and connect USB normally | Mass Storage reader |
| Hold `S2/KEY2` for at least 6 seconds while connecting USB | DirtyJTAG |
| Hold the BL616 button next to HDMI while connecting USB | BL616 UART Boot |

The v3923 microSD detect contacts are tied to ground and are not routed to the
FPGA or BL616. Recovery mode therefore uses `S2/KEY2` to hold the FPGA endpoint
in reset during the BL616's five-second mode-selection window.

## Quick start

Run simulations and build the FPGA:

```powershell
.\scripts\sim.ps1
.\scripts\build.ps1
```

Build the BL616 application in WSL:

```powershell
wsl bash ./scripts/build-bl616.sh
```

Detect and test the FPGA through DirtyJTAG:

```powershell
.\scripts\program-fpga-dirtyjtag.ps1 -Mode Detect
.\scripts\program-fpga-dirtyjtag.ps1 -Mode Sram
```

After a successful volatile SRAM test, back up and program configuration Flash:

```powershell
.\scripts\backup-fpga-flash.ps1
.\scripts\program-fpga-dirtyjtag.ps1 -Mode Flash -ConfirmFlash
```

See [Build and installation](docs/INSTALL.md) before changing BL616 Flash.
The BL616 update script writes only the application slot at `0x20000` and
requires two matching 4 MiB backups.

## Repository layout

```text
bl616/       BL616 FreeRTOS, CherryUSB MSC, DirtyJTAG and private-link firmware
constraints/ Tang Nano 20K v3923 pin and timing constraints
docs/        architecture and installation notes
patches/     small CherryUSB changes applied by the BL616 build
scripts/     simulation, build, backup and programming entry points
sim/         self-checking Verilog testbenches
src/         native SD controller and BL616/FPGA transport
```

## Hardware mapping

### Native SD interface

| Signal | FPGA pin |
| --- | ---: |
| DAT2 | 80 |
| DAT3 | 81 |
| CMD | 82 |
| CLK | 83 |
| DAT0 | 84 |
| DAT1 | 85 |

### BL616 private link

| Function | BL616 GPIO | FPGA pin |
| --- | ---: | ---: |
| CS | 0 | 86 |
| SCLK | 1 | 13 |
| MOSI | 27 | 76 |
| MISO | 30 | 75 |

See [Architecture](docs/ARCHITECTURE.md) for the data path, LED meanings, USB
mode selection and Flash layout.

## Verification performed

- Native SD transmit CRC/status/busy simulation
- BL616 link INFO, 4 KiB READ, 512-byte WRITE and 4 KiB WRITE with CRC32
- Standalone compile of the native SD block controller
- Gowin synthesis, placement and routing at a constrained 48 MHz
- DirtyJTAG detection of `GW2A(R)-18(C)`, IDCODE `0x81B`
- Volatile SRAM load followed by external configuration-Flash write/verify
- USB enumeration, exFAT mount, file hash comparison, hardware write test,
  and repeated no-buffering 4 MiB read benchmarks

## Credits

- [DirtyJTAG](https://github.com/jeanthom/DirtyJTAG) for the protocol
- [pepijndevos/bl616_dirtyjtag](https://github.com/pepijndevos/bl616_dirtyjtag)
  for the Tang Nano 20K BL616 recovery work
- [CherryUSB](https://github.com/cherry-embedded/CherryUSB)
- [Bouffalo SDK](https://github.com/bouffalolab/bouffalo_sdk)
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader)

## License

MIT
