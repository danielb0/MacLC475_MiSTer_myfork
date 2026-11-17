`timescale 1ns/1ps
// Accelerated byte deadlines; production clock division is tested separately.
module tb_swim2_catalog;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, guest_reset = 0, ce = 1, sel = 0, write = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, mode, setup;
reg mount_valid = 0, mount_hd = 1, mount_readonly = 0, mount_gcr = 0, mount_sides = 1;
reg [23:0] mount_base = 0;
reg release_request = 0, write_enable = 1;
wire mount_ready, release_done, loaded, motor, side;
wire [23:0] image_base;
wire [6:0] track;
reg [4:0] byte_phase = 0;
wire byte_tick = byte_phase == 31;
wire write_tick = byte_tick;
wire tach = 0;
wire [21:0] rd_addr, wr_addr, save_addr;
wire rd_req, wr_req, sd_buf_wr, save_valid, save_ready, flush_req, flush_ack;
wire read_fault, write_fault, buffer_owned;
wire [15:0] wr_data, sd_buf_data;
wire [7:0] sd_buf_addr;
reg rd_ack = 0, wr_ack = 0;
reg [7:0] rd_data = 0;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
assign EXT_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign EXT_BUS[31:16] = io_din;
wire [31:0] sd_lba;
wire sd_wr, fault, persist_busy;
reg sd_ack = 0, retry = 0;
reg [12:0] sd_buff_addr = 0;
wire [15:0] sd_buff_din;
reg [15:0] token_lo, token_hi, response;
reg [7:0] ram [0:18431], file_data [0:18431], expected_file [0:18431];
reg [15:0] snapshot [0:255];
integer checks = 0, decoded = 0, committed = 0, retired = 0, releases = 0;
integer target_lba = 0, saved_lba = 0, sequence_index, i, j;
integer sequence_lba [0:5];
reg [7:0] seed = 0, saved_seed = 0, got, handshake;
`ifdef SWIM2_TRACE
wire [5:0] trace_events;
wire [31:0] trace_context;
wire [7:0] trace_error;
wire [21:0] trace_decode_addr, trace_commit_addr;
integer trace_decodes = 0, trace_commits = 0, trace_starts = 0;
always @(posedge clk) begin
    if (nreset) begin
        if (trace_events[0]) begin
            check(trace_context[7:3], sequence_lba[sequence_index] % 18 + 1);
            check(trace_context[2], 1); check(trace_context[31:24], mode);
            trace_starts = trace_starts + 1;
        end
        if (trace_events[2] && sel && !write && addr == 2) check(trace_error, rdata);
        if (trace_events[3]) begin
            check(trace_decode_addr, target_lba*512); trace_decodes = trace_decodes + 1;
        end
        if (trace_events[4]) begin
            check(trace_commit_addr, target_lba*512); trace_commits = trace_commits + 1;
        end
    end
