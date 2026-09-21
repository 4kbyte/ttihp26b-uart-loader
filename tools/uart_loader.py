#!/usr/bin/env python3
"""Host CLI for the TinyTapeout UART SPI RAM Loader."""

from __future__ import annotations

import argparse
from collections.abc import Iterator
import hashlib
from pathlib import Path
import time
from typing import Callable, Protocol

VERSION = 1
MAX_BYTES = 65536
PROTOCOL_MAX_TRANSFER_BYTES = 255
MAX_REQUEST_PAYLOAD = 3 + PROTOCOL_MAX_TRANSFER_BYTES
MAX_RESPONSE_PAYLOAD = 2 + PROTOCOL_MAX_TRANSFER_BYTES
ATTEMPTS = 3

PING = 0x00
CAPABILITIES = 0x01
WRITE = 0x11
READ = 0x12
STATUS = 0x14

OK = 0x00
MEMORY_FAULT = 0x07


class Transport(Protocol):
    """Exchange framed loader messages."""

    def exchange(self, request: bytes) -> bytes:
        """Send one request and return one response."""
        ...


class CommandError(RuntimeError):
    """Report one rejected loader command."""

    def __init__(self, opcode: int, status: int, data: bytes, sequence: int):
        """Capture command identity and optional write progress."""
        self.opcode = opcode
        self.status = status
        self.sequence = sequence
        self.completed_bytes = (
            int.from_bytes(data, "little") if status == MEMORY_FAULT else None
        )
        detail = (
            f", completed_bytes={self.completed_bytes}"
            if self.completed_bytes is not None
            else ""
        )
        super().__init__(
            f"command 0x{opcode:02x} sequence 0x{sequence:02x} "
            f"failed with status 0x{status:02x}{detail}"
        )


def crc16(data: bytes) -> int:
    """Calculate CRC-16/CCITT-FALSE."""
    value = 0xFFFF
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = (
                ((value << 1) ^ 0x1021) & 0xFFFF
                if value & 0x8000
                else (value << 1) & 0xFFFF
            )
    return value


def request_frame(opcode: int, sequence: int, payload: bytes = b"") -> bytes:
    """Encode one loader request."""
    if len(payload) > MAX_REQUEST_PAYLOAD:
        raise ValueError(f"payload exceeds {MAX_REQUEST_PAYLOAD}-byte protocol maximum")
    body = bytes((VERSION, opcode, sequence)) + len(payload).to_bytes(2, "little")
    body += payload
    return b"\xa5\x5a" + body + crc16(body).to_bytes(2, "little")


def decode_response(frame: bytes) -> tuple[int, int, int, bytes]:
    """Decode and validate one loader response."""
    if len(frame) < 10 or frame[:2] != b"\x5a\xa5":
        raise ValueError("invalid response framing")
    length = int.from_bytes(frame[5:7], "little")
    if length < 1 or length > MAX_RESPONSE_PAYLOAD or len(frame) != 9 + length:
        raise ValueError("invalid response length")
    if crc16(frame[2:-2]) != int.from_bytes(frame[-2:], "little"):
        raise ValueError("invalid response CRC")
    if frame[2] != VERSION or not frame[3] & 0x80:
        raise ValueError("invalid response header")
    return frame[3] & 0x7F, frame[4], frame[7], frame[8:-2]


def decode_command_response(
    frame: bytes, opcode: int, sequence: int
) -> tuple[int, bytes]:
    """Match one response to its request."""
    response_opcode, response_sequence, status, data = decode_response(frame)
    if response_opcode != opcode:
        raise ValueError("response opcode mismatch")
    if response_sequence != sequence:
        raise ValueError("response sequence mismatch")
    if status == MEMORY_FAULT and len(data) != 2:
        raise ValueError("invalid MEMORY_FAULT response")
    return status, data


def _check_bytes(data: list[int]) -> None:
    """Reject values outside one byte."""
    if any(value < 0 or value > 0xFF for value in data):
        raise ValueError("bytes must be 0..255")


def parse_image(path: Path, image_format: str = "auto") -> bytes:
    """Read one binary or hexadecimal byte image."""
    data = path.read_bytes()
    fmt = image_format
    if fmt == "auto":
        fmt = "hex" if path.suffix.lower() in (".hex", ".txt") else "bin"
    if fmt == "bin":
        image = data
    elif fmt == "hex":
        tokens = data.decode("ascii").replace(",", " ").split()
        values = [int(token, 16) for token in tokens]
        _check_bytes(values)
        image = bytes(values)
    else:
        raise ValueError(f"unsupported image format: {fmt}")
    if len(image) > MAX_BYTES:
        raise ValueError(f"image exceeds {MAX_BYTES} bytes")
    return image


def _check_range(start: int, count: int) -> None:
    """Reject ranges outside the physical SRAM."""
    if start < 0 or count < 0 or start + count > MAX_BYTES:
        raise ValueError(f"byte range exceeds 0..{MAX_BYTES - 1}")


