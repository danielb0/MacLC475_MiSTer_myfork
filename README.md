# Mac LC 475 / Quadra 605 for MiSTer

A MiSTer FPGA implementation of the Macintosh LC 475 / Quadra 605, with a 25 MHz 68040LC (no FPU).

## Setup

- Build `MacLC475.qpf` with Quartus 17.0.2, or use a compatible `.rbf` build.
- Install the core in MiSTer's computer cores folder.
- Supply your own Macintosh ROM. Look for LC 475 / Quadra 605 ROM dumps
  (often named `Macintosh LC 475 ROM` or `Quadra 605 ROM`); verify the
  `FF7439EE` ROM checksum. MiSTer expects it at
  `games/MacLC475/boot0.rom`.
- Convert the raw 4,352-byte CUDA ROM binary with
  `python scripts/cuda_bin_to_hex.py`. It looks for `cuda341s0788.bin` in the
  current directory and writes `local/software/cuda341s0788.hex`; input and
  output paths can also be supplied. ROM and firmware files are not included.
- Select disk images from the core's OSD. Existing MacQuadra605 disk and
  PRAM files can be reused; preserve backups when moving or changing mounts.

## Status

Development candidate, not release-ready. Mac OS 7.5.3 installation from CD-ROM and 7.5.5 update from 1.44 MB floppy are confirmed working. Floppy write is wired up but untested.
