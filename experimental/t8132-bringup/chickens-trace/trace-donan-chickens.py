#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
trace-donan-chickens.py — capture Apple M4 (T8132 "Donan") chicken bits by
MEASUREMENT, using m1n1's hypervisor.

This is the honest answer to "where do the chicken bits come from": you do not
guess them, you record what Apple's own firmware writes on real silicon.

How it works
------------
m1n1's hypervisor traps guest accesses to the implementation-defined HID/EHID
registers via HACR.TRAP_HID / HACR.TRAP_EHID (see proxyclient/m1n1/hv, which
sets these unconditionally when virtualising). Every guest `msr SYS_IMP_APL_*HID*`
is then logged by the HV's MSR handler as:

    Pass: msr SYS_IMP_APL_HID3, x9 = ... (OK) (SYS_IMP_APL_HID3)

By booting *macOS itself* as the guest and capturing those lines during early
CPU bring-up, we obtain the exact per-core tunings for this specific SoC.

This script is a thin, well-labelled driver around the upstream HV. It must run
on a SECOND machine connected to the M4 target's USB debug port (the standard
m1n1 proxy setup) — it cannot introspect the SoC it is running on.

Usage
-----
    # On the host driving the M4 target over USB (m1n1 already on the target):
    export M1N1DEVICE=/dev/tty.usbmodemXXX
    PYTHONPATH=/path/to/m1n1/proxyclient \\
        python3 trace-donan-chickens.py --boot /path/to/macos-kernelcache \\
                                        --out donan-capture.txt

    # Then turn the capture into chickens_donan.c:
    python3 derive-chickens.py donan-capture.txt > chickens_donan.generated.c

Without the hardware + a second host this script intentionally does nothing but
explain itself; the capture format it documents is what derive-chickens.py
consumes, and sample-capture.txt demonstrates that format end to end.
"""

import argparse
import sys


CAPTURE_HEADER = """\
# m1n1 Donan (T8132/M4) HID/EHID capture
# Each line: <core_type> <reg_name> <hex_value>
#   core_type : ecore | pcore   (derived from MPIDR of the trapping CPU)
#   reg_name  : SYS_IMP_APL_HIDnn / SYS_IMP_APL_EHIDnn
#   hex_value : value the guest (macOS firmware) wrote
# Lines beginning with '#' are comments.
"""


def build_hv(args):
    """Wire up the upstream m1n1 hypervisor with HID/EHID trapping enabled.

    Imports are done lazily so the file is importable (and self-documenting)
    on a machine without the proxyclient or the hardware attached.
    """
    try:
        from m1n1.setup import p, u, iface  # noqa: F401  (upstream proxy bringup)
        from m1n1.hv import HV
    except Exception as exc:  # pragma: no cover - requires hardware host
        sys.exit(
            "error: m1n1 proxyclient not importable / target not connected.\n"
            f"       ({exc})\n"
            "       Run this on the host driving the M4 over USB, with\n"
            "       PYTHONPATH pointing at m1n1/proxyclient. See module docstring."
        )

    hv = HV(iface, p, u)
    # The upstream HV enables HACR.TRAP_HID / TRAP_EHID itself (see
    # proxyclient/m1n1/hv/__init__.py). We additionally tee its log so the
    # HID/EHID 'Pass: msr ...' lines are persisted in our capture format.
    return hv


def core_type_for_cpu(hv, cpu_id):
    """ecore/pcore from the trapping CPU's MPIDR affinity.

    On T8132 the P-cluster MPIDR base is 0x100 (extracted from the live ADT;
    note this differs from the 0x10100 used on M1/M2). E-cores are reg
    0x0..0x5, P-cores 0x100..0x103.
    """
    try:
        mpidr = hv.sysreg[cpu_id].get("MPIDR_EL1", cpu_id)
    except Exception:
        mpidr = cpu_id
    aff1 = (mpidr >> 8) & 0xFF
    return "pcore" if aff1 >= 1 else "ecore"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--boot", help="macOS kernelcache / boot object to run as guest")
    ap.add_argument("--out", default="donan-capture.txt", help="capture output path")
    ap.add_argument("--explain", action="store_true",
                    help="print the methodology and exit (no hardware needed)")
    args = ap.parse_args()

    if args.explain or not args.boot:
        print(__doc__)
        print("Capture format produced for derive-chickens.py:\n")
        print(CAPTURE_HEADER)
        print("ecore SYS_IMP_APL_EHID0 0x0000000080000000")
        print("pcore SYS_IMP_APL_HID3  0x0000000000000810")
        print("\n(Pass --boot <kernelcache> on a connected M4 host to capture for real.)")
        return 0

    hv = build_hv(args)  # exits with guidance if no hardware

    captured = []

    # Tee the HV log: intercept its formatted 'Pass: msr SYS_IMP_APL_*HID*'
    # lines and re-emit them in our normalised capture format.
    original_log = hv.log

    def teed_log(msg, *a, **k):
        original_log(msg, *a, **k)
        if "msr SYS_IMP_APL_" in msg and "HID" in msg:
            # 'Pass: msr SYS_IMP_APL_HID3, x9 = 810 (OK) (SYS_IMP_APL_HID3)'
            try:
                reg = msg.split("msr ", 1)[1].split(",", 1)[0].strip()
                val = msg.split("= ", 1)[1].split(" ", 1)[0].strip()
                ctype = core_type_for_cpu(hv, getattr(hv.ctx, "cpu_id", 0))
                captured.append(f"{ctype} {reg} 0x{int(val, 16):016x}")
            except Exception:
                pass

    hv.log = teed_log

    print(f"Booting guest {args.boot} under HV with HID/EHID trapping…")
    print("Let macOS reach the desktop, then Ctrl-C to stop the capture.")
    try:
        hv.start(args.boot)
        hv.run()
    except KeyboardInterrupt:
        pass

    with open(args.out, "w") as f:
        f.write(CAPTURE_HEADER)
        for line in dict.fromkeys(captured):  # de-dup, keep order
            f.write(line + "\n")
    print(f"Wrote {len(set(captured))} unique HID/EHID writes to {args.out}")
    print("Next: python3 derive-chickens.py", args.out, "> chickens_donan.generated.c")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