def _transfer_chunks(
    start: int, count: int, chunk_size: int
) -> Iterator[tuple[int, int]]:
    """Yield protocol-sized address ranges."""
    for address in range(start, start + count, chunk_size):
        yield address, min(chunk_size, start + count - address)


class LoaderClient:
    """Issue validated commands through a loader transport."""

    def __init__(
        self, transport: Transport, report: Callable[[str], None] | None = print
    ):
        """Create a client at sequence zero."""
        self.transport, self.report, self.sequence = transport, report, 0
        self.max_transfer_bytes: int | None = None

    def command(self, opcode: int, payload: bytes = b"") -> bytes:
        """Exchange one command with bounded transport retries."""
        frame = request_frame(opcode, self.sequence, payload)
        last_error: Exception | None = None
        for attempt in range(1, ATTEMPTS + 1):
            try:
                status, data = decode_command_response(
                    self.transport.exchange(frame), opcode, self.sequence
                )
                break
            except (OSError, ValueError) as error:
                last_error = error
                if self.report is not None:
                    self.report(f"retry {attempt}/{ATTEMPTS}: {error}")
        else:
            raise RuntimeError(
                f"transport failed after {ATTEMPTS} attempts"
            ) from last_error
        sequence = self.sequence
        self.sequence = (self.sequence + 1) & 0xFF
        if status != OK:
            raise CommandError(opcode, status, data, sequence)
        return data

    def ping(self) -> bytes:
        """Verify the loader identity."""
        identity = self.command(PING)
        if identity != b"ULR1":
            raise RuntimeError(f"unexpected loader identity {identity!r}")
        return identity

    def capabilities(self) -> dict[str, int]:
        """Read the loader capability record."""
        data = self.command(CAPABILITIES)
        if len(data) != 9:
            raise RuntimeError("invalid CAPABILITIES response")
        capabilities = {
            "version": data[0],
            "data_bits": data[1],
            "bytes": int.from_bytes(data[2:6], "little"),
            "max_transfer": data[6],
            "commands": int.from_bytes(data[7:9], "little"),
        }
        if capabilities["data_bits"] != 8 or capabilities["bytes"] != MAX_BYTES:
            raise RuntimeError("unsupported CAPABILITIES memory geometry")
        if not 1 <= capabilities["max_transfer"] <= PROTOCOL_MAX_TRANSFER_BYTES:
            raise RuntimeError("invalid CAPABILITIES transfer limit")
        self.max_transfer_bytes = capabilities["max_transfer"]
        return capabilities

    def status(self) -> dict[str, int]:
        """Read memory and protocol status."""
        data = self.command(STATUS)
        if len(data) != 3:
            raise RuntimeError("invalid STATUS response")
        return {
            "memory_ready": data[0] & 1,
            "memory_fault": data[1] & 7,
            "protocol_error": data[2] & 1,
        }

    def read_bytes(self, start: int, count: int) -> bytes:
        """Read a bounded byte range in protocol-sized chunks."""
        _check_range(start, count)
        result = bytearray()
        for address, size in _transfer_chunks(start, count, self._get_transfer_limit()):
            data = self.command(READ, address.to_bytes(2, "little") + bytes((size,)))
            if len(data) != 1 + size or data[0] != size:
                raise RuntimeError(f"invalid READ response at 0x{address:04x}")
            result.extend(data[1:])
        return bytes(result)

    def write_bytes(self, start: int, data: bytes, verify: bool = False) -> None:
        """Write bytes in protocol-sized chunks and optionally verify them."""
        _check_range(start, len(data))
        for address, size in _transfer_chunks(
            start, len(data), self._get_transfer_limit()
        ):
            offset = address - start
            chunk = data[offset : offset + size]
            self._write_with_repair(address, chunk)
        if verify:
            self.verify_bytes(start, data)

    def _write_with_repair(self, start: int, data: bytes) -> None:
        """Repair one partially completed write chunk."""
        payload = start.to_bytes(2, "little") + bytes((len(data),)) + data
        for attempt in range(1, ATTEMPTS + 1):
            try:
                self.command(WRITE, payload)
                return
            except CommandError as error:
                if error.status != MEMORY_FAULT:
                    raise
                actual = self.read_bytes(start, len(data))
                if actual == data:
                    return
                if attempt == ATTEMPTS:
                    raise RuntimeError(
                        f"write repair failed at 0x{start:04x} "
                        f"after {ATTEMPTS} attempts"
                    ) from error
                if self.report is not None:
                    self.report(
                        f"repairing partial write at 0x{start:04x} "
                        f"(attempt {attempt + 1}/{ATTEMPTS})"
                    )

    def _get_transfer_limit(self) -> int:
        """Discover and cache the hardware transfer limit."""
        if self.max_transfer_bytes is None:
            self.capabilities()
        assert self.max_transfer_bytes is not None
        return self.max_transfer_bytes

    def verify_bytes(self, start: int, expected: bytes) -> str:
        """Verify bytes and return their SHA-256 digest."""
        actual = self.read_bytes(start, len(expected))
        if actual != expected:
            first = next(
                i for i, pair in enumerate(zip(actual, expected)) if pair[0] != pair[1]
            )
            raise RuntimeError(
                f"verify mismatch at 0x{start + first:04x}: "
                f"read {actual[first]:02x}, expected {expected[first]:02x}"
            )
        return hashlib.sha256(actual).hexdigest()


