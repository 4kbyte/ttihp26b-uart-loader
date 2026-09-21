"""Verify host framing, transport recovery, and memory operations."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("host", ROOT / "tools" / "uart_loader.py")
assert SPEC and SPEC.loader
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)


def response_frame(opcode: int, sequence: int, status: int, data: bytes = b"") -> bytes:
    """Encode one simulated loader response."""
    payload = bytes((status,)) + data
    body = bytes((host.VERSION, opcode | 0x80, sequence))
    body += len(payload).to_bytes(2, "little") + payload
    return b"\x5a\xa5" + body + host.crc16(body).to_bytes(2, "little")


class FakeTransport:
    """Simulate loader commands against in-memory bytes."""

    def __init__(self):
        """Create empty memory and fault controls."""
        self.memory = bytearray(host.MAX_BYTES)
        self.requests: list[bytes] = []
        self.failures: list[str] = []
        self.partial_once: tuple[int, int] | None = None

    def exchange(self, request: bytes) -> bytes:
        """Execute one simulated request."""
        self.requests.append(request)
        if self.failures:
            failure = self.failures.pop(0)
            if failure == "timeout":
                raise TimeoutError("injected")
            if failure == "disconnect":
                raise OSError("injected")
            if failure == "corrupt":
                result = bytearray(response_frame(request[3], request[4], 0, b"ULR1"))
                result[-1] ^= 1
                return bytes(result)
        opcode, sequence = request[3], request[4]
        length = int.from_bytes(request[5:7], "little")
        payload = request[7 : 7 + length]
        if opcode == host.PING:
            data = b"ULR1"
        elif opcode == host.CAPABILITIES:
            data = bytes((1, 8)) + (65536).to_bytes(4, "little")
            data += bytes((16, 0x18, 0))
        elif opcode == host.STATUS:
            data = b"\x01\x00\x00"
        elif opcode == host.READ:
            start, count = int.from_bytes(payload[:2], "little"), payload[2]
            data = bytes((count,)) + self.memory[start : start + count]
        elif opcode == host.WRITE:
            start, count = int.from_bytes(payload[:2], "little"), payload[2]
            values = payload[3 : 3 + count]
            if self.partial_once == (start, count):
                self.partial_once = None
                self.memory[start] = values[0]
                return response_frame(opcode, sequence, host.MEMORY_FAULT, b"\x01\x00")
            self.memory[start : start + count] = values
            data = b""
        else:
            raise AssertionError(opcode)
        return response_frame(opcode, sequence, host.OK, data)


class HostTests(unittest.TestCase):
    def test_exact_ping_and_crc_vectors(self):
        self.assertEqual(
            host.request_frame(host.PING, 0x2A),
            bytes.fromhex("A5 5A 01 00 2A 00 00 5A FA"),
        )
        response = bytes.fromhex("5A A5 01 80 2A 05 00 00 55 4C 52 31 60 4D")
        self.assertEqual(host.decode_response(response), (0, 0x2A, 0, b"ULR1"))

    def test_framing_rejects_corruption_and_bounds(self):
        valid = response_frame(host.STATUS, 2, 0, b"\x01\x00\x00")
        damaged = bytearray(valid)
        damaged[-1] ^= 1
        with self.assertRaisesRegex(ValueError, "CRC"):
            host.decode_response(bytes(damaged))
        with self.assertRaisesRegex(ValueError, "maximum"):
            host.request_frame(host.WRITE, 0, bytes(host.MAX_REQUEST_PAYLOAD + 1))
        with self.assertRaisesRegex(ValueError, "framing"):
            host.decode_response(b"bad")

    def test_commands_chunking_dump_and_verify(self):
        transport = FakeTransport()
        client = host.LoaderClient(transport, report=None)
        self.assertEqual(client.ping(), b"ULR1")
        capabilities = client.capabilities()
        self.assertEqual(capabilities["bytes"], 65536)
        self.assertEqual(capabilities["max_transfer"], 16)
        self.assertEqual(client.status()["memory_ready"], 1)
        data = bytes(range(35))
        client.write_bytes(65536 - len(data), data, verify=True)
        self.assertEqual(transport.memory[-35:], data)
        writes = [request for request in transport.requests if request[3] == host.WRITE]
        self.assertEqual([request[9] for request in writes], [16, 16, 3])
        self.assertEqual(client.read_bytes(65535, 1), b"\x22")
        with self.assertRaisesRegex(ValueError, "range"):
            client.read_bytes(65535, 2)

    def test_partial_write_repair(self):
        transport = FakeTransport()
        transport.partial_once = (4, 3)
        diagnostics: list[str] = []
        client = host.LoaderClient(transport, diagnostics.append)
        client.write_bytes(4, b"\x11\x22\x33")
        self.assertEqual(transport.memory[4:7], b"\x11\x22\x33")
        self.assertEqual(
            [request[3] for request in transport.requests],
            [host.CAPABILITIES, host.WRITE, host.READ, host.WRITE],
        )
        self.assertTrue(any("repairing partial write" in line for line in diagnostics))

    def test_memory_fault_progress_requires_two_bytes(self):
        error = host.CommandError(host.WRITE, host.MEMORY_FAULT, b"\x02\x01", 7)
        self.assertEqual(error.completed_bytes, 0x0102)
        malformed = response_frame(host.WRITE, 7, host.MEMORY_FAULT, b"\x02")
        with self.assertRaisesRegex(ValueError, "MEMORY_FAULT"):
            host.decode_command_response(malformed, host.WRITE, 7)

    def test_bounded_retry_timeout_corruption_disconnect(self):
        for failure in ("timeout", "corrupt", "disconnect"):
            with self.subTest(failure=failure):
                transport = FakeTransport()
                transport.failures = [failure]
                client = host.LoaderClient(transport, report=None)
                self.assertEqual(client.ping(), b"ULR1")
                self.assertEqual(len(transport.requests), 2)
                self.assertEqual(transport.requests[0], transport.requests[1])
        transport = FakeTransport()
        transport.failures = ["timeout"] * host.ATTEMPTS
        with self.assertRaisesRegex(RuntimeError, "after 3 attempts"):
            host.LoaderClient(transport, report=None).ping()

    def test_binary_hex_parsing_hash_and_mismatch(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            root = Path(directory)
            binary = root / "image.bin"
            binary.write_bytes(bytes.fromhex("34 12 cd ab"))
            text = root / "image.hex"
            text.write_text("34 12 cd ab\n", encoding="ascii")
            self.assertEqual(host.parse_image(binary), bytes.fromhex("34 12 cd ab"))
            self.assertEqual(host.parse_image(text), bytes.fromhex("34 12 cd ab"))
            invalid = root / "invalid.hex"
            invalid.write_text("100\n", encoding="ascii")
            with self.assertRaisesRegex(ValueError, "0..255"):
                host.parse_image(invalid)
        transport = FakeTransport()
        client = host.LoaderClient(transport, report=None)
        client.write_bytes(0, b"\x01\x02")
        self.assertEqual(
            client.verify_bytes(0, b"\x01\x02"),
            "a12871fee210fb8619291eaea194581cbd2531e4b23759d225f6806923f63222",
        )
        with self.assertRaisesRegex(RuntimeError, "verify mismatch"):
            client.verify_bytes(0, b"\x01\x03")

    def test_serial_reopens_after_disconnect(self):
        valid = FakeTransport()

        class SerialException(OSError):
            pass

        class Endpoint:
            def __init__(self, fail):
                self.fail, self.data, self.closed = fail, b"", False

            def reset_input_buffer(self):
                pass

            def write(self, request):
                if self.fail:
                    raise SerialException("disconnect")
                self.data = valid.exchange(request)

            def read(self, count):
                result, self.data = self.data[:count], self.data[count:]
                return result

            def close(self):
                self.closed = True

        class Module:
            def __init__(self):
                self.endpoints = []

            def Serial(self, _port, baudrate, timeout):
                endpoint = Endpoint(not self.endpoints)
                self.endpoints.append(endpoint)
                return endpoint

        Module.SerialException = SerialException
        module = Module()
        client = host.LoaderClient(
            host.SerialTransport("COM9", serial_module=module), report=None
        )
        self.assertEqual(client.ping(), b"ULR1")
        self.assertEqual(len(module.endpoints), 2)
        self.assertTrue(module.endpoints[0].closed)


if __name__ == "__main__":
    unittest.main()
