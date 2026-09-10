# Contributing

Maintainer: [Maotechh](https://github.com/Maotechh).

Issues and pull requests are welcome. Include board/module revision, host
architecture, tool versions, sampling mode and the failing command. Redact
serial numbers, local usernames and private images before attaching logs.

Run `make test-host` for host-only changes, and `make all && make test` for RTL
changes. Keep `--freq 48` timing enforcement enabled. Report hardware tests
separately from simulation and say explicitly when hardware was not available.

Changes to pins, clocking, camera registers or buffering need new walking-one
and real-image checks. A passing CRC verifies transport, not every possible
sensor sampling fault. Preserve raw failed frames locally, do not hide or
retry failures silently, and document any intentionally incompatible change.

Keep this project minimal: no IDE, GUI, Python HDL, formal tool installation
or SoC framework. Host code uses Python's standard library; simulation uses
Yosys CXXRTL and a C++ compiler.

GitHub's Host Tests workflow runs the standard-library tests (including a
pseudo-terminal serial test) and shell syntax checks. It does not synthesize
the FPGA, check routed timing or replace hardware tests. Run `make -B all test`
locally after toolchain changes, and include the final timing result in the PR.

Contributions are submitted under the MIT license. Preserve notices for
third-party adaptations, including the OpenMV camera register values.
