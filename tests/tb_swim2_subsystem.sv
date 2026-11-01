`timescale 1ns/1ps
module tb_swim2_subsystem;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, guest_reset = 0, ce = 1, sel = 0, write = 0, byte_tick = 0, tach = 0;
reg write_tick = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, mode, setup;
reg mount_valid = 0, mount_hd = 1, mount_readonly = 0, release_request = 0, write_enable = 1;
reg mount_gcr = 0, mount_sides = 1;
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
reg allow_reads = 1, allow_writes = 0;
integer checks = 0, b, w, rd_delay = 0, wr_delay = 0, words = 0, saves = 0;
reg [15:0] crc;
reg [7:0] expected;
reg mark;
reg [21:0] held_read;

swim2_subsystem dut (.*);

function [7:0] pattern(input integer a);
    pattern = a[7:0] ^ {7'd0, a[8]} ^ 8'h59;
endfunction

function [15:0] crc_step(input [15:0] c, input [7:0] d);
    integer k;
    reg [15:0] v;
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

task wr(input [2:0] a, input [7:0] value);
    begin
        addr = a; wdata = value; write = 1; sel = 1;
        cycle; sel = 0; write = 0; cycle; cycle;
    end
endtask

task rd(input [2:0] a, input [7:0] value);
    begin
        addr = a; sel = 1; write = 0; #1; check(rdata, value);
        cycle; sel = 0; cycle;
    end
endtask

task command(input [3:0] cmd);
    begin
        if (cmd[3]) wr(7, 8'h20); else wr(6, 8'h20);
        wr(4, 8'hf8 | {5'd0, cmd[2:0]});
        wr(4, 8'hf0 | {5'd0, cmd[2:0]});
    end
endtask

task deadline;
    begin
        byte_tick = 1; write_tick = 1; cycle; byte_tick = 0; write_tick = 0;
        repeat (12) cycle;
    end
endtask

task put(input [2:0] a, input [7:0] value);
    begin wr(a, value); deadline; end
endtask

task marks;
    begin
        wr(1, 8'ha1); wr(1, 8'ha1); wr(7, 8);
        // Rotation alone cannot consume the write FIFO.
        byte_tick = 1; repeat (3) begin cycle; check(dut.mfm_take, 0); end
        byte_tick = 0; check(dut.tx_valid, 1); check(dut.controller.data_path.count, 2);
        ce = 0; write_tick = 1; cycle;
        check(dut.mfm_take, 0); check(dut.controller.data_path.count, 2);
        ce = 1; #1; check(dut.mfm_take, 1); cycle;
        check(dut.mfm_written_strobe, 1); check(dut.controller.data_path.count, 1);
        write_tick = 0; repeat (12) cycle;
        wr(1, 8'ha1); deadline; deadline;
        crc = 16'hcdb4;
    end
endtask

task field_byte(input [7:0] value);
    begin put(0, value); crc = crc_step(crc, value); end
endtask

task crc_token;
    begin put(2, 0); deadline; end
endtask

// Delayed level replies, including delayed ACK release.
always @(posedge clk) begin
    if (!nreset) begin
        rd_ack <= 0; wr_ack <= 0; rd_delay <= 0; wr_delay <= 0;
    end else begin
        if (rd_req && !rd_ack && allow_reads) begin
            if (rd_delay == 2) begin rd_ack <= 1; rd_data <= pattern(rd_addr); rd_delay <= 0; end
            else rd_delay <= rd_delay + 1;
        end
        if (!rd_req && rd_ack) begin
            if (rd_delay == 2) begin rd_ack <= 0; rd_delay <= 0; end
            else rd_delay <= rd_delay + 1;
        end
        if (wr_req && !wr_ack && allow_writes) begin
            if (wr_delay == 2) begin
                check(wr_addr, words * 2);
                check(wr_data, {pattern(words*2), pattern(words*2+1)});
                check(sd_buf_wr, 1); check(sd_buf_addr, words); check(sd_buf_data, wr_data);
                check(image_base, 24'h120000);
                words = words + 1; wr_ack <= 1; wr_delay <= 0;
            end else wr_delay <= wr_delay + 1;
        end
        if (!wr_req && wr_ack) begin
            if (wr_delay == 2) begin wr_ack <= 0; wr_delay <= 0; end
            else wr_delay <= wr_delay + 1;
        end
        if (save_valid && save_ready) begin check(save_addr, 0); saves = saves + 1; end
    end
end

initial begin
    cycle; nreset = 1; cycle;
    check(mount_ready, 1); mount_valid = 1; cycle; mount_valid = 0; repeat (3) cycle;
    wr(7, 8'h82); command(2); wr(4, 8'hf4); wr(7, 8);
    check(loaded, 1); check(motor, 1); check(track, 0); check(side, 0);
    // First complete sector, including mark and CRC tokens, via the bus FIFO.
    crc = 16'hcdb4;
    for (b = 0; b < 828; b = b + 1) begin
        mark = (b >= 158 && b < 161) || (b >= 202 && b < 205);
        if (b < 80) expected = 8'h4e;
        else if (b < 92) expected = 0;
        else if (b < 96) expected = b == 95 ? 8'hfc : 8'hc2;
        else if (b < 146) expected = 8'h4e;
        else if (b < 158) expected = 0;
        else if (b < 161) begin expected = 8'ha1; crc = 16'hcdb4; end
        else if (b == 161) expected = 8'hfe;
        else if (b < 164) expected = 0;
        else if (b == 164) expected = 1;
        else if (b == 165) expected = 2;
        else if (b == 166) expected = crc[15:8];
        else if (b == 167) expected = crc[7:0];
        else if (b < 190) expected = 8'h4e;
        else if (b < 202) expected = 0;
        else if (b < 205) begin expected = 8'ha1; crc = 16'hcdb4; end
        else if (b == 205) expected = 8'hfb;
        else if (b < 718) expected = pattern(b - 206);
        else if (b == 718) expected = crc[15:8];
        else if (b == 719) expected = crc[7:0];
        else expected = 8'h4e;
        if ((b >= 161 && b <= 165) || (b >= 205 && b < 718)) crc = crc_step(crc, expected);
        deadline;
        if (b >= 158) begin
            addr = 7; #1;
            check(rdata, 8'h88 | mark | ((b == 167 || b == 719) ? 0 : 2));
            rd(mark ? 1 : 0, expected);
        end
        check(read_fault, 0);
    end
    // The CPU's popped read tag anchors a normal data-only write.
    wr(6, 8); wr(7, 8'h10); wr(7, 1); wr(6, 1);
    marks; field_byte(8'hfb);
    for (b = 0; b < 512; b = b + 1) field_byte(pattern(b));
    crc_token; check(buffer_owned, 1);
    // A blocked deadline produces the existing underrun and stops ACTION.
    wr(0, 8'h4e); deadline; check(mode[3], 0); rd(2, 1);
    check(wr_req, 1); check(image_base, 24'h120000);
    command(7); repeat (3) cycle;
    guest_reset = 1; cycle; guest_reset = 0; ce = 0;
    mount_valid = 1; mount_base = 24'h340000; mount_hd = 0;
    allow_writes = 1;
    while (!save_valid) cycle;
    check(words, 256); check(mount_ready, 0); check(image_base, 24'h120000);
    repeat (5) begin cycle; check(flush_req, 0); check(save_valid, 1); end
    save_ready = 1; cycle; save_ready = 0; check(saves, 1);
    while (!flush_req) cycle;
    flush_ack = 1; cycle; flush_ack = 0; cycle; check(release_done, 1);
    repeat (5) begin cycle; check(mount_ready, 0); check(loaded, 1); end
    // The old disk must be withdrawn at a drive CE before the queued mount.
    mount_valid = 0; ce = 1;
    repeat (10) cycle;
    check(loaded, 0); check(mount_ready, 1);
    mount_valid = 1; cycle; mount_valid = 0; repeat (3) cycle;
    check(loaded, 1); check(image_base, 24'h340000);

    // A delayed old read cannot supply a new head/context after a seek.
    wr(7, 8'h82); command(2); wr(4, 8'hf4); wr(7, 8);
    allow_reads = 0;
    while (!rd_req) deadline;
    held_read = rd_addr;
    command(1); check(track, 1);
    repeat (4) begin cycle; check(rd_req, 1); check(rd_addr, held_read); end
    allow_reads = 1; repeat (10) cycle;
    check(dut.cache_valid, 0);
    // The unattended pre-seek read filled the FIFO; context preserves its bytes.
    wr(7, 1); wr(6, 1); rd(2, 1); rd(2, 0);
    // Missing payload data consumes each deadline and suppresses CRC-zero.
    allow_reads = 0;
    for (b = 0; b < 720; b = b + 1) begin
        deadline;
        addr = 7; #1;
        if (b == 719) begin check(rdata[7], 1); check(rdata[1], 1); end
        if (rdata[7]) begin
            mark = rdata[0]; addr = mark ? 1 : 0; sel = 1;
            if (b >= 206 && b < 718) begin #1; check(rdata, 0); end
            cycle; sel = 0; cycle;
        end
        if (b >= 206 && b < 718) begin
            check(read_fault, 1); check(dut.encoded_addr, b == 717 ? 9216 : 9216 + b - 205);
        end
    end
    rd(2, 0); check(dut.crc_bad, 1);
    // Host release drains while CE is stopped; remount waits for drive absence.
    ce = 0; release_request = 1; allow_reads = 1;
    while (!flush_req) cycle;
    flush_ack = 1; cycle; flush_ack = 0;
    while (!release_done) cycle;
    check(loaded, 0);
    release_request = 0; mount_valid = 1; mount_base = 24'h560000;
    repeat (8) begin cycle; check(mount_ready, 0); check(loaded, 0); end
    ce = 1;
    while (image_base != 24'h560000) cycle;
    mount_valid = 0; repeat (3) cycle; check(loaded, 1);
    $display("PASS: SWIM II combined subsystem, %0d checks", checks);
    $finish;
end
initial begin
    #2000000;
    $fatal(1, "timeout");
end
endmodule
