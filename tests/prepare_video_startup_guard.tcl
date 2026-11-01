set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts video_startup_guard.tcl]
set output_dir [file join $root local generated cpu040]
set path [generate_video_startup_guard $root $output_dir]
set input [open $path r]
set rtl [read $input]
close $input
# ModelSim 10.5b requires declarations before their first use.
set declarations "wire hps_h2f_reset_n;\nreg init_reset_n = 0;\n"
set rtl [string map [list {wire hps_h2f_reset_n;} {} {reg init_reset_n = 0;} {} \
    {integer timeout = 0;} {static integer timeout = 0;}] $rtl]
set rtl [string map [list {assign reset_out =} "$declarations\nassign reset_out ="] $rtl]
# The bench supplies the hard HPS interface; retain the actual sysmem wrapper.
set boundary [string first "module sysmem_HPS_fpga_interfaces" $rtl]
if {$boundary < 0} { error "HPS interface boundary not found" }
set output [open [file join $output_dir sysmem_video_test.sv] w]
puts -nonewline $output [string range $rtl 0 [expr {$boundary - 1}]]
set ports_end [string first {wire [29 - 1 : 0] intermediate;} $rtl $boundary]
if {$ports_end < 0} { error "HPS interface port boundary not found" }
puts $output [string range $rtl $boundary [expr {$ports_end - 1}]]
puts $output {
assign h2f_user0_clk = f2h_sdram0_clk;
assign h2f_rst_n = 1'b1;
reg mem_wait = 0;
assign f2h_sdram0_WAITREQUEST = mem_wait;
assign f2h_sdram0_READDATA = 128'h0123456789abcdef;
assign f2h_sdram0_READDATAVALID = 1'b0;
assign f2h_sdram1_WAITREQUEST = 1'b0;
assign f2h_sdram2_WAITREQUEST = 1'b0;
assign f2h_sdram1_READDATA = 64'd0;
assign f2h_sdram2_READDATA = 64'd0;
assign f2h_sdram1_READDATAVALID = 1'b0;
assign f2h_sdram2_READDATAVALID = 1'b0;
endmodule
}
close $output

set input [open [file join $root sys f2sdram_safe_terminator.sv] r]
set rtl [read $input]
close $input
set declarations "reg \[BURSTCOUNT_WIDTH-1:0\] write_burstcounter = 0;\nreg \[BURSTCOUNT_WIDTH-1:0\] write_burstcount_latch = 0;\n"
regsub -all {\moutput\M\s+} $rtl {output logic } rtl
set rtl [string map [list {wire next_state_write;} {logic next_state_write;}] $rtl]
regsub -all {reg \[BURSTCOUNT_WIDTH-1:0\] write_burst(counter|count_latch)\s*= 0;} $rtl {} rtl
set rtl [string map [list \
    {[ADDRESS_WITDH-1:0]} {[31-$clog2(DATA_WIDTH/8):0]} \
    {[BYTEENABLE_WIDTH-1:0]} {[DATA_WIDTH/8-1:0]} \
    {wire burst_write_start} "$declarations\nwire burst_write_start"] $rtl]
set output [open [file join $output_dir terminator_video_test.sv] w]
puts -nonewline $output $rtl
close $output
