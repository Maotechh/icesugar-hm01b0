# Validation Record

Bench-tested on 2026-09-08: DGX Spark, Ubuntu 24.04.4 ARM64, iCESugar v1.5
UP5K-SG48 and 16-pin Arducam HM01B0 matching the UC-805 schematic. The observed
model ID was `0x01b0`. See [toolchain versions](toolchain.md) and [wiring](wiring.md).

## Tested RTL Revision

The final camera RTL used 1720/5280 logic cells, 4/4 SPRAM blocks and 1/1 PLL.
nextpnr seed 1 with `--opt-timing` reported **48.94 MHz**, passing the required
48 MHz. Timing failure was never permitted. The native build used Yosys v0.68,
nextpnr 0.11.1, IceStorm's pinned commit, GCC 13.3.0 and CMake 3.28.3.

The original bench bitstream SHA256 was:

```text
7fa5488084c0d419cfd2dc3caf390eda2071bb3a416c1a730f4882a41c9d5ce5
```

This is an identification record, not a promise of bit-identical builds with
every compiler/library version. Always inspect the timing result of a rebuild.
The public repository contains source and tests, not prebuilt FPGA binaries.

## Hardware Results

| Check | Observed result |
| --- | --- |
| 20 walking-one frames | Every byte matches, flags 0 |
| Three standby/restart captures | Every byte matches, flags 0 |
| Five real-image frames | Correct framing/CRC, flags 0 |
| Wrong-edge diagnostic, mode 2 | Rejected with odd-nibble, line-length and unstable-sample flags |
| Five subsequent visual-check frames | Recognizable scene, no visible row displacement, tearing or pixel-block corruption |

Every accepted raw frame contained 79,056 bytes, 244 lines and exactly 648
nibbles per line. Walking frames had raw CRC32 `02236c02` and SHA256:

```text
86bb849802628d06d89b14d4155d6cd78a90e14d7fc2c6a520e9b688f89a6b2d
```

Protocol error counters remained zero during normal operation. Real images
had distinct hashes. The host verified the transport CRC and saved RAW, JSON,
PGM and PNG; saved hashes and crop bytes were independently rechecked. The
intentional invalid frame retained only RAW/JSON and returned a failing exit
status. Capture recovered without reflashing the FPGA.

Private photographs, USB identifiers and machine-specific logs are excluded
from this public repository. These are maintainer-reported historical results;
the included tests and commands let contributors perform their own verification.

## Regression Coverage

`make test` covers:

- All four nibble-order/clock-edge modes and 256 varied-timing frames.
- 128 per-wire one/two-cycle pulse cases at four offsets around the sample edge.
- Mid-frame arm, reset/rearm, malformed line/frame counts, overflow and timeout.
- I2C write/read, repeated START, ACK/NACK, clock stretching and timeout.
- UART commands, CRC16/32, incomplete request timeout and busy-command handling.
- All 79,056 bytes of a simulated frame through RAM and UART.
- Python configuration/readback, packet corruption, metadata, walking sequence
  and PNG checksum/decompression tests.

Fault injection found a two-clock data pulse that could corrupt two compared
observations without raising an error. The final receiver also compares the
following synchronized observation, and all injected cases now pass the
invariant that changed captured bytes must raise the unstable-sample flag.
This is detection and rejection, not silent pixel correction.

## Important Findings

- `0x1012=0` removes two extra bytes per line caused by the reset sync offset.
- The tested `0x3052=0x50` write reads back as `0xD0`, reproduced across three
  resets. Its internal bit meaning is unconfirmed. This exact exception is
  documented and checked; do not broaden it by masking unrelated readbacks.
- A registered RAM read address shortens the SPRAM input path while retaining
  full-frame byte alignment.
- Real scenes still have sensor noise and clipped highlights. Acceptance was
  normal recognizable images without visible acquisition corruption, not ideal
  photographic quality.

Simulation does not model analog metastability. PCLK must remain at or below
6 MHz with the configured sampling window. No temperature/supply/cable-length
stress qualification was performed. A stable wrong level across the entire
sample window can be indistinguishable from valid camera data; the parallel
camera bus has no source CRC. Do not claim unconditional absence of all glitches.
