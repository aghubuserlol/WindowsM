#!/bin/bash
# Builds m1n1.bin from AsahiLinux/m1n1 and drops it into Sources/Resources/.
#
# Host requirements (Homebrew):
#   brew install llvm imagemagick
# m1n1 cross-compiles with clang; make sure Homebrew's llvm is preferred so
# the build picks up an aarch64-capable toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ROOT}/.build-deps"
mkdir -p "${WORK}"
cd "${WORK}"

if [ ! -d m1n1 ]; then
    git clone --recursive https://github.com/AsahiLinux/m1n1.git
fi
cd m1n1
git pull --recurse-submodules || true

# The Apple M4 (Donan) core-init scaffold. Auto-enabled when building on an M4
# Mac (or force with EXPERIMENTAL_T8132=1). Stock upstream m1n1 leaves Donan
# per-core init NULL, so without this an M4 hangs immediately; the scaffold
# wires the dispatch to real init functions with empty/safe chicken regions
# (populated by the trace tooling in experimental/t8132-bringup/). See that
# README. This is unverified on hardware.
HOST_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
case "${HOST_BRAND}" in *M4*) IS_M4_HOST=1 ;; *) IS_M4_HOST=0 ;; esac
if { [ "${EXPERIMENTAL_T8132:-0}" = "1" ] || [ "${IS_M4_HOST}" = "1" ]; } \
   && [ ! -f src/chickens_donan.c ]; then
    git apply "${ROOT}/experimental/t8132-bringup/patches/m1n1-t8132-donan-chickens-scaffold.patch"
    echo "==> Applied experimental m1n1 t8132 Donan chicken scaffold (M4)."
fi

export PATH="/opt/homebrew/opt/llvm/bin:${PATH}"
make -j"$(sysctl -n hw.ncpu)"

cp build/m1n1.bin "${ROOT}/Sources/Resources/m1n1.bin"
echo "==> Sources/Resources/m1n1.bin updated. Rebuild the app to bundle it."
