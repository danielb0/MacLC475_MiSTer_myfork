`timescale 1ns/1ps
module tb_swim2_loader_cancel;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = 409600;
wire host_owned, mount_valid, mount_hd, mount_readonly, mount_gcr, mount_sides;
wire [12:0] image_blocks;
reg mount_ready = 0, release_done = 0;
wire [31:0] sd_lba;
wire sd_rd, host_req, cancel_done;
reg sd_ack = 0, sd_buff_wr = 0, host_ack = 0, host_error = 0, cancel = 0;
reg [12:0] sd_buff_addr = 0;
reg [15:0] sd_buff_dout = 16'h3412;
wire mem_req;
wire [21:0] mem_addr;
wire [15:0] mem_data;
reg mem_ack = 0, mem_busy = 0, retry = 0;
wire fault, busy;
reg mem_allow = 1, hold_mem_ack = 0;
integer checks = 0, writes = 0, cancellations = 0, i, block_index;
reg [21:0] held_addr;
swim2_loader dut (.*);

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

task check(input [31:0] actual, input [31:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "cancel check %0d at %0t: got %08h expected %08h", checks, $time, actual, wanted);
    end
endtask

always @(posedge clk) begin
    if (!nreset) mem_ack <= 0;
    else if (!mem_req) begin if (!hold_mem_ack) mem_ack <= 0; end
    else if (!mem_ack && mem_allow) begin
        check(mem_data, 16'h1234);
        mem_ack <= 1;
        writes <= writes + 1;
    end
    if (nreset && cancel_done) cancellations <= cancellations + 1;
end

task reset_loader;
    begin
        nreset = 0; img_mounted = 0; sd_ack = 0; sd_buff_wr = 0;
        host_ack = 0; host_error = 0; cancel = 0; mem_busy = 0;
        mount_ready = 0; release_done = 0; mem_allow = 1; hold_mem_ack = 0;
        cycle; writes = 0; cancellations = 0;
        nreset = 1; cycle;
        check(host_owned, 0); check(fault, 0);
    end
endtask

task mount_image;
    begin img_mounted = 1; cycle; img_mounted = 0; cycle; check(host_owned, 1); end
endtask

task transfer_block;
    begin
        while (!sd_rd) cycle;
        sd_ack = 1; cycle;
        for (i = 0; i < 256; i = i + 1) begin
            sd_buff_addr = i; sd_buff_wr = 1; cycle;
            check(mem_req, 0);
        end
        sd_buff_wr = 0; cycle; sd_ack = 0; cycle;
        while (!host_req) cycle;
    end
endtask

task result(input error);
    begin
        host_error = error; host_ack = 1; cycle;
        check(host_req, 0);
        host_ack = 0; host_error = 0; repeat (3) cycle;
    end
endtask

task wait_cancel;
    begin
        while (host_owned) cycle;
        repeat (2) cycle;
        check(cancellations, 1); check(mount_valid, 0); check(sd_rd, 0);
        check(mem_req, 0); check(host_req, 0);
        cancel = 0; cycle;
    end
endtask

task full_image;
    begin
        mount_image;
        for (block_index = 0; block_index < 800; block_index = block_index + 1) begin
            transfer_block; check(sd_lba, block_index); result(0);
        end
        while (!mount_valid) cycle;
        check(writes, 204800); check(host_owned, 1); check(fault, 0);
    end
endtask

initial begin
    // Before host launch, stale physical ACK still prevents release.
    reset_loader; sd_ack = 1; mount_image;
    check(sd_rd, 0); cancel = 1; cycle;
    repeat (6) begin cycle; check(host_owned, 1); check(cancellations, 0); end
    sd_ack = 0; wait_cancel;
    mount_image; check(image_blocks, 800);

    // An exposed request is drained through its real host result.
    reset_loader; mount_image;
    while (!sd_rd) cycle;
    sd_ack = 1; cycle; cancel = 1;
    for (i = 0; i < 256; i = i + 1) begin
        sd_buff_addr = i; sd_buff_wr = 1; cycle;
    end
    sd_buff_wr = 0; sd_ack = 0; cycle;
    while (!host_req) cycle;
    repeat (16) begin cycle; check(host_owned, 1); check(writes, 0); end
    host_ack = 1; cycle;
    repeat (8) begin cycle; check(host_owned, 1); check(writes, 0); end
    host_ack = 0; wait_cancel; check(writes, 0);

    // A failed load can be discarded after the result handshake.
    reset_loader; mount_image; transfer_block; result(1);
    while (!fault) cycle;
    check(host_owned, 1); cancel = 1; wait_cancel; check(writes, 0);

    // A memory request, held ACK and posted drain all keep ownership.
    reset_loader; mem_allow = 0; mount_image; transfer_block; result(0);
    while (!mem_req) cycle;
    held_addr = mem_addr; cancel = 1; cycle;
    repeat (8) begin
        cycle; check(mem_req, 1); check(mem_addr, held_addr);
        check(mem_data, 16'h1234); check(host_owned, 1);
    end
    hold_mem_ack = 1; mem_allow = 1;
    while (!mem_ack) cycle;
    mem_busy = 1;
    repeat (8) begin cycle; check(writes, 1); check(host_owned, 1); end
    hold_mem_ack = 0; repeat (8) cycle; check(host_owned, 1);
    mem_busy = 0; wait_cancel; check(writes, 1);

    // Cancel suppresses a ready mount offer on the same edge.
    reset_loader; full_image;
    cancel = 1; mount_ready = 1; #1; check(mount_valid, 0);
    wait_cancel;

    // Once published, cancellation cannot discard the media owner.
    reset_loader; full_image;
    mount_ready = 1; cycle; mount_ready = 0; cycle;
    cancel = 1;
    repeat (8) begin cycle; check(host_owned, 1); check(cancellations, 0); end
    cancel = 0; release_done = 1; cycle; release_done = 0;
    while (host_owned) cycle;
    check(cancellations, 0);
    mount_image; check(sd_lba, 0); check(host_owned, 1);
    $display("PASS: SWIM II load cancellation and host-result ownership, %0d checks", checks);
    $finish;
end
initial begin #100000000; $fatal(1, "timeout"); end
endmodule
