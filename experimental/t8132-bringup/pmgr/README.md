# T8132 PMGR power-domain extraction

The "mechanical but large" bring-up item, done from real data. Asahi
hand-maintains ~1100 lines of power-domain nodes per SoC; this extracts the
T8132 (M4) equivalent directly from the machine's Apple Device Tree.

## What it produces

`generate-pmgr-dtsi.py`, run on the M4, emits `t8132-pmgr.dtsi`:
**123 power-domain nodes**, each with its real register offset, label, and
parent dependency links, wired into U-Boot's `&pmgr` syscon. The committed
copy here is the output from a Mac mini (2024, Mac16,10).

## Why it is trustworthy (not fabricated)

- **Source is the silicon.** The ADT `devices` (392 entries × 48 bytes) and
  `ps-regs` (16 × 12 bytes) blobs are read live via `ioreg`. Re-running the
  generator on the machine reproduces the file byte for byte.
- **Parser matches m1n1.** The 48-byte `struct pmgr_device` layout (name at
  0x20, `addr_offset` at 0xa, `psreg_idx` at 0xb, u16 ids) is exactly the one
  in m1n1 `src/pmgr.c`. Offset = `ps_regs[psreg_idx].reg_offset +
  (addr_offset << 3)`, the same arithmetic m1n1's `pmgr_device_get_addr` uses.
- **Independent cross-check.** The extracted domains include `ECPU0..5` +
  `PCPU0..3`, the exact 6E+4P core topology derived separately from the ADT
  `cpu@` nodes. Two unrelated parts of the ADT agree.
- **It compiles and resolves.** The generated dtsi builds into
  `t8132-j773g.dtb` with **zero dangling phandles**; `serial0`'s
  `power-domains = <&ps_uart0>` resolves, and parent chains
  (e.g. `ps_uart0` -> its parent) resolve too.

## What is deliberately scoped out

- **Virtual domains (219)**, `PMGR_FLAG_VIRTUAL` devices have no register and
  are skipped (they are aggregation nodes; not needed for the DT).
- **Second register block (50)**, devices whose `ps-regs` entry points at
  `reg_idx 1` live in a different MMIO window than the main `&pmgr` syscon;
  emitting them needs a second pmgr node and is left for later.
- **`apple,always-on`**, Asahi marks core-infrastructure domains always-on by
  hand. That annotation is a hint, not derivable purely from the ADT here, so
  it is intentionally omitted rather than guessed wrong (omission is safe; a
  wrong always-on is not).

## Regenerating

```sh
# On the M4 itself:
python3 generate-pmgr-dtsi.py > t8132-pmgr.dtsi
# (the build script applies it via the u-boot DTS patch under EXPERIMENTAL_T8132=1)
```