end
`endif

swim2_subsystem dut (.*);
swim2_host_persistence persistence (.*, .mount_owned(dut.mounted),
    .image_blocks(13'd2880), .busy(persist_busy));

function [7:0] pattern(input integer offset, input [7:0] value);
    pattern = offset[7:0] ^ {7'd0, offset[8]} ^ value;
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
task wr(input [2:0] a, input [7:0] value);
    begin addr = a; wdata = value; write = 1; sel = 1; cycle; sel = 0; write = 0; cycle; end
endtask
task rd(input [2:0] a, output [7:0] value);
    begin addr = a; write = 0; sel = 1; #1; value = rdata; cycle; sel = 0; cycle; end
endtask
task command(input [3:0] cmd);
    begin
        if (cmd[3]) wr(7, 8'h20); else wr(6, 8'h20);
        wr(4, 8'hf8 | {5'd0, cmd[2:0]}); wr(4, 8'hf0 | {5'd0, cmd[2:0]});
    end
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
    byte_phase <= byte_phase + 5'd1;
    if (nreset) begin
        if (rd_req && !rd_ack) begin
            check(rd_addr < 18432, 1);
            rd_data <= ram[rd_addr]; rd_ack <= 1;
        end else if (!rd_req) rd_ack <= 0;
        if (wr_req && !wr_ack) begin
            check(wr_addr >= target_lba*512 && wr_addr < (target_lba+1)*512, 1);
            check(wr_addr[0], 0);
            check(wr_data, {pattern(wr_addr[8:0], seed), pattern(wr_addr[8:0]+1, seed)});
            ram[wr_addr] <= wr_data[15:8]; ram[wr_addr+1] <= wr_data[7:0]; wr_ack <= 1;
        end else if (!wr_req) wr_ack <= 0;
        if (dut.media.mfm_valid) begin
            check(dut.media.mfm_addr, target_lba*512); decoded <= decoded + 1;
            $display("TRACE: decoded LBA %0d", target_lba);
        end
        if (dut.media.commit_done) begin
            check(dut.media.committed_addr, target_lba*512); committed <= committed + 1;
            $display("TRACE: committed LBA %0d", target_lba);
        end
        if (save_valid && save_ready) begin
            check(save_addr, saved_lba*512); retired <= retired + 1;
        end
        if (release_done) releases <= releases + 1;
    end
end

task next_read;
    integer polls;
    begin
        polls = 0; handshake = 0;
        while (!handshake[7]) begin
            rd(7, handshake); polls = polls + 1;
            if (polls > 3000) $fatal(1, "read FIFO timeout");
        end
        check(handshake[5], 0);
        rd(handshake[0] ? 1 : 0, got);
    end
endtask
task read_anchor(input integer lba, input stop_action);
    integer marks, bytes, field_index;
    reg found;
    reg [7:0] chrn [0:5];
    begin
        wr(6, 8'h18); wr(7, 1); wr(6, 1); rd(2, got);
        if (lba >= 18) wr(7, 8'h20); else wr(6, 8'h20);
        wr(4, 8'hf4); wr(7, 8);
        marks = 0; bytes = 0; found = 0;
        while (!found) begin
            next_read; bytes = bytes + 1;
            if (handshake[0] && got == 8'ha1) marks = marks + 1;
            else begin
                if (marks >= 3 && got == 8'hfe) begin
                    for (field_index = 0; field_index < 6; field_index = field_index + 1) begin
                        next_read; chrn[field_index] = got;
                    end
                    if (chrn[2] == lba % 18 + 1) begin
                        check(chrn[0], 0); check(chrn[1], lba / 18); check(chrn[3], 2);
                        check(handshake[1], 0);
                        check(dut.write_sector_valid, 1); check(dut.write_sector, lba % 18 + 1);
                        found = 1;
                    end
                end
                marks = 0;
            end
            if (bytes > 16000) $fatal(1, "ID search timeout for LBA %0d", lba);
        end
        $display("TRACE: read-ID anchor LBA %0d", lba);
        if (stop_action) wr(6, 8);
    end
endtask
task put(input [2:0] a, input [7:0] value);
    begin
        rd(7, handshake);
        while (!handshake[7]) rd(7, handshake);
        check(handshake[5], 0); check(mode[3], 1); wr(a, value);
    end
endtask
task start_write;
    begin
        wr(6, 8); rd(2, got); wr(7, 16); wr(7, 1); wr(6, 1);
        wr(1, 8'ha1); wr(1, 8'ha1); wr(7, 8);
    end
endtask
task write_sector;
    integer offset;
    begin
        $display("TRACE: requested LBA %0d seed %02h", target_lba, seed);
        start_write; put(1, 8'ha1); put(0, 8'hfb);
        for (offset = 0; offset < 512; offset = offset + 1) put(0, pattern(offset, seed));
        put(2, 0);
        while (decoded == sequence_index) begin
            check(mode[3], 1); cycle;
        end
        wr(6, 8); rd(2, got); check(got, 0); check(write_fault, 0);
    end
endtask
task host_transfer;
    integer word_index;
    begin
        while (!sd_wr) cycle;
        saved_lba = target_lba; saved_seed = seed;
        check(sd_lba, saved_lba);
        word_io(16'h08, response); check(response, 16'h5357);
        word_io(0, response); check(response, 16'h010b);
        word_io(0, token_lo); word_io(0, token_hi);
        word_io(0, response); check(response, saved_lba);
        word_io(0, response); check(response, 0);
        word_io(0, response); check(response, 6); close_io;
        sd_ack = 1; cycle;
        for (word_index = 0; word_index < 256; word_index = word_index + 1) begin
            sd_buff_addr = word_index; cycle;
            check(sd_buff_din, {pattern(word_index*2+1, saved_seed), pattern(word_index*2, saved_seed)});
            snapshot[word_index] = sd_buff_din;
        end
        sd_ack = 0; cycle;
        while (!persistence.durable_req) cycle;
    end
endtask
task host_complete(input integer done_index);
    integer word_index;
    begin
        check(sd_lba, saved_lba); check(retired, done_index);
        for (word_index = 0; word_index < 256; word_index = word_index + 1) begin
            sd_buff_addr = word_index; cycle; check(sd_buff_din, snapshot[word_index]);
            file_data[saved_lba*512+word_index*2] = snapshot[word_index][7:0];
            file_data[saved_lba*512+word_index*2+1] = snapshot[word_index][15:8];
        end
        word_io(16'h09, response); word_io(token_lo, response); word_io(token_hi, response);
        word_io(0, response); close_io;
        // The next sector's commit may start as soon as this save retires.
        while (retired == done_index) cycle;
        check(fault, 0); check(retired, done_index+1);
        $display("TRACE: durable LBA %0d", saved_lba);
    end
endtask

initial begin
    for (i = 0; i < 18432; i = i + 1) begin
        ram[i] = 8'ha5; file_data[i] = 8'ha5; expected_file[i] = 8'ha5;
    end
    sequence_lba[0] = 26; sequence_lba[1] = 28; sequence_lba[2] = 30;
    sequence_lba[3] = 29; sequence_lba[4] = 30; sequence_lba[5] = 2;
    repeat (4) cycle; nreset = 1; cycle;
    check(mount_ready, 1); mount_valid = 1; cycle; mount_valid = 0; repeat (4) cycle;
    wr(7, 8'h82);
    for (sequence_index = 0; sequence_index < 6; sequence_index = sequence_index + 1) begin
        target_lba = sequence_lba[sequence_index]; seed = 8'h60 + sequence_index;
        read_anchor(target_lba, 1);
        // Write while the previous sector still awaits its host result. The
        // host's write and fsync take milliseconds; the guest must not see
        // underrun (.Sony wrUnderrun, -74) for the next sector meanwhile.
        write_sector;
        if (sequence_index > 0) begin
            // Decoded, but its commit waits for the persistence snapshot.
            check(committed, sequence_index); check(buffer_owned, 1);
            check(retired, sequence_index-1);
            $display("TRACE: write accepted during host save of LBA %0d", saved_lba);
            host_complete(sequence_index-1);
        end
        host_transfer;
        if (sequence_index == 5) begin
            // A guest eject must wait for the last durable host result.
            command(7); repeat (10) cycle;
            check(loaded, 1); check(releases, 0); check(save_valid, 1);
            host_complete(5);
        end
        for (i = 0; i < 512; i = i + 1) expected_file[target_lba*512+i] = pattern(i, seed);
    end
    while (loaded) cycle;
    check(releases, 1); check(decoded, 6); check(committed, 6); check(retired, 6);
`ifdef SWIM2_TRACE
    check(trace_decodes, 6); check(trace_commits, 6); check(trace_starts, 6);
`endif
    for (i = 0; i < 18432; i = i + 1) begin
        check(file_data[i], expected_file[i]); check(ram[i], expected_file[i]);
        ram[i] = file_data[i];
    end
    while (!mount_ready) cycle;
    mount_valid = 1; cycle; mount_valid = 0; repeat (4) cycle;
    for (sequence_index = 0; sequence_index < 6; sequence_index = sequence_index + 1) begin
        read_anchor(sequence_lba[sequence_index], 0);
        // The next marked field is this ID's data field.
        got = 0;
        while (got != 8'hfb || handshake[0]) next_read;
        for (j = 0; j < 512; j = j + 1) begin
            next_read; check(got, expected_file[sequence_lba[sequence_index]*512+j]);
        end
        next_read; next_read; check(handshake[1], 0); check(read_fault, 0);
        wr(6, 8);
    end
    $display("PASS: SWIM II controller catalog writes, busy saves, retry and guest eject/reload, %0d checks", checks);
    $finish;
end
initial begin #80000000; $fatal(1, "timeout"); end
endmodule
