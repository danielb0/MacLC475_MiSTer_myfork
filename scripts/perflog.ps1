# perflog.ps1 -- record the perf counters over SSH, then print the report.
#
#   .\scripts\perflog.ps1                 # record until Ctrl-C
#   .\scripts\perflog.ps1 -Seconds 40     # record for 40 s
#   .\scripts\perflog.ps1 -Name speedo    # label the capture file
#
# Streams scripts/perflog.py to the MiSTer's python3 over ssh (nothing is
# copied there) and writes the CSV to
# local/shots/perf/capture_<name>_<time>.csv.  When recording stops, runs
# scripts/perf_report.py on it and saves the report next to it as
# report_<...>.txt.  Needs a MACLC475_DEBUG core loaded.
#
# PowerShell has no '<' redirection and 5.1 writes '>' as UTF-16, so the ssh
# runs under cmd.exe, which passes the bytes through unchanged.

param(
    [string]$MiSTer = 'mister-bedroom',
    [double]$Seconds = 0,
    [double]$Interval = 1.0,
    [string]$Name = 'capture'
)

$repo   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $repo 'local\shots\perf'
New-Item -ItemType Directory -Force $outDir | Out-Null
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$csv    = Join-Path $outDir "capture_${Name}_$stamp.csv"
$txt    = Join-Path $outDir "report_${Name}_$stamp.txt"
$py     = Join-Path $PSScriptRoot 'perflog.py'

$args_py = "$Interval"
if ($Seconds -gt 0) { $args_py += " $Seconds" }

if ($Seconds -gt 0) {
    Write-Host "Recording on $MiSTer for $Seconds s -> $csv"
} else {
    Write-Host "Recording on $MiSTer -> $csv"
    Write-Host 'Press Ctrl-C when the test is done and a few idle seconds have passed.'
}

try {
    cmd /c "ssh $MiSTer python3 -u - $args_py < `"$py`" > `"$csv`""
}
finally {
    $rows = 0
    if (Test-Path $csv) { $rows = (Get-Content $csv | Measure-Object -Line).Lines - 1 }
    Write-Host "Stopped: $rows samples in $csv"
    if ($rows -ge 3) {
        $report = python (Join-Path $PSScriptRoot 'perf_report.py') $csv
        $report | Out-File -Encoding utf8 $txt
        $report | Write-Host
        Write-Host "Report saved to $txt"
    }
}
