# Native Toolchain

Tested host: NVIDIA DGX Spark, aarch64, Ubuntu 24.04.4 LTS, GCC 13.3.0,
CMake 3.28.3. All FPGA work runs natively on this host. No Docker, emulation,
cross compilation, proprietary FPGA software or GUI is required.

## Dependencies

Ubuntu 24.04 / DGX OS provides the required CMake >= 3.28 and GCC. The following
installs build/download prerequisites only, without recommended packages:

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends \
  build-essential git ca-certificates curl cmake ninja-build pkg-config \
  python3 flex bison zlib1g-dev libeigen3-dev \
  libboost-program-options-dev libboost-iostreams-dev libboost-thread-dev \
  libftdi1-dev libusb-1.0-0-dev
```

Do not install `libboost-all-dev`, Qt, an IDE, Python HDL or another simulator.
Required transitive dependencies of these packages are expected. Python is
used for upstream data generation and the stdlib serial client, not Python HDL.

## Build

```sh
bash scripts/build-toolchain.sh --check
make toolchain
make all
make test
```

`--check` checks commands, CMake version and USB libraries; CMake subsequently
checks Boost, Eigen and other build dependencies. Default parallelism is 12:

```sh
JOBS=4 make toolchain
```

Pinned sources reproduce the versions used during development, rather than
tracking a moving branch named latest:

| Tool | Pin | Purpose |
| --- | --- | --- |
| Yosys | v0.68 release archive | `synth_ice40`, JSON, CXXRTL tests |
| nextpnr | 0.11.1 / `62e659ed6748e9f60b2a4aa25dd4fe79a9605881` | UP5K place and route |
| IceStorm | `f31c39cc2eadd0ab7f29f34becba1348ae9f8721` | icepack, iceprog, UP5K database |

The Yosys archive is checked against SHA256:

```text
ad8d2198e1a486e9089cc51a3158ecc764669267879518723fb98acc6fb24787
```

Yosys's selected components include `synth` for shared mapping data and
`write_xaiger;read_aigerparse` for ABC9 dependencies. Tcl, Slang, line editing,
libffi and Python bindings are disabled. The selected Yosys version reports
`0.68+post`, commit `c12172fbae8af5e20f6fb52e3d4e92d56ed587b6`.

nextpnr builds only the `5k` database with GUI/Python/Rust/tests disabled.
IceStorm installs only icepack, iceprog, chipdb-5k and UP5K timing data.
libftdi/libusb support iceprog for compatible FTDI programmers, but **the
iCESugar built-in iCELink is programmed through mass storage**, not iceprog.

Sources and build trees are under `work/bootstrap`; installed tools are in
`work/toolchain`. Re-running the script reuses those trees and refuses tracked
source modifications. Tool versions are pinned, but system compiler/library
versions also influence placement and hashes: inspect timing on every build.
All these generated files are ignored by Git.

## Existing Tools Or Non-Root Dependencies

Use an existing compatible installation without running the bootstrap script:

```sh
make -B PREFIX=/absolute/path/to/toolchain all test
```

`YOSYS`, `NEXTPNR`, `ICEPACK` and `CXXRTL_INCLUDE` can also be overridden on the
make command line. The include path must match the CXXRTL version used to
generate the simulation model. Stock Ubuntu FPGA packages are not the versions
used to validate this project; the pinned source build is the supported route.
`-B` forces rebuilding existing outputs when changing tool installations; Make
does not otherwise track changes to tool paths or installed compiler binaries.

For advanced non-root builds, `DEPS_ROOT` may point to a directory containing
already extracted, matching Ubuntu ARM64 libftdi/libusb/Boost packages under
`usr/`. The script uses that sysroot only for USB pkg-config and the nextpnr
dependency prefix/RPATH. Other prerequisites still come from the host.

```sh
DEPS_ROOT=/absolute/path/to/extracted-packages make toolchain
```

Do not move an installed tree with dependency RPATHs; rebuild at its new path.
`BUILD_ROOT` and `PREFIX` allow an isolated build/install location. Use absolute
paths without whitespace. ARM64 is hardware-tested; native x86_64 is allowed
by the script but not hardware-qualified here.
