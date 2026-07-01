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

# EXPERIMENTAL_T8132=1 wires the Apple M4 (Donan) core-init dispatch and adds
# the chicken-bit scaffold (empty/safe by default, populated by the trace
# tooling in experimental/t8132-bringup/chickens-trace/). See that README.
if [ "${EXPERIMENTAL_T8132:-0}" = "1" ] && [ ! -f src/chickens_donan.c ]; then
    git apply "${ROOT}/experimental/t8132-bringup/patches/m1n1-t8132-donan-chickens-scaffold.patch"
    echo "==> Applied experimental m1n1 t8132 Donan chicken scaffold."
fi

export PATH="/opt/homebrew/opt/llvm/bin:${PATH}"
make -j"$(sysctl -n hw.ncpu)"

cp build/m1n1.bin "${ROOT}/Sources/Resources/m1n1.bin"
echo "==> Sources/Resources/m1n1.bin updated. Rebuild the app to bundle it."
