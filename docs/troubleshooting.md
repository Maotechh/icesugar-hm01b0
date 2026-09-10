# Troubleshooting

## No iCELink serial device

Keep both iCESugar UART jumpers fitted and connect the USB port attached to the
board's iCELink. Check discovery without changing permissions:

```sh
ls -l /dev/serial/by-id/usb-MuseLab_DAPLink_CMSIS-DAP_*-if01
python3 host/camera.py --port /dev/ttyACM0 status
```

Use the stable `/dev/serial/by-id/` path when available. The host requires
exactly one automatically discovered iCELink device; use `--port` when more
than one is present. Do not run capture with `sudo`.

## Programming

The iCESugar v1.5 uses its built-in iCELink mass-storage programmer. Copy only
the generated bitstream after confirming the mountpoint is the iCELink volume:

```sh
ICELINK_MOUNT="/media/$(id -un)/iCELink"
findmnt --mountpoint "$ICELINK_MOUNT"
cp build/camera.bin "$ICELINK_MOUNT/camera.bin"
sync -f "$ICELINK_MOUNT"
```

Wait for the copy and sync to finish. A disappearing `camera.bin` is normal;
`FAIL.TXT` indicates that programming failed. `iceprog` is included for
compatible external FTDI/SPI programmers, not for the built-in iCELink path.

## Probe or configuration fails

First confirm power, common ground, and the exact signal labels on the module.
The tested module supplies its own 24 MHz XCLK and has I2C pull-ups to 2.8 V.
Do not drive XCLK or add 3.3 V I2C pull-ups. Confirm D1 is on P2_1 / FPGA pin
46, not P1_2. Run the walking pattern before attempting a real image:

```sh
python3 host/camera.py status
python3 host/camera.py probe
python3 host/camera.py configure --pattern walking
python3 host/camera.py capture --mode 0 --walking --count 10
```

## Invalid frame or timeout

When a complete response fails frame metadata or walking-pattern checks, the
host preserves `.raw` and `.json` evidence and exits nonzero. A transport CRC
failure, truncation or disconnect may leave no complete frame to save; the
command still fails, without silently retrying the capture.
Invalid frames never produce `.png` or `.pgm` files. Each capture run
uses a new timestamped output directory, and existing frame files are refused
rather than overwritten. An explicit `--output` must also name a new directory.
Inspect the JSON error flags and check that PCLK is at or below 6 MHz.

After unplugging/replugging or terminating a capture, the FPGA may still be
finishing its previous UART response. Rerun the command to reopen the port.
The host drains old input and retries only a read-only status query until a
valid protocol-v1 reply establishes a ready connection, with an 18-second
overall limit. It cannot cancel bytes already in flight. If synchronization
still fails, check programming and the two UART jumpers before retrying.

Successful `status` output has `version: 1` and `clock_hz: 48000000`. The
`enabled` field is false after programming or `standby`; `configure` enables it.
The protocol counters should not increase during an ordinary capture run.

For wiring or module revisions outside the tested Arducam B0315 / UC-805-style
hardware, record the board revision, module labels, tool versions, mode and
JSON flags in an issue. Do not attach private images, serial numbers or local
paths.
