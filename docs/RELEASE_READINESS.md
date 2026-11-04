# Project status and release readiness

Assessed 2026-11-03 at `b041016` on `codex/small33-lc040`.

## Status

Working development candidate; not yet release-ready.

- Mac OS 7.5.3 installs from CD-ROM to SCSI HDD and updates to 7.5.5
  through three floppy swaps. Reboots, memory changes and HDD persistence
  are confirmed by guest testing.
- The small33 LC040 candidate fits: 75% ALMs, 91% RAM blocks; the November 1
  timing summary reports positive slack. CPU acceptance and a matched
  resource comparison with the reference remain pending.
- Directed bus/decode/microcode checks and CPU/machine/MMU elaboration are
  recorded as passing. CPU execution results remain unrecorded.
- Floppy catalog corruption is unresolved. Existing regressions do not
  reproduce it; successful installation does not establish safe writes.
- V-Integer fails with insufficient failure detail. Performance, broader
  compatibility and several machine subsystems remain unqualified.
- One build project and the revised OSD are in place. Deployment requires
  patched Main, CUDA firmware and a user-supplied Macintosh ROM.

This review rechecked the local fit/timing summaries and verified 96 preserved
imports with all 124 imported files present. It did not rerun simulations,
build Quartus or perform hardware testing. Detailed evidence remains in
[current direction](CURRENT_DIRECTION.md), [CPU donor](CPU_DONOR.md) and
[SWIM II trace](SWIM2_TRACE.md).

## Roadmap and release-candidate checklist

Work toward a reproducible, data-safe machine before expanding features.
Keep 25/75 MHz clocks, 4 KiB caches, no FPU and compacted BRAM VRAM fixed.
Preserve stock sys; keep CPU optimization and faithful VRAM outside this scope.
The following gates are proposed release criteria, not completed validation.

### 1. Establish correctness

- [ ] Capture the failing floppy sequence on disposable copies, recording
  RBF, Main and image hashes. Trace decode, RAM commit and host save to
  locate the incomplete catalog update before changing RTL.
  Preparation: `scripts/prepare_swim2_capture.ps1`; see `SWIM2_TRACE.md`.
- [ ] Fix the demonstrated cause and add a regression that reproduces it.
  Verify guest writes, eject/remount and reboot persistence against saved
  image contents. Close catalog corruption before declaring writes supported.
- [ ] Record passing `smoke`, `lc040`, `machine` and `mmu` execution results,
  alongside the directed checks and confirmation that no FPU is elaborated.
- [ ] Record V-Integer version, exact symptom and reproduction steps;
  resolve the fault or establish a supported, evidence-backed limitation.
- [ ] Compare reference and candidate with matched features and seed 38:
  LABs, ALMs, RAM blocks, registers and timing. Decide donor acceptance from
  correctness, guest compatibility and measured resource use.

### 2. Qualify the supported machine

- [ ] Define the supported OS, memory, display/depth and media combinations;
  record pass/fail results against identified RBF and Main builds.
- [ ] Qualify MEMCjr/PrimeTime timing and SWIM II register behavior, including
  reset values and parameter readback.
- [ ] Exercise SCSI and floppy reads/writes, swaps, write protection and
  error recovery. Rerun relevant host and RTL storage regressions.
- [ ] Verify audio, serial/MIDI, PRAM persistence, supported video modes,
  startup behavior, OSD pending settings and apply/reset behavior.
- [ ] Align the OSD with the latest PPC core: page layout, labels, ordering
  and navigation for applicable controls. Record the PPC source revision
  used for comparison and verify the resulting menus on hardware.
  Source comparison complete against local PPC `0d553b9cd6414a8ce4bc6b389e1d9782f3851234`:
  shared controls and page order match; monitor labels aligned. Empty pages
  stay omitted. Hardware menu verification remains pending.
- [ ] Repeat installation, cold boots, resets and representative sustained
  application use. Record performance against a stated reference; distinguish
  compatibility failures from expected LC040/no-FPU limitations.

### 3. Freeze and package a candidate

- [ ] Build the selected source revision with Quartus 17.0.2; review warnings,
  timing constraints and final fit/timing. Elle runs full builds and long tests.
- [ ] Confirm sys matches the intended upstream revision and recheck imports.
- [ ] Verify a fresh setup using the documented firmware/ROM prerequisites,
  both Main patches, media paths and migration instructions. Identify the
  source revision and build procedure for the distributed Main binary.
- [ ] Package the RBF and compatible Main with source revisions, hashes,
  setup instructions, required notices and concise known limitations.
- [ ] Retest the packaged artifacts on hardware. Tag an RC only after the
  gates pass, with no unexplained data corruption or blocking failures in
  the declared support matrix. Track deferred features explicitly.

The immediate next milestone is a reproducible floppy failure capture and
recorded CPU execution results. Release candidacy follows qualification;
another successful fit alone does not establish it.
