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

## 2. Loads across two cache lines: the second lookup in DC1, 2 clocks

- **Documented:** as entry 1 (UM 4.2: two cache accesses).
- **Before:** 6 clocks (entry 1), the second line read through the engine.
- **Change:** `ap68040_dmu.sv`, parameter `DC1_SPLIT` (default 1). A load
  whose operand crosses a line stays in DC1 one more clock, in which the
  cache RAMs, the valid bits and the stale tracking read the next set; DC2
  then answers from the two captures on the ordinary fast-load path. Limits:
  both lines inside one 2 KB block (the next line then has the same tag and
  the same page), both hits, cachable, not locked. The engine's split job
  (entry 1) still takes every other case: a miss on either line, a store
  ahead of the load to either line, a write landing in either set, the last
  line of a 2 KB block. A second lookup that is disturbed (engine activity,
  a snoop, a write to the first line) starts over from the first.
- **After:** 2.1 clocks for `MOVE.L (A0),D0` across two cached lines (UM: 2).
  Copy loops with a misaligned source 4.0 clocks an iteration (was 4.9), with
  both misaligned 4.6 (was 5.6). Stores across two lines are unchanged at 6.
- **Off:** `DC1_SPLIT = 0`.
- **Checked:** `tests/memsweep`, now with a paged-MMU mode (4 KB pages,
  copyback and write-through pages) and operands at the last line of a 2 KB
  block and of a page: 360 runs pass (60 seeds, three modes, store buffer on
  and off). Planted errors in the new path are caught: the check for stores
  ahead removed, the merges into the kept long word removed, the restart
  after a disturbance removed, the second lookup's hit ignored. One planted
  error is not caught (DC2 keeping its answer through a later write): the
  engine takes such a load first, so that guard is defensive. The
  `tests/run_cpu040.sh` suites pass (smoke, lc040, machine, mmu, profile).
- **Not covered by a test:** bus snoops and interrupts arriving during the
  second lookup; a build's timing (the cache RAM address has one more
  multiplexer level).

## 3. Instructions take the documented clocks at least (the pacer)

- **Documented:** MC68040UM section 10, tables 10.5 and 10.6: the clocks an
  instruction takes in the execute stage (the Execute column, interlocked
  clocks added), cache hits and aligned operands.
- **Before:** many instructions completed sooner than the 68040 can:
  MULU.W in 3.8 clocks (14), MULS.L 3.8 (20), SWAP 1 (2), ASL #n 2 (3),
  a DBRA loop 2.1 a pass (3), BSR + RTS 4.1 (7), a not-taken Bcc 1.5 (3).
  DIVU.W was too slow: 35 clocks (27).
- **Change:** `ap68040_pkg.sv` `um_clocks()` gives an instruction's
  documented clocks from its operation word; `ap68040_useq.sv` puts the
  figure on every uop (`uop.tmin`, 0 = none); `ap68040_backend.sv`,
  parameter `PACE` (through `ap68040.sv`; default 0, set to 1 in
  `rtl/cpu040.sv`), holds an instruction's last uop in EX until the count
  of clocks since the previous instruction completed reaches the figure. A
  taken Bcc and a looping DBcc take one clock less (2 and 3), from the
  branch's real outcome. It is a floor: clocks the instruction spent anyway
  count, and an instruction that redirects the front end as it leaves
  (mispredicted branch, unfollowed jump, serializing instruction) is not
  held. `rtl/cpu040.sv` also sets `DIV_STEPS(4)`, the divider's existing
  four-bits-a-clock setting, so that the divides can meet their figures.
- **Covered so far** (only tables read and checked against the manual):
  Bcc, BRA, BSR, DBcc, JSR, JMP, RTS, RTD, RTR, LINK, UNLK, LEA, MULU,
  MULS, DIVU, DIVS (word and long), ASL, ASR, LSL, LSR (register and
  memory), SWAP, EXT.W, NOP.
- **Not covered yet:** MOVE and the arithmetic group with indexed and
  memory-indirect modes, ADDA, SUBA, CMPA, rotates, bit and bit-field
  instructions, MOVEM, PEA, Scc, TAS, and the memory-indirect modes of the
  covered instructions (taken at their brief-extension figure).
- **After:** MULU.W 13.8, MULS.L 19.8, MOVE + DIVU.W 28 (UM 28), MOVE +
  DIVU.L 45 (45), SWAP 2.0, ASL #2 3.0, LSR Dn 3.0, DBRA loop 3.1,
  BNE not taken + MOVEQ 4.0 (4), BSR + RTS 7.0 (7), copy loop 5.1 (5),
  LEA d16 2.0 (2).
- **Off:** `PACE = 0` (and `DIV_STEPS(2)` for the earlier divider).
- **Checked:** `tests/memsweep` gained multiplies, divides (word and long,
  signed and unsigned), shifts, SWAP, EXT and calls and returns through the
  stack: 360 runs pass, and an error planted in the model's long divide
  fails every run. `tests/run_cpu040.sh` smoke, lc040, machine, mmu and
  profile pass.
- **Still slower than documented** (untouched by this entry): LINK about 5
  clocks (3), NOP 15 (8), mispredicted and indirect branches, traps.
