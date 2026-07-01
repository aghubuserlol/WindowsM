#!/bin/bash
# Builds wimlib (wimlib-imagex) with NTFS-3G support, plus mkntfs, and drops
# both into Sources/Resources/.
#
# NTFS-3G support is what lets wimlib apply install.wim DIRECTLY onto an NTFS
# block device — macOS's read-only NTFS driver is never involved.
#
# Host requirements (Homebrew):
#   brew install autoconf automake libtool pkg-config gettext
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ROOT}/.build-deps"
PREFIX="${WORK}/prefix"
WIMLIB_VERSION="1.14.4"
NTFS3G_VERSION="2022.10.3"
mkdir -p "${WORK}" "${PREFIX}"
cd "${WORK}"

# --- ntfs-3g (libntfs-3g for wimlib + the mkntfs formatter) ---------------
# Official release tarball (ships a pre-generated configure — the git tag
# archives require a full autotools regeneration that is fragile on macOS).
# --disable-ntfs-3g skips the FUSE driver (no macFUSE on the build machine);
# libntfs-3g and ntfsprogs (mkntfs) still build.
if [ ! -d "ntfs-3g_ntfsprogs-${NTFS3G_VERSION}" ]; then
    curl -L "https://tuxera.com/opensource/ntfs-3g_ntfsprogs-${NTFS3G_VERSION}.tgz" | tar xz
fi
cd "ntfs-3g_ntfsprogs-${NTFS3G_VERSION}"
./configure --prefix="${PREFIX}" --disable-shared --enable-static \
            --disable-ntfs-3g --disable-plugins --disable-nls
make -j"$(sysctl -n hw.ncpu)"
# rootlibdir=libdir defuses the install hook that tries to move shared libs
# into /lib (a Linux packaging convention; we build static anyway).
make install rootlibdir="${PREFIX}/lib"
cd "${WORK}"

# --- wimlib ----------------------------------------------------------------
if [ ! -d "wimlib-${WIMLIB_VERSION}" ]; then
    curl -L "https://wimlib.net/downloads/wimlib-${WIMLIB_VERSION}.tar.gz" | tar xz
fi
cd "wimlib-${WIMLIB_VERSION}"
PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
./configure --prefix="${PREFIX}" --without-fuse --with-ntfs-3g \
            --enable-static --disable-shared
make -j"$(sysctl -n hw.ncpu)"
make install

# --- stage into the app ------------------------------------------------------
cp "${PREFIX}/bin/wimlib-imagex" "${ROOT}/Sources/Resources/wimlib-imagex"
cp "${PREFIX}/sbin/mkntfs" "${ROOT}/Sources/Resources/mkntfs" 2>/dev/null \
    || cp "${PREFIX}/bin/mkntfs" "${ROOT}/Sources/Resources/mkntfs"
chmod +x "${ROOT}/Sources/Resources/wimlib-imagex" "${ROOT}/Sources/Resources/mkntfs"

echo "==> Sources/Resources/{wimlib-imagex,mkntfs} updated."
echo "    Verify NTFS support:  ${ROOT}/Sources/Resources/wimlib-imagex --version"
