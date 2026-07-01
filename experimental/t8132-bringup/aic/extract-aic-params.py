#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
extract-aic-params.py — pull the Apple T8132 (M4) AIC (v3) parameters from the
live Apple Device Tree.

m1n1's AICv3 driver (src/aic.c, aic23_init) is fully ADT-driven: it reads the
register-layout offsets below at runtime rather than hard-coding them. This
script extracts the same values so they can be (a) documented, (b) sanity
cross-checked against m1n1's known constants, and (c) encoded into a Linux
device-tree binding for aic,3.

Run on the M4 itself:  python3 extract-aic-params.py
"""

import re
import struct
import subprocess
import sys

# Offsets m1n1's aic23_init() reads from the AIC ADT node, plus a few extras
# that fully describe the v3 register window.
WANTED = [
    "cap0-offset",          # CAP0: encodes NR_IRQ and LAST_DIE
    "maxnumirq-offset",     # INFO3: MAX_IRQ / MAX_DIE
    "aic-iack-offset",      # event / IACK register (read to ack an IRQ)
    "extint-baseaddress",   # IRQ_CFG base (per-IRQ target config array)
    "extintrcfg-stride",    # per-die stride of the ext-int config block
    "intmaskset-stride",
    "intmaskclear-stride",
    "hwintmon-stride",
    "aicglbcfg-offset",
    "rev-offset",
    "#main-cpus",           # CPU count the AIC fans out to
]


def read_node(name):
    return subprocess.run(
        ["ioreg", "-lw0", "-p", "IODeviceTree", "-n", name, "-r", "-d", "1"],
        capture_output=True, text=True).stdout


def u(blob):
    b = bytes.fromhex(blob)
    if len(b) == 4:
        return struct.unpack("<I", b)[0]
    if len(b) == 8:
        return struct.unpack("<Q", b)[0]
    return int.from_bytes(b, "little")


def main():
    out = read_node("aic")
    if '"AppleARMIODevice"' not in out and '"compatible"' not in out:
        sys.exit("error: AIC node not found (run this on the M4).")

    vals = {}
    for prop in WANTED:
        m = re.search(r'"%s" = <([0-9a-f]+)>' % re.escape(prop), out)
        if m:
            vals[prop] = u(m.group(1))

    compat = re.search(r'"compatible" = <"([^"]+)"', out)
    reg = re.search(r'"reg" = <([0-9a-f]+)>', out)

    print("# T8132 AIC parameters (extracted from live ADT)")
    print(f"compatible        = {compat.group(1) if compat else '?'}")
    if reg:
        b = bytes.fromhex(reg.group(1))
        off = struct.unpack_from("<Q", b, 0)[0]
        size = struct.unpack_from("<Q", b, 8)[0]
        print(f"reg (arm-io off)  = 0x{off:x} size 0x{size:x}")
    for prop in WANTED:
        if prop in vals:
            print(f"{prop:18s} = 0x{vals[prop]:x}")

    # Cross-checks against m1n1's known AICv3 constants / topology.
    print("\n# cross-checks")
    ok = True
    if vals.get("extint-baseaddress") == 0x10000:
        print("  OK  extint-baseaddress == m1n1 AIC3_IRQ_CFG (0x10000)")
    else:
        ok = False
        print(f"  ??  extint-baseaddress 0x{vals.get('extint-baseaddress',0):x} "
              f"!= m1n1 AIC3_IRQ_CFG 0x10000")
    if vals.get("#main-cpus") == 10:
        print("  OK  #main-cpus == 10 (6 E + 4 P, matches cpu@ + pmgr ECPU/PCPU)")
    else:
        ok = False
        print(f"  ??  #main-cpus = {vals.get('#main-cpus')}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
