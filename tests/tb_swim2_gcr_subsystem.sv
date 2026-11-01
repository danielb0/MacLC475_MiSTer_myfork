`timescale 1ns/1ps
module tb_swim2_gcr_subsystem;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, guest_reset = 0, ce = 1, sel = 0, write = 0, byte_tick = 0, tach = 0;
reg write_tick = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, mode, setup;
reg mount_valid = 0, mount_hd = 0, mount_readonly = 0, mount_gcr = 1, mount_sides = 0;
reg release_request = 0, write_enable = 1;
reg [23:0] mount_base = 24'h120000;
wire mount_ready, release_done, loaded, motor, side;
wire [23:0] image_base;
wire [6:0] track;
wire [21:0] rd_addr, wr_addr, save_addr;
wire rd_req, wr_req, sd_buf_wr, save_valid, flush_req, read_fault, write_fault, buffer_owned;
wire [15:0] wr_data, sd_buf_data;
wire [7:0] sd_buf_addr;
reg rd_ack = 0, wr_ack = 0, save_ready = 0, flush_ack = 0;
reg [7:0] rd_data = 0;
reg allow_writes = 0;
integer checks = 0, geometry, b, words = 0, rd_delay = 0, wr_delay = 0;
integer expected_base = 0;
reg source_reset = 1, source_ready = 0;
wire [21:0] source_addr;
wire [7:0] source_byte;
reg [7:0] vector [0:781];

swim2_subsystem dut (.*);
floppy_track_encoder source_encoder (
    .clk(clk), .rst(source_reset), .ready(source_ready), .side(side), .sides(mount_sides),
    .track(track), .addr(source_addr), .idata(pattern(source_addr)), .odata(source_byte),
    .oneeds(), .oindex(), .osector(), .wr_byte(1'b0), .wr_mark(1'b0), .wr_mark_sector(4'd0), .wr_end(1'b0)
);
function [7:0] pattern(input integer a);
    pattern = a[7:0] ^ a[15:8] ^ a[21:16] ^ 8'h59;
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
task wr(input [2:0] a, input [7:0] value);
    begin
        addr = a; wdata = value; sel = 1; write = 1;
        cycle; sel = 0; write = 0; cycle; cycle;
    end
endtask
task rd(input [2:0] a, input [7:0] value);
    begin
        addr = a; sel = 1; write = 0; #1; check(rdata, value);
        cycle; sel = 0; cycle;
    end
endtask
task deadline;
    begin write_tick = 1; cycle; write_tick = 0; repeat (12) cycle; end
endtask

always @(posedge clk) begin
    if (!nreset) begin rd_ack <= 0; wr_ack <= 0; rd_delay <= 0; wr_delay <= 0; end
    else begin
        if (rd_req && !rd_ack) begin
            if (rd_delay == 2) begin rd_ack <= 1; rd_data <= pattern(rd_addr); rd_delay <= 0; end
            else rd_delay <= rd_delay + 1;
        end
        if (!rd_req && rd_ack) begin
            if (rd_delay == 2) begin rd_ack <= 0; rd_delay <= 0; end
            else rd_delay <= rd_delay + 1;
        end
        if (wr_req && !wr_ack && allow_writes) begin
            if (wr_delay == 2) begin
                check(wr_addr, expected_base + words * 2);
                check(wr_data, {pattern(expected_base + words*2), pattern(expected_base + words*2+1)});
                check(sd_buf_addr, words); check(sd_buf_data, wr_data); check(sd_buf_wr, 1);
                words = words + 1; wr_ack <= 1; wr_delay <= 0;
            end else wr_delay <= wr_delay + 1;
        end
        if (!wr_req && wr_ack) begin
            if (wr_delay == 2) begin wr_ack <= 0; wr_delay <= 0; end
            else wr_delay <= wr_delay + 1;
        end
    end
end

initial begin
    cycle; nreset = 1; cycle;
    for (geometry = 0; geometry < 2; geometry = geometry + 1) begin
        mount_sides = geometry; expected_base = geometry ? 6144 : 0; words = 0;
        mount_base = geometry ? 24'h340000 : 24'h120000;
        check(mount_ready, 1); mount_valid = 1; cycle; mount_valid = 0; repeat (3) cycle;
        wr(7, 8'h82); wr(4, 8'hfa); wr(4, 8'hf2); // Motor on.
        wr(5, 8'h44); wr(4, 8'hf4);
        if (geometry) wr(7, 8'h20);
        wr(7, 8); repeat (3) cycle;
        check(side, geometry); check(loaded, 1); check(motor, 1);
        source_reset = 0;
        // Every raw GCR byte, including sync, passes the FIFO without mark hunting.
        for (b = 0; b < 782; b = b + 1) begin
            vector[b] = source_byte;
            source_ready = 1; byte_tick = 1; cycle;
            source_ready = 0; byte_tick = 0; repeat (12) cycle;
            rd(0, vector[b]); check(read_fault, 0);
        end
        source_reset = 1;
        wr(6, 8); wr(7, 8'h10); wr(7, 1); wr(6, 1);
        // Format-style raw address + data fields, with no MFM CRC expansion.
        wr(0, vector[0]); wr(7, 8);
        byte_tick = 1; repeat (3) begin cycle; check(dut.tx_take, 0); end
        byte_tick = 0; check(dut.tx_valid, 1); deadline;
        for (b = 1; b < 780; b = b + 1) begin wr(0, vector[b]); deadline; end
        wr(6, 8); check(buffer_owned, 1); check(write_fault, 0);
        check(dut.media.buffer_gcr, 1);
        // Changing codecs and resetting the guest cannot switch the owned RAM.
        wr(5, 0); guest_reset = 1; cycle; guest_reset = 0; ce = 0;
        allow_writes = 1;
        while (!save_valid) cycle;
        check(words, 256); check(save_addr, expected_base); check(buffer_owned, 1);
        save_ready = 1; cycle; save_ready = 0; allow_writes = 0;
        ce = 1; repeat (3) cycle;
        wr(7, 8'h92); wr(5, 8'h44); wr(7, 1); wr(6, 1);
        if (!geometry) begin
            // The unbacked head of a 400K image must not fetch or commit.
            wr(4, 8'hf4); wr(7, 8'h20); wr(0, 8'hff); wr(7, 8); repeat (8) cycle;
            check(side, 1); check(rd_req, 0); check(dut.media.read_enable, 0);
            deadline; check(mode[3], 0); rd(2, 1);
            wr(7, 1); wr(6, 1); wr(6, 8'h20); wr(7, 8); repeat (3) cycle;
            check(side, 0); wr(6, 8);
        end
        // A polynomial CRC token has no qualified raw-GCR implementation.
        wr(2, 0); wr(7, 8); deadline; check(mode[3], 0); rd(2, 1);
        release_request = 1;
        while (!flush_req) cycle;
        flush_ack = 1; cycle; flush_ack = 0; cycle; check(release_done, 1);
        release_request = 0; repeat (8) cycle;
        check(loaded, 0); check(mount_ready, 1);
        guest_reset = 1; cycle; guest_reset = 0; repeat (2) cycle;
    end
    $display("PASS: SWIM II GCR subsystem, %0d checks", checks);
    $finish;
end
initial begin
    #2000000;
    $fatal(1, "timeout");
end
endmodule
