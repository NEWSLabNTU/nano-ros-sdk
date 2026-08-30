#!/usr/bin/env bash
# Build the patched QEMU (NEWSLabNTU/qemu fork) and package it for one host.
# Mirrors [tool.qemu.source] in nano-ros's nros-sdk-index.toml so the prebuilt
# and source-built layouts are identical. Phase 187.5.
#
#   build-qemu.sh <version> <host-key>   ->   dist/qemu-<host-key>.tar.zst
set -euo pipefail

version="${1:?usage: build-qemu.sh <version> <host-key> <upstream>}"
host="${2:?usage: build-qemu.sh <version> <host-key> <upstream>}"
# Fork branch/ref (e.g. nano-ros-v11.0.0-patches) — SSOT is the index
# [tool.qemu].upstream / source.ref, passed by build-tool.yml. No longer
# hardcoded here.
upstream="${3:?usage: build-qemu.sh <version> <host-key> <upstream>}"

root="$(pwd)"
prefix="$root/out/qemu"
rm -rf "$root/qemu-src" "$prefix"
mkdir -p "$prefix" "$root/dist"

# Host build deps. libslirp is REQUIRED — nano-ros QEMU tests use `-netdev user`
# (slirp NAT, no TAP/sudo); without --enable-slirp the binary can't network.
if [ "${host#linux-}" != "$host" ]; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq ninja-build python3-venv libglib2.0-dev \
        libpixman-1-dev libslirp-dev zstd flex bison patchelf
else
    brew install libslirp pkg-config ninja pixman glib zstd
fi

git clone --depth 1 --branch "$upstream" \
    https://github.com/NEWSLabNTU/qemu qemu-src
cd qemu-src

# The configure flags have ONE home: `[tool.qemu.source].configure` in
# nano-ros's nros-sdk-index.toml, which is also the recipe `nros setup` runs
# when it builds from source. They used to be duplicated here, with a gate in
# nano-ros diffing this script against a VENDORED COPY of itself — and the copy
# drifted in five of nine files while the gate watched one line. Read the SSOT.
index_url="https://raw.githubusercontent.com/NEWSLabNTU/nano-ros/main/nros-sdk-index.toml"
configure_line="$(curl -fsSL "$index_url" |
    sed -n '/^\[tool\.qemu\.source\]/,/^\[/p' |
    sed -n 's/^configure *= *"\(.*\)"$/\1/p' | head -1)"
[ -n "$configure_line" ] || {
    echo "error: no [tool.qemu.source].configure in $index_url" >&2
    exit 1
}
# `{prefix}` is the index's placeholder for the install prefix.
configure_cmd="${configure_line//\{prefix\}/$prefix}"
echo "configure (from the index): $configure_cmd"
eval "$configure_cmd"
make -j"$(getconf _NPROCESSORS_ONLN)"
make install
cd "$root"

# --- issue 0928 — the bundler moved to scripts/lib/bundle.sh -------------------
# It was written here (0368 F3 for Linux, 0879 for macOS) and works; what it was
# NOT was reachable. openocd and arm-none-eabi-gcc shipped linking the host for
# as long as qemu shipped self-contained, because the code lived in this file.
# Same functions, one home, `bins` now the caller's argument.
. "$(dirname "$0")/lib/bundle.sh"


if [ "${host#linux-}" != "$host" ]; then
    bundle_linux_libs "$prefix" "$prefix"/bin/qemu-system-*
    # A dist that boots is the point; --version alone would pass on a build host
    # that has every lib anyway, which is exactly how -nros2 shipped broken.
    "$prefix/bin/qemu-system-arm" --version >/dev/null
    "$prefix/bin/qemu-system-arm" -M none -netdev help | grep -qw user \
        || { echo "error: slirp (-netdev user) missing from the build"; exit 1; }
else
    bundle_macos_libs "$prefix" "$prefix"/bin/qemu-system-*
    "$prefix/bin/qemu-system-arm" --version >/dev/null
    "$prefix/bin/qemu-system-arm" -M none -netdev help | grep -qw user \
        || { echo "error: slirp (-netdev user) missing from the build"; exit 1; }
fi

# Tarball = the prefix CONTENTS (bin/, share/, …) so it unpacks straight into
# $NROS_HOME/sdk/qemu/<version>/ — the install-layout contract.
tar --use-compress-program "zstd -19 -T0" \
    -cf "dist/qemu-${host}.tar.zst" -C "$prefix" .
echo "built dist/qemu-${host}.tar.zst"
