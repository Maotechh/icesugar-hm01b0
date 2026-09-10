# Changelog

## 0.1.0 - 2026-09-11

- Synchronize each serial connection with a bounded, read-only status handshake
  before configuration or capture; validate and discard delayed responses.
- Refuse existing output directories and frame files to preserve previous
  captures. Invalid frames create only RAW/JSON evidence, never stale PNG/PGM.
- Add output-collision and pseudo-terminal recovery regression tests.
- Add a least-privilege GitHub host-test workflow with no pip dependencies.
- Correct the README's UART pin explanation and add troubleshooting guidance.
- Force rebuilding in the alternate-toolchain example to avoid stale outputs.

The FPGA RTL and protocol-v1 wire format are unchanged. Existing programmed
boards do not need reflashing for these host-side fixes. Host regression tests
pass; this update has not received a new physical camera test.
