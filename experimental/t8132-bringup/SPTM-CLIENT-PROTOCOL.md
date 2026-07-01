# The SPTM client protocol, what m1n1 must implement on M4 (increment 3)

Increment 2 concluded m1n1 must run *under* SPTM. This increment maps the
protocol it would have to speak, extracted statically from the M4 SPTM Mach-O
(`sptm.t8132.release.im4p`, decompressed).

## 1. Every physical page has a TYPE (the frame-type taxonomy)

SPTM enforces a type on every frame; the kernel may not write page tables
directly, it asks SPTM to, and SPTM checks the type. The XNU-facing types:

    XNU_DEFAULT              ordinary kernel RW data
    XNU_PAGE_TABLE          a page used as a translation table (SPTM writes it)
    XNU_PAGE_TABLE_ROZONE   read-only-zone page tables
    XNU_PAGE_TABLE_SHARED   shared-region page tables
    XNU_PAGE_TABLE_COMMPAGE commpage tables
    XNU_IOMMU               a DART/IOMMU translation table
    XNU_IO / XNU_PROTECTED_IO   MMIO mappings
    XNU_COMMPAGE_RO/RW/RX   the commpage
    XNU_KERNEL_RESTRICTED   restricted kernel pages
    XNU_COPROCESSOR_RO_IO   coprocessor MMIO

SPTM’s own + code types: `SPTM_CODE`, `SPTM_XNU_CODE`, `SPTM_PAGE_TABLE`,
`SPTM_KERNEL_ROOT_TABLE`, `SPTM_RO`, `SPTM_UNTYPED`, `SPTM_UNUSED`. To use a
page as a translation table you `sptm_retype()` it to `XNU_PAGE_TABLE` first.

## 2. The client-facing API surface

Pulled from the SPTM symbol/log strings, the operations a kernel uses:

**Bootstrap / lifecycle**
- `sptm_bootstrap_early` -> `sptm_bootstrap_late` -> `sptm_bootstrap_finalize`
- `sptm_init`, `sptm_init_txm_bootstrap_complete`
- handoff region carries the device tree (`"Could not find device tree in
  handoff region"`)

**Registration (the handshake)**
- `sptm_register_dispatch_table`, kernel registers its callback table
- `sptm_register_cpu` / `sptm_cpu_init`, per-core registration
- `sptm_register_xnu_exc_return` + `xnu_el2_exception_vector`, exception path

**Memory management (the core, all via GENTER into SPTM)**
- `sptm_retype`, change a frame’s type (the central primitive)
- `sptm_map_page`, `sptm_map_table`, SPTM performs the actual PTE write
- `sptm_uat_map_table` / `_unmap_table` / `_map_continue`, UAT (page-table) ops
- `sptm_dispatch` / `sptm_guest_dispatch` / `sptm_guest_enter`, dispatch entry

**IOMMU / DART**
- `sptm_t8110dart_init/map/unmap/map_table/unmap_table`, DART programming.
  **Note:** `t8110dart` confirms the M4 DARTs are t8110-class, exactly what our
  extracted device tree says (`compatible = "apple,t8110-dart"`). Cross-check ✓.

**NVMe / misc**
- `sptm_nvme_map_pages` / `_unmap_pages`, `sptm_register_io_frame`,
  `sptm_init_register_allow_io_range`

## 3. The call mechanism

The kernel calls into SPTM via **GXF `GENTER`** with a dispatch ID
(`"%llu is not a valid dispatch id (valid dispatch IDs are 0 - %u)"`), arriving
at the registered dispatch entry; SPTM validates the caller domain and entry
point (`"[SPTM Dispatch] Found illegal dispatch entry point. caller_domain"`).
SPTM runs at a guarded level above EL1/EL2 and returns via the exception path.

## 4. The strategically important insight

A full XNU is a heavy SPTM client. **m1n1 is not XNU**, it’s a minimal
bootloader whose entire job on M4 would be:

1. receive the SPTM handoff (it already gets a set-up address space + the ADT),
2. do the *minimum* mapping needed to place the next payload (U-Boot/UEFI),
3. jump to it.

