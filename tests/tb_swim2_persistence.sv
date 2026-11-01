`timescale 1ns/1ps
module tb_swim2_persistence;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;
reg [12:0] image_blocks = 2880;
reg [7:0] sd_buf_addr = 0;
reg [15:0] sd_buf_data = 0;
reg sd_buf_wr = 0, save_valid = 0, flush_req = 0;
reg [21:0] save_addr = 0;
wire save_ready, flush_ack, sd_wr, durable_req, fault, busy;
wire [31:0] sd_lba;
wire [15:0] sd_buff_din;
reg sd_ack = 0, durable_ack = 0, durable_error = 0, retry = 0;
reg [12:0] sd_buff_addr = 0;
reg [15:0] cached_file [0:255];
reg [15:0] durable_file [0:255];
integer checks = 0, i, j;

swim2_persistence dut (.*);

function [15:0] pattern(input integer w, input [7:0] seed);
    pattern = {w[7:0] ^ seed, w[7:0] ^ seed ^ 8'ha7};
endfunction

task check(input [31:0] actual, input [31:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "check %0d at %0t: got %08h expected %08h", checks, $time, actual, wanted);
    end
endtask

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

task snapshot(input [7:0] seed);
    begin
        for (i = 0; i < 256; i = i + 1) begin
            sd_buf_addr = i; sd_buf_data = pattern(i, seed); sd_buf_wr = 1;
            repeat (i % 3 + 1) cycle;
        end
        sd_buf_wr = 0; cycle;
    end
endtask

task transfer(input [12:0] lba, input [7:0] seed);
    reg [15:0] p;
    begin
        while (!sd_wr) cycle;
        check(sd_lba, lba); check(save_ready, 0); check(flush_ack, 0);
        repeat (7) begin cycle; check(sd_wr, 1); check(sd_lba, lba); end
        sd_ack = 1; cycle; check(sd_wr, 0);
        // HPS may address words repeatedly and out of order.
        for (j = 255; j >= 0; j = j - 1) begin
            sd_buff_addr = j; cycle;
            p = pattern(j, seed);
            check(sd_buff_din, {p[7:0], p[15:8]});
            cached_file[j] = sd_buff_din;
            check(save_ready, 0); check(flush_ack, 0); check(durable_req, 0);
        end
        sd_buff_addr = 13'h100; cycle; check(sd_buff_din, 0);
        repeat (5) begin cycle; check(sd_wr, 0); check(save_ready, 0); end
        sd_ack = 0; cycle;
        while (!durable_req) cycle;
        repeat (6) begin cycle; check(save_ready, 0); check(flush_ack, 0); end
    end
endtask

task completion(input fail_write, input late_error);
    begin
        durable_error = fail_write && !late_error;
        durable_ack = 1; cycle; check(durable_req, 0);
        if (late_error) durable_error = fail_write;
        repeat (5) begin cycle; check(save_ready, 0); check(flush_ack, 0); end
        if (!fail_write)
            for (j = 0; j < 256; j = j + 1) durable_file[j] = cached_file[j];
        durable_ack = 0; cycle; durable_error = 0;
        check(fault, fail_write); check(save_ready, !fail_write);
    end
endtask

task reset_backend;
    begin
        nreset = 0; cycle;
        check(sd_wr, 0); check(durable_req, 0); check(save_ready, 0); check(flush_ack, 0);
        save_valid = 0; flush_req = 0; sd_ack = 0; durable_ack = 0; retry = 0;
        nreset = 1; cycle;
    end
endtask

initial begin
    for (i = 0; i < 256; i = i + 1) durable_file[i] = 16'hdead;
    cycle; nreset = 1; cycle;
    snapshot(8'h59);
    sd_ack = 1; durable_ack = 1;
    save_addr = 22'd1474048; save_valid = 1; flush_req = 1; cycle;
    repeat (5) begin cycle; check(sd_wr, 0); check(save_ready, 0); check(flush_ack, 0); end
    sd_ack = 0;
    repeat (4) begin cycle; check(sd_wr, 0); end
    durable_ack = 0;
    transfer(2879, 8'h59);
    // A transferred block is still absent from durable storage.
    check(durable_file[0], 16'hdead);
    completion(1, 0);
    // Failure retains ownership and cannot complete an eject.
    sd_buf_addr = 0; sd_buf_data = 16'hffff; sd_buf_wr = 1;
    save_addr = 0; image_blocks = 1;
    repeat (8) begin cycle; check(fault, 1); check(flush_ack, 0); check(sd_wr, 0); end
    sd_buf_wr = 0;
    retry = 1; cycle; retry = 0;
    transfer(2879, 8'h59); completion(1, 1);
    check(durable_file[0], 16'hdead);
    retry = 1; cycle; retry = 0;
    transfer(2879, 8'h59); completion(0, 0);
    for (i = 0; i < 256; i = i + 1) begin
        sd_buff_addr = i; cycle;
        check(sd_buff_din, durable_file[i]);
        if (i == 0) save_valid = 0;
    end
    while (!flush_ack) cycle;
    repeat (6) begin cycle; check(flush_ack, 1); check(sd_wr, 0); end
    flush_req = 0; cycle; check(flush_ack, 0);

    // Same LBA can be rewritten after a completed barrier.
    image_blocks = 2880; snapshot(8'h36);
    save_addr = 22'd1474048; save_valid = 1;
    transfer(2879, 8'h36); completion(0, 0);
    cycle; save_valid = 0; cycle;
    check(fault, 0); check(busy, 0);

    // A stalled host cannot retire work or synthesize a successful flush.
    snapshot(8'h91); save_addr = 0; save_valid = 1; flush_req = 1;
    while (!sd_wr) cycle;
    repeat (64) begin
        cycle; check(sd_wr, 1); check(sd_lba, 0); check(save_ready, 0); check(flush_ack, 0);
    end
    sd_ack = 1; cycle;
    repeat (64) begin cycle; check(durable_req, 0); check(save_ready, 0); end
    // An unrelated high durable ACK must clear before a fresh request.
    durable_ack = 1; sd_ack = 0;
    repeat (8) begin cycle; check(durable_req, 0); check(save_ready, 0); end
    durable_ack = 0;
    while (!durable_req) cycle;
    repeat (64) begin cycle; check(durable_req, 1); check(save_ready, 0); check(flush_ack, 0); end
    reset_backend;

    // Alignment and bounds failures never reach the host or retire.
    save_addr = 1; save_valid = 1; cycle; check(fault, 1);
    retry = 1; repeat (5) begin cycle; check(sd_wr, 0); check(save_ready, 0); end
    reset_backend;
    save_addr = 22'd1474560; save_valid = 1; cycle; check(fault, 1); check(sd_wr, 0);
    reset_backend;
    image_blocks = 0; save_addr = 0; save_valid = 1; cycle; check(fault, 1);
    reset_backend;

    // Empty flush also waits for stale replies to clear.
    flush_req = 1; durable_ack = 1;
    repeat (5) begin cycle; check(flush_ack, 0); end
    durable_ack = 0; sd_ack = 1;
    repeat (5) begin cycle; check(flush_ack, 0); end
    sd_ack = 0; cycle; check(flush_ack, 1);
    flush_req = 0; cycle;
    $display("PASS: SWIM II persistence, %0d checks", checks);
    $finish;
end
initial begin #1000000; $fatal(1, "timeout"); end
endmodule
