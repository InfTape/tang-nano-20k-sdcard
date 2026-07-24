# BL616 application

The BL616 application provides two mutually exclusive USB personalities:

- USB Mass Storage when the FPGA reports a valid SD capacity within five
  seconds of boot.
- DirtyJTAG v2 when the FPGA does not respond.

DirtyJTAG uses the Microsoft OS 1.0 `WINUSB` compatible ID and a separate USB
serial string. Windows therefore binds its in-box WinUSB driver without
affecting the Mass Storage personality.

The firmware is built with Bouffalo SDK v2.3.16 and FreeRTOS. The generated
application must fit in `0x20000..0x3ffff`. Use the root-level
`scripts/update-bl616-reader.ps1` script; it requires two matching full-flash
backups and never writes address zero.

See the root [README](../README.md) and
[installation guide](../docs/INSTALL.md) for the complete workflow.
