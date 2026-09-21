# TinyTapeout UART SPI RAM Loader

A compact TinyTapeout design that loads and inspects a 23LC512-compatible
SPI SRAM through a CRC-protected UART protocol.

## Hardware

- 50 MHz system clock
- 115200 baud, 8N1 UART
- 65,536 byte addresses
- SPI mode 0 at 6.25 MHz
- 23LC512 sequential-mode initialization and readback verification

The loader supports `PING`, `CAPABILITIES`, `WRITE`, `READ`, and `STATUS`.
The exact wire format and vectors are in [docs/protocol.md](docs/protocol.md).

## Host CLI

Run these commands from the repository root. The host CLI is
`tools/uart_loader.py`.

Install pyserial:

```sh
python -m pip install pyserial==3.5
```

Use either a Windows COM port or a Linux tty:

```sh
python tools/uart_loader.py --port COM4 ping
python tools/uart_loader.py --port /dev/ttyUSB0 status
python tools/uart_loader.py --port COM4 write 0x100 0x12 0x34
python tools/uart_loader.py --port COM4 read 0x100 2
python tools/uart_loader.py --port COM4 load firmware.bin
python tools/uart_loader.py --port COM4 load firmware.hex --format hex
python tools/uart_loader.py --port COM4 dump ram.bin --start 0 --count 65536
python tools/uart_loader.py --port COM4 verify firmware.bin
```

Binary images map directly to SRAM bytes. Hex images contain whitespace- or
comma-separated byte values. Writes are chunked to the transfer size reported
by the hardware, retried with a fixed bound, repaired after partial memory
faults, and verified by default.

## Verification

```sh
cd test
make
```
