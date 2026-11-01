param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/swim2_trace_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'SWIM II trace library creation failed' }
    }
    $sources = @(Get-ChildItem rtl/swim2*.sv | ForEach-Object { "rtl/$($_.Name)" })
    $sources += @(Get-ChildItem rtl/swim2_media/*.v | ForEach-Object { "rtl/swim2_media/$($_.Name)" })
    & "$ModelSimBin/vlog.exe" -sv -work $library +define+SWIM2_TRACE rtl/rate_enable.sv $sources `
        tests/tb_swim2_trace.sv tests/tb_swim2_catalog.sv tests/tb_swim2_trace_platform.sv
    if ($LASTEXITCODE) { throw 'SWIM II trace compilation failed' }
    foreach ($testBench in @('tb_swim2_trace', 'tb_swim2_catalog', 'tb_swim2_trace_platform')) {
        $log = "local/tests/$($testBench.Substring(3))_traced.log"
        & "$ModelSimBin/vsim.exe" -c -lib $library $testBench `
            -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
        if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
            (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
            throw "SWIM II trace check failed; see $log"
        }
    }
} finally {
    Pop-Location
}
