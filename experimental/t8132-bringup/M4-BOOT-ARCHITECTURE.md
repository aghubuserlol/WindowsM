# M4 boot architecture & the m1n1 blocker, bring-up increment 1

Goal of this increment: understand *why m1n1 can't even load* on M4, because
that gates everything above it (UEFI, Windows Boot Manager, the installer).
Derived by static RE of the M4 firmware on a Mac mini (J773g): iBoot
(`iBoot.j773g.RELEASE.im4p`), SPTM (`sptm.t8132.release.im4p`), and the kernel.

## The M1/M2 model (what m1n1 was built for)

```
iBoot ──► m1n1   (runs at EL2, OWNS the machine: page tables, cores, MMIO)
```

m1n1 is loaded as the "kernel" via the boot policy. Permissive Security lets a
custom (non-Apple) kernel run, and m1n1 has full control to set up the chain.

## The M4 model (what actually happens now)

The firmware strings prove a **new, higher-privilege secure monitor** sits
between iBoot and the kernel:

```
iBoot ──► SPTM ──► XNU
          (Secure Page Table Monitor, runs at a Guarded Level above EL1/EL2
           via GXF/GENTER; OWNS all page tables; XNU is a constrained guest)
```

Evidence (all from the SPTM/iBoot binaries):

- **iBoot loads SPTM**: iBoot references `SPTM`, `SPTM-uuid-offset`,
  `load_kernelcache`, `lay_out_opaque_kernelcache`, it lays out SPTM + the
  kernelcache together.
- **SPTM runs before the kernel**: `"Synchronous external abort in early boot
  before XNU bootstrap"`, multi-stage `bootstrap` machinery
  (`"Expected bootstrap stages not reached"`).
- **SPTM owns the page tables (UAT)**: `sptm_uat_map_table`,
  `sptm_uat_unmap_table`, `XNU_PAGE_TABLE` frame type, `sptm_retype()`. Every
  physical page has a *type*; XNU may not write page tables directly, it must
  ask SPTM.
- **XNU calls into SPTM via GXF dispatch**: `GENTER immediate value`,
  `caller_domain`, `[SPTM Dispatch] illegal dispatch entry point`,
  `XNU-facing dispatch table`, `xnu_el2_exception_vector`,
  `xnu_exc_return_handler`. XNU registers handlers and traps up into SPTM.
- **Boot info passes through a Handoff region**: `"Could not find device tree
  in handoff region"`, `UAT Handoff region`, `Too many handoff pages!`. SPTM
  hands the device tree (ADT) and boot state to the kernel.
- **Memory is locked by CTRR**: `CTRR-protected frames`, SPTM's own text is
  hardware-locked read-only once bootstrapped.

## The blocker for m1n1 (the precise, real finding)

On M4 the bootloader **no longer owns the machine**, SPTM does. If m1n1 is
loaded into the kernel slot (where XNU goes), then by the time it runs:

1. SPTM has already bootstrapped at a guarded level **above** where m1n1
   executes, and **CTRR-locked** itself read-only.
2. SPTM **owns the page tables**. m1n1 expects to create and switch page tables
   freely; under SPTM it would have to route every page operation through the
   GXF dispatch interface, a fundamental rewrite of m1n1's memory model.
3. m1n1 cannot simply disable SPTM: iBoot established it before the kernel ran,
   and CTRR enforces it in hardware.

So m1n1-on-M4 requires one of:
- **(A) Become SPTM-aware**, register an XNU-style dispatch table and use
  GENTER for page operations (large rewrite, deep RE of the dispatch ABI), or
- **(B) Boot without SPTM**, determine whether a *custom, permissive-security*
  kernel is loaded by iBoot **without** SPTM (i.e. SPTM is only forced for
  signed Apple kernels). If so, m1n1 runs old-style and SPTM is irrelevant.

**Option (B) is the make-or-break question**, and it is the natural next
increment, and it's *also answerable by static RE of iBoot* (its
kernel-load/secure-boot-policy path), not only on hardware. This is exactly the
"firmware updates that necessitate reverse engineering" the Asahi project cites
as what stalled M4: the entire SPTM secure-boot layer is new since M1/M2.

## Increment 1 conclusion

