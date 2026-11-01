# Current direction

Updated 2026-11-01.

- One builder: `MacLC475.qpf`. Use branches for experiments, including trace
  captures. Preserve stock sys; project adaptations belong outside it.
- Imported from `MacQuadra605_MiSTer` commit `7a66351` (final-quadra-check).
  Active SWIM2 configuration, pipelined LC040, 25/75 MHz clocks, seed 38,
  4 KiB caches, no FPU, Ethernet/MT32-pi off and scaler startup guard retained.
  Old CPU, alternate projects, reports, binaries and investigation archives
  remain in the original repository. No new CPU donor has been imported yet.
- Keep the accepted compacted BRAM VRAM. Faithful VRAM is a separate project.
  Do not change clocks or memory architecture during the CPU refresh.
- Next: import pinned small33 CPU on a branch, preserving local LC040
  decoding, format-4/RTE and machine bus contracts. See `CPU_DONOR.md`.
  Pass CPU/bus/LC040/machine/MMU checks, then hand off one build for fitting
  and guest testing. Do not begin an independent CPU optimization campaign.
- Machine milestone: OEM floppy installation onto blank SCSI, disk swaps,
  eject, persisted writes and boot from the installed disk. Floppy catalog
  corruption remains unresolved and write acceptance is paused. Existing
  catalog regressions do not reproduce the corruption. Capture the failing
  guest sequence on disposable copies before guessing at RTL fixes.
- Own routine decisions and batch coherent implementation. "Continue" is
  sufficient direction. Research/tests must unblock a concrete milestone.
  Ask for missing resources, consequential ambiguity or hardware observations.
  Elle runs full Quartus builds and long scripts. Do not create new chats
  unless asked. Keep documentation short and current.

Import verification, 2026-11-01:

- Quartus 17.0.2 Analysis & Elaboration passes: zero errors, 192 warnings.
- 96 preserved imports verify; 124 imported files present. Stock sys matches
  the source byte-for-byte. No full build, fit or new hardware acceptance.
- Repository initialized on main; imported files are uncommitted.
