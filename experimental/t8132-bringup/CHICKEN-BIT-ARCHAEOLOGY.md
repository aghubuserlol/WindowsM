# Where did the M4 chicken bits go?, a static-RE investigation

Goal: find the Apple M4 (T8132 "Donan") CPU chicken bits **without** the usual
hardware setup (an M4 + a second Mac running m1n1's hypervisor over USB), by
statically reverse-engineering the firmware that ships on the machine.

Everything here was derived on a real Mac mini (2024, J773g / M4) from binaries
already on disk. The method and every count are reproducible.

## Method (validated)

Apple ships **per-SoC kernels** at `/System/Library/Kernels/kernel.release.<soc>`
(t8103=M1, t8112=M2, t8122=M3, t8132=M4 …), unencrypted Mach-Os. The chicken
bits are writes to the implementation-defined `HID`/`EHID` registers, which live
in the `S3_0_C15_*` system-register space.

An `msr` to that space has a fixed instruction encoding:

    (word & 0xFFFFF000) == 0xD518F000      # msr S3_0_C15_C<m>_<n>, X<t>

Validated against ground truth: this byte-mask finds **exactly 102** such
instructions in the M1 kernel, matching `llvm-objdump`’s disassembly count, and
the raw bytes confirm it (`d518f42e` = `msr S3_0_C15_C4_1, x14`).

## Finding 1, the chicken bits are being *engineered away*

Classic `S3_0_C15` (HID/EHID) writes, per shipping kernel:

| SoC | kernel | HID writes |
|---|---|---|
| M1 | t8103 | **102** |
| M2 | t8112 | 10 |
| M3 | t8122 | 10 |
| M4 | t8132 | **0** |

Across four generations the count collapses to zero. The M4 kernel touches the
classic HID space **nowhere**.

## Finding 2, it’s not in any other on-disk M4 boot component either

M4 introduced a new secure-boot architecture (SPTM + TXM). All extracted,
decompressed (lzfse, **not encrypted**), and scanned with the validated mask:

| M4 component | source | classic `S3_0_C15` writes |
|---|---|---|
| XNU kernel | `kernel.release.t8132` | 0 |
| kernel `__bootcode` | (section) | 0 |
| SPTM | `sptm.t8132.release.im4p` | 0 |
| TXM | `txm.macosx.release.im4p` | 0 |
| **iBoot** | `all_flash/iBoot.j773g.RELEASE.im4p` | 0 |

(iBoot decompressed cleanly to 2.97 MB, `"iBootStage2 for j773g Copyright
2007-2026, Apple Inc."`, so the image is complete, not truncated.)

## Finding 3, the encoding *changed*; config moved into SPTM

The impl-defined registers didn’t vanish, they **re-encoded**. M4 SPTM performs
**202 writes to `CRn=15` impl-defined registers**, but at *non-zero op1*
encodings (`S3_4_C15`, `S3_6_C15`, …), never the classic `S3_0_C15`.

Honest caveat: much of that `S3_6_C15` space is SPTM’s **own** security
machinery (GXF / SPRR, Guarded Execution, Shadow Permission Remapping), not
necessarily core init. Separating the two needs per-register analysis not done
here. The clean, certain claim is only: **the classic HID sequence is absent.**

## Finding 4 (decisive), M4 cores ARE M3-family cores

The M3 kernel’s surviving 10 writes decode to real, recognisable chicken bits:

- `HID4`/`EHID4` bit 11 = `HID4_DISABLE_DC_MVA`, set/cleared **per core type**
  (gated by an `MPIDR_EL1 & 1` check), m1n1 already handles this as the
  generic `disable_dc_mva` feature.
- `HID13[63:62] = 0b11` (a power/cycle-delay tuning).
- `S3_0_C15_C15_0` bit 32.

And the M4 ADT reports the cores as:

    compatible = "apple,everest"   (P-cores)
    compatible = "apple,sawtooth"  (E-cores)

- the **same microarchitecture strings as M3**. The M4 "Donan" cores are
Everest/Sawtooth (MIDR part `0x53`/`0x52`, a newer revision of M3’s `0x43`/`0x42`).

## Conclusion

1. **The M4 cores are not an unknown quantity.** They’re the M3 Everest/Sawtooth
   microarchitecture, which m1n1 **already supports** (`chickens_everest.c`,
   `chickens_sawtooth.c`). Those are the **evidence-based** starting point for
   `chickens_donan.c`, not a blind guess, but the same core family confirmed by
   the ADT.
2. **The classic chicken-bit pile is nearly gone** (102 -> 0). Newer silicon has
   saner reset defaults; this matches upstream m1n1’s near-empty `features_m4`.
   M4 likely needs *very few* classic chicken bits.
3. **The real M4 bring-up gap is SoC-level, not core-level**: the new SPTM
   secure-boot architecture, the unimplemented deep-sleep mode
   (`features_m4.sleep_mode = SLEEP_NONE // XXX`), the AICv3 wiring, and the
   relocated register encodings, *not* a mountain of un-measured chicken bits.

This is the useful, non-obvious result: static RE didn’t hand over a chicken-bit
table because **there isn’t much of one to find**, and the cores are a family
m1n1 already knows. M4 is gated by the boot architecture, not the CPU init.

## What still needs hardware

The Donan revision (`0x53`) could differ from M3 (`0x43`) in details, and the
sleep sequence + SPTM interaction can’t be derived from these binaries alone.
Confirming the core init and capturing the sleep mode still wants the m1n1
hypervisor on real hardware (see `chickens-trace/`). But the search space is now
*small and bounded*, starting from known M3 code, not open-ended.
