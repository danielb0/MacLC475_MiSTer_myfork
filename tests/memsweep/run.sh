#!/bin/sh
# Random memory-operand programs on cpu040, checked against a model's memory image.
#
#   sh tests/memsweep/run.sh [first seed] [last seed]      (from WSL; default 1 20)
#
# OPS=n (default 1500) operations a program.  Each seed runs in three
# modes (write-through, copyback, paged MMU), with the store buffer on and off and a
# bus speed taken from the seed.  A line per run goes to local/tests/memsweep/
# results.txt as it ends; the exit status is the number of failures.
set -u
cd "$(dirname "$0")/../.."
out=local/tests/memsweep
mkdir -p "$out"
sources=$(sed -n 's/.*-name \(SYSTEMVERILOG\|VERILOG\)_FILE .*"\([^"]*\)".*/rtl\/ap68040_faster\/rtl\/\2/p' rtl/ap68040_faster/rtl/ap68040.qip)
newer=$(find rtl tests/memsweep/tb_memsweep.sv -newer "$out/obj/Vtb_memsweep" 2>/dev/null | head -n 1)
if [ ! -x "$out/obj/Vtb_memsweep" ] || [ -n "$newer" ]; then
    verilator --binary --timing -j "${JOBS:-4}" -Wno-fatal --top-module tb_memsweep -DCPU_AP68040 \
        --Mdir "$out/obj" -Irtl -Irtl/ap68040_faster/rtl -Irtl/ap68040_faster/rtl/fpu \
        $sources rtl/bus040.sv rtl/wombat_store_buffer.sv rtl/perf_counters.sv rtl/cpu040.sv \
        tests/memsweep/tb_memsweep.sv > "$out/build.log" 2>&1 || { tail -n 40 "$out/build.log"; exit 99; }
fi
cd "$out"
fails=0
for seed in $(seq "${1:-1}" "${2:-20}"); do
    for mode in wt cb mm; do
        python3 ../../../tests/memsweep/gen.py "$seed" "$mode" "${OPS:-1500}" > gen.log || exit 98
        case $((seed % 4)) in
            0) bus="+WAITS=0 +BWAITS=0" ;;
            1) bus="+WAITS=2 +BWAITS=1" ;;
            2) bus="+JIT=3" ;;
            3) bus="+WAITS=1 +JIT=2" ;;
        esac
        for sb in 1 0; do
            ./obj/Vtb_memsweep +SB=$sb $bus > run.log 2>&1
            res=$(grep -E "^(PASS|FAIL)" run.log | head -n 1)
            dmu=$(grep -c "FAIL: DMU" run.log)
            [ -n "$res" ] || res="FAIL no result"
            [ "$dmu" = 0 ] || res="FAIL (DMU check) $res"
            echo "seed $seed $mode sb=$sb $bus: $res" | tee -a results.txt
            case "$res" in PASS*) ;; *) fails=$((fails + 1)); cp run.log "fail_${seed}_${mode}_${sb}.log"; cp prog.hex "fail_${seed}_${mode}_${sb}.prog.hex" ;; esac
        done
    done
done
echo "failures: $fails"
exit $fails
