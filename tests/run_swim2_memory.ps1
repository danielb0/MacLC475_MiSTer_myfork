param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem',
    [string]$Python = 'C:\Users\Elle\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/swim2_memory_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'SWIM II memory library creation failed' }
    }
    # ModelSim 10.5 requires declarations before use; production RTL is unchanged.
    $raw = 'local/tests/swim2_memory_raw.sv'
    $ordered = 'local/tests/swim2_memory_ordered.sv'
    & "$ModelSimBin/vlog.exe" -sv -mfcu -E $raw -work $library rtl/sdram.sv rtl/sdram_beat32.sv
    if (!(Test-Path $raw)) { throw 'SWIM II memory preprocessing failed' }
    & $Python tests/support/modelsim_declarations.py $raw $ordered
    if ($LASTEXITCODE) { throw 'SWIM II memory declaration ordering failed' }
    & "$ModelSimBin/vlog.exe" -sv -work $library $ordered rtl/swim2_memory.sv tests/tb_sdram.sv tests/tb_swim2_memory.sv
    if ($LASTEXITCODE) { throw 'SWIM II memory compilation failed' }
    $log = 'local/tests/swim2_memory.log'
    & "$ModelSimBin/vsim.exe" -c -lib $library -L altera_mf_ver -L cyclonev_ver -L altera_ver -L lpm_ver tb_swim2_memory `
        -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
    if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
        (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
        throw "SWIM II memory simulation failed; see $log"
    }
} finally {
    Pop-Location
}
