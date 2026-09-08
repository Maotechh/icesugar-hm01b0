#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_root=${BUILD_ROOT:-"$project_dir/work/bootstrap"}
prefix=${PREFIX:-"$project_dir/work/toolchain"}
jobs=${JOBS:-12}
yosys_version=0.68
yosys_sha256=ad8d2198e1a486e9089cc51a3158ecc764669267879518723fb98acc6fb24787
nextpnr_commit=62e659ed6748e9f60b2a4aa25dd4fe79a9605881
icestorm_commit=f31c39cc2eadd0ab7f29f34becba1348ae9f8721

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ ${1:-} == '' || ${1:-} == --check ]] || fail 'Usage: bash scripts/build-toolchain.sh [--check]'
[[ $jobs =~ ^[1-9][0-9]*$ ]] || fail 'JOBS must be a positive integer'
[[ $build_root == /* && $prefix == /* ]] || fail 'BUILD_ROOT and PREFIX must be absolute paths'
[[ $build_root != / && $prefix != / ]] || fail 'Do not use / as a build or install directory'
[[ "$project_dir $build_root $prefix" != *$'\n'* ]] || fail 'Paths must not contain newlines'
[[ $project_dir != *[[:space:]]* && $build_root != *[[:space:]]* && $prefix != *[[:space:]]* ]] ||
    fail 'Upstream build tools require paths without whitespace'

for command in git gcc g++ make cmake ninja pkg-config python3 flex bison curl tar sha256sum install; do
    command -v "$command" >/dev/null || fail "Missing $command; see docs/toolchain.md"
done
case $(uname -m) in
    aarch64|x86_64) ;;
    *) fail 'Supported host architectures: aarch64 (hardware-tested) and x86_64 (not hardware-tested)' ;;
esac
cmake_version=$(cmake --version | head -n 1)
python3 -c 'import re,sys; v=re.search(r"(\d+)\.(\d+)",sys.argv[1]); sys.exit(not v or tuple(map(int,v.groups())) < (3,28))' \
    "$cmake_version" || fail 'CMake >= 3.28 is required (Ubuntu 24.04 provides it)'

# Optional extracted Ubuntu dependencies for non-root builds on the original host.
cmake_deps=()
iceprog_ldflags=()
pkg_config_env=()
if [[ -n ${DEPS_ROOT:-} ]]; then
    [[ $DEPS_ROOT == /* && $DEPS_ROOT != *[[:space:]]* ]] || fail 'DEPS_ROOT must be an absolute path without whitespace'
    multiarch=$(gcc -print-multiarch)
    dep_lib="$DEPS_ROOT/usr/lib/$multiarch"
    pkg_config_env=("PKG_CONFIG_SYSROOT_DIR=$DEPS_ROOT"
        "PKG_CONFIG_PATH=$dep_lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}")
    cmake_deps=(-DCMAKE_PREFIX_PATH="$DEPS_ROOT/usr" -DCMAKE_INSTALL_RPATH="$dep_lib")
    iceprog_ldflags=("LDFLAGS=-Wl,-rpath,$dep_lib")
fi
env "${pkg_config_env[@]}" pkg-config --exists libftdi1 libusb-1.0 || fail 'Missing libftdi1/libusb development files; see docs/toolchain.md'
printf 'Prerequisites checked. CMake will validate Boost, Eigen and zlib during configuration.\n'
[[ ${1:-} != --check ]] || exit 0

mkdir -p "$build_root/src" "$prefix/bin" "$prefix/share/icebox"
checkout_source() {
    local url=$1 directory=$2 revision=$3
    if [[ ! -e $directory ]]; then
        git clone "$url" "$directory"
    fi
    [[ $(git -C "$directory" remote get-url origin) == "$url" ]] || fail "Unexpected source origin: $directory"
    git -C "$directory" diff --quiet || fail "Modified source files: $directory"
    git -C "$directory" diff --cached --quiet || fail "Staged source files: $directory"
    if ! git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$directory" fetch origin "$revision"
    fi
    git -C "$directory" checkout --detach "$revision"
}

checkout_source https://github.com/YosysHQ/icestorm.git "$build_root/src/icestorm" "$icestorm_commit"
ice="$build_root/src/icestorm"
make -C "$ice/icepack" -j"$jobs" CC=gcc CXX=g++ icepack
env "${pkg_config_env[@]}" make -C "$ice/iceprog" -j"$jobs" CC=gcc CXX=g++ "${iceprog_ldflags[@]}" iceprog
make -C "$ice/icebox" -j"$jobs" chipdb-5k.txt
install -m 755 "$ice/icepack/icepack" "$ice/iceprog/iceprog" "$prefix/bin/"
install -m 644 "$ice/icebox/chipdb-5k.txt" "$ice/icefuzz/timings_up5k.txt" "$prefix/share/icebox/"

archive="$build_root/src/yosys-v$yosys_version.tar.gz"
if [[ ! -f $archive ]]; then
    curl -fL --retry 3 --connect-timeout 20 \
        "https://github.com/YosysHQ/yosys/releases/download/v$yosys_version/yosys.tar.gz" -o "$archive.download"
    mv "$archive.download" "$archive"
fi
printf '%s  %s\n' "$yosys_sha256" "$archive" | sha256sum -c -
if [[ ! -d $build_root/src/yosys ]]; then
    unpack_dir=$(mktemp -d "$build_root/src/yosys-unpack.XXXXXXXX")
    tar -xzf "$archive" --no-same-owner -C "$unpack_dir"
    mv "$unpack_dir" "$build_root/src/yosys"
fi
cmake -S "$build_root/src/yosys" -B "$build_root/yosys" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    '-DYOSYS_COMPONENTS=synth_ice40;synth;write_cxxrtl;prep;read_json;chparam;write_verilog;help;write_xaiger;read_aigerparse' \
    -DYOSYS_WITHOUT_TCL=ON -DYOSYS_WITHOUT_SLANG=ON \
    -DYOSYS_WITHOUT_READLINE=ON -DYOSYS_WITHOUT_EDITLINE=ON \
    -DYOSYS_WITHOUT_LIBFFI=ON -DYOSYS_WITH_PYTHON=OFF
cmake --build "$build_root/yosys" --target yosys yosys-abc -j"$jobs"
# Install the selected tools/data without recursively installing unrelated targets.
cmake -DCMAKE_INSTALL_LOCAL_ONLY=1 -DCMAKE_INSTALL_DO_STRIP=1 \
    -P "$build_root/yosys/cmake_install.cmake"

checkout_source https://github.com/YosysHQ/nextpnr.git "$build_root/src/nextpnr" "$nextpnr_commit"
cmake -S "$build_root/src/nextpnr" -B "$build_root/nextpnr" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DARCH=ice40 -DICE40_DEVICES=5k -DICESTORM_INSTALL_PREFIX="$prefix" \
    -DBUILD_GUI=OFF -DBUILD_PYTHON=OFF -DBUILD_RUST=OFF -DBUILD_TESTS=OFF \
    "${cmake_deps[@]}"
cmake --build "$build_root/nextpnr" -j"$jobs"
cmake --install "$build_root/nextpnr" --strip

"$prefix/bin/yosys" -V
"$prefix/bin/nextpnr-ice40" --version
printf '\nTools installed in %s/bin. Run make all and make test.\n' "$prefix"
