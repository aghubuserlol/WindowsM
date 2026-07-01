# T8132 (Apple M4) bring-up, experimental

Notes and tooling toward booting the m1n1 -> U-Boot -> UEFI chain on M4
Macs.

Nothing in here has booted on real hardware yet. Every constant was pulled
from a real M4's hardware description (see `extracted/t8132-facts.md`),
the driver-support claims were checked against the upstream source trees,
and everything compiles. Treat it as a starting point, not a port.

## What's here

| Path | What it is |
|---|---|
| `extracted/Mac16,10-IODeviceTree.txt` | Full ADT dump from a Mac mini M4 (the raw evidence) |
| `extracted/t8132-facts.md` | Decoded facts: addresses, topology, compatibles, driver status |
| `patches/u-boot-t8132-experimental-dts.patch` | `t8132.dtsi` + `t8132-j773g.dts` + `t8132-pmgr.dtsi` for U-Boot, CPUs, UART, WDT, AICv3, USB, pmgr + **123 power domains** |
| `pmgr/generate-pmgr-dtsi.py` | Extracts the 123-node power-domain tree from the live ADT (pure extraction; reproducible) |
| `pmgr/t8132-pmgr.dtsi` | The generated power-domain tree (committed output) |
| `aic/extract-aic-params.py` | Extracts + cross-checks the AICv3 register parameters from the live ADT |
| `aic/t8132-aic.md` | AICv3 register model, parameters, and the three core-count cross-checks |
| `CHICKEN-BIT-ARCHAEOLOGY.md` | Static-RE study of M1->M4 firmware: where the chicken bits went, and proof the M4 cores are M3-family Everest/Sawtooth |
| `patches/m1n1-t8132-donan-chickens-scaffold.patch` | Wires m1n1's NULL Donan dispatch to real E/P-core init functions + a safe, empty, trace-populated chicken-bit scaffold |
| `chickens-trace/trace-donan-chickens.py` | Captures Donan HID/EHID chicken bits by **measuring** them under m1n1's hypervisor (HACR.TRAP_HID) |
| `chickens-trace/derive-chickens.py` | Turns a capture into the MEASURED regions of `chickens_donan.c` |
| `chickens-trace/sample-capture.txt` | **Synthetic** capture (clearly labelled) proving the toolchain end-to-end |
| `m1n1-t8132-experimental.bin` | m1n1 HEAD **with the Donan scaffold applied** (dispatch wired; chicken regions empty/safe) |

## State of each layer (checked 2026-06-12)

1. **m1n1: further along than commonly believed, and now wired for Donan.**
   Upstream HEAD already identifies M4 ("Donan" cores, MIDR parts 0x52/0x53),
   has the T8132 early UART base, and ships an AICv3 driver. Upstream left
   per-core init `NULL` and `features_m4` a placeholder. The scaffold patch in
   this directory replaces those `NULL`s with real `init_t8132_donan_ecore` /
   `_pcore` functions whose chicken-bit regions are **empty by default** (as
   safe as the `NULL` was) and are filled by *measurement* via the
   `chickens-trace/` tooling. **We did not invent chicken-bit values**, the
   entire point of the trace harness is to read what the silicon actually
   wants. Wrong HID writes hang cores, so the values come from the hardware or
   they stay empty.

2. **U-Boot, the gap this directory actually fills.** Upstream has no T8132
   support at all. The patch adds a deliberately minimal, evidence-only
   device tree: CPUs (6E+4P, real MPIDR layout, P-cluster at 0x100, not the
   t8112-style 0x10100), S5L UART, S5L watchdog, AICv3 node (no driver, so
   `disabled`), and the USB complex with real addresses (`dart,t8110` DARTs -
   a generation existing drivers already support, but `disabled` pending
   atcphy work). Interrupt numbers and the pmgr clock tree are *omitted*, not
   faked; U-Boot's console path polls and relies on iBoot leaving the UART
   powered.