The thing blocking m1n1 (and therefore UEFI, and therefore the Windows
installer) on M4 is **not** the CPU cores (those are known M3-family
Everest/Sawtooth, see CHICKEN-BIT-ARCHAEOLOGY.md). It is the **SPTM
secure-page-table monitor**, a whole new privileged boot stage that owns the
page tables and constrains the kernel. m1n1 must either coexist with it or be
loaded in a path that skips it.

**Next (increment 2):** RE iBoot's kernel-load path to determine whether a
permissive-security custom kernel gets SPTM forced on it, or boots without it.
That single answer decides whether M4 bring-up is "old-style m1n1 with a new
device tree" (tractable) or "rewrite m1n1 to live under SPTM" (a major effort).

---

# Increment 2, is SPTM skippable for a custom kernel? (the make-or-break)

Method: disassembled the decompressed M4 iBoot (capstone), resolved ADRP+ADD
string xrefs, and read the control flow around SPTM loading and the trust
decision.

## Evidence

1. **SPTM is platform firmware, registered unconditionally.** iBoot builds a
   flat table of standalone firmware objects, each a `(name, path)` pair fed to
   a register routine, and **SPTM is one entry among the other base firmware**,
   with no branch around it. Its path is fixed:
   `/usr/standalone/firmware/FUD/Ap,SecurePageTableMonitor.img4`.
   - `FUD` = Firmware Update Directory; the `Ap,` prefix is the Image4 manifest
     category for **Application-Processor platform firmware**, the *same class
     as iBoot itself*. SPTM is manifest-listed platform firmware, not part of
     the swappable `krnl` object.

2. **iBoot knows it's booting non-Apple code, and only *records* it.** The
   `non-apple-or-untrusted-code` string is used to **set a device-tree property**
   (via iBoot's property-set path) that *informs the OS* of the trust state. It
   is trust **reporting**, not a gate that skips platform firmware.

3. **Real-world corroboration.** If SPTM were trivially skipped for custom
   kernels, M4 bring-up would not be blocked on it, yet the Asahi project
   states M4 is stalled precisely on "firmware updates that necessitate reverse
   engineering," which is this secure-monitor layer.

## Increment 2 conclusion, we are in the hard world (Option A)

The boot-object structure (SPTM = AP platform firmware in the manifest, loaded
unconditionally before the kernel) plus the real-world stall point both point
the same way:

> **A custom, permissive-security kernel (m1n1) is still booted with SPTM
> active. SPTM is not skippable by swapping the kernel.** m1n1 must therefore
> *coexist with / run under* SPTM (Option A), not bypass it (Option B).

Confidence: **strong, not absolute.** Proving it to 100% needs a full trace of
iBoot's manifest-driven load loop (and may depend on runtime LocalPolicy state,
not just static branches). But the firmware *class* of SPTM and the independent
Asahi stall make Option A the working assumption.

## What that means for the road ahead

M4 bring-up is **not** "old-style m1n1 + our device tree." It is:

1. **RE the SPTM dispatch ABI**, the `GENTER`-based interface XNU uses to ask
   SPTM for page-table operations (entry points are visible in SPTM's
   `dispatch.c` symbols: the XNU-facing dispatch table, `xnu_el2_exception_vector`,
   the page `retype` calls). m1n1 would have to speak this protocol.
2. **Make m1n1 a legitimate SPTM client**, register a dispatch table, route its
   memory management through SPTM, satisfy the handoff-region contract.
3. *Or* find a higher-privilege foothold to neutralise SPTM, much harder, since
   SPTM CTRR-locks itself in hardware once bootstrapped.

This is exactly the work the Asahi team is doing for M4, and it's why there's no
ETA. The bring-up is gated on **reverse-engineering and implementing the SPTM
client protocol**, a substantial, hardware-in-the-loop effort, not on the
device tree or chicken bits (which we've already shown are done / trivial).

**Next (increment 3):** begin mapping the SPTM dispatch ABI from `dispatch.c` -
enumerate the dispatch IDs and the XNU-facing entry points SPTM exposes, since
that protocol is what m1n1 must implement to run under SPTM. (Static RE of the
SPTM binary, still doable from here.)
