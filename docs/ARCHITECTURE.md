# Architecture

## Data path

```text
Windows USB MSC
      |
    BL616
  CherryUSB + 4 KiB buffer
      |
  private synchronous GPIO link
  CS=GPIO0, SCLK=GPIO1, MOSI=GPIO27, MISO=GPIO30
      |
   GW2AR-18 FPGA
  native SD 4-bit controller
      |
    microSD
```

The FPGA runs from a 48 MHz system clock and generates a 24 MHz SD clock.
Initialization uses CMD0, CMD8, ACMD41, CMD2, CMD3, CMD9, CMD7, ACMD6, and
CMD16 where applicable. The card must be SDHC or SDXC.

Reads currently use CMD17 one sector at a time. Writes use CMD24 for one sector
and `CMD55 -> ACMD23 -> CMD25 -> CMD12` for batches of two to eight sectors.
Each SD lane has an independent CRC16. The BL616/FPGA transport uses CRC32 for
payloads.

## USB boot modes

The BL616 chooses exactly one USB personality at power-up:

- A valid FPGA capacity response within five seconds selects USB Mass Storage.
- No valid response selects DirtyJTAG.

Tang Nano 20K v3923 does not route the microSD socket's detect contacts to the
FPGA or BL616. To select recovery mode deterministically, hold `S2/KEY2` while
connecting USB and keep it held for at least six seconds. This holds the FPGA
endpoint in reset while the BL616 performs mode detection.

DirtyJTAG advertises a Microsoft OS 1.0 compatible ID, so current Windows
versions bind the in-box WinUSB driver without Zadig. MSC and DirtyJTAG use
different USB serial strings to keep Windows driver caches separate.

## BL616 flash layout

```text
0x00000..0x1ffff  signed first-stage loader (never touched by update script)
0x20000..0x3ffff  this repository's BL616 application
```

The application update script refuses images larger than 128 KiB and requires
two matching full-flash backups. It writes only `0x20000`.

## FPGA diagnostics

The six LEDs are active-low and sticky after the corresponding event:

| LED | Meaning |
| --- | --- |
| 0 | PLL locked and reset complete |
| 1 | SDHC/SDXC initialization complete |
| 2 | BL616 asserted private-link chip select |
| 3 | Private-link clock observed |
| 4 | Valid private-link request received |
| 5 | Response generated, or SD error |

In DirtyJTAG mode, after loading the reader bitstream to SRAM, LEDs 0 and 1 are
expected to be on. In reader mode, normal host probing eventually lights all
six.
