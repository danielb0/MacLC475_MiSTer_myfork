# Current direction

Updated 2026-11-01.

- One builder: `MacLC475.qpf`. Use branches for experiments, including trace
  captures. Preserve stock sys; project adaptations belong outside it.
- Imported from `MacQuadra605_MiSTer` commit `7a66351` (final-quadra-check).
  Active SWIM2 configuration, pipelined LC040, 25/75 MHz clocks, seed 38,
  4 KiB caches, no FPU, Ethernet/MT32-pi off and scaler startup guard retained.
  Old CPU, alternate projects, reports, binaries and investigation archives
  remain in the original repository. This is the reference on `main`.
- Keep the accepted compacted BRAM VRAM. Faithful VRAM is a separate project.
  Do not change clocks or memory architecture during the CPU refresh.
- Candidate on `codex/small33-lc040`: pinned small33 CPU imported with local
  LC040 decoding, format-4/RTE and scalar DMU adaptation. DUAL=0, BTIC=0;
  no FPU, 4 KiB caches and machine bus contracts retained. See `CPU_DONOR.md`.
  Elle runs CPU execution checks before fitting and guest testing. Do not
  accept this donor or begin an independent CPU optimization campaign yet.
- Machine milestone: OEM floppy installation onto blank SCSI, disk swaps,
  eject, persisted writes and boot from the installed disk. Floppy catalog
  corruption remains unresolved and write acceptance is paused. Existing
  catalog regressions do not reproduce the corruption. Capture the failing
  guest sequence on disposable copies before guessing at RTL fixes. The
  supplied clean/damaged images and failure details are in `SWIM2_TRACE.md`.
- OSD follows Dani's computer-core layout: media/Load ROM and Memory at root,
  fixed page numbers, empty pages omitted, PRAM/retry under Advanced. Existing
  mount slots and status bits remain; memory and video changes show pending
  until reset. Diagnostics require `MACLC475_DEBUG` and live on P9.
- Own routine decisions and batch coherent implementation. "Continue" is
  sufficient direction. Research/tests must unblock a concrete milestone.
  Ask for missing resources, consequential ambiguity or hardware observations.
  Elle runs full Quartus builds and long scripts. Do not create new chats
  unless asked. Keep documentation short and current.

Candidate verification, 2026-11-01:

- Quartus 17.0.2 Analysis & Elaboration passes: zero errors, 195 warnings.
- 96 preserved imports verify; 124 imported files present. Stock sys matches
  the reference. Directed bus/decode/trap/microcode checks and CPU/machine/MMU
  elaboration pass; LC040 elaborates without an FPU. CPU execution, full fit
  and guest acceptance remain pending. Changes are uncommitted on the branch.
