#!/usr/bin/env bash
# Repackage ARM's prebuilt Arm GNU Toolchain (arm-none-eabi) for one host into
# the nano-ros install-layout contract. Building GCC from source costs hours, so
# this is a fetch+repackage, not a source build. Phase 187.5.
#
#   build-arm-none-eabi-gcc.sh <version> <host-key>
#       -> dist/arm-none-eabi-gcc-<host-key>.tar.zst
set -euo pipefail

version="${1:?usage: build-arm-none-eabi-gcc.sh <version> <host-key> <upstream>}"
host="${2:?usage: build-arm-none-eabi-gcc.sh <version> <host-key> <upstream>}"
# Exact ARM release id (e.g. 13.2.rel1) — SSOT is the index [tool.*].upstream,
# passed by build-tool.yml. No longer hand-derived from the version label.
upstream="${3:?usage: build-arm-none-eabi-gcc.sh <version> <host-key> <upstream>}"

case "$host" in
linux-x86_64) arch="x86_64" ;;
linux-arm64) arch="aarch64" ;;
macos-arm64) arch="darwin-arm64" ;;
*)
    echo "build-arm-none-eabi-gcc: unsupported host $host" >&2
    exit 1
    ;;
esac

asset="arm-gnu-toolchain-${upstream}-${arch}-arm-none-eabi"
url="https://developer.arm.com/-/media/Files/downloads/gnu/${upstream}/binrel/${asset}.tar.xz"

. "$(dirname "$0")/lib/bundle.sh"

root="$(pwd)"
rm -rf "$root/work"
mkdir -p "$root/dist" "$root/work"
cd "$root/work"

curl -fL --retry 3 -o tc.tar.xz "$url"
tar -xf tc.tar.xz # ARM's top-dir name varies by release/arch — glob it, don't assume.

topdir="$(find . -maxdepth 1 -type d -name 'arm-gnu-toolchain-*' | head -1)"
if [ -z "$topdir" ]; then
    echo "build-arm-none-eabi-gcc: no extracted toolchain dir; got:" >&2
    ls -la >&2
    exit 1
fi

# issue 0928 — ARM links its gdb against ncurses **5**, which Ubuntu 22.04 and
# later do not ship. So the compiler works and the DEBUGGER does not:
#
#   arm-none-eabi-gdb: error while loading shared libraries: libncursesw.so.5
#
# A partial breakage reads as "the toolchain installed fine", which is why it
# went unnoticed until 0926's audit. Measured: of the 31 binaries in bin/, gdb
# is the ONLY one needing a non-host library, and none carries an existing
# RUNPATH — so passing the whole directory is safe and keeps the bundler's
# policy-not-a-name-list property. ARM's own `lib/` holds no `*.so*` directly
# (its shared objects nest deeper), so the bundler's `$ORIGIN` pass touches
# only what it copied there.
#
# Linux only. The macOS bundler swaps each binary for a DYLD_LIBRARY_PATH
# launcher, which is proportionate for qemu's handful of `qemu-system-*` and
# not for a 31-binary toolchain; macOS host support is deferred anyway
# (nano-ros phase-401 W4).
case "$host" in
linux-*)
    sudo apt-get update -qq
    # The bundler can only copy what it can RESOLVE, and ncurses 5 is not on a
    # modern runner either — installing it here is what makes the library
    # available to bundle, not a dependency of the build.
    # BOTH ncurses 5 spellings: the x86_64 toolchain links the wide build
    # (`libncursesw.so.5`) and the arm64 one links the narrow (`libncurses.so.5`),
    # which is not visible from either binary alone and failed the arm64 leg
    # with `bundle: cannot resolve libncurses.so.5` after x86_64 had gone green.
    sudo apt-get install -y -qq patchelf libncurses5 libncursesw5 libtinfo5
    bundle_linux_libs "$topdir" "$topdir"/bin/*
    ;;
esac

# Pack the CONTENTS so it unpacks into $NROS_HOME/sdk/arm-none-eabi-gcc/<ver>/.
tar --use-compress-program "zstd -19 -T0" \
    -cf "$root/dist/arm-none-eabi-gcc-${host}.tar.zst" -C "$topdir" .
echo "built dist/arm-none-eabi-gcc-${host}.tar.zst"
