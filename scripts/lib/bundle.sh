#!/usr/bin/env bash
# Make a dist self-contained: bundle the libraries it needs beside it, and make
# the binaries find them without the user installing anything.
#
#   bundle_linux_libs <prefix> <binary>...
#   bundle_macos_libs <prefix> <binary>...
#
# ONE home, sourced by every build script. Issue 0928 — this lived inside
# `build-qemu.sh`, so qemu shipped self-contained (-nros3..-nros6) while openocd
# and arm-none-eabi-gcc shipped linking the host. That is not a hypothetical:
# on a stock Ubuntu 22.04, `openocd` dies on `libftdi.so.1` and
# `arm-none-eabi-gdb` on `libncursesw.so.5`, both measured. Copying the function
# into each script would have been a second spelling of a subtle walk; nano-ros
# CLAUDE.md's rule is one shared helper, not a second idiom.
#
# The functions are VERBATIM from build-qemu.sh apart from the one qemu-specific
# line in each — `local bins=("$prefix"/bin/qemu-system-*)` — which becomes the
# caller's argument list. Everything else, including both verification passes,
# is the code that has been cutting qemu releases since issue 0879.

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
#
# EVERY `ldd` here runs under `env -u LD_LIBRARY_PATH`, and that is correctness
# rather than hygiene. This function COPIES what the loader resolved, so with a
# stray `LD_LIBRARY_PATH` in the build environment it bundles whatever that path
# points at — on a host with ROS sourced, `libddsc.so.0` resolves to ROS's build
# and the dist ships a library nobody chose. The verification pass has the same
# blind spot in the other direction: it asks "did the rpath WIN?" against the
# caller's environment, so a polluted env fails a correct bundle. Both were
# measured on a developer host in 2026-08-30; a clean runner hid it. This is
# nano-ros issue 0774's class in the producer instead of the consumer.
bundle_linux_libs() {
    local prefix="$1"
    local host_only='^(ld-linux.*|ld64.*|libc|libm|libdl|libpthread|librt|libutil|libnsl|libresolv|libcrypt|libgcc_s|libstdc\+\+|libselinux)\.so'
    shift
    # ELF only. A caller may legitimately pass a whole `bin/`, and a toolchain's
    # is not uniform: ARM's arm-none-eabi-gcc ships shell wrappers and symlinks
    # beside the 31 real binaries, and `patchelf` on the first one aborts the
    # build with `patchelf: not an ELF executable`. Filtering here rather than
    # in each caller keeps "hand me the directory" the supported shape — the
    # same reason this walk is a policy and not a name list.
    local bins=() _f
    for _f in "$@"; do
        [ -f "$_f" ] || continue
        case "$(file -b "$_f")" in *ELF*) bins+=("$_f") ;; esac
    done
    [ "${#bins[@]}" -gt 0 ] || { echo "bundle: no ELF binaries among $# argument(s)" >&2; exit 1; }
    local b n soname path real rc=0
    local queue="" seen="" map

    mkdir -p "$prefix/lib"
    # soname -> absolute path, from the resolved closure of every binary.
    map="$(for b in "${bins[@]}"; do env -u LD_LIBRARY_PATH ldd "$b"; done |
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
        # ALREADY ours. A dist that ships its own libraries resolves them
        # through its own RUNPATH, so this would copy a file onto itself and
        # `cp` fails the build. qemu never hit it — nothing was in its `lib/`
        # until this function put it there — but cyclonedds ships
        # `libddsc.so.0` and `libcycloneddsidl.so.0` beside its binaries, and
        # openocd/arm-none-eabi-gcc are the same shape. Walk what it needs,
        # copy nothing.
        case "$(readlink -f "$path")" in
            "$(readlink -f "$prefix")"/*)
                queue="$queue $(patchelf --print-needed "$path")"
                continue
                ;;
        esac
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
        done < <(for b2 in "${bins[@]}"; do env -u LD_LIBRARY_PATH ldd "$b2"; done | awk '$2 == "=>" {print $1, $3}')
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
    shift
    local bins=("$@")
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
        # Only the dylibs WE bundled — qemu installs libfdt.a and pkgconfig/
        # into the same lib/, and a bare listing treats those as sonames.
        for f in "$prefix"/lib/*.dylib; do
            base="$(basename "$f")"
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
