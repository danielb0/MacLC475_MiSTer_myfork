# CPU donor tracker

Status: small33 imported on `codex/small33-lc040`; qualification pending.
Updated: 2026-11-01.

## Intent

Find a stable LC040 donor target with maximum practical resource headroom
at 25 MHz. The computer mostly works, but CPU integration remains bring-up
work. Our imported revision is behind upstream, and the optimal Q605
configuration has not been established.

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
- [ ] Compare matched features/seed/source: occupied LABs, ALMs, M10Ks,
  registers and timing. Confirm guest behavior before accepting a donor.

Until then, retain the current LC040 implementation as
the reference. Use a branch for the import; keep one MacLC475 project.

## Handoff

Directed bus (489), LC040 decode/trap (1393) and frame microcode (8) checks
pass. CPU, LC040, machine and MMU Verilator elaboration passes; no FPU is
elaborated. Quartus 17.0.2 Analysis & Elaboration: 0 errors, 195 warnings.
ModelSim 10.5b cannot compile the full donor; use Verilator for execution.

Elle runs `wsl.exe --exec sh tests/run_cpu040.sh MODE` for each of `smoke`,
`lc040`, `machine` and `mmu`, then one full `MacLC475` fit if all pass.
Compare the reference and candidate with the same seed (38) and features.
The donor defaults enable DUAL and BTIC; those remain a separate comparison,
not the initial fitting target. No CPU execution or hardware acceptance is
claimed for this import. Existing LC040 register-file probes remain confined
to the CPU-specific test; machine logic and bus adapter are unchanged.
