#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
m4_probe.py — first-contact triage for m1n1 on an Apple M4 (T8132 "Donan").

This is the host-side tool for the "second-computer adventure". It does NOT
reimplement m1n1's proxy — it builds on it (the same proxyclient our
chickens-trace harness uses). Its job is the very first question of M4
bring-up: **once m1n1 is loaded on the M4, how far did it get, and what is the
SPTM secure monitor doing to it?**

Why this and not just the m1n1 REPL: on M1/M2 m1n1 runs at EL2 and owns the
machine. On M4 (per M4-BOOT-ARCHITECTURE.md / SPTM-CLIENT-PROTOCOL.md) iBoot
hands off to SPTM, which runs at a guarded level *above* the kernel and owns the
page tables. So the first thing to learn empirically is: which exception level
did m1n1 actually land at, is GXF/guarded mode active, where is SPTM's
CTRR-locked region, and which registers does SPTM trap. This script reads that
state and interprets it for bring-up.

## Setup (host = the second computer, target = the M4 over USB-C)

    # 1. m1n1 must already be loaded on the M4 (lowered Startup Security + the
    #    m1n1 stage installed), exposing its proxy over USB-C.
    # 2. On the host:
    export M1N1DEVICE=/dev/tty.usbmodemXXX        # the M4's m1n1 serial device
    export PYTHONPATH=/path/to/m1n1/proxyclient
    python3 m4_probe.py

