# M4 bring-up proxy client (host side)

The host-side tooling for the "second-computer adventure". It does **not**
reimplement m1n1's proxy, it builds on m1n1's own `proxyclient` (same as the
`chickens-trace/` harness). These scripts answer the first live questions of M4
bring-up.

## Contents

- **`m4_probe.py`**, first-contact triage. Once m1n1 reaches proxy mode on the
  M4, it reads the CPU/guarded-mode/CTRR state and reports, on live silicon,
  *which exception level m1n1 landed at and how much SPTM is constraining it*.
  This is the empirical counterpart to the static-RE docs.

## Host setup

The "host" is the second computer (Linux box, Pi, or another Mac) connected to
the M4 over a USB-C **data** cable. The target M4 must already have m1n1 loaded
(lowered Startup Security + the m1n1 stage installed).

```sh
# 1. Python deps for m1n1's proxyclient (validated needed):
pip3 install construct pyserial

# 2. Point at m1n1's proxyclient and the M4's USB serial device:
export PYTHONPATH=/path/to/m1n1/proxyclient
export M1N1DEVICE=/dev/tty.usbmodemXXX      # macOS host
#   or /dev/ttyACM0 on a Linux host

# 3. Run the triage:
python3 m4_probe.py
```

## What `m4_probe.py` reads, and why each matters

| Register | Tells us |
|---|---|
| `MIDR_EL1` | Confirms Donan (M4) cores (part `0x52`/`0x53`) |
| `CurrentEL` | **The key one.** EL2 = m1n1 owns the machine (M1/M2-style). EL1 = SPTM took the higher privilege and m1n1 is a constrained guest, the M4 problem, observed live. |
| `GXF_CONFIG_EL1` | Whether GXF/guarded mode is active (SPTM rides on it) |
| `SPRR_CONFIG_EL1` | Whether Shadow Permission Remapping is in force |
| `CTRR_A_LWR/UPR_EL1` | The hardware-locked region, SPTM's protected text |
| `SCTLR/TTBR0/VBAR_EL1` | The running address space SPTM handed us |
| `VBAR_GL2` | Whether we can even peek at SPTM's guarded level |

Note: `GXF_CONFIG_EL1` = `S3_6_C15_C1_2`, `CTRR_A_LWR_EL1` = `S3_4_C15_C2_3` -
the same `S3_4/S3_6_C15` impl-defined space the archaeology found SPTM writing.

## Status

`m4_probe.py` is syntax-clean and its register lookups are validated against the
real m1n1 `sysreg` module (10/10 resolve). The only untestable part from a desk
is the live USB connection, that needs the M4 + m1n1 + the second computer.

**Next tool (when the hardware's wired):** `m4_sptm_trace.py`, extend m1n1's
hypervisor to trap macOS's `GENTER`/SPTM dispatch calls and record the exact
dispatch ABI (the numeric piece static RE couldn't reach, see
SPTM-CLIENT-PROTOCOL.md, increment 4).