class SerialTransport:
    """Exchange loader frames over a reconnecting serial port."""

    def __init__(
        self, port: str, baud: int = 115200, timeout: float = 2.0, serial_module=None
    ):
        """Open the configured serial port."""
        if serial_module is None:
            try:
                import serial as serial_module  # type: ignore[import-not-found]
            except ImportError as error:
                raise RuntimeError("pyserial is required") from error
        self.module, self.port, self.baud, self.timeout = (
            serial_module,
            port,
            baud,
            timeout,
        )
        self.serial = self._open()

    def _open(self):
        """Open a serial endpoint."""
        return self.module.Serial(self.port, baudrate=self.baud, timeout=self.timeout)

    def _read_sync(self) -> bytes:
        """Read through the response synchronization marker."""
        deadline, sync = time.monotonic() + self.timeout, b""
        while time.monotonic() < deadline:
            byte = self.serial.read(1)
            if not byte:
                break
            sync = (sync + byte)[-2:]
            if sync == b"\x5a\xa5":
                return sync
        raise TimeoutError("response synchronization timeout")

    def _read_exact(self, count: int, description: str) -> bytes:
        """Read an exact response segment."""
        data = self.serial.read(count)
        if len(data) != count:
            raise TimeoutError(f"incomplete response {description}")
        return data

    def exchange(self, request: bytes) -> bytes:
        """Exchange one frame and reopen after disconnection."""
        try:
            self.serial.reset_input_buffer()
            self.serial.write(request)
            sync = self._read_sync()
            header = self._read_exact(5, "header")
            length = int.from_bytes(header[3:5], "little")
            tail = self._read_exact(length + 2, "body")
            return sync + header + tail
        except self.module.SerialException:
            try:
                self.serial.close()
            finally:
                self.serial = self._open()
            raise


def _number(value: str) -> int:
    """Parse a decimal or prefixed integer."""
    return int(value, 0)


def _add_image_arguments(parser: argparse.ArgumentParser) -> None:
    """Add shared image arguments to a subcommand."""
    parser.add_argument("image", type=Path)
    parser.add_argument("--format", choices=("auto", "bin", "hex"), default="auto")
    parser.add_argument("--start", type=_number, default=0)


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="COM3, /dev/ttyUSB0, etc.")
    parser.add_argument("--baud", type=int, default=115200)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("ping")
    sub.add_parser("capabilities")
    sub.add_parser("status")
    read = sub.add_parser("read")
    read.add_argument("start", type=_number)
    read.add_argument("count", type=_number)
    write = sub.add_parser("write")
    write.add_argument("start", type=_number)
    write.add_argument("bytes", nargs="+", type=_number)
    load = sub.add_parser("load")
    _add_image_arguments(load)
    load.add_argument("--no-verify", action="store_true")
    dump = sub.add_parser("dump")
    dump.add_argument("path", type=Path)
    dump.add_argument("--start", type=_number, default=0)
    dump.add_argument("--count", type=_number, default=MAX_BYTES)
    verify = sub.add_parser("verify")
    _add_image_arguments(verify)
    return parser


def run_command(args: argparse.Namespace, client: LoaderClient) -> None:
    """Execute one parsed command."""
    if args.command == "ping":
        print(client.ping().decode())
    elif args.command == "capabilities":
        print(client.capabilities())
    elif args.command == "status":
        print(client.status())
    elif args.command == "read":
        data = client.read_bytes(args.start, args.count)
        print(" ".join(f"{value:02x}" for value in data))
    elif args.command == "write":
        _check_bytes(args.bytes)
        client.write_bytes(args.start, bytes(args.bytes), verify=True)
    elif args.command == "load":
        data = parse_image(args.image, args.format)
        client.write_bytes(args.start, data, verify=not args.no_verify)
        digest = hashlib.sha256(data).hexdigest()
        print(f"wrote {len(data)} bytes; SHA-256 {digest}")
    elif args.command == "dump":
        data = client.read_bytes(args.start, args.count)
        args.path.write_bytes(data)
        print(f"dumped {len(data)} bytes")
    elif args.command == "verify":
        data = parse_image(args.image, args.format)
        print(client.verify_bytes(args.start, data))


def main() -> int:
    """Run the loader CLI."""
    args = build_parser().parse_args()
    run_command(args, LoaderClient(SerialTransport(args.port, args.baud)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
