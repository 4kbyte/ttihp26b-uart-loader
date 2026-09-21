# UART Loader Protocol

## Transport

UART is 115200 baud, 8 data bits, no parity, one stop bit. Multi-byte numeric
fields are little-endian. A request is:

| Bytes | Field                                  |
|------:|----------------------------------------|
|     2 | Sync `A5 5A`                           |
|     1 | Version `01`                           |
|     1 | Opcode                                 |
|     1 | Sequence                               |
|     2 | Payload length                         |
|     N | Payload                                |
|     2 | CRC-16/CCITT-FALSE, little-endian      |

The CRC starts at `FFFF`, uses polynomial `1021`, and covers version through
the final payload byte. A response uses sync `5A A5`, opcode `request|80`,
the request sequence, and a payload whose first byte is status. Response data
follows status.

## Commands

| Opcode | Command      | Request                                | Successful response data                                                         |
|-------:|--------------|----------------------------------------|----------------------------------------------------------------------------------|
|   `00` | PING         | empty                                  | ASCII `ULR1`                                                                     |
|   `01` | CAPABILITIES | empty                                  | `version:u8`, `data_bits:u8`, `bytes:u32`, `max_transfer:u8`, `command_mask:u16` |
|   `11` | WRITE        | `start:u16`, `count:u8`, `count` bytes | empty                                                                            |
|   `12` | READ         | `start:u16`, `count:u8`                | `count:u8`, `count` bytes                                                        |
|   `14` | STATUS       | empty                                  | `memory_ready:u8`, `memory_fault:u8`, `protocol_error:u8`                        |

The maximum READ and WRITE count is an RTL parameter in the range 1..255 and
is returned by CAPABILITIES. The default is 16 bytes. Valid byte addresses are
`0000..FFFF`; `start + count` may equal `10000` but not exceed it. The command
mask is `0018`, with bit 3 for READ and bit 4 for WRITE.

## Status and errors

| Value | Meaning       |
|------:|---------------|
|  `00` | OK            |
|  `01` | BAD_VERSION   |
|  `02` | BAD_OPCODE    |
|  `03` | BAD_LENGTH    |
|  `04` | BAD_CRC       |
|  `06` | BAD_ADDRESS   |
|  `07` | MEMORY_FAULT  |

On a memory fault, response data is a little-endian 16-bit count of bytes
completed before the failing byte. The protocol-error STATUS bit is sticky
after protocol validation errors and clears only on electrical reset.

## SPI mapping

Reset sends `WRMR 40`, then `RDMR 00`, and accepts the SRAM only when mode
bits `7:6` read back as `01`. SPI uses mode 0 and MSB-first command/address
bits. Each loader address maps directly to one SRAM byte address.

## Worked PING vector

Request, sequence `2A`:

```text
A5 5A 01 00 2A 00 00 5A FA
```

Response:

```text
5A A5 01 80 2A 05 00 00 55 4C 52 31 60 4D
```
