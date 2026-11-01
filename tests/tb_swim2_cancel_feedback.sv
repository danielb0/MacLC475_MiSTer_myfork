`timescale 1ns/1ps
module tb_swim2_cancel_feedback;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = 409600;
wire host_owned, mount_valid, mount_hd, mount_readonly, mount_gcr, mount_sides;
wire [12:0] image_blocks;
reg mount_ready = 0, release_done = 0;
wire [31:0] sd_lba;
wire sd_rd, host_req, cancel_done;
reg sd_ack = 1, sd_buff_wr = 0, host_ack = 0, host_error = 0;
reg [12:0] sd_buff_addr = 0;
reg [15:0] sd_buff_dout = 0;
wire mem_req;
wire [21:0] mem_addr;
wire [15:0] mem_data;
reg mem_ack = 0, mem_busy = 0, retry = 0, external_cancel = 0;
wire fault, busy, host_cancel;
wire cancel = external_cancel || host_cancel;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
wire io_selected, release_request, loader_retry, save_retry;
wire [15:0] io_dout;
integer checks = 0, cancellations = 0, run_index;
reg [15:0] response, status, lo, hi;
reg [31:0] old_token, new_token;

swim2_loader loader (.*);
swim2_host_control control_host (
    .clk(clk), .nreset(nreset), .io_strobe(io_strobe), .io_enable(io_enable),
    .io_din(io_din), .io_selected(io_selected), .io_dout(io_dout),
    .host_owned(host_owned), .media_live(1'b0), .loader_fault(fault), .writer_fault(1'b0),
    .cancel(host_cancel), .release_request(release_request),
    .loader_retry(loader_retry), .save_retry(save_retry)
);
always @(posedge clk) begin
    if (nreset) begin
        if (cancel_done) cancellations = cancellations + 1;
        if (sd_rd || mem_req || host_req || mount_valid)
            $fatal(1, "cancelled or stale-ACK acquisition launched work");
    end
end

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
task check(input [63:0] actual, input [63:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "feedback check %0d at %0t: got %h expected %h", checks, $time, actual, wanted);
    end
endtask
task word_io(input [15:0] value);
    begin
        io_enable = 1; io_strobe = 1; io_din = value; cycle;
        io_strobe = 0; cycle; response = io_dout;
    end
endtask
task close_io;
    begin io_enable = 0; cycle; check(io_selected, 0); end
endtask
task metadata;
    begin
        word_io(16'h0c); check(response, 16'h5343);
        word_io(0); status = response;
        word_io(0); lo = response; word_io(0); hi = response;
        word_io(0); word_io(0); word_io(0); check(response, 6); close_io;
    end
endtask
task eject(input [31:0] token);
    begin
        word_io(16'h0d); word_io(token[15:0]); word_io(token[31:16]); word_io(1); close_io;
    end
endtask

initial begin
    repeat (3) cycle; nreset = 1; cycle;
    // A simultaneous external cancel must not feed back into the reservation.
    external_cancel = 1; img_mounted = 1; #1; check(host_owned, 1);
    cycle; img_mounted = 0; external_cancel = 0; cycle;
    check(host_owned, 0); check(image_blocks, 0); check(cancel_done, 0);

    for (run_index = 0; run_index < 3; run_index = run_index + 1) begin
        img_size = 409600; img_mounted = 1; #1; check(host_owned, 1);
        cycle; img_mounted = 0; repeat (3) cycle;
        metadata; old_token = {hi, lo}; check(status, 16'h0101);
        eject(old_token); check(host_cancel, 1);
        repeat (4) begin cycle; check(host_owned, 1); check(cancel_done, 0); end
        // The final drain still owns the old mount, even with ACK withdrawn.
        mem_busy = 1; sd_ack = 0;
        repeat (4) begin cycle; check(host_owned, 1); check(cancel_done, 0); end
        mem_busy = 0;
        while (!cancel_done) cycle;
        check(host_owned, 0); check(host_cancel, 0);
        // Remount before control_host has sampled the old ownership release.
        img_size = 737280; img_readonly = 1; sd_ack = 1; img_mounted = 1;
        #1; check(host_owned, 0); check(host_cancel, 0);
        cycle; img_mounted = 0;
        check(host_owned, 1); check(host_cancel, 0); check(image_blocks, 1440);
        check(mount_gcr, 0); check(mount_sides, 1); check(mount_readonly, 1);
        repeat (2) cycle;
        metadata; new_token = {hi, lo}; check(new_token, old_token + 1);
        check(status, 16'h0101);
        eject(old_token); check(host_cancel, 0); check(host_owned, 1);
        eject(new_token); check(host_cancel, 1);
        sd_ack = 0;
        while (!cancel_done) cycle;
        check(host_owned, 0); check(host_cancel, 0);
        repeat (3) cycle; check(cancel_done, 0); check(host_owned, 0);
        sd_ack = 1;
    end
    check(cancellations, 6);
    nreset = 0; cycle; check(host_owned, 0); check(host_cancel, 0);
    $display("PASS: SWIM II cancellation feedback and immediate remount, %0d checks", checks);
    $finish;
end
initial begin #1000000; $fatal(1, "timeout"); end
endmodule
