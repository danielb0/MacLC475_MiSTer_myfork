param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem',
    [string[]]$Bench = @('tb_swim2_control', 'tb_swim2_data', 'tb_swim2_registers', 'tb_swim2_mfm',
        'tb_swim2_drive', 'tb_swim2_write_commit', 'tb_swim2_media', 'tb_swim2_subsystem',
        'tb_swim2_gcr', 'tb_swim2_gcr_subsystem', 'tb_swim2_persistence', 'tb_swim2_persistence_media',
        'tb_swim2_host', 'tb_swim2_host_mailbox', 'tb_swim2_loader', 'tb_swim2_loader_cancel',
        'tb_swim2_host_read', 'tb_swim2_host_control', 'tb_swim2_cancel_feedback', 'tb_swim2_catalog')
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/swim2_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'SWIM II library creation failed' }
    }
    & "$ModelSimBin/vlog.exe" -sv -work $library rtl/swim2_control.sv rtl/swim2_data.sv rtl/swim2.sv `
        rtl/swim2_mfm_write.sv rtl/swim2_drive.sv rtl/swim2_write_commit.sv rtl/swim2_media.sv rtl/swim2_subsystem.sv rtl/swim2_persistence.sv `
        rtl/swim2_media/mfm_track_encoder.v rtl/swim2_media/mfm_write_decoder.v `
        rtl/swim2_media/floppy_track_encoder.v rtl/swim2_media/floppy_track_decoder.v `
        tests/tb_swim2_control.sv tests/tb_swim2_data.sv tests/tb_swim2_registers.sv `
        tests/tb_swim2_mfm.sv tests/tb_swim2_drive.sv tests/tb_swim2_write_commit.sv tests/tb_swim2_media.sv tests/tb_swim2_subsystem.sv `
        tests/tb_swim2_gcr.sv tests/tb_swim2_gcr_subsystem.sv `
        tests/tb_swim2_persistence.sv tests/tb_swim2_persistence_media.sv tests/tb_swim2_catalog.sv
    if ($LASTEXITCODE) { throw 'SWIM II compilation failed' }
    & "$ModelSimBin/vlog.exe" -sv -work $library rtl/swim2_host.sv rtl/swim2_host_persistence.sv tests/tb_swim2_host.sv `
        rtl/swim2_loader.sv tests/tb_swim2_loader.sv tests/tb_swim2_loader_cancel.sv `
        rtl/swim2_host_read.sv tests/tb_swim2_host_read.sv `
        rtl/swim2_host_control.sv tests/tb_swim2_host_control.sv tests/tb_swim2_cancel_feedback.sv
    if ($LASTEXITCODE) { throw 'SWIM II host compilation failed' }
    foreach ($testBench in $Bench) {
        $log = "local/tests/$($testBench.Substring(3)).log"
        & "$ModelSimBin/vsim.exe" -c -lib $library $testBench `
            -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
        if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
            (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
            throw "SWIM II simulation failed; see $log"
        }
    }
} finally {
    Pop-Location
}
