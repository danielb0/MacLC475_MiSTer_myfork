# SWIM II write trace

Known failure: System 7.5.3 Revision 2 Install 01 booted, then became
unbootable (Happy Mac, reset) during folder creation/eject/remount testing.
The exact failing step and deployed RBF/Main hashes were not recorded.
Both images were already supplied and compared; do not request them again.

- Clean: `D:/MiSTer/Macintosh/Mac OS/Apple SSW and Mac OS/7/Apple Mac OS 7.5.3 Revision 2 (3.5-1.44mb)/Install 01.img`
  SHA-256: `c290f3d285f7da06561e43ec09861b678d2fc717d8bf73a73ccc650be1636aa4`.
- Damaged: `C:/Workspace/Git/MacQuadra605_MiSTer/local/Install 01-bad.img`
  SHA-256: `ee4710ec5608e2e65a575fc181bc0cd5ebf694937eb8fca752bdbac720d534e8`.

Only LBAs 2, 26 and 28 differ (250 bytes). The damaged catalog references
leaf node 4 at LBA 30, which remains zero. This proves an incomplete catalog
update, not where or when the write was lost. The remaining evidence is a
hardware trace through decode, RAM commit and host save on disposable media.

On a diagnostic branch, add `SWIM2_TRACE=1` and `rtl/swim2_trace.sv` to
the existing `MacLC475.qsf` assignments. Build `MacLC475.qpf`; output stays
in `output_files/`. Do not add another project.
This diagnostic project replaces the HPS modem UART output with a passive trace.
Normal projects retain guest serial output and omit the tracer. Stock sys is unchanged.
Check the diagnostic fit/timing before loading it; no fitted result is established.

Use disposable floppy copies. Preserve the clean/damaged installer images.
Record the RBF, Main and input-image hashes with the capture. On MiSTer:

```sh
stty -F /dev/ttyS1 115200 raw -echo -ixon -ixoff cs8 -cstopb -parenb
cat /dev/ttyS1 > /media/fat/swim2-trace.txt
```

Start capture before mounting the disposable image, repeat the failing action,
then stop capture. Decode the copied file with:

```text
python scripts/decode_swim2_trace.py swim2-trace.txt
```

Each `W` line holds one atomic snapshot: 16 event bits, 32 clock bits, 32 context
bits, 22 decode-address bits, 22 commit-address bits, 32 host-LBA bits, 16 dropped
event counts, 8 error bits, 8 status bits and version nibble 1, most significant
first. Simultaneous events share a record. Byte addresses are image-relative.

Context: mode, setup, track[6:0], head, anchor[4:0], anchor-valid, buffer-owned,
stream-enabled. Status bits 7..0: loaded, host-release, read-fault, write-fault,
storage-fault, HD, host-write-request, host-transfer-ack. Error is the guest's
nonzero error-register read; a fault edge can precede that read with error zero.
Storage fault includes loader/memory faults. Save retirement proves that the
core accepted the host's successful result; it does not independently verify disk data.

The 128-record queue never stalls the machine. Overflow saturates its counter
at 65535; one-second heartbeats report loss even after events stop. Missing or
malformed records make absence inconclusive. The decoder returns failure for
loss/malformed data. Timestamps wrap every 2^32 machine clocks and restart only
on global abort, not guest reset. The trace contains no payload or image identity.
