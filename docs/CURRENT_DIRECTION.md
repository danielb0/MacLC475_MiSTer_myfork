# Current direction

Updated 2026-11-04.

## Fixed

- One builder: `MacLC475.qpf`; branches for experiments. Stock sys only.
- 25/75 MHz clocks, seed 38, 4 KiB caches, no FPU, Ethernet/MT32-pi off.
- CPU refresh complete on `codex/small33-lc040` (Q800 small33, DUAL=0,
  BTIC=0); see `CPU_DONOR.md`. `main` holds the older reference CPU.
- Compacted BRAM VRAM (320 KB physical, 512 KB advertised). Full VRAM is a
  later option via the Q800 DDR3-VRAM branch (`6f72684`); keep VRAM behind
  the memsel beat port and DAFB fetch port so a backend swap stays local.
- OSD: Dani's computer-core layout. Memory/monitor wait for reset; aspect
  and scale apply live. Diagnostics need `MACLC475_DEBUG` (P9).

## Experiment

- `exp/lean-ddr3-vram`: lean Q800 CPU + DDR3 VRAM + ROM cache + store buffer, no FPU. See `CPU_DONOR.md`. Awaiting fit and hardware comparison against `diag/swim2-trace`/`codex/small33-lc040`.

## State

- Guest: 7.5.3 CD install to SCSI HDD, 7.5.5 update via floppy, reboots and
  memory changes work.
- Floppy catalog corruption unresolved; regressions do not reproduce it.
  Trace build on `diag/swim2-trace` fits (positive slack). See `SWIM2_TRACE.md`.
- `diag/swim2-trace` commit `9ed2fd9` mixes the scale/AR and docs changes
  with the trace qsf lines. Return only non-trace changes to the candidate.
- Latest candidate fit (`5ea79ea`): 75% ALMs, 91% RAM blocks, positive slack.
- Unrecorded: CPU execution tests (`tests/run_cpu040.sh` smoke/lc040/machine/
  mmu), matched resource comparison with `main`.

## Next

1. Hardware capture of the floppy failure; decode, then fix with regression.
2. Performance baseline: Speedometer 3 + Machine Report from a real LC 475
   (Elle sourcing), matched setup. Target is real 25 MHz behavior; slower
   points at the memory path, faster means MEMCjr wait states. A CPU-upgrade
   enhancement may follow later.
3. Remaining qualification: see `RELEASE_READINESS.md`.

## Open questions

- May DUAL/BTIC/other CPU options be tried if the bus work falls short
  (RAM blocks at 91%)?
- V-Integer: README and `RELEASE_READINESS.md` still report failure; resolved?

## Working rules

Own routine decisions; "continue" suffices. Ask for resources, consequential
ambiguity or hardware observations. Elle runs Quartus builds and long scripts.
