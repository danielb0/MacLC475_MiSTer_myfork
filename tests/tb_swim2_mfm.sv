`timescale 1ns/1ps
module tb_swim2_mfm;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, ce = 1, sel = 0, write = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, setup, mode, tx_data;
wire tx_mark, tx_crc, tx_valid, tx_take;
reg [6:0] track = 0;
reg side = 0, hd = 0;
reg read_tick = 0, write_tick = 0, media_reset = 1;
wire [21:0] image_addr;
wire [7:0] media_data;
wire media_mark, media_crc_zero, media_needs, media_index;
wire [4:0] media_sector, write_sector;
wire write_sector_valid;
wire [7:0] written_data;
wire written_mark, written_strobe;
wire sector_valid, reject, amark;
wire [4:0] decoded_sector;
wire [21:0] decoded_addr;
reg [8:0] buf_addr = 0;
wire [7:0] buf_data;
wire [8:0] commit_buf_addr;
wire commit_busy, commit_done, commit_req, commit_ready, commit_rejected;
wire [21:0] commit_addr, committed_addr;
wire [15:0] commit_data;
reg commit_ack = 0;
reg decoder_reset = 1, corrupt = 0;
integer checks = 0, commits = 0, rejects = 0, ids = 0;
integer density, cylinder, head, s, b, test_case;
integer before_commits, before_rejects, target_sector;
integer popped = 0;
reg read_synced = 0;
reg [15:0] reference_crc;
reg [7:0] byte_value;

function [7:0] pattern(input [21:0] a);
    pattern = a[7:0] ^ a[15:8] ^ {2'd0, a[21:16]} ^ 8'h5a;
endfunction

// Bit-serial reference, initialized from FFFF before the actual A1 bytes.
function [15:0] reference_step(input [15:0] c, input [7:0] d);
    reg [15:0] v;
    integer k;
    begin
        v = c;
        for (k = 7; k >= 0; k = k - 1)
            if (v[15] ^ d[k]) v = {v[14:0], 1'b0} ^ 16'h1021;
            else v = {v[14:0], 1'b0};
        reference_step = v;
    end
endfunction

function [21:0] sector_base(input integer sector_number);
    sector_base = ((track * 2 + side) * (hd ? 18 : 9) + sector_number - 1) * 512;
endfunction

swim2 controller (
    .clk(clk), .nreset(nreset), .ce(ce), .sel(sel), .write(write), .addr(addr),
    .wdata(wdata), .rdata(rdata), .phase_in(4'd0), .zero_count(8'd0),
    .rddata(1'b0), .sense(1'b0), .rx_valid(read_tick), .rx_data(media_data),
    .context_changed(1'b0),
    .rx_mark(media_mark), .rx_crc_zero(media_crc_zero), .rx_sector(media_sector),
    .rx_short(1'b0), .rx_long(1'b0), .tx_fault(1'b0), .tx_take(tx_take), .tx_data(tx_data),
    .tx_mark(tx_mark), .tx_crc(tx_crc), .tx_valid(tx_valid),
    .phase_out(), .phase_oe(), .setup(setup), .mode(mode),
    .write_late(), .write_early(), .write_sector(write_sector),
    .write_sector_valid(write_sector_valid)
);

mfm_track_encoder encoder (
    .clk(clk), .ready(read_tick && ce), .rst(media_reset), .side(side),
    .track(track), .hd(hd), .addr(image_addr), .idata(pattern(image_addr)),
    .odata(media_data), .omark(media_mark), .ocrc0(media_crc_zero),
    .oneeds(media_needs), .oindex(media_index), .osector(media_sector)
);

swim2_mfm_write writer (
    .clk(clk), .nreset(nreset), .ce(ce),
    .active(mode[3] && mode[4] && !mode[0] && !setup[6]), .tick(write_tick),
    .q_data(tx_data), .q_mark(tx_mark), .q_crc(tx_crc), .q_valid(tx_valid),
    .q_take(tx_take), .data(written_data), .mark(written_mark), .strobe(written_strobe)
);

mfm_write_decoder decoder (
    .clk(clk), .rst(decoder_reset || !nreset), .ready(written_strobe && !commit_busy),
    .idata(written_data ^ {7'd0, corrupt}), .imark(written_mark),
    .side(side), .track(track), .hd(hd), .anchor_sector(write_sector),
    .anchor_valid(write_sector_valid), .sector_valid(sector_valid),
    .sector(decoded_sector), .addr(decoded_addr), .reject(reject),
    .amark(amark), .amark_sector(), .amark_cyl(), .amark_head(),
    .buf_addr(commit_busy ? commit_buf_addr : buf_addr), .buf_data(buf_data)
);

swim2_write_commit committer (
    .clk(clk), .nreset(nreset), .sector_valid(sector_valid), .sector_addr(decoded_addr),
    .sector_ready(commit_ready), .rejected(commit_rejected),
    .buf_addr(commit_buf_addr), .buf_data(buf_data),
    .wr_addr(commit_addr), .wr_data(commit_data), .wr_req(commit_req), .wr_ack(commit_ack),
    .busy(commit_busy), .done(commit_done), .committed_addr(committed_addr),
    .sd_buf_addr(), .sd_buf_data(), .sd_buf_wr()
);

always @(negedge clk) begin
    if (sector_valid) commits = commits + 1;
    if (reject) rejects = rejects + 1;
    if (amark) ids = ids + 1;
end

task check(input [31:0] actual, input [31:0] expected);
    begin
        checks = checks + 1;
        if (actual !== expected)
            $fatal(1, "check %0d: got %08h expected %08h", checks, actual, expected);
    end
endtask

task wr(input [2:0] a, input [7:0] d);
    begin
        @(negedge clk); addr = a; wdata = d; sel = 1; write = 1;
        @(negedge clk); sel = 0; write = 0;
    end
endtask

task rd(input [2:0] a, input [7:0] expected);
    begin
        @(negedge clk); addr = a; sel = 1; write = 0;
        #1; check(rdata, expected);
        @(negedge clk); sel = 0;
    end
endtask

task reset;
    begin
        @(negedge clk); nreset = 0; media_reset = 1; decoder_reset = 1;
        read_tick = 0; write_tick = 0; sel = 0; write = 0; ce = 1;
        @(negedge clk); nreset = 1; media_reset = 0; decoder_reset = 0;
        read_synced = 0; popped = 0;
    end
endtask

task read_byte(input [7:0] expected, input mark, input crc_zero, input integer sector_number);
    begin
        @(negedge clk);
        check(media_data, expected); check(media_mark, mark);
        check(media_crc_zero, crc_zero); check(media_sector, sector_number);
        read_tick = 1;
        @(negedge clk); read_tick = 0;
        if (mark) read_synced = 1;
        if (read_synced) begin
            @(negedge clk); addr = 7; #1;
            check(rdata, 8'h80 | mark | ((!crc_zero) << 1));
            rd(mark ? 1 : 0, expected);
            check(write_sector, sector_number); check(write_sector_valid, 1);
            popped = popped + 1;
        end
    end
endtask

task read_run(input integer length, input [7:0] value, input integer sector_number);
    integer k;
    begin
        for (k = 0; k < length; k = k + 1) read_byte(value, 0, 0, sector_number);
    end
endtask

task read_marks(input integer sector_number);
    integer k;
    begin
        reference_crc = 16'hffff;
        for (k = 0; k < 3; k = k + 1) begin
            read_byte(8'ha1, 1, 0, sector_number);
            reference_crc = reference_step(reference_crc, 8'ha1);
        end
        check(reference_crc, 16'hcdb4);
    end
endtask

task read_field_byte(input [7:0] value, input integer sector_number);
    begin
        read_byte(value, 0, 0, sector_number);
        reference_crc = reference_step(reference_crc, value);
    end
endtask

task write_byte(input [7:0] expected, input mark);
    begin
        @(negedge clk); write_tick = 1;
        @(posedge clk); #1;
        check(written_strobe, 1); check(written_data, expected); check(written_mark, mark);
        @(negedge clk); write_tick = 0;
        @(negedge clk); #1; // Decoder has consumed the registered output pulse.
    end
endtask

task write_marks;
    begin
        wr(1, 8'ha1); wr(1, 8'ha1); wr(7, 8);
        write_byte(8'ha1, 1); wr(1, 8'ha1);
        write_byte(8'ha1, 1); write_byte(8'ha1, 1);
        reference_crc = 16'hcdb4;
    end
endtask

task write_field_byte(input [7:0] value);
    begin
        wr(0, value); write_byte(value, 0);
        reference_crc = reference_step(reference_crc, value);
    end
endtask

task write_crc;
    begin
        wr(2, 8'hff);
        write_byte(reference_crc[15:8], 0);
        // One FIFO token produces both CRC bytes, with no spurious underrun.
        write_byte(reference_crc[7:0], 0);
    end
endtask

// Drain the actual decoder's synchronous buffer with delayed level replies.
task drain_sector(input [21:0] base);
    integer word_number;
    reg [21:0] saved_addr;
    reg [15:0] saved_data;
    begin
        for (word_number = 0; word_number < 256; word_number = word_number + 1) begin
            while (!commit_req) @(negedge clk);
            check(commit_busy, 1); check(commit_ready, 0); check(commit_rejected, 0);
            check(commit_addr, base + word_number * 2);
            check(commit_data, {pattern(base + word_number * 2), pattern(base + word_number * 2 + 1)});
            saved_addr = commit_addr; saved_data = commit_data;
            repeat (3) begin
                @(negedge clk);
                check(commit_req, 1); check(commit_addr, saved_addr); check(commit_data, saved_data);
            end
            commit_ack = 1;
            repeat (3) @(negedge clk);
            check(commit_req, 0); check(commit_done, 0); check(commit_busy, 1);
            commit_ack = 0;
            @(negedge clk);
        end
        check(commit_done, 1); check(commit_busy, 0); check(committed_addr, base);
        @(negedge clk); check(commit_done, 0);
    end
endtask

initial begin
    // Complete revolutions at both densities and both extremes of track/side.
    for (density = 0; density < 2; density = density + 1) begin
        for (cylinder = 0; cylinder < 2; cylinder = cylinder + 1) begin
            for (head = 0; head < 2; head = head + 1) begin
                hd = density; track = cylinder ? 79 : 0; side = head;
                reset; wr(7, 8);
                read_run(80, 8'h4e, 1); read_run(12, 0, 1);
                read_run(3, 8'hc2, 1); read_byte(8'hfc, 0, 0, 1); read_run(50, 8'h4e, 1);
                for (s = 1; s <= (hd ? 18 : 9); s = s + 1) begin
                    read_run(12, 0, s); read_marks(s);
                    read_field_byte(8'hfe, s); read_field_byte({1'b0, track}, s);
                    read_field_byte({7'd0, side}, s); read_field_byte(s, s); read_field_byte(2, s);
                    if (!hd && track == 0 && side == 0 && s == 1) check(reference_crc, 16'hca6f);
                    read_byte(reference_crc[15:8], 0, 0, s); read_byte(reference_crc[7:0], 0, 1, s);
                    read_run(22, 8'h4e, s); read_run(12, 0, s); read_marks(s);
                    read_field_byte(8'hfb, s);
                    for (b = 0; b < 512; b = b + 1) begin
                        check(media_needs, 1); check(image_addr, sector_base(s) + b);
                        read_field_byte(pattern(sector_base(s) + b), s);
                    end
                    read_byte(reference_crc[15:8], 0, 0, s); read_byte(reference_crc[7:0], 0, 1, s);
                    read_run(108, 8'h4e, s);
                end
                check(media_index, 1); check(media_sector, 1); rd(2, 0);
                check(popped, (hd ? 18 : 9) * 682 - 12);

                // Format-style ID+DATA stream through FIFO, writer and decoder.
                reset; wr(7, 8'h10);
                write_marks; write_field_byte(8'hfe); write_field_byte({1'b0, track});
                write_field_byte({7'd0, side}); write_field_byte(hd ? 18 : 9);
                write_field_byte(2); write_crc;
                check(ids, density * 4 + cylinder * 2 + head + 1);
                wr(6, 8); // Prefill before restarting ACTION for the data field.
                write_marks; write_field_byte(8'hfb);
                for (b = 0; b < 512; b = b + 1) write_field_byte(pattern(sector_base(hd ? 18 : 9) + b));
                write_crc;
                check(commits, density * 4 + cylinder * 2 + head + 1);
                check(decoded_sector, hd ? 18 : 9); check(decoded_addr, sector_base(hd ? 18 : 9));
                drain_sector(sector_base(hd ? 18 : 9));
                for (b = 0; b < 512; b = b + 1) begin
                    @(negedge clk); buf_addr = b;
                    @(negedge clk); check(buf_data, pattern(sector_base(hd ? 18 : 9) + b));
                end
                check(rejects, 0); rd(2, 0);
                // The deadline after the second CRC byte is a real underrun.
                @(negedge clk); write_tick = 1;
                @(negedge clk); write_tick = 0;
                check(mode[3], 0); check(written_strobe, 0); rd(2, 1);
            end
        end
    end

    // Ordinary writes use the ID sector read by the CPU, without a new ID.
    // Refuse missing anchors, corrupt data CRC and anchors outside geometry.
    for (test_case = 0; test_case < 4; test_case = test_case + 1) begin
        hd = test_case == 3; track = 79; side = 1;
        reset;
        before_commits = commits; before_rejects = rejects;
        target_sector = test_case == 3 ? 18 : 1;
        if (test_case != 1) begin
            // Rotate while disarmed, then read one tagged ID mark at the head.
            while (!media_mark || media_sector != target_sector) begin
                @(negedge clk); read_tick = 1;
                @(negedge clk); read_tick = 0;
            end
            wr(7, 8); read_byte(8'ha1, 1, 0, target_sector); wr(6, 8);
            check(write_sector, target_sector); check(write_sector_valid, 1);
        end
        hd = 0;
        wr(7, 8'h10); wr(7, 1); wr(6, 1);
        write_marks; write_field_byte(8'hfb);
        for (b = 0; b < 512; b = b + 1) write_field_byte(pattern(sector_base(target_sector) + b));
        wr(2, 0); write_byte(reference_crc[15:8], 0);
        corrupt = test_case == 2;
        write_byte(reference_crc[7:0], 0); corrupt = 0;
        if (test_case == 0) begin
            check(commits, before_commits + 1); check(rejects, before_rejects);
            check(decoded_sector, 1); check(decoded_addr, sector_base(1));
            drain_sector(sector_base(1));
        end else begin
            check(commits, before_commits); check(rejects, before_rejects + 1);
        end
        rd(2, 0);
    end

    // Pause at the CRC-token boundary; cancel before its second output byte.
    reset; wr(7, 8'h10); wr(1, 8'ha1); wr(2, 0); wr(7, 8);
    decoder_reset = 1; // This case checks the writer, not a complete field.
    write_byte(8'ha1, 1);
    ce = 0; write_tick = 1;
    repeat (3) begin @(negedge clk); check(written_strobe, 0); check(tx_take, 0); end
    write_tick = 0; ce = 1;
    write_byte(8'hcd, 0);
    wr(6, 8); wr(7, 1); wr(6, 1); // Abort pending CRC and clear FIFO.
    wr(0, 8'h4e); wr(7, 8); write_byte(8'h4e, 0); rd(2, 0);
    check(commits, 9); check(rejects, 3);

    $display("PASS: SWIM II MFM media, %0d checks, %0d sectors, %0d rejected", checks, commits, rejects);
    $finish;
end

initial begin
    #20000000;
    $fatal(1, "timeout");
end
endmodule
