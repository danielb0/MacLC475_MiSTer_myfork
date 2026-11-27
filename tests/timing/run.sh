#!/bin/sh
# Clocks per instruction of cpu040 against the MC68040 User's Manual, section 10.
#
#   sh tests/timing/run.sh [plusargs]         (from WSL; needs verilator and python3)
#
# plusargs: +PROG=prog_cb.hex|prog_wt.hex  copyback (default) or write-through
#           +SB=1          store_buffer_ok high (posted RAM stores, as the machine)
#           +WAITS=n       extra clocks before the first acknowledge of a transfer
#           +BWAITS=n      extra clocks before each later beat of a line
#           +TRACE=n       per-clock pipeline trace of test n (0-based line of tests.txt)
#           +TPASS=p +TMAX=lines   (the trace follows the second, timed run of the test)
# SUITE=n (environment): 1 the first set, 2 the rest of the tables, 3 the instruction supply, 4 the sweep
#           (instruction length, branches, calls and returns)
# PASSES=n (environment) sets how often the whole program runs; the last pass is reported.
# Output: RESULT lines "warm clocks|units|UM clocks per unit|first-pass clocks|name",
# all under local/tests/timing (ignored by git).
set -eu
cd "$(dirname "$0")/../.."
out=local/tests/timing
mkdir -p "$out"
sources=$(sed -n 's/.*-name \(SYSTEMVERILOG\|VERILOG\)_FILE .*"\([^"]*\)".*/rtl\/ap68040_faster\/rtl\/\2/p' rtl/ap68040_faster/rtl/ap68040.qip)
newer=$(find rtl tests/timing/tb_timing.sv -newer "$out/obj/Vtb_timing" 2>/dev/null | head -n 1)
if [ ! -x "$out/obj/Vtb_timing" ] || [ -n "$newer" ]; then
    verilator --binary --timing -j "${JOBS:-4}" -Wno-fatal --top-module tb_timing -DCPU_AP68040 \
        --Mdir "$out/obj" -Irtl -Irtl/ap68040_faster/rtl -Irtl/ap68040_faster/rtl/fpu \
        $sources rtl/bus040.sv rtl/wombat_store_buffer.sv rtl/perf_counters.sv rtl/cpu040.sv \
        tests/timing/tb_timing.sv > "$out/build.log" 2>&1 || { tail -n 40 "$out/build.log"; exit 1; }
fi
cd "$out"
python3 ../../../tests/timing/gen.py > gen.log
./obj/Vtb_timing "$@" > run.log 2>&1 || true
grep -E "^(RESULT|T |TIMEOUT|HALTED)" run.log
