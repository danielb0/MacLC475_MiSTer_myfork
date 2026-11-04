# MacLC475

MiSTer Macintosh LC 475 / Quadra 605: 25 MHz LC040, no FPU, 4 KiB caches,
MEMCjr, CUDA, SCSI and one internal SWIM II SuperDrive.

Open `MacLC475.qpf` in Quartus 17.0.2. This is the only build project.
Output: `output_files/MacLC475.rbf`. Use branches for experiments.

The required CUDA firmware is `local/software/cuda341s0788.hex`; the initial
local import includes it. Firmware and generated files remain untracked.
On MiSTer, put the native FF7439EE ROM at `games/MacLC475/boot0.rom`.
Copy existing games/config data from MacQuadra605 and reselect saved mounts
when their paths change. Preserve original disk and PRAM files.

The OSD follows [Dani's computer-core layout](https://github.com/danifunker/hp9000-715_MiSTer/blob/master/docs/osd-standard.md).
Media, Load ROM and Memory are at root; Video is P2 and Advanced is P5.
Memory and video changes wait for Apply and reset. PRAM and floppy retry
are under Advanced. `MACLC475_DEBUG` adds diagnostics on P9.

Main needs both patches in `patches/` for MacLC475 SCSI and floppy services.
`scripts/build_main_q605.sh` builds a patched checkout at `local/Main_MiSTer`;
that host checkout/toolchain is not part of this FPGA source import.
The existing host checkout remains in the original MacQuadra605 repository.

Short checks: `scripts/check_imports.ps1` and `tests/run_cpu040.ps1`.
CPU execution: `wsl.exe --exec sh tests/run_cpu040.sh lc040` (also smoke,
machine and mmu). Elle runs longer checks and full Quartus builds.

Mac OS 7.5 CD-ROM installation to SCSI HDD (7.5.3), the 7.5.5 SuperDrive
update with three floppy swaps, repeated reboots and memory configuration
changes are confirmed. Floppy write corruption remains unresolved; use
disposable floppy copies. V-Integer is reported not working; cause unknown.
Performance and broader compatibility remain unqualified. See
`docs/CURRENT_DIRECTION.md` and `docs/CPU_DONOR.md` for status and next work.
See [release readiness](docs/RELEASE_READINESS.md) for the status assessment
and release-candidate checklist.
