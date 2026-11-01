`timescale 1ns/1ps
module tb_swim2_storage #(parameter HD = 0);
localparam BLOCKS = HD ? 2880 : 1440;
localparam BYTES = BLOCKS * 512;
localparam SPT = HD ? 18 : 9;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, init = 0;
reg [15:0] sdram_sz = 16'h8003;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
assign EXT_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign EXT_BUS[31:16] = io_din;
reg img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = BYTES;
wire host_owned, mount_valid, mount_ready, mount_hd, mount_readonly, mount_gcr, mount_sides;
wire [12:0] image_blocks;
wire release_done;
wire host_release_request;
reg rd_req = 0;
reg [21:0] rd_addr = 0;
wire rd_ack;
wire [7:0] rd_data;
wire wr_req, wr_ack;
wire [21:0] wr_addr, save_addr;
wire [15:0] wr_data, sd_buf_data;
wire [7:0] sd_buf_addr;
wire sd_buf_wr, save_valid, save_ready, flush_req, flush_ack;
wire [31:0] sd_lba;
wire sd_rd, sd_wr;
reg sd_ack = 0, sd_buff_wr = 0;
reg [12:0] sd_buff_addr = 0;
reg [15:0] sd_buff_dout = 0;
wire [15:0] sd_buff_din;
reg loader_retry = 0, save_retry = 0;
reg loader_cancel = 0;
wire cancel_done;
wire loading, persist_busy, fault, memory_ready, mem_busy;
reg cpu_req = 0, cpu_we = 0;
reg [26:2] cpu_addr = 25'h100;
reg [3:0] cpu_be = 4'hf;
reg [31:0] cpu_wdata = 0;
wire cpu_ack;
wire [31:0] cpu_rdata;
wire beat_req, beat_we;
wire [26:2] beat_addr;
wire [3:0] beat_be;
wire [31:0] beat_wdata;
reg beat_ack = 0;
reg [31:0] beat_rdata = 0;
wire beat_busy;
reg beat_line_pending = 0;
reg posted = 0, hold_drain = 0;
reg [26:2] posted_addr;
reg [3:0] posted_be;
reg [31:0] posted_data;
integer posted_delay = 0;
reg [31:0] ram [0:BYTES/4-1];
reg [7:0] file_data [0:BYTES-1];
reg [7:0] expected_file [0:BYTES-1];
reg [15:0] transfer_buffer [0:255];
localparam [26:2] IMAGE_BASE = 25'h0900000;
integer checks = 0, load_words = 0, accepted = 0, releases = 0, saves = 0;
integer target_lba = 0, decoded = 0, committed = 0, sequence_index;
integer sequence_lba [0:5];
integer i, b, w, lane, index;
reg [15:0] response, token_lo, token_hi, read_token_lo, read_token_hi, crc;
reg guest_reset = 0, context_changed = 0, release_request = 0;
wire mounted, media_hd, media_gcr, media_sides, write_protect;
wire [23:0] image_base;
wire releasing, media_changed, read_enable, read_discard, stream_enable, write_fault, buffer_owned;
wire gcr_byte, gcr_mark;
wire [3:0] gcr_mark_sector;
reg selected = 1, motor = 1, write_active = 1, write_enable = 1;
reg [6:0] track = 0;
reg side = 0;
reg [4:0] anchor_sector = 1;
reg anchor_valid = 1;
reg [7:0] write_data = 0;
reg write_mark = 0, write_strobe = 0, write_tick = 0;
wire read_busy = rd_req || rd_ack;
reg [7:0] seed = 8'h35;
reg fail_read_once = 1;
reg [31:0] old_read_token;

assign beat_busy = posted || hold_drain;
swim2_storage dut (.*, .release_request(host_release_request));
swim2_media media (.*, .release_request(release_request || host_release_request), .mount_base(24'd0), .gcr(1'b0));

function [7:0] original(input integer address);
    original = address[7:0] ^ address[16:9] ^ 8'h9b;
endfunction
function [7:0] written(input integer address);
    written = address[7:0] ^ {7'd0, address[8]} ^ seed;
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
task word_io(input [15:0] value, output [15:0] reply);
    begin
        io_enable = 1; io_strobe = 1; io_din = value; cycle;
        io_strobe = 0; cycle; reply = EXT_BUS[15:0];
    end
endtask
task close_io;
    begin io_enable = 0; cycle; check(EXT_BUS[32], 0); end
endtask

task host_control(input [15:0] action);
    reg [15:0] lo, hi;
    begin
        word_io(16'h0c, response); check(response, 16'h5343);
        word_io(0, response); check(response[0], 1);
        word_io(0, lo); word_io(0, hi);
        word_io(0, response); word_io(0, response);
        word_io(0, response); check(response, 6); close_io;
        word_io(16'h0d, response); word_io(lo, response);
        word_io(hi, response); word_io(action, response); close_io;
    end
endtask

always @(posedge clk) begin
    beat_ack <= 0;
    if (posted && !hold_drain) begin
        if (posted_delay == 0) begin
            index = posted_addr - IMAGE_BASE;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (posted_be[3-lane]) ram[index][(3-lane)*8 +: 8] <= posted_data[(3-lane)*8 +: 8];
            posted <= 0;
        end else posted_delay <= posted_delay - 1;
    end
    if (beat_req && !beat_ack && !posted) begin
        beat_ack <= 1;
        accepted <= accepted + 1;
        if (beat_addr == cpu_addr && !beat_we) beat_rdata <= 32'h13579bdf;
        else begin
            check(beat_addr >= IMAGE_BASE, 1); check(beat_addr < IMAGE_BASE + BYTES/4, 1);
            if (beat_we) begin
                posted <= 1; posted_addr <= beat_addr;
                posted_be <= beat_be; posted_data <= beat_wdata;
                posted_delay <= 2;
                if (!mounted) begin
                    check(beat_be, load_words[0] ? 4'b0011 : 4'b1100);
                    check(beat_addr, IMAGE_BASE + (load_words >> 1));
                    check(beat_wdata[31:16], {file_data[load_words*2], file_data[load_words*2+1]});
                    load_words <= load_words + 1;
                end
            end else beat_rdata <= ram[beat_addr - IMAGE_BASE];
        end
    end
    if (nreset && save_valid && save_ready) saves <= saves + 1;
    if (nreset && release_done) releases <= releases + 1;
    if (nreset && media.mfm_valid) begin
        check(media.mfm_addr, target_lba * 512);
        decoded <= decoded + 1;
        $display("TRACE: decoded LBA %0d seed %02h", target_lba, seed);
    end
    if (nreset && media.commit_done) begin
        check(media.committed_addr, target_lba * 512);
        committed <= committed + 1;
        $display("TRACE: committed LBA %0d", target_lba);
    end
    if (nreset && save_valid) check(save_addr, target_lba * 512);
end

task load_image;
    begin
        load_words = 0;
        img_mounted = 1; #1; check(host_owned, 1); cycle; img_mounted = 0;
        for (b = 0; b < BLOCKS; b = b + 1) begin
            while (!sd_rd) cycle;
            check(sd_lba, b); check(sd_wr, 0); check(mounted, 0); check(host_owned, 1);
            read_metadata;
            load_transfer;
            if (fail_read_once && b == 0) begin
                old_read_token = {read_token_hi, read_token_lo};
                read_result(1);
                while (!fault) cycle;
                check(load_words, 0); check(host_owned, 1); check(mounted, 0);
                host_control(2);
                while (!sd_rd) cycle;
                read_metadata;
                check({read_token_hi, read_token_lo} != old_read_token, 1);
                load_transfer;
                word_io(16'h0b, response); word_io(old_read_token[15:0], response);
                word_io(old_read_token[31:16], response); word_io(0, response); close_io;
                repeat (12) cycle;
                check(load_words, 0); check(mounted, 0); check(host_owned, 1);
                fail_read_once = 0;
            end
            read_result(0);
        end
        while (load_words < BYTES/2 || posted) cycle;
        while (!mounted) cycle;
        check(image_blocks, BLOCKS); check(mount_gcr, 0); check(mount_hd, HD);
        check(mount_sides, 1); check(host_owned, 1); check(fault, 0);
    end
endtask

task load_transfer;
    begin
        sd_ack = 1; cycle; check(sd_rd, 0);
        for (w = 0; w < 256; w = w + 1) begin
            sd_buff_addr = w;
            sd_buff_dout = {file_data[b*512+w*2+1], file_data[b*512+w*2]};
            sd_buff_wr = 1; cycle; check(sd_lba, b);
        end
        sd_buff_wr = 0; repeat (3) cycle; check(sd_lba, b);
        sd_ack = 0; cycle;
    end
endtask

task read_metadata;
    begin
        word_io(16'h0a, response); check(response, 16'h5352);
        word_io(0, response); check(response, 16'h010b);
        word_io(0, read_token_lo); word_io(0, read_token_hi);
        word_io(0, response); check(response, sd_lba[15:0]);
        word_io(0, response); check(response, sd_lba[31:16]);
        word_io(0, response); check(response, 6); close_io;
    end
endtask

task read_result(input error);
    begin
        word_io(16'h0b, response); word_io(read_token_lo, response); word_io(read_token_hi, response);
        word_io({15'd0, error}, response); close_io;
    end
endtask

task fetch(input [21:0] address, input [7:0] expected);
    begin
        rd_addr = address; rd_req = 1;
        while (!rd_ack) cycle;
        check(rd_data, expected); rd_req = 0;
        while (rd_ack) cycle;
    end
endtask
task send(input [7:0] value, input mark);
    begin
        write_data = value; write_mark = mark; write_strobe = 1;
        cycle; write_strobe = 0; cycle;
    end
endtask
task write_sector;
    begin
        $display("TRACE: requested LBA %0d seed %02h", target_lba, seed);
        send(8'ha1, 1); send(8'ha1, 1); send(8'ha1, 1);
        crc = 16'hcdb4; send(8'hfb, 0); crc = crc_step(crc, 8'hfb);
        for (i = 0; i < 512; i = i + 1) begin
            send(written(i), 0); crc = crc_step(crc, written(i));
        end
        send(crc[15:8], 0); send(crc[7:0], 0);
        check(buffer_owned, 1);
        while (!sd_wr) cycle;
        while (posted) cycle;
        for (i = 0; i < 128; i = i + 1)
            check(ram[target_lba*128+i], {written(i*4), written(i*4+1), written(i*4+2), written(i*4+3)});
    end
endtask
task save_transfer;
    begin
        while (!sd_wr) cycle;
        word_io(16'h08, response); check(response, 16'h5357);
        word_io(0, response); check(response, 16'h010b);
        word_io(0, token_lo); word_io(0, token_hi);
        word_io(0, response); check(response, target_lba);
        word_io(0, response); check(response, 0);
        word_io(0, response); check(response, 6); close_io;
        sd_ack = 1; cycle;
        for (w = 0; w < 256; w = w + 1) begin
            sd_buff_addr = w; cycle;
            check(sd_buff_din, {written(w*2+1), written(w*2)});
            transfer_buffer[w] = sd_buff_din;
            check(sd_lba, target_lba); check(host_owned, 1); check(buffer_owned, 1);
        end
        sd_ack = 0; cycle;
        repeat (8) cycle; check(save_ready, 0); check(flush_ack, 0);
    end
endtask
task save_result(input error);
    begin
        if (!error) for (w = 0; w < 256; w = w + 1) begin
            file_data[target_lba*512+w*2] = transfer_buffer[w][7:0];
            file_data[target_lba*512+w*2+1] = transfer_buffer[w][15:8];
        end
        word_io(16'h09, response); word_io(token_lo, response); word_io(token_hi, response);
        word_io({15'd0, error}, response); close_io;
        repeat (6) cycle;
        if (!error) $display("TRACE: durable LBA %0d", target_lba);
    end
endtask

initial begin
    for (i = 0; i < BYTES; i = i + 1) begin
        file_data[i] = original(i);
        expected_file[i] = original(i);
    end
    repeat (4) cycle; nreset = 1; repeat (4) cycle;
    // Cancel an active load only after its checked host result drains.
    img_mounted = 1; cycle; img_mounted = 0;
    while (!sd_rd) cycle;
    b = 0; read_metadata;
    host_control(1);
    repeat (8) begin cycle; check(host_owned, 1); check(cancel_done, 0); end
    load_transfer;
    repeat (8) begin cycle; check(host_owned, 1); check(load_words, 0); end
    read_result(1);
    while (host_owned) cycle;
    check(load_words, 0); check(mounted, 0); check(releases, 0);
    repeat (8) cycle;
    load_image;
    for (i = 0; i < BYTES/4; i = i + 1)
        check(ram[i], {original(i*4), original(i*4+1), original(i*4+2), original(i*4+3)});
    fetch(0, original(0)); fetch(1, original(1)); fetch(2, original(2)); fetch(3, original(3));
    fetch(BYTES-1, original(BYTES-1));
    write_sector;
    guest_reset = 1; context_changed = 1; host_control(1);
    save_transfer; save_result(1);
    repeat (8) begin
        cycle; check(host_owned, 1); check(mounted, 1); check(buffer_owned, 1);
        check(releases, 0); check(flush_ack, 0);
    end
    check(saves, 0); check(file_data[0], original(0)); check(fault, 1);
    host_control(3);
    save_transfer; save_result(0);
    while (host_owned) cycle;
    check(releases, 1); check(saves, 1); check(mounted, 0); check(fault, 0);
    release_request = 0; guest_reset = 0; context_changed = 0;
    repeat (8) cycle;
    for (i = 0; i < BYTES/4; i = i + 1) ram[i] = 0;
    load_image;
    for (i = 0; i < 512; i = i + 1) fetch(i, written(i));
    fetch(512, original(512)); fetch(BYTES-1, original(BYTES-1));
    check(write_fault, 0); check(fault, 0);
    for (i = 0; i < 512; i = i + 1) expected_file[i] = written(i);
    // Synthetic catalog-sector sequence; actual guest ordering is unknown.
    sequence_lba[0] = 2; sequence_lba[1] = 26; sequence_lba[2] = 28;
    sequence_lba[3] = 30; sequence_lba[4] = 29; sequence_lba[5] = 30;
    for (sequence_index = 0; sequence_index < 6; sequence_index = sequence_index + 1) begin
        target_lba = sequence_lba[sequence_index];
        write_active = 0; context_changed = 1; cycle;
        track = target_lba / (SPT*2);
        side = (target_lba / SPT) % 2;
        anchor_sector = target_lba % SPT + 1;
        seed = 8'h60 + sequence_index;
        context_changed = 0; write_active = 1; cycle;
        write_sector;
        save_transfer;
        // A delayed durable result must retain the exact sector and payload.
        repeat (100) begin
            cycle; check(save_ready, 0); check(buffer_owned, 1);
            check(sd_lba, target_lba);
        end
        if (sequence_index == 3) begin
            save_result(1); check(fault, 1);
            host_control(3); save_transfer;
        end
        save_result(0);
        while (buffer_owned || persist_busy) cycle;
        for (i = 0; i < 512; i = i + 1) expected_file[target_lba*512+i] = written(i);
        check(decoded, sequence_index + 2); check(committed, sequence_index + 2);
        check(saves, sequence_index + 2); check(write_fault, 0); check(fault, 0);
    end
    // Release without a guest/global reset, then reload every saved sector.
    write_active = 0; host_control(1);
    while (host_owned) cycle;
    check(releases, 2); check(mounted, 0);
    for (i = 0; i < BYTES; i = i + 1) check(file_data[i], expected_file[i]);
    repeat (8) cycle;
    for (i = 0; i < BYTES/4; i = i + 1) ram[i] = 0;
    load_image;
    for (i = 0; i < BYTES/4; i = i + 1)
        check(ram[i], {expected_file[i*4], expected_file[i*4+1], expected_file[i*4+2], expected_file[i*4+3]});
    for (sequence_index = 0; sequence_index < 6; sequence_index = sequence_index + 1)
        for (i = 0; i < 512; i = i + 1)
            fetch(sequence_lba[sequence_index]*512+i, expected_file[sequence_lba[sequence_index]*512+i]);
    check(decoded, 7); check(committed, 7); check(saves, 7); check(fault, 0);
    $display("PASS: SWIM II storage load/write/save/release/reload, %0d checks", checks);
    $finish;
end
initial begin #200000000; $fatal(1, "timeout"); end
endmodule
