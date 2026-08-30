#!/usr/bin/env bash
# Build OpenOCD from source (GPL) and package it for one host. Phase 187.5.
#
#   build-openocd.sh <version> <host-key>   ->   dist/openocd-<host-key>.tar.zst
set -euo pipefail

version="${1:?usage: build-openocd.sh <version> <host-key> <upstream>}"
host="${2:?usage: build-openocd.sh <version> <host-key> <upstream>}"
# Upstream tag (e.g. v0.12.0) — SSOT is the index [tool.*].upstream, passed by
# build-tool.yml. No longer hand-derived from the version label.
upstream="${3:?usage: build-openocd.sh <version> <host-key> <upstream>}"

. "$(dirname "$0")/lib/bundle.sh"

root="$(pwd)"
prefix="$root/out/openocd"
rm -rf "$root/openocd-src" "$prefix"
mkdir -p "$prefix" "$root/dist"

# Build deps (libusb/hidapi/libftdi enable the common debug adapters).
case "$host" in
linux-*)
    sudo apt-get update -qq
    sudo apt-get install -y -qq autoconf automake libtool pkg-config texinfo \
        libusb-1.0-0-dev libhidapi-dev libftdi-dev zstd patchelf
    ;;
macos-*)
    brew install libusb hidapi libftdi automake libtool pkg-config texinfo zstd
    bp="$(brew --prefix)"
    export PKG_CONFIG_PATH="$bp/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    ;;
*)
    echo "build-openocd: unsupported host $host" >&2
    exit 1
    ;;
esac

git clone --recurse-submodules --depth 1 --branch "$upstream" \
    https://github.com/openocd-org/openocd openocd-src
cd openocd-src
./bootstrap
./configure --prefix="$prefix" --enable-ftdi --enable-stlink --enable-jlink \
    --enable-cmsis-dap --disable-werror
make -j"$(getconf _NPROCESSORS_ONLN)"
make install
cd "$root"

# issue 0928 — make the dist self-contained, the way qemu has been since 0368
# F3. This is the STRONGEST case in the tree and not merely an undeclared dep:
# openocd needs `libftdi.so.1`, which Ubuntu ships as `libftdi1` at version
# 0.20 — libftdi *0.x*. Its successor installs `libftdi1.so.2` under the
# confusingly-named `libftdi1-2`, which a normal developer host HAS and which
# does not satisfy this binary. So the failure is not "install the obvious
# package"; it is a dead binary on a host that looks like it has the library:
#
#   openocd: error while loading shared libraries: libftdi.so.1
#
# `libhidapi-hidraw.so.0`, `libusb-1.0.so.0` and `libudev.so.1` ride along.
case "$host" in
linux-*) bundle_linux_libs "$prefix" "$prefix"/bin/openocd ;;
macos-*) bundle_macos_libs "$prefix" "$prefix"/bin/openocd ;;
esac

tar --use-compress-program "zstd -19 -T0" \
    -cf "dist/openocd-${host}.tar.zst" -C "$prefix" .
echo "built dist/openocd-${host}.tar.zst"
