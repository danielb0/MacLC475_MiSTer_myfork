`timescale 1ns/1ps
module tb_swim2_trace_platform;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, guest_reset = 0, sd_ack = 0;
wire [35:0] EXT_BUS;
assign EXT_BUS[35:33] = 0;
assign EXT_BUS[31:16] = 0;
wire trace_tx;
integer checks = 0;
swim2_platform dut (
    .clk(clk), .nreset(nreset), .guest_reset(guest_reset), .init(1'b0),
    .sdram_sz(16'h8003), .EXT_BUS(EXT_BUS), .sel(1'b0), .write(1'b0),
    .addr(3'd0), .wdata(8'd0), .rdata(), .img_mounted(1'b0), .img_size(64'd0),
    .img_readonly(1'b0), .sd_lba(), .sd_rd(), .sd_wr(), .sd_ack(sd_ack),
    .sd_buff_addr(13'd0), .sd_buff_dout(16'd0), .sd_buff_wr(1'b0), .sd_buff_din(), .fault(),
    .cpu_req(1'b0), .cpu_we(1'b0), .cpu_addr(25'd0), .cpu_be(4'd0), .cpu_wdata(32'd0),
    .cpu_ack(), .cpu_rdata(), .beat_req(), .beat_we(), .beat_addr(), .beat_be(),
    .beat_wdata(), .beat_ack(1'b0), .beat_rdata(32'd0), .beat_busy(1'b0),
    .beat_line_pending(1'b0), .trace_tx(trace_tx)
);
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
task event_check(input [15:0] expected);
    begin
        #1; checks = checks + 1;
        if (dut.tracer.events !== expected)
            $fatal(1, "trace events got %04h expected %04h", dut.tracer.events, expected);
    end
endtask
initial begin
    // Inject boundary events without running a full image load.
    force dut.sd_wr = 0; force dut.sd_lba = 32'd30;
    force dut.save_valid = 0; force dut.save_ready = 0; force dut.fault = 0;
    force dut.mount_valid = 0; force dut.mount_ready = 1; force dut.release_done = 0;
    repeat (4) cycle; nreset = 1; cycle; event_check(0);
    // Loader ACKs must not flood the write trace.
    sd_ack = 1; event_check(0); cycle; sd_ack = 0; event_check(0); cycle;
    force dut.sd_wr = 1; event_check(16'h0040); cycle; event_check(0);
    sd_ack = 1; event_check(16'h1000); cycle;
    force dut.sd_wr = 0; event_check(0); cycle;
    sd_ack = 0; event_check(16'h2000); cycle; event_check(0);
    sd_ack = 1; event_check(0); cycle; sd_ack = 0; event_check(0); cycle;
    force dut.fault = 1; event_check(16'h0100); cycle; event_check(0);
    force dut.fault = 0; cycle;
    // Retry reports a fresh request, then retirement, not success on transfer ACK.
    force dut.sd_wr = 1; event_check(16'h0040); cycle;
    force dut.sd_wr = 0; cycle;
    force dut.save_valid = 1; force dut.save_ready = 1; event_check(16'h0080); cycle;
    force dut.save_valid = 0; force dut.save_ready = 0; event_check(0);
    force dut.mount_valid = 1; event_check(16'h0200); cycle;
    force dut.mount_valid = 0; force dut.release_done = 1; event_check(16'h0400); cycle;
    force dut.release_done = 0; guest_reset = 1; event_check(16'h0800); cycle;
    event_check(0);
    $display("PASS: SWIM II platform trace event wiring, loader filtering, save retry/retirement and reset, %0d checks", checks);
    $finish;
end
initial begin #100000; $fatal(1, "timeout"); end
endmodule
