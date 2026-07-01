#!/bin/bash
#
# wm-register-boot.sh - swaps the "WinM Stub" macOS install's kernel slot for
# m1n1 via kmutil configure-boot, so picking the stub in the startup picker
# boots the Windows chain. Same mechanism the Asahi installer uses. Runs as
# root via one admin prompt from the app.
#
# Markers the app parses:
#     @@RB_OK                 done
#     @@RB_NEEDS_1TR <cmd>    kmutil refused, run <cmd> in the recoveryOS
#                             Terminal instead
#     anything else           log line
#
# Env: WM_DISK (whole-disk BSD name, e.g. disk4), WM_RESOURCES (m1n1.bin dir)
#
set -uo pipefail

DISK="${WM_DISK:?WM_DISK not set}"
RES="${WM_RESOURCES:?WM_RESOURCES not set}"
M1N1="${RES}/m1n1.bin"

# Stage-1 lives on the internal disk so the recoveryOS fallback can reach it
# (its /tmp does not survive a reboot; /Users/Shared does).
STAGE1_DIR="/Users/Shared/WindowsM"
STAGE1="${STAGE1_DIR}/m1n1-stage1.bin"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

log() { echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---- sanity ----------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "must run as root (use the app, which authenticates once)"
case "${DISK}" in
    disk[0-9]|disk[0-9][0-9]) ;;
    *) die "refusing: '${DISK}' is not a whole-disk BSD name" ;;
esac
if diskutil info -plist "${DISK}" | plutil -extract Internal raw - 2>/dev/null | grep -qi true; then
    die "refusing: ${DISK} is an internal disk"
fi
[ -f "${M1N1}" ] || die "missing m1n1.bin in ${RES} (run scripts/build-m1n1.sh)"

STUB_PART="${DISK}s2"
EFI_PART="${DISK}s1"

# ---- 1. locate the stub's APFS container and its macOS system volume -------
CONTAINER="$(diskutil info -plist "${STUB_PART}" 2>/dev/null \
    | plutil -extract APFSContainerReference raw - 2>/dev/null)" || true
[ -n "${CONTAINER:-}" ] || die "${STUB_PART} is not an APFS physical store, was the disk prepared by WindowsM?"

# The stub volume group after a macOS install holds System/Data/Preboot/
# Recovery volumes; the System volume is the one with SystemVersion.plist.
STUB_VOL=""
for i in 1 2 3 4 5 6 7 8; do
    VD="${CONTAINER}s${i}"
    diskutil info -plist "${VD}" >/dev/null 2>&1 || continue
    MP="$(diskutil info -plist "${VD}" | plutil -extract MountPoint raw - 2>/dev/null)" || true
    if [ -z "${MP:-}" ]; then
        diskutil mount "${VD}" >/dev/null 2>&1 || continue
        MP="$(diskutil info -plist "${VD}" | plutil -extract MountPoint raw - 2>/dev/null)" || true
    fi
    [ -n "${MP:-}" ] || continue
    if [ -f "${MP}/System/Library/CoreServices/SystemVersion.plist" ]; then
        STUB_VOL="${MP}"
        break
    fi
done
[ -n "${STUB_VOL}" ] || die "no macOS system volume found on ${STUB_PART}, install macOS onto 'WinM Stub' first (Boot Setup step 1)"
log "Stub macOS volume: ${STUB_VOL}"

# ---- 2. ESP partition UUID for the chainload hop ----------------------------
EFI_UUID="$(diskutil info -plist "${EFI_PART}" | plutil -extract DiskUUID raw - 2>/dev/null)" || true
[ -n "${EFI_UUID:-}" ] || die "could not read the partition UUID of ${EFI_PART}"
log "ESP ${EFI_PART} partition UUID: ${EFI_UUID}"

# ---- 3. assemble m1n1 stage 1 -----------------------------------------------
# m1n1 reads config variables appended to its image; `chainload` makes stage 1
# jump straight to stage 2 (m1n1 + UEFI payload) on the ESP, which the
# installer already wrote as m1n1/boot.bin.
mkdir -p "${STAGE1_DIR}"
cat "${M1N1}" > "${STAGE1}" || die "could not stage ${STAGE1}"
printf 'chainload=%s;m1n1/boot.bin\n' "${EFI_UUID}" >> "${STAGE1}"
chmod a+r "${STAGE1}"
log "Stage 1 assembled: ${STAGE1} ($(stat -f%z "${STAGE1}") bytes, chainload -> ESP m1n1/boot.bin)"

# ---- 4. kmutil configure-boot ------------------------------------------------
# m1n1's raw-image entry point is 0x800 (2048); these are the flags m1n1's own
# docs and the Asahi installer use. Succeeds only when the stub volume's
# security policy is already Permissive (set in recoveryOS, Boot Setup step 3);
# some macOS releases additionally restrict cross-volume LocalPolicy writes to
# recoveryOS entirely, in that case we hand the user the exact 1TR command.
KM_ARGS=(configure-boot -c "${STAGE1}" --raw --entry-point 2048 --lowest-virtual-address 0 -v "${STUB_VOL}")
log "+ kmutil ${KM_ARGS[*]}"
if OUT="$(kmutil "${KM_ARGS[@]}" 2>&1)"; then
    [ -n "${OUT}" ] && log "${OUT}"
    log "Boot object registered. Hold the power button at startup and pick 'WinM Stub' to boot Windows."
    echo "@@RB_OK"
    exit 0
else
    STATUS=$?
    [ -n "${OUT}" ] && log "${OUT}"
    log "kmutil refused (status ${STATUS}). This usually means the stub's Startup Security is not Permissive yet, or this macOS only allows the change from recoveryOS."
    # In recoveryOS the stub mounts under /Volumes and the internal Data
    # volume (where stage 1 was written) under '/Volumes/Macintosh HD - Data'
    # (adjust if the internal volume was renamed).
    echo "@@RB_NEEDS_1TR kmutil configure-boot -c '/Volumes/Macintosh HD - Data/Users/Shared/WindowsM/m1n1-stage1.bin' --raw --entry-point 2048 --lowest-virtual-address 0 -v '/Volumes/WinM Stub'"
    exit 2
fi
