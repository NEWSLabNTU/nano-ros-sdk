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

# Configure flags mirror just/qemu-baremetal.just's setup-qemu so the prebuilt
# == the source build.
git clone --depth 1 --branch "$upstream" \
    https://github.com/NEWSLabNTU/qemu qemu-src
cd qemu-src
./configure --prefix="$prefix" \
    --target-list=arm-softmmu,riscv64-softmmu \
    --enable-slirp \
    --disable-docs --disable-tools --disable-gtk --disable-vnc \
    --disable-sdl --disable-spice
make -j"$(getconf _NPROCESSORS_ONLN)"
make install
cd "$root"

# --- issue 0368 F3 — make the Linux dist self-contained -----------------------
# The dist linked libslirp/libglib/libpixman/libpng from the HOST, so a clean
# Ubuntu installed it and then died in the loader ("error while loading shared
# libraries: libpixman-1.so.0") before any nano-ros code ran. Declaring the libs
# as `[tool.qemu].system` (the -nros2 stopgap) only moved the message earlier —
# it still made every user apt-install libraries the tarball can carry.
#
# Policy, not a name list: bundle the closure reachable from the binaries,
# EXCEPT the loader/libc family and the compiler runtime, which must stay the
# host's (linuxdeploy's excludelist). The name list is what shipped -nros2
# declaring `libslirp` alone while a bare 22.04 was missing SEVEN.
#
# The walk goes through BUNDLED libs only — a lib reachable solely via an
# excluded one (libpcre2 via libselinux) is the host's problem by construction,
# and copying it would leave an unused file the loader never picks up.
bundle_linux_libs() {
    local prefix="$1"
    local host_only='^(ld-linux.*|ld64.*|libc|libm|libdl|libpthread|librt|libutil|libnsl|libresolv|libcrypt|libgcc_s|libstdc\+\+|libselinux)\.so'
    local bins=("$prefix"/bin/qemu-system-*)
    local b n soname path real rc=0
    local queue="" seen="" map

    mkdir -p "$prefix/lib"
    # soname -> absolute path, from the resolved closure of every binary.
    map="$(for b in "${bins[@]}"; do ldd "$b"; done |
        awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' | sort -u)"

    for b in "${bins[@]}"; do
        queue="$queue $(patchelf --print-needed "$b")"
    done
    while [ -n "${queue// /}" ]; do
        set -- $queue
        soname="$1"
        shift
        queue="$*"
        case " $seen " in *" $soname "*) continue ;; esac
        seen="$seen $soname"
        [[ "$soname" =~ $host_only ]] && continue
        path="$(awk -v s="$soname" '$1 == s {print $2; exit}' <<<"$map")"
        [ -n "$path" ] || { echo "bundle: cannot resolve $soname" >&2; exit 1; }
        cp -L "$path" "$prefix/lib/$soname"
        chmod u+w "$prefix/lib/$soname"
        queue="$queue $(patchelf --print-needed "$prefix/lib/$soname")"
    done

    # `$ORIGIN` must survive to the ELF — single quotes, always.
    patchelf --set-rpath '$ORIGIN/../lib' "${bins[@]}"
    # The bundled libs need EACH OTHER (libgio -> libglib); DT_RUNPATH is not
    # inherited, so each one carries its own.
    patchelf --set-rpath '$ORIGIN' "$prefix"/lib/*.so*

    # Verify the rpath WINS rather than the build host merely having the libs:
    # every soname we bundled must resolve INSIDE the prefix. `ldd` prints the
    # unnormalised `bin/../lib/...`, so compare realpaths.
    for b in "${bins[@]}"; do
        while read -r soname path; do
            if [ "$path" = "not" ]; then
                echo "bundle: $b: $soname not found" >&2
                rc=1
                continue
            fi
            [ -e "$prefix/lib/$soname" ] || continue
            real="$(readlink -f "$path")"
            case "$real" in
                "$(readlink -f "$prefix")"/lib/*) ;;
                *) echo "bundle: $b resolves $soname from the host ($real)" >&2; rc=1 ;;
            esac
        done < <(for b2 in "${bins[@]}"; do ldd "$b2"; done | awk '$2 == "=>" {print $1, $3}')
    done
    [ "$rc" -eq 0 ] || exit 1
    echo "bundled $(ls "$prefix"/lib/*.so* | wc -l) libs into lib/ (rpath \$ORIGIN/../lib)"
}

if [ "${host#linux-}" != "$host" ]; then
    bundle_linux_libs "$prefix"
    # A dist that boots is the point; --version alone would pass on a build host
    # that has every lib anyway, which is exactly how -nros2 shipped broken.
    "$prefix/bin/qemu-system-arm" --version >/dev/null
    "$prefix/bin/qemu-system-arm" -M none -netdev help | grep -qw user \
        || { echo "error: slirp (-netdev user) missing from the build"; exit 1; }
fi
# macOS is NOT bundled: its deps are Homebrew absolute paths (glib, pixman,
# slirp, …) and there is no macOS runner in nano-ros CI to verify a change
# against, so an untested install_name_tool pass would ship worse than the
# documented Homebrew requirement. Tracked in nano-ros issue 0879.

# Tarball = the prefix CONTENTS (bin/, share/, …) so it unpacks straight into
# $NROS_HOME/sdk/qemu/<version>/ — the install-layout contract.
tar --use-compress-program "zstd -19 -T0" \
    -cf "dist/qemu-${host}.tar.zst" -C "$prefix" .
echo "built dist/qemu-${host}.tar.zst"
