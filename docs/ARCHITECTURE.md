# Architecture

## Data path

```text
Windows USB MSC
      |
    BL616
  CherryUSB MSC thread + 16 KiB transfer buffer
  three 16 KiB background prefetch slots
      |
  private mode-0 SPI link at 6 MHz
  CS=GPIO0, SCLK=GPIO1, MOSI=GPIO27, MISO=GPIO30
      |
   GW2AR-18 FPGA
  SCLK-domain frontend + two 16 KiB read banks
      |
  native SD 4-bit controller
      |
    microSD
```

The FPGA runs from a 48 MHz system clock and generates a 24 MHz SD clock.
Initialization uses CMD0, CMD8, ACMD41, CMD2, CMD3, CMD9, CMD7, ACMD6, and
CMD16 where applicable. The card must be SDHC or SDXC.

Single-block reads use CMD17. Multi-block reads issue one CMD18, collect up to
32 sequential sectors in a 16 KiB buffer, then issue CMD12 and wait for DAT0
to leave busy before returning the batch. Writes use CMD24 for one sector and
`CMD55 -> ACMD23 -> CMD25 -> CMD12` for batches of up to 32 sectors. Each SD
lane has an independent CRC16. The BL616/FPGA transport uses CRC32 for
payloads. The validated image sets `ALLOW_WRITES=1`.

The BL616 drives SCLK, MOSI, and MISO with hardware SPI0 in mode 0. GPIO0
remains a software-controlled chip select so it stays asserted across the
request, FPGA processing delay, and response. The current validated clock is
6 MHz and transfers use the polling SPI API. The bit-banged implementation is
kept as a compile-time fallback by setting `FPGA_LINK_USE_HW_SPI=0`.

The FPGA SPI shifter and bit counters run directly from SCLK. MISO changes on
falling edges and is sampled by the BL616 on rising edges. Toggle mailboxes
cross compact request and response descriptors to the 48 MHz system domain,
while payload bytes use dual-clock block RAM. A two-bank owner state machine
tracks `FREE -> PRODUCER -> READY -> CONSUMER`.

The FPGA may start filling a free bank while the other bank is ready or being
returned over SPI. The BL616 background worker reserves two 16 KiB cache
slots, starts the first read, starts the second read into the other FPGA bank,
retrieves the first while the second is filling, then retrieves the second.
Three BL616 slots allow one READY slot to serve the USB MSC thread while the
worker fills the other two. The MSC callbacks run in CherryUSB thread mode;
the lower-priority prefetch task runs while endpoint transfers wait for USB,
so SD access, private-link transfer, and USB service overlap.

High-level private-link operations have a separate mutex so the multi-exchange
start/status/data sequence cannot interleave with a direct read or write.
Writes cancel speculative reads before taking this operation lock. SD write
completion uses a five-second real-time deadline and yields between busy
polls, accommodating card erase and page-folding pauses.

The design is constrained at 20 MHz SCLK. The validated place-and-route
reported 38.747 MHz SCLK Fmax and zero setup/hold TNS for constrained clock
domains. A 10 MHz board experiment nevertheless returned inconsistent read
data; restoring 6 MHz produced a clean file-system scan and matching file
hashes, so the deployed private-link clock remains 6 MHz. DMA is not part of
the validated implementation.

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
