param(
    [string]$QuartusBin = 'C:\intelFPGA_lite\17.0\quartus\bin64',
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & "$QuartusBin/quartus_sh.exe" -t tests/prepare_video_startup_guard.tcl
    if ($LASTEXITCODE) { throw 'Video startup source preparation failed' }
    $library = 'local/tests/video_startup_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'ModelSim library creation failed' }
    }
    & "$ModelSimBin/vlog.exe" -sv -work $library local/generated/cpu040/terminator_video_test.sv `
        local/generated/cpu040/sysmem_video_test.sv tests/tb_video_startup_guard.sv
    if ($LASTEXITCODE) { throw 'Video startup compilation failed' }
    $log = 'local/tests/video_startup_guard.log'
    & "$ModelSimBin/vsim.exe" -c -lib $library tb_video_startup_guard `
        -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
    if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
        (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
        throw "Video startup simulation failed; see $log"
    }
} finally {
    Pop-Location
}
