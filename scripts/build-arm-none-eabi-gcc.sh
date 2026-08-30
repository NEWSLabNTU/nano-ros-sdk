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
# --- nano-ros issue 0929 — give gdb the Python stdlib it cannot find ----------
#
# ARM links a CPython into gdb STATICALLY and bakes `sys.prefix` to a path from
# their own build container. On any other machine the interpreter finds no
# stdlib and aborts during init — and it is a FATAL error, so gdb dies with it:
#
#   Could not find platform independent libraries <prefix>
#   Fatal Python error: init_fs_encoding: failed to get the Python codec
#     of the filesystem encoding
#
# The symptom is a debugger that exits 0 and prints NOTHING, which reads as
# "installed fine" — measured on Ubuntu 22.04, where the compiler works and the
# debugger does not.
#
# Fix: ship the matching stdlib inside the dist and point PYTHONHOME at it from
# a launcher. Pure Python only — no build, no compiler, ~1.6 MB compressed.
#
# WHAT THIS CANNOT FIX, and it is ARM's decision rather than a gap here: their
# x86_64 gdb exports ZERO Python C-API symbols (`nm -D` finds none), so a `.so`
# extension module can never load into it. `import struct` and `import math`
# therefore fail no matter what stdlib is present — including on a host with a
# full system python3.8. The 34 modules they built in are the ceiling, and this
# reaches it rather than falling short of it.
ship_gdb_python() {
    local prefix="$1"
    local gdb="$prefix/bin/arm-none-eabi-gdb"
    [ -x "$gdb" ] || { echo "gdb-python: no $gdb" >&2; exit 1; }

    # Derive the minor from the binary rather than hardcoding it: ARM bumps this
    # between releases, and a stdlib for the wrong minor would install cleanly
    # and fail at run time. Unknown minor FAILS the build — loudly beats
    # shipping a mismatch.
    local minor patch
    minor="$(strings -a "$gdb" | grep -oE 'python3\.[0-9]+' | head -1)"
    case "$minor" in
        python3.8) patch="3.8.11" ;;   # matches the interpreter in 13.2.rel1
        *)
            echo "gdb-python: gdb wants '$minor', which this script has no pinned" >&2
            echo "  stdlib for. Add one to the case above (any patch release of" >&2
            echo "  that minor works; matching the interpreter removes a variable)." >&2
            exit 1
            ;;
    esac
    echo "gdb-python: gdb embeds $minor; shipping the $patch stdlib"

    local home="$prefix/lib/nros-$minor"
    mkdir -p "$home/lib"
    curl -fL --retry 3 -o py.tgz "https://www.python.org/ftp/python/$patch/Python-$patch.tgz"
    tar -xzf py.tgz "Python-$patch/Lib" --strip-components=1
    mv Lib "$home/lib/$minor"
    rm -rf py.tgz

    # Trim what a debugger's Python never reaches. 46 MB -> ~11 MB on disk.
    ( cd "$home/lib/$minor" &&
      rm -rf test idlelib tkinter lib2to3 distutils ensurepip turtledemo \
             pydoc_data unittest/test venv/scripts )

    # The launcher stays in bin/ and the real binary stays BESIDE it, not in
    # lib/ where the macOS bundler puts things: gdb derives its
    # `--data-directory` from its own location, and moving it out of bin/ moves
    # `share/gdb` out from under it.
    mv "$gdb" "$gdb.real"
    cat > "$gdb" <<'WRAP'
#!/bin/sh
# nano-ros-sdk launcher (issue 0929) — ARM's gdb embeds a CPython whose baked
# sys.prefix does not exist here; point it at the stdlib shipped beside it.
# Set unconditionally: the interpreter needs ITS minor, so honouring a caller's
# PYTHONHOME for a different Python would restore the crash this exists to fix.
here="$(cd "$(dirname "$0")" && pwd)"
PYTHONHOME="$here/../lib/nros-PYMINOR" export PYTHONHOME
exec "$here/arm-none-eabi-gdb.real" "$@"
WRAP
    sed -i "s/nros-PYMINOR/nros-$minor/" "$gdb"
    chmod +x "$gdb"

    # Prove it, here, where a failure is a build failure rather than a user's
    # problem. `--version` printing nothing is the exact symptom of 0929.
    local out
    out="$(env -u PYTHONHOME -u PYTHONPATH "$gdb" --version 2>&1)" || true
    case "$out" in
        *"GNU gdb"*) echo "gdb-python: OK — $(echo "$out" | head -1)" ;;
        *) echo "gdb-python: gdb still does not run:" >&2
           echo "$out" | head -5 >&2
           exit 1 ;;
    esac
}

# linux-x86_64 ONLY, and the arm64 exclusion is a finding rather than a
# shortcut. ARM's aarch64 gdb is linked against `libpython3.8.so.1.0`; Ubuntu
# 22.04 ships Python 3.10 and has no python3.8 at all, so there is nothing on
# the runner to bundle and nothing a user could `apt install` either. The
# bundler fails loudly (`bundle: cannot resolve libpython3.8.so.1.0`) rather
# than shipping a dist that is bundled everywhere except the one library that
# was unhandled — which is the behaviour we want; it is ARM's packaging that is
# the problem, not the walk. Tracked in nano-ros issue 0928.
case "$host" in
linux-x86_64)
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
    ship_gdb_python "$topdir"
    ;;
linux-arm64)
    echo "arm-none-eabi-gcc: linux-arm64 NOT bundled — ARM's aarch64 gdb needs" \
         "libpython3.8, absent from 22.04 (nano-ros issue 0928)."
    ;;
esac

# Pack the CONTENTS so it unpacks into $NROS_HOME/sdk/arm-none-eabi-gcc/<ver>/.
tar --use-compress-program "zstd -19 -T0" \
    -cf "$root/dist/arm-none-eabi-gcc-${host}.tar.zst" -C "$topdir" .
echo "built dist/arm-none-eabi-gcc-${host}.tar.zst"
