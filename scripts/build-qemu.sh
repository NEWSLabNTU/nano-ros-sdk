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

# --- issue 0879 — the same, for macOS ------------------------------------------
# Different mechanism, same goal. rpath is not usable here: rewriting a Mach-O
# invalidates its signature on arm64, so it would need a `codesign -s - -f` pass
# per file. `DYLD_LIBRARY_PATH` substitutes by LEAF NAME even for absolute
# install names, so a launcher that points it at ../lib covers the whole closure
# while modifying no binary — the idiom build-xrce-agent.sh already uses here.
bundle_macos_libs() {
    local prefix="$1"
    local bins=("$prefix"/bin/qemu-system-*)
    local queue="" seen="" dylib base b out rc=0

    mkdir -p "$prefix/lib"
    # `otool -L` prints only DIRECT dependencies (unlike ldd), so this needs a
    # real worklist to reach the closure.
    for b in "${bins[@]}"; do
        queue="$queue $(otool -L "$b" | awk 'NR>1 {print $1}')"
    done
    while [ -n "${queue// /}" ]; do
        set -- $queue
        dylib="$1"
        shift
        queue="$*"
        case " $seen " in *" $dylib "*) continue ;; esac
        seen="$seen $dylib"
        case "$dylib" in
            # /usr/lib and /System are the OS's own, and are not even files on
            # disk — they live in the dyld shared cache. Never bundle them.
            /usr/lib/* | /System/*) continue ;;
            /*) ;;
            *)
                # @rpath/@loader_path would need the load commands resolved.
                # Fail rather than skip: a silent skip ships a dist that is
                # bundled everywhere except the one lib that was unhandled.
                echo "bundle: non-absolute install name '$dylib' — unhandled" >&2
                exit 1
                ;;
        esac
        base="$(basename "$dylib")"
        [ -e "$prefix/lib/$base" ] && continue
        cp "$dylib" "$prefix/lib/$base"
        chmod u+w "$prefix/lib/$base"
        queue="$queue $(otool -L "$prefix/lib/$base" | awk 'NR>1 {print $1}')"
    done

    # The launcher derives its own name, so one body serves every binary.
    for b in "${bins[@]}"; do
        base="$(basename "$b")"
        mv "$b" "$prefix/lib/$base.real"
        cat > "$b" <<'WRAP'
#!/bin/sh
# nano-ros-sdk relocatable launcher — resolves bundled dylibs next to itself.
# `env` takes the assignment as an ARGUMENT, so SIP stripping DYLD_* from a
# protected binary's environment cannot lose it in transit.
here="$(cd "$(dirname "$0")" && pwd)"
libdir="$here/../lib"
exec env DYLD_LIBRARY_PATH="$libdir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$libdir/$(basename "$0").real" "$@"
WRAP
        chmod +x "$b"
    done

    # Prove the bundle WINS. `DYLD_PRINT_LIBRARIES` names every image actually
    # loaded, so this distinguishes "resolved from the bundle" from "the build
    # host happens to have Homebrew" — which is the whole failure mode, and the
    # reason the macOS half went unfixed while Linux shipped.
    for b in "${bins[@]}"; do
        out="$(DYLD_PRINT_LIBRARIES=1 "$b" --version 2>&1 >/dev/null)" || rc=1
        for base in $(ls "$prefix/lib"); do
            case "$base" in *.real) continue ;; esac
            case "$out" in
                *"$prefix/lib/$base"*) ;;
                *) echo "bundle: $b did not load $base from the bundle" >&2; rc=1 ;;
            esac
            case "$out" in
                *"/opt/homebrew/"*"/$base"* | *"/usr/local/"*"/$base"*)
                    echo "bundle: $b still loads $base from Homebrew" >&2
                    rc=1
                    ;;
            esac
        done
    done
    [ "$rc" -eq 0 ] || exit 1
    echo "bundled $(ls "$prefix"/lib/*.dylib | wc -l) dylibs into lib/ (DYLD_LIBRARY_PATH launcher)"
}

if [ "${host#linux-}" != "$host" ]; then
    bundle_linux_libs "$prefix"
    # A dist that boots is the point; --version alone would pass on a build host
    # that has every lib anyway, which is exactly how -nros2 shipped broken.
    "$prefix/bin/qemu-system-arm" --version >/dev/null
    "$prefix/bin/qemu-system-arm" -M none -netdev help | grep -qw user \
        || { echo "error: slirp (-netdev user) missing from the build"; exit 1; }
else
    bundle_macos_libs "$prefix"
    "$prefix/bin/qemu-system-arm" --version >/dev/null
    "$prefix/bin/qemu-system-arm" -M none -netdev help | grep -qw user \
        || { echo "error: slirp (-netdev user) missing from the build"; exit 1; }
fi

# Tarball = the prefix CONTENTS (bin/, share/, …) so it unpacks straight into
# $NROS_HOME/sdk/qemu/<version>/ — the install-layout contract.
tar --use-compress-program "zstd -19 -T0" \
    -cf "dist/qemu-${host}.tar.zst" -C "$prefix" .
echo "built dist/qemu-${host}.tar.zst"
