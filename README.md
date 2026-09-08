# iCESugar HM01B0

An open-source FPGA camera capture project by [Maotechh](https://github.com/Maotechh).
Capture Arducam HM01B0 grayscale images using an **iCESugar v1.5 / iCE40UP5K**,
with synthesis, place-and-route and programming performed directly on an
**NVIDIA DGX Spark (Ubuntu 24.04, ARM64)**.

[中文说明](README.zh-CN.md) | [Wiring](docs/wiring.md) |
[Toolchain](docs/toolchain.md) | [Validation](docs/validation.md) |
[Protocol](docs/protocol.md)

```text
HM01B0 four-bit pixels -> FPGA frame capture -> 128 KiB SPRAM
                      -> CRC32-protected UART -> DGX Spark -> RAW / PNG / PGM
```

- Verilog RTL for I2C configuration, nibble assembly, frame checks and buffering.
- Three synchronized data observations detect short pulses around the sample point.
- Strict host-side packet, frame-size, line-count and test-pattern validation.
- Python standard library only; no pip dependencies, GUI or SoC framework.
- Simulation with Yosys CXXRTL and the system C++ compiler, no extra simulator.

This is **single-frame acquisition**, not live video. A 324x244 raw frame takes
about seven seconds to transfer at 115200 baud. Valid images are cropped to
320x240; intervening free-running sensor frames are not acquired.

## Hardware

Tested with iCESugar **v1.5**, UP5K **SG48**, and the 16-pin Arducam module whose
labels match the **B0315 / UC-805** schematic. Other module revisions need
verification before use.

**Read the [wiring and voltage notes](docs/wiring.md) before powering up.**
The module has its own 24 MHz oscillator: **the FPGA must not drive XCLK**.
Use 3.3 V for module VCC, not a GPIO. The module's I2C pull-ups are to 2.8 V;
the FPGA uses open-drain outputs without additional 3.3 V pull-ups.

Camera **D1 goes to P2_1 / FPGA pin 46**, leaving UART pin 4 free. Both board
UART jumpers must be fitted. Flashing uses built-in **iCELink**, not FTDI iceprog.

## Quick Start

On Ubuntu 24.04 / DGX OS, clone into a directory without spaces:

```sh
git clone https://github.com/Maotechh/icesugar-hm01b0.git
cd icesugar-hm01b0
```

Install only the [required build dependencies](docs/toolchain.md), then:

```sh
make toolchain
make all
make test
```

The script builds pinned Yosys, nextpnr-ice40 and IceStorm sources locally under
`work/`. It enables only the UP5K nextpnr database and disables GUI and Python
bindings. `make all` enforces 48 MHz timing; timing failures stop the build.

After confirming that the mounted volume really is the connected iCELink:

```sh
ICELINK_MOUNT="/media/$(id -un)/iCELink"
findmnt --mountpoint "$ICELINK_MOUNT"
# Continue only if the preceding command identifies the actual iCELink volume.
cp build/camera.bin "$ICELINK_MOUNT/camera.bin"
sync -f "$ICELINK_MOUNT"
```

Wait for both commands to finish and check the volume for `FAIL.TXT` before
using serial. iCELink prints programming messages over CDC while flashing;
the bitstream file disappearing from its virtual drive afterward is normal.
Adjust `ICELINK_MOUNT` if your desktop mounts it elsewhere.

First validate all four data wires with the deterministic walking-one pattern:

```sh
python3 host/camera.py status
python3 host/camera.py probe
python3 host/camera.py configure --pattern walking
python3 host/camera.py capture --mode 0 --walking --count 10
```

Then acquire a real image with sensor automatic exposure/gain:

```sh
python3 host/camera.py configure --pattern image
python3 host/camera.py capture --mode 0 --count 1
python3 host/camera.py standby
```

The host automatically selects exactly one iCELink serial port. To select one
explicitly, put `--port /dev/ttyACM0` **before** the subcommand. The user must
have read/write access to the port; use your distribution's serial-device group
policy, not `sudo` for image capture or world-writable device permissions.

Results go to a timestamped directory under `outputs/`. Failed frames retain
RAW and JSON evidence, produce a nonzero exit status and stop the run. No
requested frame is silently skipped or retried. `standby` stops sensor streaming
and releases FPGA control; `disable` alone only releases control. Neither stops
the module's onboard oscillator while powered.

## Validation And Limitations

The tested FPGA revision passed 20 walking-one frames, three restart captures,
five real-image frames and an intentional wrong-edge rejection. Five additional
real frames were visually checked for a recognizable scene without row shifts,
tearing or pixel-block corruption. See [results and exact versions](docs/validation.md).
Private photographs and machine-specific logs are intentionally not published.

- PCLK must remain at or below 6 MHz with the configured stability window.
- `0x1012=0` is necessary to remove the sensor's reset-default sync offset.
- The tested module reads `0x3052` as `0xD0` after writing `0x50`. This exact
  board-specific readback is checked, not silently masked; other revisions may differ.
- CRC32 protects FPGA-to-host transport. The camera pixel bus has no source
  CRC, so neither CRC nor simulation proves absence of every electrical fault.
- Sensor noise and clipped highlights can remain in real scenes. Raw PNGs are
  not enhanced or denoised to hide acquisition problems.
- SystemVerilog support is Yosys's synthesizable `read_verilog -sv` subset,
  not the complete language or testbench syntax.

## Contributing And License

Built and maintained by **[Maotechh](https://github.com/Maotechh)**. Reports from
other iCESugar/HM01B0 revisions and reproducible fixes are welcome through
[Issues](https://github.com/Maotechh/icesugar-hm01b0/issues) and pull requests.
See [CONTRIBUTING.md](CONTRIBUTING.md) for test expectations.

[MIT](LICENSE). OpenMV-derived camera register values retain their
[original MIT notice](LICENSES/OpenMV.txt). Downloaded build tools retain their
own licenses and are not redistributed in this repository.
