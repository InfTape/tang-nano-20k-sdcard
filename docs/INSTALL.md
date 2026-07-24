# Build and installation

This project has been tested on Tang Nano 20K revision `v3923`.

## Prerequisites

- Gowin EDA Education (tested with 1.9.11.03)
- Icarus Verilog
- WSL for the BL616 build
- Bouffalo SDK v2.3.16
- Bouffalo T-Head RISC-V toolchain
- openFPGALoader 1.1.1 or newer for DirtyJTAG recovery

Dependencies belong under `.deps/` and are ignored by Git.

## Verify and build

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sim.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
wsl bash ./scripts/build-bl616.sh
```

Outputs:

- `impl/pnr/tang_nano_20k_sdcard.fs`
- `bl616/build/build_out/bl616_dirtyjtag_bl616.bin`

## Back up before changing firmware

Enter BL616 UART Boot by holding the button next to HDMI while connecting USB:

```powershell
.\scripts\backup-bl616.ps1 -Port COM6
```

Run it twice and confirm that both 4 MiB files have the same SHA-256. Backups
are written under the ignored `backup/` directory.

For an already converted board with a compatible signed loader, update only
the application:

```powershell
.\scripts\update-bl616-reader.ps1 -Port COM6
```

The script writes only `0x20000`. It does not install or replace the signed
loader at address zero.

> A fresh factory board may not boot an application placed at `0x20000`.
> Perform the one-time signed-loader conversion using the upstream
> `pepijndevos/bl616_dirtyjtag` recovery procedure, after making redundant
> full-flash backups. This repository intentionally does not distribute or
> overwrite that loader.

## Program the FPGA through DirtyJTAG

Hold `S2/KEY2` while connecting USB, keep it held for at least six seconds,
then release it.

```powershell
.\scripts\program-fpga-dirtyjtag.ps1 -Mode Detect
.\scripts\program-fpga-dirtyjtag.ps1 -Mode Sram
```

SRAM programming is volatile. If LEDs 0 and 1 turn on, make a full 8 MiB
configuration-flash backup and then program non-volatile flash:

```powershell
.\scripts\backup-fpga-flash.ps1
.\scripts\program-fpga-dirtyjtag.ps1 -Mode Flash -ConfirmFlash
```

The factory Gowin FT2232 path remains available in `program.ps1` (SRAM) and
`flash-fpga.ps1` (configuration flash) when the original debugger firmware is
active.

## Normal and recovery boot

- Reader: insert the card and connect USB without pressing a button.
- DirtyJTAG: hold `S2/KEY2` for at least six seconds while connecting USB.
- BL616 UART Boot: hold the BL616 button next to HDMI while connecting USB.
