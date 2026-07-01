# T8132 (Apple M4), extracted hardware facts

Source machine: **Mac mini (2024), Mac16,10, target-type J773g** (this repo's
development machine). All values read from the live Apple Device Tree via
`ioreg -p IODeviceTree` (macOS exposes the ADT that iBoot hands to every OS).
Raw dump: [Mac16,10-IODeviceTree.txt](Mac16,10-IODeviceTree.txt) (8,890 lines,
331 `compatible` entries).

Address translation: ADT `reg` offsets are relative to the `arm-io` node and
were translated to absolute MMIO through the `arm-io.ranges` table (27 rows;
row 0: child `0x0` -> parent `0x200000000`, size `0x3a0000000`; the
`0x4xxxxxxxx` USB block is identity-mapped).

**Validation:** the derived UART address `0x3ad200000` independently matches
`EARLY_UART_BASE` for `TARGET == T8132` in upstream m1n1 `src/soc.h`, two
unrelated sources agreeing on the decode.

## Identification

| Fact | Value |
|---|---|
| chip-id | `0x8132` (T8132) |
| board-id | `0x2a` |
| arm-io compatible | `arm-io,t8132` |
| product | `Mac16,10`, "Mac mini (2024)", SoC name "Apple M4" |

## CPU complex

| Fact | Value |
|---|---|
| Topology | 10 cores: 6 E-cores (reg `0x0`–`0x5`) + 4 P-cores (reg `0x100`–`0x103`) |
| P-cluster MPIDR base | `0x100`, **not** `0x10100` as on t8103/t8112 |
| E-core ADT compatible | `apple,sawtooth` (A16/M3 E-core lineage) |
| P-core ADT compatible | `apple,everest` (A16/M3 P-core lineage) |
| MIDR parts (upstream m1n1 midr.h) | Donan E `0x52`, Donan P `0x53` |

## Peripherals (absolute MMIO after ranges translation)

| Node | ADT compatible | Address | Size | Driver situation |
|---|---|---|---|---|
| aic | `aic,3` | `0x381000000` | `0x1cc000` | AICv3: driver exists in upstream m1n1 (`aic23_init(3,…)`); **no** Linux/U-Boot binding yet |
| uart0 | `uart-1,samsung` | `0x3ad200000` | `0x4000` | S5L UART, supported everywhere |
| wdt | `wdt,t8132`, `wdt,s5l8960x` | `0x3882b0000` | `0x4000` | S5L-lineage watchdog, supported |
| dart-usb0 | `dart,t8110` | `0x402f00000` | `0xc000` | T8110 DART generation, **already supported** by existing apple-dart drivers |
| dart-usb1 | `dart,t8110` | `0x40af00000` | `0xc000` | same |
| usb-drd0 | `usb-drd,t8132` | `0x402280000` | `0x11800` | dwc3 core block |
| usb-drd1 | `usb-drd,t8132` | `0x40a280000` | `0x11800` | dwc3 core block |
| atc-phy0 | `atc-phy,t8132` | `0x402a90000` | `0x4000` | new PHY generation, needs real bring-up |
| pmgr | `pmgr1,t8132` |, |, | ADT-driven in m1n1; full clock tree unmapped |

## Upstream m1n1 HEAD status for T8132 (as of 2026-06-12 clone)

- `soc.h`: `T8132` defined, `EARLY_UART_BASE 0x3ad200000` present
- `midr.h`: `MIDR_PART_T8132_DONAN_ECORE 0x52` / `_PCORE 0x53`
- `chickens.c`: dispatch entries exist, "M4 Donan (E core)" / "(P core)" -
  but `init = NULL` (no chicken-bit init function) and `features_m4` is a
  placeholder marked `XXX figure out what features are actually available`,
  with `SLEEP_NONE` ("probably new mode required")
- `aic.c`: AICv3 detected and driven (`aic,3` -> `aic23_init(3, node)`)

Translation: m1n1 *identifies* M4 and can plausibly reach proxy mode; the
per-core configuration and deep-sleep support are the open items upstream.
