# AP68040 changes made in this fork

Changes to the AP68040 CPU core (`rtl/ap68040_faster`) made in this fork of
MacLC475_MiSTer, kept so they can be offered back. Each entry gives the
documented behaviour it works towards, the change, how to switch it off, and
how it was checked. Timings are BCLK clocks from `tests/timing` (zero-wait
bus, caches on, copyback); "UM" is the MC68040 User's Manual (M68040UM/AD).

## 1. Operands across two cache lines: 8 clocks to 6

- **Documented:** an operand that crosses a cache line takes two cache
  accesses (UM 4.2). UM 10.1 leaves the timing of misaligned operands to the
  reader; one clock per extra access gives 2 clocks for a long word move.
- **Before:** 8 clocks for a load, and for a copyback store, when both lines
  are in the cache (the "fast split" job: E_S_START, E_SP_W, E_SP_2, E_SP_3,
  E_S_DONE, and a clock for DC1's lookup to recover).
- **Change:** `ap68040_dmu.sv`, parameter `FAST_SPLIT` (default 1). E_IDLE
  starts the second line's lookup itself, without the E_S_START clock, and
  E_SP_3 answers DC2 itself, without the E_S_DONE clock (a pending push bus
  error still goes through E_S_DONE).
- **After:** 6 clocks. Still three times the documented figure: the second
  lookup goes through the engine's stolen ports. A second lookup made by DC1
  itself is the remaining step.
- **Off:** `FAST_SPLIT = 0`.
- **Checked:** `tests/memsweep` (random byte/word/long operands on and
  around line boundaries, in colliding sets, cached and noncachable, with
  data-dependent branches; result compared with a model's memory image):
  160 runs pass before and after. A planted error in the split merge is
  caught. `tests/run_cpu040.sh` smoke, lc040, machine, mmu, profile pass.
