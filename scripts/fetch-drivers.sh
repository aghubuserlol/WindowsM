#!/bin/bash
# Stages Apple Silicon Windows drivers into Sources/Resources/drivers/.
#
# Reality check: there is no public, redistributable driver pack for Windows
# on Apple Silicon bare metal. The minimum viable set (network, USB, NVMe)
# comes from the Windows-on-ARM community efforts around Apple hardware —
# availability and licensing vary, so this script intentionally does NOT
# download anything automatically.
#
# Place driver folders (each containing .inf/.sys/.cat) under:
#   Sources/Resources/drivers/<DriverName>/
#
# WindowsM stages this directory onto the EFI partition; inside Windows run
# (from an elevated prompt):
#   pnputil /add-driver "X:\drivers\*.inf" /subdirs /install
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/Sources/Resources/drivers"
mkdir -p "${DEST}"

COUNT=$(find "${DEST}" -name '*.inf' | wc -l | tr -d ' ')
echo "==> ${DEST}"
echo "    ${COUNT} driver .inf file(s) currently staged."
if [ "${COUNT}" = "0" ]; then
    echo "    Drop driver packages here before archiving the app for real use."
fi
