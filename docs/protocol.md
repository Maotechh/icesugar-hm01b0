# UART Protocol v1

115200 baud, 8 data bits, no parity, one stop bit, no flow control. Send one
request at a time and wait for its complete response. The host uses sequence
numbers and checks every response header, size, status and checksum.

On opening a port, the host drains old bytes and performs a bounded status-only
handshake before any user operation. A busy FPGA may drop that status request;
the host drains the previous response and retries status within 18 seconds.
Once synchronized, configuration and capture commands are never retried
automatically. Random initial sequence numbers alone are not synchronization.

## Request

Nine bytes, with multi-byte request fields in **big-endian** order:

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 2 | Magic ASCII `HC` |
| 2 | 1 | Operation |
| 3 | 1 | Sequence number |
| 4 | 2 | Sensor register address, or zero |
| 6 | 1 | Value or capture mode |
| 7 | 2 | CRC16-CCITT of bytes 0..6, polynomial 0x1021, initial 0xffff |

## Response

Multi-byte response fields are **little-endian**:

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 2 | Magic ASCII `HC` |
| 2 | 1 | Echoed operation |
| 3 | 1 | Echoed sequence |
| 4 | 1 | Status, zero for successful command |
| 5 | 4 | Payload length N |
| 9 | N | Payload |
| 9+N | 4 | IEEE CRC32 of header and payload, equivalent to Python zlib.crc32 |

The largest allowed payload is 131072 + 16 bytes. Status nonzero rejects a
command. A successful capture command may still contain **invalid frame flags**;
the host must check both status and metadata before accepting the image.

| Operation | Request | Response payload |
| --- | --- | --- |
| 0 | Status | 16 bytes described below |
| 1 | I2C register write, address/value | One byte; value not meaningful for writes |
| 2 | I2C register read, address | One register byte |
| 3 | Enable control, value 0 or 1 | Echoed enable value |
| 4 | Capture, value mode 0..3 | 16-byte metadata followed by raw image |

The I2C slave address is fixed at 7-bit `0x24`; register addresses are 16 bits.
Read transactions use repeated START. Status errors include `0x10 | byte_index`
for NACK, `0x20` for a non-idle bus, `0x21` for I2C timeout, `0x30` for disabled
camera control and `0x31` for an unsupported operation.

Status payload: byte 0 version (1), byte 1 enabled, byte 2 GPIO snapshot,
byte 3 reserved; uint16 counters at 4/6/8 for request CRC/UART/busy errors;
bytes 10..11 reserved; uint32 clock_hz at 12. GPIO bits 7..0 are SCL, SDA, INT,
VSYNC, HREF, PCLK, D1, D0. Counters are 16-bit and wrap; read them during long runs.

Bad request CRC produces no response. Requests while busy are counted and
dropped. Incomplete requests time out after about 100 ms and increment the
UART error counter. Use bounded host timeouts, not implicit retries.

## Frame Metadata

The first 16 payload bytes use Python struct format `<IHHHBBI`:

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 4 | Raw byte count |
| 4 | 2 | Line count |
| 6 | 2 | Minimum nibbles per line |
| 8 | 2 | Maximum nibbles per line |
| 10 | 1 | Error flags |
| 11 | 1 | Actual capture mode |
| 12 | 4 | Active frame duration in 48 MHz cycles |

Flags bit 0..7: odd nibbles, wrong line length, wrong line count, overlapping
sync, buffer overflow, unstable sample, short PCLK, capture timeout.

Mode bit 0 selects high-nibble-first (1) versus low-nibble-first (0); bit 1
selects falling (1) versus rising (0) PCLK. The tested module uses **mode 0**
with sensor `0x3068=0x20`. Do not select a mode solely by visual appearance:
validate it with the walking pattern.

A valid raw frame has 79056 bytes, 244 lines, min/max 648 nibbles, flags 0 and
the requested mode. Crop rows 2..241 and columns 2..321 to obtain 320x240.
Walking-one pixels repeat `01 02 04 08 10 20 40 80 00`; all-zero data is invalid.

The host's JSON `crc32`/`sha256` describe the **raw image alone**, while the
wire CRC32 covers the entire response header and payload. They are distinct
checksums with different scopes.