So m1n1 needs only a **minimal subset** of this protocol, the bootstrap
handshake, dispatch-table + exception registration, and a handful of
`sptm_retype` / `sptm_map_page` calls, **not** the full UAT/commpage/IOMMU
surface XNU uses. That makes the task bounded: implement a thin SPTM client
shim in m1n1, not a reimplementation of XNU’s VM.

## Increment 3 conclusion

The SPTM client protocol is now **mapped**: a typed-frame memory model, a
`GENTER`-dispatch ABI, a registration handshake, and per-CPU/exception setup.
m1n1’s path on M4 is to implement a **minimal SPTM-client shim**, accept the
handoff, register, map the payload via SPTM, jump. The work is real but
*bounded and named*, which is more than “stalled on firmware RE.”

**Next (increment 4):** pin down the concrete ABI details a shim needs, the
dispatch-table layout (how many entries / which IDs), the handoff-region struct
(what SPTM hands the kernel: ADT pointer, memory map, CPU list), and the
`GENTER` calling convention. All still extractable from the SPTM binary.

---

# Increment 4, the concrete ABI, and where shell-RE bottoms out

## What is cleanly nailed down

- **The call mechanism is GXF.** The Apple guarded-mode instructions are present
  in the SPTM binary: `gexit` (encoding `0x00201400`) appears 7×, `genter`
  (`0x00201420`) 1×. So a client enters SPTM via `genter` (with a dispatch
  selector) and SPTM returns to the guest via `gexit`, confirmed, not inferred.
- **The bootstrap/handoff sequence** is a staged protocol with an announce
  mechanism (`bootstrap_stage_announce`, `"Expected bootstrap stages not
  reached"`): `sptm_bootstrap_early -> late -> finalize`. SPTM enters the guest
  kernel and watches it (`"[SPTM] Synchronous exception taken from guest before
  XNU bootstrap"`).
- **The handoff region contract**: must be page-aligned and a multiple of
  `SPTM_PAGE_SIZE`, is bounded (`"Too many handoff pages!"`), must be non-null,
  and **carries the device tree** (`"Could not find device tree in handoff
  region"`). That is precisely what a client reads on entry.

## Where shell-based static RE stops (an honest boundary)

`LC_SYMTAB` reports **nsyms: 1, strsize: 16**, SPTM is **stripped**. Every
"name" in increments 1–4 comes from embedded assert/log strings, *not* a symbol
table. That means the remaining numeric ABI cannot be recovered by string/byte
scanning from a shell:

- the dispatch **table layout** and the integer **dispatch IDs**,
- the **register calling convention** for `genter` (which reg carries the
  selector, which carry args),
- the **struct offsets** of the handoff region and the page-type **enum values**.

These need one of two things, and **neither is a shell script**:

1. **A real disassembler + manual analysis** (Ghidra/IDA): trace the `genter`
   exception handler, recover the dispatch-table base and bounds, label structs.
   Days of human RE.
2. **Hardware tracing**, and this is the elegant part: the **m1n1 hypervisor**
   (the "second-computer route") can trap macOS's `genter`/SPTM dispatch calls
   and record the **exact** dispatch IDs and register values *empirically*. It's
   the **same hypervisor-trace technique** we built for chicken bits
   (`chickens-trace/`), simply retargeted at the SPTM dispatch interface.

## Increment 4 conclusion, the static-RE phase is complete

Increments 1–4 mapped, from this machine alone, the entire **shape** of the M4
boot problem:

| | Result |
|---|---|
| Boot architecture | `iBoot -> SPTM -> XNU`, SPTM owns page tables (incr. 1) |
| Is SPTM skippable? | No, platform firmware, m1n1 must run under it (incr. 2) |
| Protocol surface | typed frames + registration + `genter` dispatch (incr. 3) |
| Call mechanism | GXF `genter`/`gexit`, staged bootstrap, ADT in handoff (incr. 4) |
| Exact numeric ABI | **needs Ghidra or hardware `genter`-tracing** (incr. 4 boundary) |

The desk-research phase has produced a real spec and a thin-shim strategy. The
next increment **requires the second Mac**, and it's the same `genter`-trap
hypervisor trace, now capturing the SPTM dispatch ABI instead of chicken bits.
After that it's pure hardware bring-up (cores, UEFI, framebuffer), and finally
the separate Windows cliff (AIC-vs-GIC + ACPI).
