param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/cpu040_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'ModelSim library creation failed' }
    }
    & "$ModelSimBin/vlog.exe" -sv -work $library `
        +incdir+rtl/ap68040_faster/rtl `
        rtl/ap68040_faster/rtl/ap68040_pkg.sv `
        rtl/ap68040_faster/rtl/gen/ap68040_upkg.sv `
        rtl/ap68040_faster/rtl/ap68040_lc040_pkg.sv `
        rtl/ap68040_faster/rtl/ap68040_lc040.sv `
        tests/tb_lc040_decode.sv tests/tb_lc040_ucode.sv `
        rtl/bus040.sv tests/tb_bus040.sv `
        *> local/tests/cpu040_compile.log
    if ($LASTEXITCODE) { throw 'ModelSim compilation failed; see local/tests/cpu040_compile.log' }
    foreach ($bench in @('tb_bus040', 'tb_lc040_decode', 'tb_lc040_ucode')) {
        $log = "local/tests/$bench.log"
        & "$ModelSimBin/vsim.exe" -c -lib $library $bench `
            -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
        if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
            (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
            throw "Simulation failed: $bench"
        }
    }
} finally {
    Pop-Location
}
