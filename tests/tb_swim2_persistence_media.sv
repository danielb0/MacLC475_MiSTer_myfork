`timescale 1ns/1ps
module tb_swim2_persistence_media;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, guest_reset = 0, context_changed = 0;
reg mount_valid = 0, mount_hd = 1, mount_readonly = 0;
reg mount_gcr = 0, mount_sides = 1, gcr = 0;
wire media_gcr, media_sides, gcr_byte, gcr_mark;
wire [3:0] gcr_mark_sector;
reg [23:0] mount_base = 24'h120000;
wire mount_ready, mounted, media_hd, write_protect, release_done, releasing, media_changed;
wire [23:0] image_base;
reg release_request = 0, selected = 1, motor = 1, write_active = 1, write_enable = 1;
reg read_busy = 0;
wire read_enable, read_discard;
reg [6:0] track = 0;
reg side = 0;
reg [4:0] anchor_sector = 1;
reg anchor_valid = 1;
reg [7:0] write_data = 0;
reg write_mark = 0, write_strobe = 0, write_tick = 0;
wire stream_enable, write_fault, buffer_owned, wr_req, sd_buf_wr, save_valid, flush_req;
wire [21:0] wr_addr, save_addr;
wire [15:0] wr_data, sd_buf_data;
wire [7:0] sd_buf_addr;
reg wr_ack = 0;
wire save_ready, flush_ack;
reg [12:0] image_blocks = 2880;
wire [31:0] sd_lba;
wire sd_wr, fault, persist_busy;
wire [15:0] sd_buff_din;
reg sd_ack = 0, retry = 0;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0, response, token_lo, token_hi;
assign EXT_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign EXT_BUS[31:16] = io_din;
reg [12:0] sd_buff_addr = 0;
reg [15:0] memory [0:255];
reg [15:0] cached_file [0:255];
reg [15:0] durable_file [0:255];
reg [7:0] seed = 8'h59;
reg [15:0] crc;
integer checks = 0, i, j, notifications = 0, releases = 0;

swim2_media media (.*);
swim2_host_persistence persistence (.*, .mount_owned(mounted), .busy(persist_busy));

function [7:0] pattern(input integer offset);
    pattern = offset[7:0] ^ {7'd0, offset[8]} ^ seed;
endfunction

function [15:0] crc_step(input [15:0] c, input [7:0] d);
    reg [15:0] v;
    integer k;
    begin
        v = c;
        for (k = 7; k >= 0; k = k - 1)
            if (v[15] ^ d[k]) v = {v[14:0], 1'b0} ^ 16'h1021;
            else v = {v[14:0], 1'b0};
        crc_step = v;
    end
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

task word_io(input [15:0] value, output [15:0] reply);
    begin
        io_enable = 1; io_strobe = 1; io_din = value; cycle;
        io_strobe = 0; cycle; reply = EXT_BUS[15:0];
    end
endtask

task close_io;
    begin io_enable = 0; cycle; check(EXT_BUS[32], 0); end
endtask

always @(posedge clk) begin
    if (!nreset) wr_ack <= 0;
    else if (wr_req && !wr_ack) begin
        memory[wr_addr[8:1]] <= wr_data;
        wr_ack <= 1;
    end else if (!wr_req) wr_ack <= 0;
    if (nreset && save_valid && save_ready) notifications = notifications + 1;
    if (nreset && release_done) releases = releases + 1;
end

task send(input [7:0] value, input mark);
    begin
        write_data = value; write_mark = mark; write_strobe = 1;
        cycle; write_strobe = 0; cycle;
    end
endtask

task write_sector;
    begin
        send(8'ha1, 1); send(8'ha1, 1); send(8'ha1, 1);
        crc = 16'hcdb4;
        send(8'hfb, 0); crc = crc_step(crc, 8'hfb);
        for (i = 0; i < 512; i = i + 1) begin
            send(pattern(i), 0); crc = crc_step(crc, pattern(i));
        end
        send(crc[15:8], 0); send(crc[7:0], 0);
        check(buffer_owned, 1);
        while (!sd_wr) cycle;
        check(save_addr, 0); check(sd_lba, 0);
        for (i = 0; i < 256; i = i + 1)
            check(memory[i], {pattern(i*2), pattern(i*2+1)});
    end
endtask

task host_transfer;
    begin
        while (!sd_wr) cycle;
        word_io(16'h08, response); check(response, 16'h5357);
        word_io(0, response); check(response, 16'h010b);
        word_io(0, token_lo); word_io(0, token_hi);
        word_io(0, response); check(response, sd_lba[15:0]);
        word_io(0, response); check(response, sd_lba[31:16]);
        word_io(0, response); check(response, 6); close_io;
        sd_ack = 1; cycle;
        for (j = 0; j < 256; j = j + 1) begin
            sd_buff_addr = j; cycle;
            check(sd_buff_din, {pattern(j*2+1), pattern(j*2)});
            cached_file[j] = sd_buff_din;
            check(save_valid, 1); check(buffer_owned, 0); check(save_ready, 0); check(flush_ack, 0);
        end
        sd_ack = 0; cycle;
        while (!persistence.durable_req) cycle;
    end
endtask

task host_complete(input fail_write);
    begin
        word_io(16'h09, response); word_io(token_lo, response); word_io(token_hi, response);
        check(save_valid, 1); check(buffer_owned, 0); check(mounted, 1);
        if (!fail_write)
            for (j = 0; j < 256; j = j + 1) durable_file[j] = cached_file[j];
        word_io({15'd0, fail_write}, response); close_io;
        repeat (5) cycle;
        check(fault, fail_write);
        cycle;
    end
endtask

initial begin
    for (i = 0; i < 256; i = i + 1) durable_file[i] = 16'hdead;
    cycle; nreset = 1; cycle;
    mount_valid = 1; cycle; mount_valid = 0; cycle;
    write_sector;
    // Guest reset and host mount offers cannot replace the pending owner.
    guest_reset = 1; context_changed = 1; release_request = 1;
    mount_valid = 1; mount_base = 24'h340000;
    host_transfer;
    check(durable_file[0], 16'hdead); check(image_base, 24'h120000);
    check(notifications, 0); check(mount_ready, 0);
    host_complete(1);
    repeat (8) begin
        cycle; check(save_valid, 1); check(buffer_owned, 0); check(mounted, 1);
        check(mount_ready, 0); check(release_done, 0); check(flush_ack, 0);
    end
    check(notifications, 0);
    retry = 1; cycle; retry = 0;
    host_transfer; host_complete(0);
    while (releases == 0) cycle;
    check(notifications, 1); check(mounted, 0);
    // Reload the modeled durable file, discarding volatile image RAM.
    for (i = 0; i < 256; i = i + 1) begin
        memory[i] = 0;
        memory[i] = {durable_file[i][7:0], durable_file[i][15:8]};
        check(memory[i], {pattern(i*2), pattern(i*2+1)});
    end
    mount_valid = 0; release_request = 0; guest_reset = 0; context_changed = 0;
    repeat (3) cycle; check(mount_ready, 1);
    // A new DD image uses a fresh snapshot, with no bytes from the old mount.
    mount_hd = 0; image_blocks = 1440; mount_valid = 1;
    cycle; mount_valid = 0; cycle; seed = 8'h36;
    write_sector; host_transfer; host_complete(0);
    check(notifications, 2); check(buffer_owned, 0); check(image_base, 24'h340000);
    for (i = 0; i < 256; i = i + 1)
        check(durable_file[i], {pattern(i*2+1), pattern(i*2)});
    check(write_fault, 0);
    $display("PASS: SWIM II media persistence, %0d checks", checks);
    $finish;
end
initial begin #1000000; $fatal(1, "timeout"); end
endmodule
