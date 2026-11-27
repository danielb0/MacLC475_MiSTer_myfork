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

## 4. The pacer's table completed

- **Documented:** MC68040UM 10.4 (MOVE), 10.5 and 10.6, pages 10-9 to 10-28.
- **Change:** `um_clocks()` now takes the first extension word as well and
  covers the integer instruction set: MOVE (source by destination, 10-9 and
  10-10), MOVEA, MOVEQ, ADD/AND/OR/EOR/SUB/CMP/TST/CLR/NEG/NEGX/NOT, the
  immediate group and CMPI, ADDQ/SUBQ, ADDA, SUBA, CMPA, ADDX/SUBX, CMPM,
  ABCD/SBCD/NBCD, EXG, EXT, EXTB, Scc, PEA, CHK, MOVE to/from CCR, MOVE from
  SR, the bit instructions (immediate and register bit number), the bit
  fields, ROL/ROR/ROXL/ROXR, MOVEM (2 or 3 clocks plus one a register, from
  the mask), TRAPV, and entry 3's. Not listed, so not paced: instructions
  that synchronize or run locked (MOVE to SR, the to-SR immediates, MOVEC,
  MOVES, MOVEP, CAS, CAS2, CHK2, CMP2, TAS on memory, PACK, UNPK, RTE, STOP,
  RESET, cache and MMU instructions), traps, floating point. Indexed modes
  are taken at the brief extension word's figure.
- **After** (`SUITE=2 tests/timing/run.sh`, new second set, 38 cases): 30
  within 0.1 clock of the manual, among them ADDA.L Dn,An 2.0 (2), SUBA 1.0
  (1), MOVEA.W (An) 2.0 (2), MOVE (An)+,(An)+ 2.0 (2), indexed MOVE and ADD
  3.0 (3), ROL # 3.0 (3), ROR Dn 4.0 (4), ROXL 5.0 (5), BSET # 3.0 (3), BCLR
  Dn 4.0 (4), Scc 2.0 (2), BFEXTU 4.0 (4), CMPM 3.0 (3), ABCD 3.0 (3), the
  MOVEM pairs 12.9 (13) and 10.8 (11), LEA indexed 4.0 (4). The first set's
  indexed MOVE went from 1.6 to 3.0 (3) and its MOVEM pair from 30.1 to 32.9
  (33).
- **Slower than documented, found by the second set** (not the pacer's
  doing; for later): MOVE (An),(An) 2.0 clocks (1); MOVE d16,d16 2.5 (2);
  ADDQ #,d16(An) 3.0 (2); ADDI.L #,Dn 2.3 (1); CMPI.L #,d16(An) 5.0 (2);
  EXG 3.0 (1 and 2); BFTST 4.0 (3); BTST #,Dn 1.2 (1).
- **Checked:** `tests/memsweep` 180 runs pass; `tests/run_cpu040.sh` smoke,
  lc040, machine, mmu, profile pass.

## 5. A store's cache miss: 22 clocks to 15

- **Documented:** MC68040UM 4.2 and 7.4: a copyback store that misses reads
  its line (one burst, 5 clocks with no wait states) and then writes into
  it. Section 10 gives no figure for a miss.
- **Before:** 22 clocks (MOVE.L Dn,(An) + LEA, line not cached, clean
  victim): E_S_START, E_S_ACT, E_FILL, E_FILLW, E_FILL_W, E_BUS, the burst,
  E_FILL_INS, E_S_XL, E_S_XLW, E_S_XL2, E_S_ACT, E_S_NEXT, E_S_DONE. The
  load's miss already skipped eight of these (475-resume); the store's did
  not.
- **Change:** `ap68040_dmu.sv`, parameter `FAST_STMISS` (default 1). The
  store's line read goes to the bus from E_S_ACT, the victim's steps (fv)
  running during the burst, exactly as the load's; and after a fill with no
  dirty victim to push, E_FILL_INS marks the part a hit in the way just
  installed and goes to E_S_NEXT, which is all the second lookup would say.
  A pending snoop cancel, a dirty victim, a failed or inhibited fill keep
  the old path.
