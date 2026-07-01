# Bundled Resources

This directory is the staging area for binaries that ship inside
`WindowsM.app/Contents/Resources`. None of them are committed — each is
produced by a script in `scripts/`:

| File | Produced by | Purpose |
|---|---|---|
| `m1n1.bin` | `scripts/build-m1n1.sh` | Asahi Linux bootloader stage; chainloads the UEFI stage |
| `edk2-apple.fd` | `scripts/build-edk2.sh` | UEFI stage payload for m1n1 (currently Apple-silicon DTBs + gzipped U-Boot, the chain Asahi ships; see the script header for the EDK2/Project Mu story) |
| `wimlib-imagex` | `scripts/build-wimlib.sh` | Applies install.wim directly to NTFS |
| `mkntfs` | `scripts/build-wimlib.sh` | Formats the Windows partition NTFS |
| `uup-converter/` | `scripts/fetch-uup-converter.sh` | Builds an ISO from UUP packages |
| `drivers/` | `scripts/fetch-drivers.sh` (manual) | Apple Silicon Windows drivers |
| `BCD` | manual (see README "BCD template") | Boot Configuration Data template |

After adding or rebuilding resources, run `xcodegen generate` so the Xcode
project picks up new files, then rebuild the app.

The app fails fast with a descriptive error (naming the script to run) when a
required resource is missing — so a fresh checkout builds and runs the wizard
UI without any of these present.
