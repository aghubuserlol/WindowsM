#!/bin/bash
# Fetches the UUP dump conversion scripts (the same ones uupdump.net bundles
# for Linux/macOS) into Sources/Resources/uup-converter/.
#
# The converter turns downloaded UUP packages into a bootable ISO locally.
# It needs these host tools at runtime:
#   brew install aria2 cabextract wimlib chntpw
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${ROOT}/Sources/Resources/uup-converter"
mkdir -p "${DEST}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The Gitea instance does not serve /archive tarballs; clone instead.
git clone --depth 1 https://git.uupdump.net/uup-dump/converter.git "${TMP}/converter"
rm -rf "${TMP}/converter/.git"
cp -R "${TMP}/converter/." "${DEST}/"
chmod +x "${DEST}"/*.sh

# Drop chntpw from the converter's hard dependency check — it is only used for
# virtual-edition synthesis (which WindowsM disables) and is not packaged for
# macOS by Homebrew. wimlib-imagex is provided by the app bundle via PATH.
if grep -q 'for prog in aria2c cabextract wimlib-imagex chntpw' "${DEST}/convert.sh"; then
    /usr/bin/sed -i '' 's/for prog in aria2c cabextract wimlib-imagex chntpw/for prog in aria2c cabextract wimlib-imagex/' "${DEST}/convert.sh"
    echo "==> Patched convert.sh: chntpw no longer required."
fi

echo "==> Sources/Resources/uup-converter/ updated. Rebuild the app to bundle it."