- **After:** 15 clocks. A line-crossing store into uncached lines 25.7
  (was 31.9). The project's profile case "copyback RAM to RAM MOVE.L copy,
  8 KB" 86 clocks an iteration (108 on 475-resume, with this fork's pacer
  on as well).
- **Off:** `FAST_STMISS = 0`.
- **Checked:** `tests/memsweep` 360 runs pass; a wrong way planted in the
  new shortcut fails 12 of 18 runs. `tests/run_cpu040.sh` smoke, lc040,
  machine, mmu, profile pass.

## 6. Stores across two cache lines: the second lookup in DC1, 2 clocks

- **Documented:** MC68040UM 4.2 (two cache accesses); one clock an extra
  access gives 2 clocks for a long word store across a line.
- **Before:** 6 clocks (entry 1), the second line looked up by the engine.
- **Change:** `ap68040_dmu.sv`, under `DC1_SPLIT` (entry 2). A store across
  a line makes its second lookup in DC1 as a load does. When both lines are
  copyback hits (`m2_st2`) DC2 has nothing left to do and WB's existing
  two-part fast store (`wb_fs`) writes them; anything else takes the
  engine's job as before. A store keeps no data from its first lookup, so
  a write of the line's bytes during the second lookup does not disturb it
  (only the caches' own activity does).
- **After:** 2.0 clocks. Copy loops: destination misaligned 5.3 clocks an
  iteration (UM 5.25), source misaligned 5.6 (5.5), both 5.1 (5.75).
- **Checked:** `tests/memsweep` 360 runs pass; ignoring the second line's
  hit fails 8 of 18 runs. `tests/run_cpu040.sh` smoke, lc040, machine, mmu,
  profile pass.

## Notes for later (found while measuring entries 5 and 6)

- **A load behind a store of the same bytes waits two clocks** (store
  then load 4 clocks; none once two instructions separate them). The manual
  describes pending, deferrable write-backs (2.1, 4.2) and gives no timing
  for a read that depends on one; the store's data does not exist before
  the end of its execute clock. Left as it is: no documented figure.
  `tests/timing` SUITE=2 has cases with and without the dependency; with
  independent addresses a store and a load take 2.0 clocks (UM 2).
- **Read-modify-write instructions on neighbouring long words stall**:
  ADD.L Dn,(An)+ 2.5 clocks (UM 1), ADDQ.L #,(An)+ 2.8 (2). An RMW is
  compared with a load behind it by line, not by bytes.
- **Multi-word instructions are supplied slowly**: MOVE.L d16(An),Dn 1.2
  clocks, MOVE.L Dn,d16(An) 1.6, ADDI.L #,Dn 2.3 (UM 1 each); CMPI.L
  #,d16(An) 5.0 (2). The fetch side, not the data side.
- **A memory-to-memory MOVE is two uops**: MOVE.L (An),(An) 2 clocks
  (UM 1). The forms the manual gives 2 clocks to are met.

## 7. Both caches the MC68040's size: 4 Kbytes

- **Documented:** MC68040UM section 4: each cache is four-way
  set-associative, 64 sets of four 16-byte lines, 4 Kbytes.
- **Before:** instruction cache 16 Kbytes (`ap68040_fetch.sv` CSB 8, "an
  experiment"), data cache 8 Kbytes (`ap68040_pkg.sv` CSB 7).
- **Change:** CSB 6 in both. No other change: the design takes CSB as a
  constant, and entry 2's and 6's second lookup falls back at the last line
  of a block, now 1 Kbyte.
- **Effect:** more misses, as on the real processor. Instruction timing
  with the code cached is unchanged.
- **Bench:** the `tests/timing` program is larger than 4 Kbytes, so each
  test now runs twice in a row and the second run is timed; the "cold"
  column is the first run of the first pass.
- **Checked:** `tests/memsweep` 360 runs pass (its operands were chosen to
  collide at this size too); `tests/run_cpu040.sh` smoke, lc040, machine,
  mmu, profile pass.

## Notes from the board (2026-11-26, captures in local/shots/perf)

- A RAM line read takes about 13 clocks on the board (3.27 a beat), where
  `tests/timing`'s ideal memory answers a zero-wait 2-1-1-1 burst in 5: the
  bench understates a miss's cost on the machine. The LC 475's own wait
  states are not in Apple's developer note.
- Norton's "Function" test read 1.07 of a Quadra 700 after entry 6 (1.01
  before): a line-crossing store at 2 clocks is faster than the real
  processor's. The manual gives the two cache accesses but no time.

## Estimates where the documentation is silent (not yet built)

Agreed 2026-11-26: where no document gives a figure, a reasoned estimate is
used, named as one, with its basis; entries above rest on the manual, these
do not.

- **Main memory bus timing of the LC 475** (the MEMCjr, Apple 343S0164-A).
  Not documented: Apple's developer notes for the LC 475 / Quadra 605 and
  for the Centris 610, 650 and Quadra 800 (the related MEMC) give no wait
  states or registers, and MAME's model of the chip is functional only.
  Estimate: a line read 4-2-2-2 (10 clocks), a single read 4 clocks.
  Basis: the RAM must be 80 ns or faster (LC 475 note) and a 25 MHz clock
  is 40 ns, so the access alone is two clocks, with one before it for
  address decode and the row/column multiplex and one after for data setup;
  fast-page RAM of that speed needs 45 to 50 ns between accesses in a row,
  more than one clock, so each later beat takes two -- which is also why
  the Centris 650 and Quadra 800 interleave bank pairs "reducing access
  time for burst access cycles" (their note), and the LC 475, with one
  SIMM socket, cannot. Uncertainty: about a clock on the first beat.
  For comparison the 68040's minimum is 2-1-1-1 (5), and this core on the
  board takes about 13 clocks a line and 9 for a single read.
  Order: remove the core's own overhead around a miss first, then set the
  bus to the estimate behind a setting; Norton's memory tests as a guide
  that it is not far off, not as a target.
- **A store across two cache lines** is left at 2 clocks (entry 6). Norton's
  Function test reads 1.07 of a Quadra 700 with it; the manual gives the two
  cache accesses and no time, and no better figure can be argued.

## 8. The instruction queue: 8 words to 16

- **Documented:** MC68040UM 10.4 - 10.6 give an instruction's clocks by its
  operation and addressing modes, not its length: `MOVE.L #<xxx>,Dn` (three
  words) takes 1 clock, `MOVE.L #<xxx>,(xxx).L` (five words) 2.
- **Measured before** (`tests/timing`, `SUITE=3`, code cached): two words
  1.22 clocks (long-aligned) and 1.64 (word-aligned), three words 2.45,
  four 2.98, five 5.47.
- **Cause:** `ap68040_fetch.sv` F1 to F3 cannot wait, so F0 fetches only
  while the queue has room for every word on its way (`room`): six words
  with each stage full. With `QN` 8 that was true only with the queue
  empty, so the fetch ran in bursts, and an instruction of three words or
  more waited for the fetch pipeline's three clocks again each time.
- **Change:** `QN` 16. The fetch then runs without a break, one long word
  a clock.
- **After:** two words 1.00 at either alignment, three 1.45, four 1.98,
  five 2.45. (`QN` 12: the same except five words, 2.95.) What is left is
  the fetch's rate, two words a clock; MC68040UM 4.7.1 has a cache hit put
  a half-line, four words, on the instruction bus.
- **Checked:** `tests/memsweep` 360 runs pass; `tests/run_cpu040.sh` smoke,
  lc040, machine, mmu, profile pass.

## 9. A fetch is a half-line: four words a clock

- **Documented:** MC68040UM 4.7.1: "For instruction prefetch requests that
  hit in the cache, the half-line selected by physical address bit 3 is
  multiplexed onto the internal instruction data bus." 7.3: the processor
  prefetches by half-lines whatever the alignment.
- **Before** (entry 8): one long word a clock, so three words took 1.45
  clocks for 1 and five 2.45 for 2.
- **Change** (`ap68040_fetch.sv`, parameter `HLF`; `cpu040.sv` sets it; not
  with `BTIC`, whose target words are a long word):
  - F0's address is where the chunk starts; F1 delivers from there to the
    end of the half-line, or to the last word of the first branch the BTB
    takes at or after it. F0 goes on at the next half-line.
  - The cache's data is read a half-line at a time: two memories per way,
    one per long word, each beat of a fill written to its own.
  - The BTB is four arrays of half the rows (row PC[BTB_AW+1:3], array
    PC[2:1]): the same entries and tags, all four read with the half-line.
  - F2 and F3 carry four words; a second predecode table; the predecode
    ring has four banks, one write each a cycle.
  - F3 waits when the queue cannot take its words, so F0 needs room only
    for the words ahead of its own chunk (which is then the one chunk that
    can wait, with nothing behind it). With four words in each stage the
    old rule would have stopped the fetch as entry 8 describes.
- **After** (`SUITE=3`): three words 1.00, four 1.98, five 1.98 - 2.03,
  `BRA.L` 1.98, a 3-word instruction at a branch target 3.02 for 3. Cold
  code (instruction cache misses) is 10 to 20 percent quicker; sets 1 and
  2 are unchanged or nearer their figures, none faster than the manual.
- **Checked:** `tests/memsweep` 360 runs pass; `tests/run_cpu040.sh` smoke,
  lc040, machine, mmu, profile pass; with `HLF` 0 the figures are entry
  8's. Planted fault (F3 never waits): 24 of 24 memsweep runs fail.

## 10. The pacer: BRA and BSR take 2 clocks

- **Documented:** MC68040UM 10.5: BRA 2, BSR 1L + 1; Bcc 2 taken, 3 not.
- **Defect (entry 3's):** BRA and BSR reach EX as a Bcc that is always
  taken, and the pacer took a clock off every taken Bcc: they were held to
  1 clock. The fetch's redirect hid it; with entry 9 `BRA.S` followed by a
  3-word instruction took 2.70 clocks for 3.
- **Change** (`ap68040_backend.sv` `pace_br`): the clock comes off only a
  Bcc whose figure is 3 (a true conditional) and a DBcc.
- **After:** `BRA.S` 1.98, `BRA.L` 1.98, the pair above 3.02.

## Notes from the instruction-supply sweep (tests/timing SUITE=3, 2026-11-27)

Clocks per instruction, code cached, ideal memory; the manual's figure first.

- **A wrong branch prediction costs about 9 clocks.** The MC68040 has no
  history: Bcc 2 taken / 3 not, DBcc 3 / 4. Here a loop branch that always
  goes one way is on the figure, one that alternates takes 18.6 for 9, a
  DBcc's exit 13 for 4, a two-turn loop 18.4 for 8. Forward `BNE.S` taken
  64 times in a row: 5.45 for 2, every other one mispredicted (not traced);
  not taken in a row 5.4 for 3.
- **Jumps through a register redirect at the end of the pipeline:**
  `JSR d16(An)` + `RTS` 17 for 9, `LEA` + `JMP (An)` 14.5 for 5, `PEA` +
  `RTS` (a return no call made) 17.5 for 9. `BSR`/`JSR (xxx).L` + `RTS`,
  `BRA`, `JMP (xxx).L` and `JMP (d16,PC)` are on their figures; `BRA.L`
  2.95 for 2.
- **An instruction cache miss costs about 13 clocks a line with ideal
  memory** (the bus: 5). After the last beat the fetch looks the line up
  in the cache again (4 clocks to the queue), the words take 4 more
  through decode to AG, and the next line's miss is found only then.

## 11. The fetch waits for a place in the branch-target list

- **Found by** the board: with entry 9 Norton's Search fell 2.7% and Sort
  1% against entry 8 alone (0.691 -> 0.672, 0.710 -> 0.703), and on the
  bench the loop `SUBQ.L #1,D0 / BNE.S` went from 3.12 to 3.20 clocks a turn.
- **Cause:** the queue's words that end a BTB-taken branch have their targets
  in a list of four (`tq`). A fetch issued with the list full (`bt_room`
  false) could not take its BTB hit, ran on past the branch and was
  redirected by the decoder. With half-line fetches the fetch gets ahead of
  a short loop until four turns wait in the queue; the trace shows the
  decoder's redirect every 34 clocks.
- **Change** (`ap68040_fetch.sv` `f0_go`): with HLF, F0 waits for a place in
  the list. The words already queued are at least four instructions.
- **After:** the loop 3.11 (manual 3). Of the three sets only three other
  cases moved, each by under 0.1 clock: `MOVE.B (A0)+,(A1)+ / DBRA` 5.15 ->
  5.12, `BRA.S` + 3-word instruction 3.02 -> 2.98, `BSR.W / RTS` 6.97 -> 7.06.
- **Verified:** tests/timing sets 1-3, run_cpu040 smoke/lc040/machine/mmu/
  profile, memsweep 360 of 360. Not yet on the board.

## Sweep for clocks lost by accident (2026-11-27, tests/timing SUITE=4)

Entry 11's bug prompted a sweep of the whole CPU for the same family:
lists and counters that fill, predictions and cached results thrown away,
waits wider than their cause. Three read-only audits listed candidates;
each got a bench case, and only what the bench confirmed was changed
(entries 12-16). Clocks, the manual's figure first.

Not borne out: a loop's place in a half-line (3.12 a turn at all four);
a miss that evicts a modified line (the push's bus time, about 5 clocks,
and no more); the ADDA and SUBA rows of `um_clocks` (the manual's tables
10-13 and 10-27 do differ: ADDA Dn 2, An and # 1; SUBA Dn 1, An and # 2).
Left open: a store miss costs 2.5 clocks more than a load miss and a
read-modify-write miss 3.3 more; the second use of a pointer just loaded
loses a clock; the store buffer lets a read pass only one queued write.

## 12. Exception stacking and the vector fetch use the data cache

- **Before:** the donor marked them no-allocate (`dm_noalloc`: MFC_SUP).
  With the frame's stack line not in the cache every word of the frame
  went to the bus, came back from the bus at RTE, and the line never
  entered the cache; the vector's line likewise.
- **Documentation:** MC68040UM 8 (stack frames: long-word transfers, an
  aligned stack pointer "greatly enhances exception processing
  performance") gives the data cache no exception for them.
- **Change** (`ap68040_backend.sv`): `dm_noalloc` is 0. The level-7
  vector's read past the cache (`dm_pastc`) is untouched.
- **After:** `TRAP #0` + `RTE` 63 -> 56 (29); A-line + handler 66 -> 58
  (31); the same trap four calls deep, its frame on a new line, 140 -> 100.

## 13. The return stack is restored after an exception

- **Before:** the uops of an exception's routine carry no return-stack
  snapshot, so the redirect to the handler restored nothing. The calls and
  returns D1 had decoded past the trapping instruction stayed counted, and
  every return to a frame open at the exception was mispredicted.
- **Change** (`ap68040_backend.sv` `cr_v`, `cr_s`): the stack as the last
  completed instruction left it is kept, and a redirect whose uop has no
  snapshot restores that.
- **After:** `TRAP #0 / RTS` four calls deep 108 -> 88 (with entry 12: 160
  before both; 84 would be the trap's own cost).

## 14. A return the stack did not see spends its entry

- **Before:** `MOVEA.L (A7)+,A0 / JMP (A0)` (and RTD) left the call's
  entry on the stack; every enclosing RTS then took the entry of the
  frame inside it and was mispredicted. Four calls deep: 64.5 for 27.
- **Change** (`ap68040_decode.sv` `ras_xp`, `ap68040_fetch.sv`): a
  back-end redirect to the address on top of the restored stack pops it, a
  clock after the redirect, in D1's stack and the fetch's.
- **After:** 36.9 (the jump through a register still redirects late: the
  sweep's item C). One call deep is unchanged at 19.4 for 6.
- The MC68040 has no return stack: these two entries only stop this
  core's from costing more than the manual's figures.

## 15. PEA and JSR (An) no longer wait for a MOVE's scratch register

- **Before:** `PEA` and `JSR (An)/(d16,An)` form their address in T0 at
  AG; a memory-to-memory `MOVE` before them loads T0 at EX, and AG waits
  for an older EX writer of the register it updates. 2 clocks, a false
  dependency: `MOVE.L 8(A6),-(A7) / PEA 12(A6) / ADDQ.L #8,A7` 7 for 5.
- **Change** (`gen/ap68040_ucode_init.svh`, `gen/ap68040_ucode_rom.svh`,
  words 27, 28, 90, 91): they use T4, which only RTE and the FPU's moves
  write. Patched in the generated tables: `tools/ucode.py` is not in this
  repository, so the generator needs the same change upstream.
- **After:** 5.

## 16. A load beside a modified operand is compared by bytes

- **Before:** a load waited for an older read-modify-write (`ADDQ.L
  #1,(A0)`) to any byte of its 16-byte line (`st_byte`, "RMW by the
  line"), 2 clocks. A plain store was already compared by bytes.
- **Change** (`ap68040_dmu.sv`): an unlocked RMW writes in WB as a store
  does, by the same byte mask, and is compared the same way; a locked one
  (TAS, CAS) keeps the line.
- **After:** `ADDQ.L #1,(A0) / MOVE.L 4(A0),D0` 4.03 -> 3.02 (the clock
  left is the RMW on the bytes it wrote the turn before); `ADD.L
  D0,(A0)+` over successive long words 2.53 -> 1.03 (1); `ADDQ.L
  #1,(A0)+` 2.77 -> 2.02.

Entries 12-16 verified together: tests/timing sets 1-4 (nothing under its
figure that was not before), run_cpu040 smoke/lc040/machine/mmu/profile,
memsweep 360 of 360. Not yet on the board.

## Machine side: the RAM line read (2026-11-27; not the CPU)

Board counters under Norton's CPU tests (build 10, local/shots/perf
analysis_norton_cpu_20261127_104603.txt): every RAM data read in them is a
data-cache line fill, and a line read holds the CPU's bus 13 clocks (17
behind queued writes). Instruction spends 28% of its clocks there, Tree
22%, BMove/A 58%. A bench with the real bridge, controller and a chip
model (local/tests/linetrace, not tracked) reproduces 12/13/14 by the
SDRAM's row state and 17.2 behind a line write; about 9 of the clocks are
the SDRAM's own, the rest registering stages. No Apple document gives the
LC 475's RAM timing; the estimate noted above is 10 (4-2-2-2).

- **17. `swim2_memory` passes the machine's beat in the clock it selects
  it.** With SWIM2 defined (the board build) every RAM beat went through
  the floppy image arbiter's request register: one clock a line read. The
  bridge now sees the request in the selecting clock; the registers carry
  it from the next. Floppy clients are selected as before.
- **18. A line's second beat is acknowledged the clock the line turns
  valid** (`lc475.sv` `bus_tail_wait`). The first long word is
  acknowledged a clock before the bridge publishes the whole line, so the
  burst's look-ahead missed and the second beat took two more clocks.
- **After** (line read, clocks; arbiter in the path): row open 12.6 ->
  10.6, a new row every line 13.9 -> 11.9, behind a line write 17.2 ->
  16.2. Every long word of every fill is checked against the chip model.
- **Verified:** linetrace (18 configurations), run_cpu040 smoke/machine/
  profile/mmu. Not run: `tests/tb_swim2_memory.sv` (it needs
  `tests/tb_sdram.sv`, which is not in the repository), so the arbiter with
  floppy clients active is checked by reading only. Not yet on the board.
- **Left:** the request is registered in lc475 and again in the bridge (1
  clock); a read waits for the whole write FIFO, whose drain takes 7
  clk_ram a long word, and its read pointer crosses through an extra
  register (2-3 clocks behind writes).

## 19. A data-cache miss is answered before its victim is pushed

- **Board:** under Norton every RAM data read is a line fill; the engine's
  lookup states took about 5 clocks a miss on top of the bus (Instruction:
  11% of all clocks).
- **Before:** with a dirty victim the fill's end went to the push first
  (`E_PUSHV_B`), which takes `bo_line`, and the access then looked its own
  line up again (`E_S_XL` ... `E_S_DONE`): answered about 20 clocks after
  the line read with ideal memory, against at once for a clean victim. A
  read-modify-write got no shortcut with either victim.
- **Documentation:** MC68040UM 4.6.2: the dirty line goes to the push
  buffer and is written after the line read; the access does not wait.
- **Change** (`ap68040_dmu.sv`): the load's and the store's own-fill
  shortcuts apply with a dirty victim as well (also the last-beat one);
  the victim stays in the push buffer and is pushed from `E_IDLE` before
  the engine takes any other job. An unlocked, unsplit read-modify-write
  takes the load's shortcut, its write finding the way just installed. A
  split access keeps the old order (its second part may need the push
  buffer); a simulation check fails a fill that finds the buffer full.
- **A push that ends in a bus error** is now reported with the next DC2
  job, not the one whose fill evicted the line (no RAM here answers TEA).
- **After** (clocks a turn of `op / LEA 16(A1),A1 / DBRA`, ideal memory,
  every turn a miss): load 16.4 -> 12.5 dirty, 11.4 -> 11.1 mixed; store
  16.4 -> 14.5; `ADDQ.L #1,(A1)` 17.8 -> 15.0 dirty, 14.6 -> 11.8.
  `MOVE.L D0,(A4)` write misses 27.0 -> 23.0.
- **Verified:** tests/timing sets 1-4, run_cpu040 smoke/lc040/machine/mmu/
  profile, memsweep 360 of 360 (dirty evictions, split operands, the
  final memory image compared), linetrace with the real SDRAM path (a
  line read 0.3-0.5 clock slower on average, some now behind the push).
  Not yet on the board.

## 20. A load waits for a store by PA19-4, not the offset in the page

- **Before:** `st_line` matched a load in DC2 against the stores in EX and
  WB by PA11-4 only. A copy whose source and destination lie a multiple of
  4 Kbytes apart had every load wait for the store before it: `MOVE.L
  (A0),(A1)` 4 clocks.
- **Change** (`ap68040_dmu.sv`): the compare takes PA19-4.
- **After:** 2 clocks, as with any other destination. (The manual's 1
  needs both of the move's uops in one clock: DUAL, off in this build.)
- **What the tables do not give** (MC68040UM 10.1): write-back times
  ("system dependent"), so a store followed by a load of the same place,
  and unaligned operands (supposition 3). The bench's figures for those
  cases are sums or estimates of mine, not the manual's.
- **Verified:** tests/timing sets 1 and 2, memsweep 360 of 360.

## 21. The refill after a redirect: three clocks shorter

- **Documentation:** the MC68040 prefetches both paths of a conditional
  branch (7.x): Bcc 2 clocks taken, 3 not, whatever it did before; JMP
  (An) 3. This core guesses one path, and a redirect refilled the whole
  front: about 9 clocks from the redirect to AG.
- **Timing margin:** at this machine's 25 MHz the CPU's slowest path has
  about 14 ns to spare of 40 (the donor ran faster), so stages that only
  register can be passed with room.
- **Changes:**
  - `ap68040_fetch.sv` (`fa`, `rf0`): the redirect's own clock is the F0
    of its target. The cache, tag, BTB and I-ATC lookups take the target
    address in that clock, where the redirect first loaded `fpc` and F0
    ran the clock after.
  - `ap68040_useq.sv` / `ap68040_decode.sv` (`d_push`, `d_rec`): with no
    record waiting, the microcode ROM is addressed from the record D1 is
    pushing, not from `rq0` the clock after.
  - `ap68040_useq.sv` (`uo_v`, `uo_u`): with the uop queue empty the uop
    being formed goes to AG in that clock, not through `uq0`.
- **After** (clocks; the manual's figure last): alternating Bcc loop 18.6
  -> 15.6 (9); two-turn loop 18.4 -> 15.4 (8); DBRA's exit 14 -> 11 (5);
  `JSR (A2)` + `RTS` 16 -> 13 (8); `LEA` + `JMP (A0)` 14.3 -> 11.3 (5);
  `TRAP #0` + `RTE` 56 -> 49 (29); `NOP` 14.9 -> 11.9 a pair (8). Over the
  146 cases with a figure the excess over the manual fell from 228 clocks
  to 162; no case newly under its figure.
- **Tried and left off:** DUAL (1) leaves `MOVE.L (A0),(A1)` at 2 and puts
  `MOVE.L D0,D1` at 0.98; BTIC (1) does nothing for a wrong guess.
- **Verified:** tests/timing sets 1-4, run_cpu040 smoke/lc040/machine/mmu/
  profile, memsweep 360 of 360. Not yet on the board.
