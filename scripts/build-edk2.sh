#!/bin/bash
# Builds the UEFI stage that m1n1 chainloads, staged as
# Sources/Resources/edk2-apple.fd.
#
# ── Why this builds U-Boot and not EDK2 ─────────────────────────────────────
# The EDK2 Apple Silicon port this slot was named after (AppleSiliconPkg)
# has been deleted from GitHub. Its successor — the Project Mu based
# https://github.com/AppleWOA/apple_silicon_platforms_mu — is self-described
# as "wildly incomplete": its Windows loader currently hangs at the
# bootloader→kernel handoff, and its stuart build system is hostile to macOS
# hosts. The maintained, actually-booting UEFI provider for Apple Silicon is
# U-Boot (what Asahi Linux ships): its EFI implementation chainloads
# \EFI\BOOT\BOOTAA64.EFI from the ESP.
#
# The staged artifact is the m1n1 *payload* blob, Asahi-style:
#     <all Apple DTBs> + gzip(u-boot-nodtb.bin)
# The app's helper concatenates m1n1.bin + this blob into ESP/m1n1/boot.bin,
# which is exactly the assembly Asahi documents. When the Mu/EDK2 port
# matures, drop its .fd here instead — nothing else changes.
#
# Host requirements (Homebrew):
#   brew install aarch64-elf-gcc dtc make openssl@3
#   (macOS's bundled GNU make 3.81 is too old; gmake 4.x is required)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ROOT}/.build-deps"
mkdir -p "${WORK}"
cd "${WORK}"

if [ ! -d u-boot-asahi ]; then
    git clone --depth 1 https://github.com/AsahiLinux/u-boot.git u-boot-asahi
fi
cd u-boot-asahi

# EXPERIMENTAL_T8132=1 applies the WindowsM-authored minimal device tree for
# the Apple M4 Mac mini (see experimental/t8132-bringup/) so the payload also
# carries a t8132 DTB. Evidence-based but never booted — read the README.
if [ "${EXPERIMENTAL_T8132:-0}" = "1" ] && [ ! -f arch/arm/dts/t8132.dtsi ]; then
    git apply "${ROOT}/experimental/t8132-bringup/patches/u-boot-t8132-experimental-dts.patch"
    echo "==> Applied experimental t8132 device tree patch."
fi

OPENSSL="$(brew --prefix openssl@3)"
GMAKE="$(command -v gmake || true)"
if [ -z "${GMAKE}" ]; then
    echo "error: gmake not found — brew install make" >&2
    exit 1
fi

"${GMAKE}" apple_m1_defconfig CROSS_COMPILE=aarch64-elf- HOSTCC=clang
"${GMAKE}" -j"$(sysctl -n hw.ncpu)" CROSS_COMPILE=aarch64-elf- HOSTCC=clang \
    HOSTCFLAGS="-I${OPENSSL}/include" HOSTLDFLAGS="-L${OPENSSL}/lib"

# Assemble the m1n1 payload: every Apple-silicon DTB U-Boot built (m1n1
# selects the right one for the machine at boot) + gzipped U-Boot. The
# experimental t8132 DTB is appended automatically when it was built; it is
# inert on M1/M2 machines (m1n1 matches DTBs by model compatible).
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
EXTRA_DTBS=""
if compgen -G "arch/arm/dts/t8132-*.dtb" > /dev/null; then
    EXTRA_DTBS="$(echo arch/arm/dts/t8132-*.dtb)"
fi
# shellcheck disable=SC2086
cat arch/arm/dts/t8103-*.dtb arch/arm/dts/t8112-*.dtb \
    arch/arm/dts/t600*-*.dtb arch/arm/dts/t602*-*.dtb ${EXTRA_DTBS} > "${TMP}/dtbs.bin"
gzip -9 -c u-boot-nodtb.bin > "${TMP}/u-boot-nodtb.bin.gz"
cat "${TMP}/dtbs.bin" "${TMP}/u-boot-nodtb.bin.gz" > "${ROOT}/Sources/Resources/edk2-apple.fd"

echo "==> Sources/Resources/edk2-apple.fd updated ($(wc -c < "${ROOT}/Sources/Resources/edk2-apple.fd" | tr -d ' ') bytes)."
echo "    Rebuild the app to bundle it."
