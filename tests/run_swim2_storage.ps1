param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/swim2_storage_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'SWIM II storage library creation failed' }
    }
    & "$ModelSimBin/vlog.exe" -sv -work $library `
        rtl/swim2_loader.sv rtl/swim2_memory.sv rtl/swim2_storage.sv rtl/swim2_host_control.sv `
        rtl/swim2_persistence.sv rtl/swim2_host.sv rtl/swim2_host_persistence.sv rtl/swim2_host_read.sv `
        rtl/swim2_media.sv rtl/swim2_write_commit.sv `
        rtl/swim2_media/mfm_write_decoder.v rtl/swim2_media/floppy_track_decoder.v `
        tests/tb_swim2_storage.sv
    if ($LASTEXITCODE) { throw 'SWIM II storage compilation failed' }
    foreach ($hd in @(0, 1)) {
        $log = if ($hd) { 'local/tests/swim2_storage_hd.log' } else { 'local/tests/swim2_storage.log' }
        & "$ModelSimBin/vsim.exe" -c -lib $library tb_swim2_storage "-gHD=$hd" `
            -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
        if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
            (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
            throw "SWIM II storage simulation failed; see $log"
        }
    }
} finally {
    Pop-Location
}
