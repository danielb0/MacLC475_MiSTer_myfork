# Current direction

Updated 2026-11-02.

- One builder: `MacLC475.qpf`. Use branches for experiments, including trace
  captures. Preserve stock sys; project adaptations belong outside it.
- Imported from `MacQuadra605_MiSTer` commit `7a66351` (final-quadra-check).
  Active SWIM2 configuration, pipelined LC040, 25/75 MHz clocks, seed 38,
  4 KiB caches, no FPU, Ethernet/MT32-pi off and scaler startup guard retained.
  Old CPU, alternate projects, reports, binaries and investigation archives
  remain in the original repository. This is the reference on `main`.
- Keep the accepted compacted BRAM VRAM (320 KB physical, 512 KB advertised).
  Full 512 KB VRAM is a later option via the Q800 DDR3-VRAM branch
  (`6f72684`); keep VRAM behind the memsel beat port and DAFB fetch port so
  a DDR3 backend can replace the BRAM block without machine changes.
  DDR3 already serves ROM fills; scanout would need a prefetch buffer.
- CPU refresh complete on `codex/small33-lc040`: latest Q800 small33 CPU with
  local LC040 decoding, format-4/RTE and scalar DMU adaptation. DUAL=0,
  BTIC=0; no FPU, 4 KiB caches and machine bus contracts retained. See
  `CPU_DONOR.md`. CPU execution results remain unrecorded.
- Performance is the next major concern; establish a measured baseline first.
- Elle confirmed Mac OS 7.5 CD-ROM installation to SCSI ID 0 HDD (7.5.3),
  then the 7.5.5 SuperDrive update with three floppy swaps. Repeated reboots
  and memory configuration changes work; the HDD installation persists.
  This does not close floppy write acceptance. Floppy catalog corruption
  remains unresolved and write acceptance is paused. Existing
  catalog regressions do not reproduce the corruption. Capture the failing
  guest sequence on disposable copies before guessing at RTL fixes. The
  supplied clean/damaged images and failure details are in `SWIM2_TRACE.md`.
- Performance remains untested. Remaining qualification includes
  MEMCjr/PrimeTime timing, SWIM II register behavior, audio,
  serial/MIDI, PRAM persistence and supported display/depth combinations.
- OSD follows Dani's computer-core layout: media/Load ROM and Memory at root,
  fixed page numbers, empty pages omitted, PRAM/retry under Advanced. Existing
  mount slots and status bits remain; memory and monitor changes show pending
  until reset. Aspect ratio and Scale apply live. Diagnostics require
  `MACLC475_DEBUG` and live on P9.
- Own routine decisions and batch coherent implementation. "Continue" is
  sufficient direction. Research/tests must unblock a concrete milestone.
  Ask for missing resources, consequential ambiguity or hardware observations.
  Elle runs full Quartus builds and long scripts. Do not create new chats
  unless asked. Keep documentation short and current.

Candidate verification:

- Quartus 17.0.2 Analysis & Elaboration passes: zero errors, 195 warnings.
- 96 preserved imports verify; 124 imported files present. Stock sys matches
  the reference. Directed bus/decode/trap/microcode checks and CPU/machine/MMU
  elaboration pass; LC040 elaborates without an FPU. CPU execution results
  remain unrecorded.
- Local Quartus fit report dated 2026-11-01: successful; 31,370/41,910 ALMs
  (75%), 505/553 RAM blocks (91%), 3,753,532/5,662,720 memory bits (66%),
  29,268 registers and 36/112 DSP blocks (32%). Timing summary reports
  positive slack for all listed checks; minimum setup 0.612 ns, hold 0.231 ns.
  A matched reference comparison remains pending.
