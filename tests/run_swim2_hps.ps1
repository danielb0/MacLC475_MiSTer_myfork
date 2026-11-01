param(
    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    $library = 'local/tests/swim2_hps_work'
    New-Item -ItemType Directory -Path local/tests -Force | Out-Null
    # ModelSim 10.5 requires declarations before use and explicit static locals.
    $source = Get-Content sys/hps_io.sv -Raw
    $source = $source.Replace('[VD:0]', '[VDNUM-1:0]').Replace('[AW:0]', '[(WIDE ? 12 : 13):0]').Replace('[DW:0]', '[(WIDE ? 15 : 7):0]')
    $source = [regex]::Replace($source, '(?ms)^module .*?^endmodule', {
        param($module)
        $body = $module.Value
        $declarations = [regex]::Matches($body, '(?m)^(?:localparam |reg |wire (?!.*=))[^\r\n]+;[^\r\n]*\r?$')
        $moved = ($declarations | ForEach-Object { $_.Value }) -join "`n"
        foreach ($declaration in $declarations) { $body = $body.Replace($declaration.Value, '') }
        # PS2DIV=0 removes these generated devices; outer references still need declarations.
        $ps2 = [regex]::Matches($body, '(?m)^\t\t(?:reg|wire) [^\r\n]*(?:kbd|mouse)_[^\r\n]*;\r?$')
        foreach ($declaration in $ps2) {
            $moved += "`n" + $declaration.Value.TrimStart()
            $body = $body.Replace($declaration.Value, '')
        }
        $portEnd = $body.IndexOf(');') + 2
        $body = $body.Insert($portEnd, "`n$moved`n")
        [regex]::Replace($body, '(?m)^(\s+)reg (.*=.*;)', '$1static reg $2')
    })
    Set-Content local/tests/hps_io_swim2_test.sv $source -Encoding ascii
    if (!(Test-Path $library)) {
        & "$ModelSimBin/vlib.exe" $library
        if ($LASTEXITCODE) { throw 'SWIM II hps library creation failed' }
    }
    & "$ModelSimBin/vlog.exe" -sv -work $library local/tests/hps_io_swim2_test.sv `
        rtl/swim2_persistence.sv rtl/swim2_host.sv rtl/swim2_host_persistence.sv rtl/swim2_loader.sv rtl/swim2_host_read.sv rtl/swim2_host_control.sv `
        tests/tb_swim2_hps.sv tests/tb_swim2_loader_hps.sv
    if ($LASTEXITCODE) { throw 'SWIM II hps compilation failed' }
    foreach ($bench in @('tb_swim2_hps', 'tb_swim2_loader_hps')) {
        $log = "local/tests/$($bench.Substring(3)).log"
        & "$ModelSimBin/vsim.exe" -c -lib $library $bench `
            -do 'onerror {quit -f -code 1}; onbreak {quit -f -code 1}; run -all; quit -f -code 0' -l $log
        if ($LASTEXITCODE -or !(Select-String $log -Pattern '^# PASS:') -or
            (Select-String $log -Pattern '^# \*\* (Fatal|Error):')) {
            throw "SWIM II hps simulation failed; see $log"
        }
    }
} finally {
    Pop-Location
}
