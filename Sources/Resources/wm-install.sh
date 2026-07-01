#!/bin/bash
#
# wm-install.sh, the actual Windows-on-Apple-Silicon install, run as root.
#
# WindowsM bundles this and runs it via one administrator authentication
# (osascript "with administrator privileges"), which is what lets an unsigned
# local build perform privileged disk operations without a blessed SMJobBless
# helper. The signed/notarised build path still uses the XPC helper; this is
# the path that works on a dev machine today.
#
# Every privileged step the helper would do is here, in order. Progress is
# emitted as structured markers the app parses:
#     @@STAGE <id>         one of InstallStage's raw ids
#     @@PROGRESS <0..1>    overall fraction
#     anything else        a log line
#
# Parameters come from the environment (the app writes a tiny job wrapper that
# sets these and execs us, so nothing has to survive AppleScript quoting):
#     WM_DISK        target whole-disk BSD name, e.g. disk4   (WILL BE ERASED)
#     WM_ISO         path to the Windows 11 ARM64 ISO
#     WM_RESOURCES   app bundle Resources dir (wimlib-imagex, mkntfs, m1n1.bin…)
#     WM_IMAGE_INDEX install.wim image index (default 1)
#     WM_STUB_SIZE   APFS "WinM Stub" partition size (default 32G), holds the
#                    minimal macOS install whose LocalPolicy boots the chain
#     WM_DRY_RUN     1 = print what would happen, touch nothing destructive
#
set -uo pipefail

DISK="${WM_DISK:?WM_DISK not set}"
ISO="${WM_ISO:?WM_ISO not set}"
RES="${WM_RESOURCES:?WM_RESOURCES not set}"
IMAGE_INDEX="${WM_IMAGE_INDEX:-1}"
STUB_SIZE="${WM_STUB_SIZE:-32G}"
DRY_RUN="${WM_DRY_RUN:-0}"

WIMLIB="${RES}/wimlib-imagex"
MKNTFS="${RES}/mkntfs"
M1N1="${RES}/m1n1.bin"
PAYLOAD="${RES}/edk2-apple.fd"
MSR_GUID="E3C9E316-0B5C-4DB8-817D-F92DF00215AE"

# GUI/osascript hands us a thin PATH; add Homebrew and the standard locations.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

stage()    { echo "@@STAGE $1"; }
progress() { echo "@@PROGRESS $1"; }
log()      { echo "$*"; }
die()      { echo "ERROR: $*" >&2; echo "@@STAGE failed"; exit 1; }

run() {
    # Echo + execute, or just echo under dry-run.
    if [ "${DRY_RUN}" = "1" ]; then
        log "[dry-run] $*"
    else
        log "+ $*"
        "$@" || return $?
    fi
}

# ---- sanity ---------------------------------------------------------------
# Dry run touches nothing, so it needs no privilege; a real run must be root.
if [ "${DRY_RUN}" != "1" ] && [ "$(id -u)" != "0" ]; then
    die "must run as root (use the app, which authenticates once)"
fi
case "${DISK}" in
    disk[0-9]|disk[0-9][0-9]) ;;
    *) die "refusing: '${DISK}' is not a whole-disk BSD name" ;;
esac
# Hard refusal: never touch an internal disk.
if diskutil info -plist "${DISK}" | plutil -extract Internal raw - 2>/dev/null | grep -qi true; then
    die "refusing: ${DISK} is an internal disk"
fi
[ -f "${ISO}" ]    || die "ISO not found: ${ISO}"
[ -x "${WIMLIB}" ] || die "missing wimlib-imagex in ${RES} (run scripts/build-wimlib.sh)"
[ -x "${MKNTFS}" ] || die "missing mkntfs in ${RES}"
[ -f "${M1N1}" ]   || die "missing m1n1.bin in ${RES}"
[ -f "${PAYLOAD}" ]|| die "missing edk2-apple.fd in ${RES}"

log "Target: /dev/${DISK}  (everything on it will be erased)"
log "ISO:    ${ISO}"
[ "${DRY_RUN}" = "1" ] && log "*** DRY RUN, no destructive action will be taken ***"

# ---- 1. mount ISO, locate install.wim -------------------------------------
stage mountingISO; progress 0.03
MNT="$(mktemp -d /tmp/wm-iso.XXXXXX)"
if [ "${DRY_RUN}" = "1" ]; then
    log "[dry-run] would hdiutil attach ${ISO}"
    WIM="${MNT}/sources/install.wim"
else
    hdiutil attach "${ISO}" -mountpoint "${MNT}" -nobrowse -readonly >/dev/null \
        || die "could not mount ISO"
    trap 'hdiutil detach "${MNT}" -force >/dev/null 2>&1 || true' EXIT
    WIM=""
    for c in sources/install.wim sources/install.esd Sources/install.wim Sources/install.esd; do
        [ -f "${MNT}/${c}" ] && WIM="${MNT}/${c}" && break
    done
    [ -n "${WIM}" ] || die "no sources/install.wim in ISO, is this a Windows 11 ARM64 image?"
fi
log "Install image: ${WIM}"

# ---- 2. partition: GPT = EFI(auto) + APFS stub + MSR + NTFS ----------------
stage partitioning; progress 0.08
run diskutil unmountDisk force "/dev/${DISK}"
# diskutil reserves s1 as a 200 MB EFI System Partition on GPT automatically.
# s2 is declared as a plain ExFAT placeholder and converted to the APFS
# "WinM Stub" container AFTER the gpt(8) retype below, gpt needs the physical
# disk quiescent, and an active APFS container would hold it busy.
run diskutil partitionDisk "/dev/${DISK}" GPT \
    ExFAT STUB "${STUB_SIZE}" \
    ExFAT MSR 128M \
    ExFAT WINDOWS R
