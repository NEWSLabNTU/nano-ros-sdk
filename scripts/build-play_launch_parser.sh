#!/usr/bin/env bash
# Build play_launch_parser (the launch-graph parser nano-ros's `nros plan` /
# `nros codegen-system` resolver shells out to) and package it for one host.
# Mirrors [tool.play_launch_parser.source] in nano-ros's nros-sdk-index.toml.
#
#   build-play_launch_parser.sh <version> <host-key> <upstream>
#       ->  dist/play_launch_parser-<host>.tar.zst
#
# nano-ros/issue 1273 (RFC-0099 D4): DECIDED — we build this dist ourselves and
# publish it here, on our own schedule, rather than waiting on an upstream
# release cycle for a repo we own (`NEWSLabNTU/play_launch` has none to wait
# on; `jerry73204/play_launch_parser`, the pre-2026-08-28 upstream, is
# ARCHIVED). `upstream` is a commit SHA on `play_launch`'s `main` — no tags —
# same convention as `[tool.cyclonedds]`'s fork-branch pin.
#
# NOT bundled (unlike qemu/openocd since issue 0928): the index already
# declares `system = ["libexpat1", "libpython310", "libz1"]` for this tool, and
# that stays the contract — `libpython3.10.so.1.0` in particular is a pyo3
# `auto-initialize` link (issue 0368 F5, the same shape as nano-ros's own
# `nros-launch-resolve`), and bundling an embedded-interpreter build would ship
# a python runtime with no matching stdlib/site-packages rather than solve
# anything. Build-time-only `python3-dev` is a RUNNER package, not part of the
# dist — nano-ros's `[prereq.python3-dev]` is the same requirement one layer up
# for anyone building this tool from source instead of taking the dist.
set -euo pipefail

version="${1:?usage: build-play_launch_parser.sh <version> <host-key> <upstream>}"
host="${2:?usage: build-play_launch_parser.sh <version> <host-key> <upstream>}"
# Commit SHA on NEWSLabNTU/play_launch's `main` — SSOT is nano-ros's index
# [tool.play_launch_parser].upstream, passed by build-tool.yml.
#
# THIS IS NOT REQUIRED TO EQUAL nano-ros's `packages/cli/third-party/play_launch`
# submodule pin, and the sentence that used to sit here said it was (nano-ros
# issue 1413). It went unmeasured on both sides and drifted ~40 commits. The
# relationship that IS required — the index may LAG the gitlink, never lead it,
# and a lag must be declared beside the index entry — is measured over there by
# `check-play-launch-parser-ref`, not asserted here.
#
# Why they differ right now: nano-ros issue 0897 moved pyo3 out of the
# `play_launch_parser` crate, so at the gitlink this CLI has no Python backend —
# `.launch.py` hard-errors and `$(eval …)` exits 0 with the substitution
# UNEXPANDED. `838ce948` is the newest commit whose `cargo install` yields a
# Python-capable binary, so that is what this dist is cut from until the CLI
# registers a `pyload` backend and ships `libplay_launch_parser_pyexec.so`
# beside itself.
upstream="${3:?usage: build-play_launch_parser.sh <version> <host-key> <upstream>}"

root="$(pwd)"
src="$root/play_launch-src"
prefix="$root/out/play_launch_parser"
rm -rf "$src" "$prefix"
mkdir -p "$prefix/bin" "$root/dist"

case "$host" in
linux-*)
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3-dev pkg-config
    ;;
macos-*)
    brew install python pkg-config
    ;;
*)
    echo "build-play_launch_parser: unsupported host $host" >&2
    exit 1
    ;;
esac

# Non-recursive: this dist builds the `play_launch_parser` crate only, not the
# layer-3 runtime submodules (`src/vendor/*`, container, msgs) `play_launch`
# also carries — nano-ros never builds those either (CLAUDE.md "Launch
# toolchain").
git clone --depth 1 https://github.com/NEWSLabNTU/play_launch "$src"
git -C "$src" fetch --depth 1 origin "$upstream"
git -C "$src" checkout "$upstream"

cargo install \
    --path "$src/src/ros-launch-resolve/parser/crates/play_launch_parser" \
    --root "$prefix" --locked

test -x "$prefix/bin/play_launch_parser" \
    || { echo "error: play_launch_parser not installed into $prefix/bin"; exit 1; }

# Smoke it before packaging — same reason `[tool.zephyr-sdk]`'s neighbours run
# one: a binary that cannot even start must not reach a Release asset (issue
# 0929's class). Runtime libs are the HOST's here (system = [...] above), so
# this also proves the runner's own python3/libexpat/zlib satisfy what the
# binary just linked, before any consumer's host has to find that out first.
"$prefix/bin/play_launch_parser" --help >/dev/null

tar --use-compress-program "zstd -19 -T0" \
    -cf "dist/play_launch_parser-${host}.tar.zst" -C "$prefix" .
echo "built dist/play_launch_parser-${host}.tar.zst"
