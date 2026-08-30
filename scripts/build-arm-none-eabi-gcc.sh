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
    local prefix="$1" host="$2"
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

    local home="$prefix/lib/nros-$minor"
    mkdir -p "$home/lib"

    if ldd "$gdb" 2>/dev/null | grep -q "lib$minor\.so"; then
        # --- arm64: the interpreter is a SHARED LIBRARY (issue 0932) ---------
        # From Ubuntu's own ports archive, not a PPA and not a source build.
        # focal is where python3.8 lives; its .so needs at most GLIBC_2.29 and
        # the runner has 2.35, so a focal-built library runs on jammy.
        echo "gdb-python: gdb LINKS lib$minor — taking it from Ubuntu focal"
        local ver="3.8.10-0ubuntu1~20.04.18"
        local arch="arm64" gnu="aarch64-linux-gnu"
        local base="http://ports.ubuntu.com/ubuntu-ports/pool/main/p/$minor"
        local d
        rm -rf pydeb && mkdir -p pydeb
        for d in "lib$minor" "lib$minor-minimal" "lib$minor-stdlib"; do
            curl -fL --retry 3 -o "pydeb/$d.deb" "$base/${d}_${ver}_${arch}.deb"
            dpkg-deb -x "pydeb/$d.deb" pydeb/x
        done
        cp -L "pydeb/x/usr/lib/$gnu/lib$minor.so.1.0" "$prefix/lib/"
        # The stdlib INCLUDING lib-dynload. `struct` and `math` are actually
        # built INTO Ubuntu's libpython (`nm -D` finds `PyInit__struct`), and
        # the 44 lib-dynload modules add the rest; all of them resolve their
        # Python symbols from the shared libpython gdb has already loaded.
        #
        # A few carry focal-era dependencies jammy does not have —
        # `_ssl`/`_hashlib` want libssl.so.1.1 — so those imports fail. That is
        # the normal shape of an optional extension with an unmet dependency,
        # it is not silent (the ImportError names the library), and a debugger
        # needs none of them. Bundling libssl 1.1 to fix `import ssl` in gdb
        # would be shipping a deprecated TLS stack for no user.
        cp -a "pydeb/x/usr/lib/$minor" "$home/lib/$minor"
        rm -rf pydeb
        # Resolve libpython from the prefix. Done BEFORE bundle_linux_libs so
        # its `ldd` walk finds the library at all — without this the bundler
        # fails with `cannot resolve libpython3.8.so.1.0`, which is exactly how
        # this host stayed broken.
        patchelf --set-rpath '$ORIGIN/../lib' "$gdb"
        patchelf --set-rpath '$ORIGIN' "$prefix/lib/lib$minor.so.1.0"
    else
        # --- x86_64: the interpreter is STATIC, so only a stdlib is missing --
        echo "gdb-python: gdb embeds $minor statically; shipping the $patch stdlib"
        curl -fL --retry 3 -o py.tgz "https://www.python.org/ftp/python/$patch/Python-$patch.tgz"
        tar -xzf py.tgz "Python-$patch/Lib" --strip-components=1
        mv Lib "$home/lib/$minor"
        rm -rf py.tgz
    fi

    # Trim what a debugger's Python never reaches. lib-dynload is NEVER trimmed:
    # on arm64 it is the whole reason `import struct` works.
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
# nano-ros-sdk launcher (issues 0929/0932) — ARM's gdb embeds a CPython whose
# baked sys.prefix does not exist here; point it at the stdlib shipped beside
# it. Set unconditionally: the interpreter needs ITS minor, so honouring a
# caller's PYTHONHOME for a different Python would restore the crash this
# exists to fix.
here="$(cd "$(dirname "$0")" && pwd)"
PYTHONHOME="$here/../lib/nros-PYMINOR" export PYTHONHOME
exec "$here/arm-none-eabi-gdb.real" "$@"
WRAP
    sed -i "s/nros-PYMINOR/nros-$minor/" "$gdb"
    chmod +x "$gdb"
    echo "gdb-python: staged $minor for $host"
}