progress 0.10
# Retype s3 to Microsoft Reserved (best effort; Windows boots without it).
run diskutil unmountDisk force "/dev/${DISK}"
if [ "${DRY_RUN}" != "1" ]; then
    eval "$(gpt -r show "${DISK}" 2>/dev/null | awk '$3 == "3" && $4 == "GPT" {print "S3_START="$1" S3_SIZE="$2}')" || true
    if [ -n "${S3_START:-}" ]; then
        gpt remove -i 3 "${DISK}" 2>/dev/null \
            && gpt add -i 3 -b "${S3_START}" -s "${S3_SIZE}" -t "${MSR_GUID}" "${DISK}" 2>/dev/null \
            && log "MSR partition retyped" || log "MSR retype skipped (harmless)"
    fi
fi
progress 0.12
# Now convert the placeholder into the APFS stub container. The user later
# installs a minimal macOS here (Boot Setup step); its personalized
# LocalPolicy is what lets iBoot chainload m1n1 from an external disk -
# see wm-register-boot.sh for the hijack.
run diskutil apfs create "/dev/${DISK}s2" "WinM Stub"
EFI_PART="${DISK}s1"; WIN_PART="${DISK}s4"

# ---- 3. format Windows partition NTFS -------------------------------------
run diskutil unmount force "${WIN_PART}"
log "Formatting ${WIN_PART} as NTFS…"
run "${MKNTFS}" -f -F -L WINDOWS "/dev/${WIN_PART}" || die "mkntfs failed"
progress 0.14

# ---- 4. apply Windows image straight onto NTFS (the long stage) -----------
stage applyingImage
run diskutil unmount force "${WIN_PART}"
log "Applying image ${IMAGE_INDEX} to /dev/${WIN_PART} via wimlib (NTFS-3G)…"
if [ "${DRY_RUN}" = "1" ]; then
    log "[dry-run] would: ${WIMLIB} apply ${WIM} ${IMAGE_INDEX} /dev/${WIN_PART}"
else
    # wimlib prints "... (NN% done)"; rewrite those into @@PROGRESS spanning
    # this stage's 0.14..0.82 slice of the overall bar.
    "${WIMLIB}" apply "${WIM}" "${IMAGE_INDEX}" "/dev/${WIN_PART}" 2>&1 | while IFS= read -r line; do
        echo "${line}"
        pct="$(printf '%s' "${line}" | grep -oE '[0-9]{1,3}% done' | grep -oE '^[0-9]+' | head -1)"
        if [ -n "${pct}" ]; then
            awk -v p="${pct}" 'BEGIN{printf "@@PROGRESS %.4f\n", 0.14 + (p/100.0)*0.68}'
        fi
    done
    [ "${PIPESTATUS[0]}" = "0" ] || die "wimlib apply failed"
fi
progress 0.82

# ---- 5. extract boot files + assemble boot.bin into a staging tree --------
#
# We do NOT write the EFI System Partition here. macOS 15+/26 mounts FAT
# through the FSKit user-space driver, and the root process spawned by
# `osascript … with administrator privileges` cannot write that ESP by ANY
# means (through the mount OR the raw device, the latter is a protected
# EFI-type partition). The proven-writable context is an ordinary user session
# (no Full Disk Access required). So this privileged script only PREPARES the
# files; the app then copies them onto the ESP from its own user session.
stage extractingBootFiles
ESP_STAGE="$(mktemp -d /tmp/wm-esp.XXXXXX)"
mkdir -p "${ESP_STAGE}/EFI/Microsoft/Boot" "${ESP_STAGE}/EFI/BOOT" "${ESP_STAGE}/m1n1"

if [ "${DRY_RUN}" != "1" ]; then
    "${WIMLIB}" extract "${WIM}" "${IMAGE_INDEX}" /Windows/Boot/EFI \
        --dest-dir="${ESP_STAGE}/.wimboot" --no-acls >/dev/null 2>&1 \
        || die "boot-file extract failed"
    cp -R "${ESP_STAGE}/.wimboot/EFI/." "${ESP_STAGE}/EFI/Microsoft/Boot/" 2>/dev/null || true
    rm -rf "${ESP_STAGE}/.wimboot"
    if [ -f "${ESP_STAGE}/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
        cp "${ESP_STAGE}/EFI/Microsoft/Boot/bootmgfw.efi" "${ESP_STAGE}/EFI/BOOT/BOOTAA64.EFI"
    else
        log "WARNING: bootmgfw.efi not found in WIM, Windows boot manager missing"
    fi
    cat "${M1N1}" "${PAYLOAD}" > "${ESP_STAGE}/m1n1/boot.bin" || die "could not assemble boot.bin"
    log "boot.bin = $(stat -f%z "${ESP_STAGE}/m1n1/boot.bin") bytes (m1n1 + payload)"
    chmod -R a+rX "${ESP_STAGE}"   # the app (user session) must read this staging

    # Make sure macOS isn't holding the ESP, then hand off to the app, which
    # writes the ESP from the user session (the only context FSKit permits).
    diskutil unmount force "${EFI_PART}" >/dev/null 2>&1 || true
    echo "@@ESP_STAGING ${ESP_STAGE}"
    echo "@@ESP_PART ${EFI_PART}"
    log "Boot files staged; handing the EFI partition write to the app…"
else
    log "[dry-run] would stage boot files and hand the ESP write to the app"
    rm -rf "${ESP_STAGE}"
fi
progress 0.90

# Stages installingBootchain / configuringBoot / finished are completed by the
# app after this script exits (it copies the staged tree onto the ESP from the
# user session, then cleans up the staging dir).
log "Privileged phase complete. The app will finish writing the EFI partition."
exit 0
