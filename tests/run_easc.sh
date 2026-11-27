#!/bin/sh
# Directed bench for rtl/easc.sv (Verilator 5).
#   tests/run_easc.sh                 registers, FIFO, interrupt, CD-XA decoder
#   CHIME=bytes.hex CHIMEOUT=out.txt tests/run_easc.sh
#                                     also plays that compressed sound the way
#                                     the ROM does and writes the left output
set -eu
cd "$(dirname "$0")/.."
mkdir -p local/tests
obj=local/tests/obj_easc
verilator --binary --timing -j ${JOBS:-2} -Wno-fatal -DSIMULATION     --top-module tb_easc --Mdir "$obj"     rtl/easc.sv rtl/rate_enable.sv tests/tb_easc.sv     >local/tests/easc-build.log 2>&1 || { tail -n 30 local/tests/easc-build.log; exit 1; }
args=
if [ -n "${CHIME:-}" ]; then args="+CHIME=$CHIME +CHIMEOUT=${CHIMEOUT:-local/tests/easc-chime.txt}"; fi
"$obj/Vtb_easc" $args >local/tests/easc-run.log 2>&1 || { tail -n 30 local/tests/easc-run.log; exit 1; }
grep -E '^(PASS|FAIL|CHIME)' local/tests/easc-run.log
grep -q '^PASS:' local/tests/easc-run.log