3. **Linux/Windows device support, not addressed here.** That layer is
   team-years of work and is where "Windows on M4" actually lives or dies.

## How to test (when you're ready to experiment)

Requires lowering Startup Security in recoveryOS first, and a serial/UART
debug cable (or m1n1 proxy over USB) to see anything useful:

```sh
# 1. Apply the patch and rebuild the payload (script does both):
EXPERIMENTAL_T8132=1 ./scripts/build-edk2.sh

# 2. Rebuild m1n1 (stock upstream HEAD is correct, it has the M4 tables):
./scripts/build-m1n1.sh

# 3. Rebuild the app; the installer stages the payload as usual.
```

This cannot brick the machine: the boot object lives on the external SSD's
ESP and is only entered when explicitly chosen from the startup picker;
macOS on the internal disk is untouched.

## The remaining work, mapped (updated)

In dependency order. ✅ = tooling/scaffold landed this round; ⬜ = open.

1. ⬜ **m1n1 proxy mode on M4**, try the staged build; debug over UART/USB
   proxy. Needs the hardware + a second host.
2. ✅ **Donan chicken-bit pipeline + archaeology**, `chickens_donan.c` is
   wired into m1n1's dispatch (was `NULL`), and `chickens-trace/` *measures*
   the values under the hypervisor. **Static RE of the shipping firmware**
   (`CHICKEN-BIT-ARCHAEOLOGY.md`) then largely answered the question without
   hardware: the classic HID chicken-bit pile has shrunk 102 -> 10 -> 10 -> **0**
   from M1 -> M4, and the M4 cores are confirmed M3-family Everest/Sawtooth
   (ADT compatible strings + MIDR), which m1n1 already supports. So the M4
   core-init gap is small and bounded, not an open-ended measurement problem.
3. ⬜ **features_m4 / deep sleep**, upstream's `features_m4` is still a
   placeholder (`SLEEP_NONE`). The same trace harness surfaces the sleep
   sequence; encoding it is the next step after (2).
4. 🟡 **AICv3**, fully *characterised*. The v3 register-layout parameters
   (`aic-iack-offset 0x40000`, `extint-baseaddress 0x10000`, strides, etc.)
   are extracted from the live ADT (`aic/extract-aic-params.py`,
   `aic/t8132-aic.md`), the DT node is complete and wired to `ps_aic`, and the
   `extint-baseaddress` value independently matches m1n1's `AIC3_IRQ_CFG`
   constant. m1n1's driver needs nothing further (it reads these at boot). The
   remaining piece is the upstream **Linux** `apple,aic3` driver delta, a
   bounded change that needs a kernel tree to compile-verify.
5. ⬜ **atcphy for t8132**, USB PHY bring-up, hardest piece on this list.
6. ✅ **pmgr block + power domains**, node added with the real base
   (`0x380700000`), and **123 power-domain children extracted from the live
   ADT** (`pmgr/generate-pmgr-dtsi.py` -> `t8132-pmgr.dtsi`). Compiles into the
   DTB with zero dangling phandles; `serial0` is wired to `ps_uart0`. The
   remaining pieces are the second-MMIO-block domains (50) and the
   hand-annotated `always-on` hints. See `pmgr/README.md`.
7. ⬜ **Everything above U-Boot**, kernel/Windows drivers; different project.

Steps 1–3 need exactly the hardware this repo was developed on, an M4 Mac,
plus a USB debug cable and a second host to run the proxy.

## Proving the chicken-bit toolchain without hardware

```sh
cd chickens-trace
python3 trace-donan-chickens.py --explain            # methodology, no HW
python3 derive-chickens.py sample-capture.txt --emit-c  # synthetic -> C
```

The emitted C was compiled and linked into m1n1 (`build/chickens_donan.o`,
then `m1n1.bin`) to confirm the generator produces valid bring-up code. On a
real M4 you would instead run `trace-donan-chickens.py --boot <kernelcache>`,
then `derive-chickens.py donan-capture.txt --patch src/chickens_donan.c`.