# Prove gdb RUNS, here, where a failure is a build failure rather than a user's
# problem. Split from `ship_gdb_python` so it runs AFTER `bundle_linux_libs`:
# on arm64 gdb also needs the ncurses the bundler supplies, so checking before
# that would fail for the wrong reason.
#
# `--version` printing nothing is the exact symptom of issue 0929, and
# `import struct` is the arm64-only capability issue 0932 buys — asserted where
# it is available rather than assumed.
verify_gdb_runs() {
    local prefix="$1"
    local gdb="$prefix/bin/arm-none-eabi-gdb"
    local out
    out="$(env -u PYTHONHOME -u PYTHONPATH "$gdb" --version 2>&1)" || true
    case "$out" in
        *"GNU gdb"*) echo "gdb-check: runs — $(echo "$out" | head -1)" ;;
        *) echo "gdb-check: gdb does not run:" >&2; echo "$out" | head -5 >&2; exit 1 ;;
    esac

    out="$(env -u PYTHONHOME -u PYTHONPATH "$gdb" --batch \
        -ex 'python import sys; print("PYOK", sys.version.split()[0])' 2>&1)" || true
    case "$out" in
        *PYOK*) echo "gdb-check: embedded python — $(echo "$out" | grep -o 'PYOK.*')" ;;
        *) echo "gdb-check: the embedded interpreter does not work:" >&2
           echo "$out" | head -5 >&2; exit 1 ;;
    esac

    # Extension modules load only where libpython is SHARED. Asserting this on
    # x86_64 would fail forever: ARM's static build exports no C-API symbols, so
    # no `.so` extension can ever load into it.
    if ldd "$gdb.real" 2>/dev/null | grep -q 'libpython3\.[0-9]*\.so'; then
        out="$(env -u PYTHONHOME -u PYTHONPATH "$gdb" --batch \
            -ex 'python import struct, math; print("EXTOK")' 2>&1)" || true
        case "$out" in
            *EXTOK*) echo "gdb-check: extension modules load (shared libpython)" ;;
            *) echo "gdb-check: lib-dynload did not load:" >&2
               echo "$out" | head -5 >&2; exit 1 ;;
        esac
    fi
}


# Both Linux hosts, by two different routes — nano-ros issues 0928/0929/0932.
#
# ARM's gdb embeds Python differently per architecture, so the fix differs too
# and pretending otherwise is what kept arm64 broken:
#
#   x86_64  Python is STATIC in gdb, and the binary exports no C-API symbols.
#           A stdlib is all it can use, and all it needs.
#   arm64   gdb LINKS libpython3.8.so.1.0. It fails at the LOADER, before any
#           interpreter runs, so a stdlib alone is not enough.
#
# 22.04 packages no python3.8 — but UBUNTU'S OWN archive does, in focal, for
# arm64. That is where the shared library comes from: `ports.ubuntu.com`, the
# same publisher as the runner's own packages, rather than a PPA (a
# supply-chain decision nobody asked for) or a source build (which would turn a
# repackage into a compile).
#
# Consequence worth knowing: arm64 ends up with MORE working Python than
# x86_64. The focal debs carry lib-dynload, and a dynamically-linked libpython
# exports the C-API those extensions need — so `import struct` works there and
# cannot work on x86_64 at all.
case "$host" in
linux-*)
    sudo apt-get update -qq
    # The bundler can only copy what it can RESOLVE, and ncurses 5 is on no
    # modern runner — installing it here is what makes the library available to
    # bundle, not a dependency of the build.
    #
    # BOTH spellings: x86_64's toolchain links the wide build
    # (`libncursesw.so.5`), arm64's links the narrow (`libncurses.so.5`). That
    # is invisible from either binary alone and failed the arm64 leg once.
    sudo apt-get install -y -qq patchelf libncurses5 libncursesw5 libtinfo5

    # libpython FIRST, where applicable: the bundler resolves through `ldd`, so
    # the library has to be findable before it runs. Placing it in the prefix
    # and setting the rpath makes it resolve from there, and the bundler then
    # recognises it as already ours and walks its needs without copying it
    # onto itself.
    ship_gdb_python "$topdir" "$host"

    bundle_linux_libs "$topdir" "$topdir"/bin/*
    verify_gdb_runs "$topdir"
    ;;
esac

# Pack the CONTENTS so it unpacks into $NROS_HOME/sdk/arm-none-eabi-gcc/<ver>/.
tar --use-compress-program "zstd -19 -T0" \
    -cf "$root/dist/arm-none-eabi-gcc-${host}.tar.zst" -C "$topdir" .
echo "built dist/arm-none-eabi-gcc-${host}.tar.zst"
