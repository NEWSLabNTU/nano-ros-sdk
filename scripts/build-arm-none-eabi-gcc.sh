#!/usr/bin/env bash
# Repackage ARM's prebuilt Arm GNU Toolchain (arm-none-eabi) for one host into
# the nano-ros install-layout contract. Building GCC from source costs hours, so
# this is a fetch+repackage, not a source build. Phase 187.5.
#
#   build-arm-none-eabi-gcc.sh <version> <host-key>
#       -> dist/arm-none-eabi-gcc-<host-key>.tar.zst
set -euo pipefail

version="${1:?usage: build-arm-none-eabi-gcc.sh <version> <host-key>}"
host="${2:?usage: build-arm-none-eabi-gcc.sh <version> <host-key>}"

# nros version label <upstream>-nros<n>; ARM's release id is <upstream>.rel1.
upstream="${version%-nros*}.rel1" # 13.2 -> 13.2.rel1

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

root="$(pwd)"
rm -rf "$root/work"
mkdir -p "$root/dist" "$root/work"
cd "$root/work"

curl -fL --retry 3 -o tc.tar.xz "$url"
tar -xf tc.tar.xz # extracts to ${asset}/ (bin/ lib/ arm-none-eabi/ share/ …)

# Pack the CONTENTS so it unpacks into $NROS_HOME/sdk/arm-none-eabi-gcc/<ver>/.
tar --use-compress-program "zstd -19 -T0" \
    -cf "$root/dist/arm-none-eabi-gcc-${host}.tar.zst" -C "$asset" .
echo "built dist/arm-none-eabi-gcc-${host}.tar.zst"