If m1n1 never reaches proxy mode, that itself is the finding — note how far the
m1n1 console got before it stopped (SPTM likely faulted it).
"""

import sys

# MIDR part IDs for the M4 Donan cores (from CHICKEN-BIT-ARCHAEOLOGY.md / m1n1).
DONAN_ECORE = 0x52
DONAN_PCORE = 0x53
KNOWN_PARTS = {
    0x52: "M4 Donan E-core (Sawtooth)",
    0x53: "M4 Donan P-core (Everest)",
    0x42: "M3 Sawtooth E", 0x43: "M3 Everest P",
    0x32: "M2 Blizzard E", 0x33: "M2 Avalanche P",
    0x22: "M1 Icestorm E", 0x23: "M1 Firestorm P",
}


def connect():
    """Bring up the m1n1 proxy connection (auto-connects from M1N1DEVICE)."""
    try:
        # setup.py builds iface/p/u/hv and connects on import — the m1n1 idiom.
        from m1n1 import setup  # noqa: F401
        from m1n1.setup import p, u
        from m1n1 import sysreg
        return p, u, sysreg
    except Exception as exc:  # pragma: no cover - needs the hardware host
        sys.exit(
            "error: could not reach m1n1 on the target.\n"
            f"       ({exc})\n"
            "       Check: M1N1DEVICE points at the M4's USB serial device,\n"
            "       PYTHONPATH points at m1n1/proxyclient, and m1n1 actually\n"
            "       reached proxy mode on the M4. If m1n1's console stalled\n"
            "       before USB came up, that stall IS the first data point.")


def rd(u, sysreg, name):
    """Read a system register by name; return (value, status).

    status: 'ok' | 'trapped' (SPTM/EL trapped the access) | 'missing'.
    A trapped guarded register is itself a signal that SPTM owns it.
    """
    reg = getattr(sysreg, name, None)
    if reg is None:
        return None, "missing"
    try:
        return u.mrs(reg, silent=True), "ok"
    except Exception:
        return None, "trapped"


def main():
    p, u, sysreg = connect()
    print("=== m1n1 reached proxy mode on the target — first contact OK ===\n")

    findings = {}

    # --- who/where are we? ---------------------------------------------------
    midr, st = rd(u, sysreg, "MIDR_EL1")
    if st == "ok":
        part = (midr >> 4) & 0xFFF
        name = KNOWN_PARTS.get(part, f"unknown part 0x{part:x}")
        print(f"MIDR_EL1        = {midr:#018x}  -> {name}")
        findings["is_donan"] = part in (DONAN_ECORE, DONAN_PCORE)
        if not findings["is_donan"]:
            print("  ! not a Donan part — is this really an M4?")
    else:
        print(f"MIDR_EL1        : {st}")

    cel, st = rd(u, sysreg, "CurrentEL")
    if st == "ok":
        el = (cel >> 2) & 3
        print(f"CurrentEL       = EL{el}")
        findings["el"] = el
        if el == 2:
            print("  -> m1n1 is at EL2 (owns the hypervisor level) — M1/M2-style. "
                  "SPTM may not be constraining execution as feared.")
        elif el == 1:
            print("  -> m1n1 landed at EL1, NOT EL2. Strong sign SPTM/guarded "
                  "mode took the higher privilege and m1n1 is the constrained "
                  "guest. This is the core M4 problem, observed live.")
    else:
        print(f"CurrentEL       : {st}")

    # --- is guarded mode (GXF) / SPRR active? SPTM rides on these ------------
    gxf, st = rd(u, sysreg, "GXF_CONFIG_EL1")
    print(f"GXF_CONFIG_EL1  = " + (f"{gxf:#x}" if st == "ok" else st)
          + ("   [GXF/guarded mode ENABLED -> SPTM resident]"
             if st == "ok" and gxf else
             "   [trapped -> SPTM owns GXF]" if st == "trapped" else ""))
    findings["gxf"] = (st, gxf)

    sprr, st = rd(u, sysreg, "SPRR_CONFIG_EL1")
    print(f"SPRR_CONFIG_EL1 = " + (f"{sprr:#x}" if st == "ok" else st)
          + ("   [SPRR active -> SPTM permission remapping in force]"
             if st == "ok" and sprr else ""))

    # --- where is SPTM locked in memory? (CTRR region) ----------------------
    lwr, s1 = rd(u, sysreg, "CTRR_A_LWR_EL1")
    upr, s2 = rd(u, sysreg, "CTRR_A_UPR_EL1")
    if s1 == "ok" and s2 == "ok" and (lwr or upr):
        print(f"CTRR region     = {lwr:#x} .. {upr:#x}   "
              f"[{(upr - lwr) >> 10} KiB hardware-locked — SPTM's protected text]")
        findings["ctrr"] = (lwr, upr)
    else:
        print(f"CTRR_A_LWR/UPR  : {s1}/{s2}")

    # --- the running address space (did SPTM set up our MMU?) ---------------
    for name in ("SCTLR_EL1", "TTBR0_EL1", "VBAR_EL1"):
        val, st = rd(u, sysreg, name)
        print(f"{name:15} = " + (f"{val:#x}" if st == "ok" else st))
        if name == "SCTLR_EL1" and st == "ok":
            print(f"  MMU={'on' if val & 1 else 'off'}  "
                  f"I-cache={'on' if val & (1<<12) else 'off'}  "
                  f"D-cache={'on' if val & (1<<2) else 'off'}")

    # --- can we even peek at the guarded level SPTM occupies? ---------------
    _, stg = rd(u, sysreg, "VBAR_GL2")
    print(f"VBAR_GL2 (peek) : {stg}"
          + ("   [readable -> we have guarded-level visibility]" if stg == "ok"
             else "   [trapped/owned by SPTM, as expected]"))

    # --- verdict ------------------------------------------------------------
    print("\n=== verdict ===")
    el = findings.get("el")
    if el == 1:
        print("m1n1 is running as a CONSTRAINED GUEST under SPTM (landed at EL1, "
              "guarded mode active). This confirms the static-RE conclusion on "
              "live silicon: m1n1 must become an SPTM client (register a "
              "dispatch table, route page ops through GENTER). Next: trace the "
              "SPTM dispatch ABI (m4_sptm_trace.py) to learn the exact calls.")
    elif el == 2:
        print("m1n1 is at EL2 — less constrained than expected. Re-test whether "
              "page-table setup actually works (try a small map); SPTM may only "
              "gate specific operations. If page ops work, bring-up is closer to "
              "M1/M2-style than feared.")
    else:
        print("Could not read CurrentEL — m1n1 may be only partially up. Capture "
              "the m1n1 console log to see where it stopped; that's the next clue.")
    print("\n(Full register dump above is the empirical ground truth — save it "
          "alongside the static-RE docs in experimental/t8132-bringup/.)")


if __name__ == "__main__":
    main()
