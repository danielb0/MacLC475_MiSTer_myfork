# CPU donor tracker

Status: small33 fits and runs Mac OS 7.5.5 on `codex/small33-lc040`;
qualification pending.
Updated: 2026-11-02.

## Intent

Find a stable LC040 donor target with maximum practical resource headroom
at 25 MHz. Installation and reboot work; CPU correctness, compatibility and
the optimal Q605 configuration remain under qualification.

Q605 owns machine integration and qualification. CPU optimization belongs
to the upstream team. Preserve the working CPU while qualifying a replacement.

The immediate priority is to avoid new coupling to this CPU implementation.
Keep machine logic and integration tests tied to bus contracts and LC040
behavior, rather than internal pipeline states, hierarchy or fixed response
latencies. Confine unavoidable implementation details to the existing CPU
adapter or CPU-specific tests. Flag such dependencies during review; do not
invent a new abstraction or refactor working paths without a concrete need.
Expect a future donor replacement, rather than tracking every optimization.

## Targets

- Reference on `main`: Alan's `pipelined-040-66mhz-timing` at
  `eefa4aa8df9b57ee19791a14be2f728243d50fca`, with local LC040 adaptations.
  Optional predictor/timing features are already disabled.
- Candidate: Alan recommends `pipelined-040-small33` for size/headroom.
  Audited tip: `82122463f51cc22d61164aa343178188cb225953`, 38 commits beyond
  our donor. It includes dual issue, BTIC and later FPU work. This is an
  imported candidate, not an accepted replacement or proven resource win.
- Source: <https://github.com/alanswx/MacQuadra800_MiSTer/tree/pipelined-040-small33>.
- Live MiSTer-devel branch tips checked 2026-11-01: small33 remains
  `82122463f51cc22d61164aa343178188cb225953`; DDR3-VRAM is
  `6f7268457e6888ffadae7e7de7a2dc89521e5031`. Prefer the recommended
  size candidate first. A CPU import does not require importing DDR3 VRAM.

## Lean DDR3 experiment (`exp/lean-ddr3-vram`, 2026-11-07)

- Donor: Alan's `dual-memory-ddr3-lean` at `b370a056ca5ddde770c9dd6dae57938c27265d44` (newest Q800 branch, 2026-11-05; MiSTer-devel's `pipelined-040-ddr3-vram` is older). CPU three-way merged over small33; local LC040 adaptations kept (HAS_FPU, `entry_point`, no-FPU tie-offs). Still DUAL=0, BTIC=0, no FPU, 4 KiB caches, 25 MHz 1:1; lean's 54/27/81 MHz clocking, SYS_HZ and pixel-clock retarget check are not taken.
- Wrapper: lean's two-entry posted-store queue (`rtl/wombat_store_buffer.sv`) between `bus040` and the machine, qualified by `store_buffer_ok && lock_n`; `AP040_STORE_BUFFER_OFF=1` removes it.
- VRAM: `rtl/vram_ddr3.sv` (1 MB in DDR3, scanline DMA, includes the DMA-take race fix `3b1761d`) replaces the 320 KB BRAM VRAM; `VRAM_BRAM=1` restores it. DAFB takes lean's line handshake, 16/24 bpp direct colour and 2-bit monitor select (LC 475 still offers 13"/12" only). 16 bpp detection uses lean's AC842a PCBR1 rule on our Antelope PCBR1; unverified.
- ROM: lean's 128 KB on-chip ROM cache (`rtl/rom_cache_128k.sv`); `ROM_CACHE_OFF=1` removes it.
- Checks 2026-11-07: Verilator lint, smoke, lc040 (90), machine (2 runs), mmu (30) PASS; no FPU elaborated; Quartus A&E 0 errors, 194 warnings; imports verify. Fit, timing and hardware not yet run.

## Next checkpoints

- [x] Review ongoing integration work for new CPU-specific assumptions;
  preserve the ability to replace the donor without rewriting machine logic.
- [x] Import the pinned small33 CPU as an isolated candidate; review supplied
  size settings and known limits during adaptation.
- [x] Reconcile donor changes with local no-FPU decoding, format-4/RTE,
  exception/store fixes, generated microcode and DMU adaptation.
- [x] Prepare an isolated experiment with `DUAL=0`, `BTIC=0`; preserve 4 KiB
  caches, machine interfaces, 25/75 MHz clocks, scaler startup guard and sys.
- [ ] Pass existing CPU, LC040, bus, machine and MMU checks; verify no FPU
  is elaborated. Elle runs longer execution builds and full Quartus fits.
- [x] Complete a full Quartus fit and guest installation through Mac OS 7.5.5,
  including update floppy swaps, repeated reboots and memory changes.
- [ ] Compare matched features/seed/source: occupied LABs, ALMs, M10Ks,
  registers and timing. Confirm guest behavior before accepting a donor.

Until then, retain the current LC040 implementation as
the reference. Use a branch for the import; keep one MacLC475 project.

## Handoff

Directed bus (489), LC040 decode/trap (1393) and frame microcode (8) checks
pass. CPU, LC040, machine and MMU Verilator elaboration passes; no FPU is
elaborated. Quartus 17.0.2 Analysis & Elaboration: 0 errors, 195 warnings.
ModelSim 10.5b cannot compile the full donor; use Verilator for execution.

CPU execution results remain unrecorded. Elle runs
`wsl.exe --exec sh tests/run_cpu040.sh MODE` for each of `smoke`, `lc040`,
`machine` and `mmu`.
Compare the reference and candidate with the same seed (38) and features.
The donor defaults enable DUAL and BTIC; those remain a separate comparison,
not the initial fitting target. The local 2026-11-01 fit uses 31,370 ALMs
(75%) and 505 RAM blocks (91%); the timing summary has positive slack for
all listed checks. No matched resource win or final donor acceptance is claimed.

Elle confirmed CD-ROM installation to SCSI ID 0 HDD (7.5.3), the 7.5.5
SuperDrive update with three floppy swaps, repeated reboots and memory
configuration changes. V-Integer did not work; version, exact symptom and
cause remain unrecorded. Performance is untested. Floppy write corruption
remains open; successful installation does not close that acceptance gate.
Existing LC040 register-file probes remain confined to the CPU-specific test;
machine logic and bus adapter are unchanged.
