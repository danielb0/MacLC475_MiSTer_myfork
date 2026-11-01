set framework_input [open sys/sys.tcl r]
set framework_settings [read $framework_input]
close $framework_input
set framework_qip {set_global_assignment -name QIP_FILE sys/sys.qip}
if {[string first $framework_qip $framework_settings] < 0} {
    error "Video startup guard: stock framework QIP assignment not found"
}
eval [string map [list $framework_qip \
    {set_global_assignment -name QIP_FILE configs/video_startup_guard.qip}] $framework_settings]
source sys/sys_analog.tcl
