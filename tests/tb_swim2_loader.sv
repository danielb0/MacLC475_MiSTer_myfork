`timescale 1ns/1ps
module tb_swim2_loader;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = 0;
wire host_owned, mount_valid, mount_hd, mount_readonly, mount_gcr, mount_sides;
wire [12:0] image_blocks;
reg mount_ready = 0, release_done = 0;
wire [31:0] sd_lba;
wire sd_rd;
reg sd_ack = 0, sd_buff_wr = 0;
reg [12:0] sd_buff_addr = 0;
reg [15:0] sd_buff_dout = 0;
wire mem_req;
wire [21:0] mem_addr;
wire [15:0] mem_data;
reg mem_ack = 0, mem_busy = 0, retry = 0;
reg cancel = 0, host_ack = 0, host_error = 0;
wire cancel_done, host_req;
reg host_enable = 1, hold_host_ack = 0;
integer host_delay = 0;
wire fault, busy;
reg model_enable = 1, hold_ack = 0;
integer checks = 0, writes = 0, i, b, delay_count = 0;
reg [21:0] expected_addr = 0;
reg [7:0] seed = 8'h63;
swim2_loader dut (.*);

function [15:0] pattern(input [21:0] address);
    reg [7:0] a, z;
    begin
        a = address[8:1] ^ address[16:9] ^ seed;
        z = address[21:14] ^ address[8:1] ^ 8'ha7;
        pattern = {a, z};
    end
endfunction

task check(input [63:0] actual, input [63:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "check %0d at %0t: got %016h expected %016h", checks, $time, actual, wanted);
    end
endtask
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

always @(posedge clk) begin
    if (!nreset) begin host_ack <= 0; host_delay <= 0; end
    else if (!host_req) begin
        host_delay <= 0;
        if (!hold_host_ack) host_ack <= 0;
    end else if (host_enable && !host_ack) begin
        if (host_delay == 2) host_ack <= 1;
        else host_delay <= host_delay + 1;
    end
    if (model_enable) begin
        if (!nreset) begin mem_ack <= 0; delay_count <= 0; end
        else if (!mem_req) begin
            if (!hold_ack) mem_ack <= 0;
            delay_count <= 0;
        end else if (!mem_ack) begin
            if (delay_count == (expected_addr[3:1] % 3)) begin
                check(mem_addr, expected_addr);
                check(mem_data, pattern(expected_addr));
                check(mount_valid, 0); check(host_owned, 1);
                mem_ack <= 1;
                writes <= writes + 1;
                expected_addr <= expected_addr + 22'd2;
            end else delay_count <= delay_count + 1;
        end
    end
end

task reset_loader;
    begin
        nreset = 0; img_mounted = 0; sd_ack = 0; sd_buff_wr = 0;
        mount_ready = 0; release_done = 0; mem_busy = 0; retry = 0;
        cancel = 0; host_error = 0; host_enable = 1; hold_host_ack = 0;
        model_enable = 1; hold_ack = 0; cycle;
        writes = 0; expected_addr = 0; nreset = 1; cycle;
        check(host_owned, 0); check(mount_valid, 0); check(fault, 0);
    end
endtask

task mount_image(input [63:0] size, input readonly);
    begin
        img_size = size; img_readonly = readonly; img_mounted = 1;
        #1; check(host_owned, size != 0);
        cycle; img_mounted = 0; cycle;
    end
endtask

task host_block(input integer malformed);
    reg [15:0] data;
    integer w, count;
    begin
        while (!sd_rd) cycle;
        sd_ack = 1; cycle; check(sd_rd, 0);
        count = malformed == 1 ? 255 : 256;
        for (w = 0; w < count; w = w + 1) begin
            sd_buff_addr = w;
            if (malformed == 2 && w == 9) sd_buff_addr = 8;
            if (malformed == 3 && w == 9) sd_buff_addr = 13'h109;
            data = pattern({sd_lba[12:0], w[7:0], 1'b0});
            sd_buff_dout = {data[7:0], data[15:8]};
            sd_buff_wr = 1; cycle;
            check(mem_req, 0); check(mount_valid, 0);
        end
        if (malformed == 4) begin sd_buff_addr = 256; cycle; end
        sd_buff_wr = 0;
        repeat (3) begin cycle; check(mem_req, 0); end
        sd_ack = 0; cycle;
    end
endtask

task first_block_geometry(input [63:0] size, input [12:0] blocks,
                          input hd, input gcr, input sides);
    begin
        reset_loader; mount_image(size, 1);
        check(image_blocks, blocks); check(mount_hd, hd); check(mount_gcr, gcr);
        check(mount_sides, sides); check(mount_readonly, 1);
        img_size = 64'd1; img_readonly = 0;
        host_block(0);
        while (writes < 256 || mem_ack) cycle;
        check(sd_lba, 0); check(mount_valid, 0);
        while (!sd_rd) cycle;
        check(sd_lba, 1); check(image_blocks, blocks); check(mount_readonly, 1);
    end
endtask

initial begin
    reset_loader;
    mount_image(0, 0); check(host_owned, 0); check(fault, 0); check(sd_rd, 0);
    mount_image(409601, 0); check(host_owned, 0); check(fault, 1); check(sd_rd, 0);
    mount_image(64'h1000000064000, 0); check(host_owned, 0); check(fault, 1);
    mount_image(737280, 1); check(host_owned, 1); check(image_blocks, 1440);
    check(mount_readonly, 1); check(mount_gcr, 0); check(mount_hd, 0);
    // An owned mount cannot replace metadata or cancel an active transfer.
    img_mounted = 1; img_size = 0; cycle; img_mounted = 0; cycle;
    check(fault, 1); check(host_owned, 1); check(sd_rd, 1); check(image_blocks, 1440);

    for (b = 1; b <= 4; b = b + 1) begin
        reset_loader; mount_image(409600, 0); host_block(b);
        repeat (14) cycle;
        check(fault, 1); check(writes, 0); check(mem_req, 0);
        check(sd_rd, 0); check(host_owned, 1); check(mount_valid, 0);
        retry = 1; cycle; retry = 0;
        host_block(0);
        while (writes < 256 || mem_ack) cycle;
        check(fault, 0); check(mount_valid, 0); check(writes, 256);
    end

    reset_loader;
    model_enable = 0; mem_ack = 1; sd_ack = 1;
    mount_image(409600, 0);
    repeat (5) begin cycle; check(sd_rd, 0); check(mem_req, 0); end
    sd_ack = 0; repeat (5) begin cycle; check(sd_rd, 0); end
    mem_ack = 0; model_enable = 1;
    while (!sd_rd) cycle;
    sd_ack = 1; cycle;
    repeat (5) begin cycle; check(mem_req, 0); check(mount_valid, 0); end
    sd_ack = 0; cycle; repeat (14) cycle;
    check(fault, 1); check(writes, 0);

    // Complete bytes alone cannot authorize memory writes.
    reset_loader; host_enable = 0;
    mount_image(409600, 0); host_block(0);
    repeat (16) begin cycle; check(writes, 0); check(host_owned, 1); end
    check(host_req, 1); check(mount_valid, 0);
    host_error = 1; hold_host_ack = 1; host_enable = 1;
    while (!host_ack) cycle;
    repeat (8) begin cycle; check(writes, 0); check(host_owned, 1); end
    hold_host_ack = 0;
    repeat (8) cycle; check(fault, 1); check(writes, 0);
    host_error = 0; retry = 1; cycle; retry = 0;
    host_block(0);
    while (writes < 256 || mem_ack) cycle;
    check(fault, 0); check(writes, 256);

    reset_loader; mount_image(409600, 0); host_block(0);
    hold_ack = 1;
    while (!mem_ack) cycle;
    repeat (8) begin
        cycle; check(mem_req, 0); check(mem_addr, 0); check(writes, 1);
        check(mem_data, pattern(0)); check(mount_valid, 0);
    end
    hold_ack = 0;
    while (writes < 256 || mem_ack) cycle;
    while (!sd_rd) cycle;
    check(sd_lba, 1);

    first_block_geometry(819200, 1600, 0, 1, 1);
    first_block_geometry(737280, 1440, 0, 0, 1);
    first_block_geometry(1474560, 2880, 1, 0, 1);

    // Full 400K load: every byte and LBA, delayed memory and held final drain.
    reset_loader; mount_image(409600, 0);
    check(image_blocks, 800); check(mount_sides, 0); check(mount_gcr, 1);
    mem_busy = 1;
    for (b = 0; b < 800; b = b + 1) begin
        while (!sd_rd) cycle;
        check(sd_lba, b); host_block(0);
    end
    while (writes < 204800 || mem_req || mem_ack) cycle;
    repeat (8) begin cycle; check(mount_valid, 0); check(host_owned, 1); end
    check(writes, 204800); check(expected_addr, 409600);
    mem_busy = 0; repeat (3) cycle;
    check(mount_valid, 1); check(fault, 0); check(busy, 1);
    repeat (5) cycle; check(mount_valid, 1); check(sd_rd, 0);
    // A stale release signal cannot release a newly published image.
    release_done = 1; mount_ready = 1; cycle; mount_ready = 0;
    repeat (4) cycle; check(host_owned, 1); check(mount_valid, 0); check(busy, 0);
    release_done = 0; cycle; release_done = 1; cycle;
    mem_busy = 1; release_done = 0; repeat (4) cycle; check(host_owned, 1);
    mem_busy = 0; cycle; check(host_owned, 0);
    mount_image(819200, 1); check(host_owned, 1); check(image_blocks, 1600);
    check(mount_gcr, 1); check(mount_sides, 1); check(mount_readonly, 1);
    $display("PASS: SWIM II raw-image loader, %0d checks, complete 400K image", checks);
    $finish;
end
initial begin #100000000; $fatal(1, "timeout"); end
endmodule
