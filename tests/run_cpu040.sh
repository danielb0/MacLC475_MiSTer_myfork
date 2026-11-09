#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p local/tests
sources=$(sed -n 's/.*-name \(SYSTEMVERILOG\|VERILOG\)_FILE .*"\([^"]*\)".*/rtl\/ap68040_faster\/rtl\/\2/p' rtl/ap68040_faster/rtl/ap68040.qip)
case "${1:-lint}" in
    lint|machine-lint|profile-lint|mmu-lint) mode="--lint-only" ;;
    smoke|lc040|machine|machine-ddr3|profile|profile-ddr3|mmu) mode="--binary --timing -j ${JOBS:-2}" ;;
    *) echo "Usage: $0 [lint|smoke|lc040|machine|machine-ddr3|machine-lint|profile|profile-ddr3|profile-lint|mmu|mmu-lint]" >&2; exit 1 ;;
esac
top=tb_quadra_cpu040
bench=tests/tb_quadra_cpu040.sv
if [ "${1:-lint}" = lc040 ]; then top=tb_lc040; bench=tests/tb_lc040.sv; fi
if [ "${1:-lint}" = mmu ] || [ "${1:-lint}" = mmu-lint ]; then
    top=tb_cpu040_mmu
    bench=tests/tb_cpu040_mmu.sv
fi
if [ "${1:-lint}" = machine ] || [ "${1:-lint}" = machine-lint ] ||
   [ "${1:-lint}" = profile ] || [ "${1:-lint}" = profile-lint ] ||
   [ "${1:-lint}" = profile-ddr3 ] || [ "${1:-lint}" = machine-ddr3 ]; then
    top=tb_cpu040_machine
    bench=tests/tb_cpu040_machine.sv
    sources="$sources $(sed -n 's/^set_global_assignment -name \(SYSTEMVERILOG\|VERILOG\)_FILE \(rtl\/[^ ]*\)$/\2/p' files.qip | sed '/\/pll/d; /\/quadra_cpu040.sv/d; /\/quadra_bus040.sv/d; /\/wombat_store_buffer.sv/d') tests/support/altsyncram_stub.v"
fi
# profile-ddr3: the same fixture with rtl/vram_ddr3.sv behind a DDR3 model
defs=-DCPU_AP68040
obj="local/tests/obj_cpu040_$top"
if [ "${1:-lint}" = profile-ddr3 ] || [ "${1:-lint}" = machine-ddr3 ]; then
    defs="$defs -DVRAM_DDR3"
    obj="${obj}_ddr3"
fi
verilator $mode --timing -Wno-fatal --top-module "$top" $defs \
    --Mdir "$obj" -Irtl -Irtl/ap68040_faster/rtl \
    -Irtl/ap68040_faster/rtl/fpu $sources rtl/quadra_bus040.sv \
    rtl/wombat_store_buffer.sv rtl/quadra_cpu040.sv "$bench" \
    >"local/tests/cpu040-$top-build.log" 2>&1 || {
        tail -n 30 "local/tests/cpu040-$top-build.log"; exit 1;
    }
if [ "${1:-lint}" = machine-lint ] || [ "${1:-lint}" = profile-lint ]; then
    echo 'PASS: staged CPU and MEMCjr machine fixture lint/elaborate'
    exit 0
fi
if [ "${1:-lint}" = mmu-lint ]; then
    echo 'PASS: staged CPU MMU/copyback fixture lint/elaborate'
    exit 0
fi
if [ "${1:-lint}" != lint ]; then
    run_arg=
    run_log="local/tests/cpu040-$top-run.log"
    if [ "${1:-lint}" = profile ]; then
        run_arg=+PROFILE
        run_log=local/tests/cpu040-profile-run.log
    fi
    if [ "${1:-lint}" = machine-ddr3 ]; then
        run_log=local/tests/cpu040-machine-ddr3-run.log
    fi
    if [ "${1:-lint}" = profile-ddr3 ]; then
        # extra plusargs, e.g. PROFILE_ARGS="+DDR_RD_LAT=16 +VID_STRIDE=1280"
        run_arg="+PROFILE ${PROFILE_ARGS:-}"
        run_log=local/tests/cpu040-profile-ddr3-run.log
    fi
    "$obj/V$top" $run_arg >"$run_log" 2>&1 || {
        tail -n 30 "$run_log"; exit 1;
    }
    grep -E '^(PASS:|PROFILE:)' "$run_log"
else
    verilator --lint-only --timing -Wno-fatal --top-module tb_lc040 -DCPU_AP68040 \
        -Irtl/ap68040_faster/rtl -Irtl/ap68040_faster/rtl/fpu \
        $sources rtl/quadra_bus040.sv rtl/wombat_store_buffer.sv rtl/quadra_cpu040.sv tests/tb_lc040.sv \
        >local/tests/cpu040-lc040-lint.log 2>&1 || {
            tail -n 30 local/tests/cpu040-lc040-lint.log; exit 1;
        }
    verilator --xml-only -Wno-fatal --top-module quadra_cpu040 \
        --xml-output local/tests/cpu040-lc040.xml \
        -Irtl/ap68040_faster/rtl -Irtl/ap68040_faster/rtl/fpu \
        $sources rtl/quadra_bus040.sv rtl/wombat_store_buffer.sv rtl/quadra_cpu040.sv \
        >local/tests/cpu040-lc040-structure.log 2>&1 || {
            tail -n 30 local/tests/cpu040-lc040-structure.log; exit 1;
        }
    if grep -Eq '<cell .*submodname="(ap68040_fpif|ap040_fpu)' local/tests/cpu040-lc040.xml; then
        echo 'FAIL: LC040 elaborated an FPU' >&2; exit 1
    fi
    grep -q '<cell .*submodname="ap68040_lc040' local/tests/cpu040-lc040.xml
    verilator --lint-only -Wno-fatal --top-module quadra_cpu040 -GAP040_HAS_FPU=1 \
        -Irtl/ap68040_faster/rtl -Irtl/ap68040_faster/rtl/fpu \
        $sources rtl/quadra_bus040.sv rtl/wombat_store_buffer.sv rtl/quadra_cpu040.sv \
        >local/tests/cpu040-full-fpu-lint.log 2>&1 || {
            tail -n 30 local/tests/cpu040-full-fpu-lint.log; exit 1;
        }
    echo 'PASS: staged LC040 and execution fixtures lint/elaborate; FPU absent'
    echo 'PASS: donor full-FPU configuration still lint/elaborates'
fi
