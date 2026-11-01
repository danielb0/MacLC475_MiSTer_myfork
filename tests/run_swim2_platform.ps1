param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem',
    [string]$Python = 'C:\Users\Elle\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe',
    [string[]]$Bench = @('tb_swim2_bus', 'tb_swim2_timing', 'tb_swim2_platform')
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/swim2_platform_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'SWIM II platform library creation failed' }
    }
    $raw = 'local/tests/swim2_platform_raw.sv'
    $ordered = 'local/tests/swim2_platform_ordered.sv'
    & "$ModelSimBin/vlog.exe" -sv -mfcu -E $raw -work $library +define+SWIM2 `
        rtl/ncr53c96.sv rtl/cd_audio.sv rtl/rate_enable.sv rtl/iosb.sv rtl/via6522.sv `
        rtl/cuda/m68hc05_core.sv rtl/cuda/m68hc05_alu.sv rtl/cuda/cuda_mcu.sv `
        rtl/cuda/cuda_board.sv rtl/adb_device.sv rtl/easc.sv `
        rtl/scc.v rtl/uart/rxuart.v rtl/uart/txuart.v rtl/dpram.v *> local/tests/swim2_platform_preprocess.log
    if (!(Test-Path $raw)) { throw 'SWIM II platform preprocessing failed' }
    & $Python tests/support/modelsim_declarations.py $raw $ordered
    if ($LASTEXITCODE) { throw 'SWIM II platform declaration ordering failed' }
    $sources = @(Get-ChildItem rtl/swim2*.sv | ForEach-Object { $_.FullName })
    $sources += @(Get-ChildItem rtl/swim2_media/*.v | ForEach-Object { $_.FullName })
    & "$ModelSimBin/vlog.exe" -sv -work $library $ordered $sources `
        tests/tb_swim2_bus.sv tests/tb_swim2_timing.sv tests/tb_swim2_platform.sv
    if ($LASTEXITCODE) { throw 'SWIM II platform compilation failed' }
    foreach ($testBench in $Bench) {
        $log = "local/tests/$($testBench.Substring(3)).log"
        & "$ModelSimBin/vsim.exe" -c -lib $library -L altera_mf_ver $testBench `
            -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
        if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
            (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
            throw "SWIM II platform simulation failed; see $log"
        }
    }
} finally {
    Pop-Location
}
