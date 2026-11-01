`timescale 1ns/1ps
module video_startup_case #(parameter PHASE = 0)(output reg done = 0);
reg clk = 0;
always #5 clk = ~clk;
reg reset_req = 1, wr = 1, rd = 0;
reg [127:0] data = 0;
wire waitrequest, reset_out;
integer beats = 0, reads = 0;
sysmem_lite dut (
    .clock(), .reset_out(reset_out), .reset_core_req(reset_req),
    .reset_hps_cold_req(1'b0), .reset_hps_warm_req(1'b0),
    .ram1_clk(clk), .ram1_address(29'd0), .ram1_burstcount(8'd1),
    .ram1_read(1'b0), .ram1_write(1'b0), .ram1_writedata(64'd0), .ram1_byteenable(8'hff),
    .ram1_waitrequest(), .ram1_readdata(), .ram1_readdatavalid(),
    .ram2_clk(clk), .ram2_address(29'd0), .ram2_burstcount(8'd1),
    .ram2_read(1'b0), .ram2_write(1'b0), .ram2_writedata(64'd0), .ram2_byteenable(8'hff),
    .ram2_waitrequest(), .ram2_readdata(), .ram2_readdatavalid(),
    .vbuf_clk(clk), .vbuf_address(28'h2000000), .vbuf_burstcount(8'd16),
    .vbuf_waitrequest(waitrequest), .vbuf_read(rd), .vbuf_write(wr),
    .vbuf_writedata(data), .vbuf_byteenable(16'hffff), .vbuf_readdata(), .vbuf_readdatavalid()
);
always @(posedge clk) begin
    if (!dut.vbuf_open && (dut.f2h_vbuf_write || dut.f2h_vbuf_read || !waitrequest))
        $fatal(1, "Startup traffic escaped, phase %0d", PHASE);
    if (dut.f2h_vbuf_write && !dut.f2h_vbuf_waitrequest) beats = beats + 1;
    if (dut.f2h_vbuf_read && !dut.f2h_vbuf_waitrequest) reads = reads + 1;
end
task tick;
    @(negedge clk);
endtask
initial begin
    // Skip the fixed 20 ms power-up timer, retaining core-reset synchronization.
    force dut.init_reset_n = 1'b1;
    repeat (8) tick();
    reset_req = 0;
    repeat (PHASE + 1) tick();
    wr = 0;
    // A second reset before opening must restart the full delay.
    reset_req = 1;
    rd = 1;
    repeat (5) tick();
    reset_req = 0;
    wait (!dut.vbuf_reset_1);
    tick();
    repeat (32) begin
        if (dut.vbuf_open) $fatal(1, "Guard opened early");
        tick();
    end
    if (!dut.vbuf_open || beats || reads) $fatal(1, "Invalid startup delay or traffic");
    rd = 0;
    // A stalled first burst must preserve its header and complete all 16 beats.
    dut.fpga_interfaces.mem_wait = 1;
    wr = 1;
    data = 128'h0101;
    repeat (4) tick();
    if (!waitrequest || beats) $fatal(1, "Backpressure lost");
    dut.fpga_interfaces.mem_wait = 0;
    repeat (16) begin
        #1;
        if (waitrequest || !dut.f2h_vbuf_write || dut.f2h_vbuf_writedata !== data ||
            dut.f2h_vbuf_address !== 28'h2000000 || dut.f2h_vbuf_byteenable !== 16'hffff)
            $fatal(1, "First burst corrupted");
        tick();
        data = data + 1'b1;
    end
    wr = 0;
    if (beats != 16) $fatal(1, "First burst incomplete: %0d", beats);
    rd = 1;
    tick();
    rd = 0;
    if (reads != 1) $fatal(1, "Read did not pass");
    // Reset during a later burst must leave the stock terminator able to finish it.
    wr = 1;
    repeat (3) tick();
    reset_req = 1;
    wait (dut.f2sdram_safe_terminator_vbuf.terminating);
    tick();
    wr = 0;
    repeat (24) tick();
    if (!dut.vbuf_open || beats != 32)
        $fatal(1, "Later reset cut a burst: %0d", beats);
    reset_req = 0;
    repeat (8) tick();
    done = 1;
end
endmodule

module tb_video_startup_guard;
wire [15:0] done;
genvar i;
generate for (i = 0; i < 16; i = i + 1) begin : cases
    video_startup_case #(.PHASE(i)) test_case (.done(done[i]));
end endgenerate
initial begin
    wait (&done);
    $display("PASS: 16 startup phases, reset restart, stalled header bursts, reads and later burst termination");
    $finish;
end
initial begin
    #20000;
    $fatal(1, "Video startup guard timeout");
end
endmodule
