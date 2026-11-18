#!/usr/bin/env python3
# perflog.py -- runs ON the MiSTer (python3, stdlib only).  Samples the perf
# counter snapshot that a MACLC475_DEBUG core writes to DDR3 (MacLC475.sv,
# DDR_PERF_BASE) and prints one CSV row per sample to stdout:
#
#   t,seq,c0,...,c41
#
# t is the MiSTer's wall clock (seconds), seq the core's snapshot number
# (one per 2^18 clocks), c0-c41 the raw 32-bit counters (they wrap; the
# report takes differences modulo 2^32).  Run it from the PC so the CSV lands
# there and nothing has to be copied to the MiSTer:
#
#   ssh mister-bedroom python3 -u - < scripts/perflog.py > capture.csv
#
# Optional arguments: the sample interval in seconds (default 1.0), then a
# run time in seconds (default: until stopped).  Stop with Ctrl-C or by
# killing the ssh; it also exits when its ssh session goes away.  From
# PowerShell, scripts/perflog.ps1 does all of this.  scripts/perf_report.py
# reads the CSV.

import mmap
import os
import struct
import sys
import time

PHYS = 0x27F00000
MAGIC = 0x50455246
WORDS = 23                    # 64-bit words: header, 21 counter pairs, trailer
N = 42

interval = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0

fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
mem = mmap.mmap(fd, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=PHYS)


def snapshot():
    """One whole snapshot as (seq, counters), or None if none is valid."""
    for _ in range(50):
        w = struct.unpack_from("<%dI" % (WORDS * 2), mem, 0)
        magic, seq = w[0], w[1]
        tmagic, tseq = w[-2], w[-1]
        if magic != MAGIC or tmagic != (~MAGIC & 0xFFFFFFFF):
            return None
        if seq == tseq:
            return seq, w[2:2 + N]
        time.sleep(0.0005)    # caught the core mid-copy: try again
    return None


print("t,seq," + ",".join("c%d" % i for i in range(N)), flush=True)
last_seq = None
stale = 0
next_t = time.time()
end_t = next_t + duration if duration > 0 else None
try:
    while end_t is None or time.time() <= end_t:
        if os.getppid() == 1:     # the ssh session is gone
            break
        s = snapshot()
        now = time.time()
        if s is None:
            print("perflog: no snapshot at 0x%08X (not a debug core with "
                  "the DDR3 export?)" % PHYS, file=sys.stderr, flush=True)
        else:
            seq, c = s
            if seq == last_seq:
                stale += 1
                if stale == 3:
                    print("perflog: snapshot not advancing (core stopped?)",
                          file=sys.stderr, flush=True)
            else:
                stale = 0
            last_seq = seq
            print("%.3f,%d," % (now, seq) + ",".join(map(str, c)), flush=True)
        next_t += interval
        time.sleep(max(0.0, next_t - time.time()))
except (KeyboardInterrupt, BrokenPipeError, OSError):
    pass
