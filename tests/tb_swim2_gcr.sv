`timescale 1ns/1ps
module tb_swim2_gcr;
reg clk = 0;
always #5 clk = ~clk;
reg rst = 1, ready = 0, decode_ready = 0;
reg side = 0, sides = 0;
reg [6:0] track = 0;
wire [21:0] image_addr, decoded_addr;
wire [7:0] encoded;
reg [7:0] input_byte = 0;
wire needs, index, valid, reject, amark, fmt_mark, fmt_ds, byte_ready;
wire [3:0] enc_sector, sector, amark_sector;
reg [8:0] buf_addr = 0;
wire [7:0] buf_data;
reg wr_byte = 0, wr_mark = 0, wr_end = 0;
reg [3:0] wr_mark_sector = 0;
integer checks = 0, commits = 0, rejects = 0, formats = 0;
integer t, geometry, h, s, b, i, n, fetches, expected_sector;
integer cases [0:9];
reg [7:0] vector [0:781];
reg [7:0] reference [0:702];
integer before_commits, before_rejects;
localparam [511:0] ALPHABET = 512'h96979a9b9d9e9fa6a7abacadaeafb2b3b4b5b6b7b9babbbcbdbebfcbcdcecfd3d6d7d9dadbdcdddedfe5e6e7e9eaebecedeeeff2f3f4f5f6f7f9fafbfcfdfeff;

function [7:0] symbol(input integer nibble);
    symbol = ALPHABET[511 - (nibble & 63) * 8 -: 8];
endfunction

// Whole-byte reference independent of the donor's clocked nibbler pipeline.
task prepare_reference(input integer sector_base);
    integer g, k, pos, a, d0, d1, d2, x0, x1, x2;
    integer c1, c2, c3, rotated, sum3, sum2;
    begin
        c1 = 0; c2 = 0; c3 = 0; pos = 0;
        for (g = 0; g < 175; g = g + 1) begin
            a = g * 3;
            d0 = a < 12 ? 0 : pattern(sector_base + a - 12);
            d1 = a + 1 < 12 ? 0 : pattern(sector_base + a + 1 - 12);
            d2 = a + 2 < 12 || a + 2 >= 524 ? 0 : pattern(sector_base + a + 2 - 12);
            rotated = ((c1 << 1) & 255) | (c1 >> 7);
            sum3 = c3 + d0 + (c1 >> 7); c3 = sum3 & 255; x0 = d0 ^ rotated;
            sum2 = c2 + d1 + (sum3 >> 8); c2 = sum2 & 255; x1 = d1 ^ c3;
            x2 = a + 2 < 524 ? d2 ^ c2 : 0;
            c1 = a + 2 < 524 ? (rotated + d2 + (sum2 >> 8)) & 255 : rotated;
            reference[pos] = symbol(((x0 >> 6) << 4) | ((x1 >> 6) << 2) | (x2 >> 6));
            reference[pos+1] = symbol(x0); reference[pos+2] = symbol(x1);
            pos = pos + 3;
            if (a + 2 < 524) begin reference[pos] = symbol(x2); pos = pos + 1; end
        end
        reference[pos] = symbol(((c3 >> 6) << 4) | ((c2 >> 6) << 2) | (c1 >> 6));
        reference[pos+1] = symbol(c3); reference[pos+2] = symbol(c2); reference[pos+3] = symbol(c1);
    end
endtask

function [7:0] pattern(input integer a);
    pattern = a[7:0] ^ a[15:8] ^ a[21:16] ^ 8'h59;
endfunction

function integer base(input integer tr, input integer hd, input integer ds, input integer sec);
    integer k, count;
    begin
        count = 0;
        for (k = 0; k < tr; k = k + 1) count = count + 12 - k / 16;
        base = (count * (ds ? 2 : 1) + hd * (12 - tr / 16) + sec) * 512;
    end
endfunction

floppy_track_encoder encoder (
    .clk(clk), .rst(rst), .ready(ready), .side(side), .sides(sides), .track(track),
    .addr(image_addr), .idata(pattern(image_addr)), .odata(encoded), .oneeds(needs),
    .oindex(index), .osector(enc_sector), .wr_byte(wr_byte), .wr_mark(wr_mark),
    .wr_mark_sector(wr_mark_sector), .wr_end(wr_end)
);
floppy_track_decoder decoder (
    .clk(clk), .rst(rst), .ready(decode_ready), .idata(input_byte), .byte_ready(byte_ready),
    .side(side), .sides(sides), .track(track), .sector_valid(valid), .sector(sector),
    .addr(decoded_addr), .reject(reject), .amark(amark), .amark_sector(amark_sector),
    .fmt_mark(fmt_mark), .fmt_ds(fmt_ds), .buf_addr(buf_addr), .buf_data(buf_data)
);

always @(negedge clk) begin
    if (valid) commits = commits + 1;
    if (reject) rejects = rejects + 1;
    if (fmt_mark) formats = formats + 1;
end

task check(input [31:0] actual, input [31:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "check %0d at %0t: got %08h expected %08h", checks, $time, actual, wanted);
    end
endtask
task cycle;
    begin @(posedge clk); #1; @(negedge clk); #1; end
endtask
task reset;
    begin rst = 1; ready = 0; decode_ready = 0; cycle; rst = 0; cycle; end
endtask
task feed(input [7:0] value);
    begin
        check(byte_ready, 1); input_byte = value; decode_ready = 1;
        cycle; decode_ready = 0; repeat (4) cycle;
    end
endtask

initial begin
    cases[0]=0; cases[1]=15; cases[2]=16; cases[3]=31; cases[4]=32;
    cases[5]=47; cases[6]=48; cases[7]=63; cases[8]=64; cases[9]=79;
    for (geometry = 0; geometry < 2; geometry = geometry + 1) begin
        sides = geometry;
        for (t = 0; t < 10; t = t + 1) begin
            track = cases[t];
            for (h = 0; h <= geometry; h = h + 1) begin
                side = h; reset; expected_sector = 0;
                for (s = 0; s < 12 - track / 16; s = s + 1) begin
                    fetches = 0; before_commits = commits;
                    prepare_reference(base(track, side, sides, expected_sector));
                    for (b = 0; b < 782; b = b + 1) begin
                        check(enc_sector, expected_sector);
                        if (needs) begin
                            check(image_addr, base(track, side, sides, expected_sector) + fetches);
                            fetches = fetches + 1;
                        end
                        if (geometry == 0 && t == 0 && s == 0) vector[b] = encoded;
                        if (b == 56) check(encoded, 8'hd5);
                        if (b == 57) check(encoded, 8'haa);
                        if (b == 58) check(encoded, 8'h96);
                        if (b == 71) check(encoded, 8'hd5);
                        if (b == 72) check(encoded, 8'haa);
                        if (b == 73) check(encoded, 8'had);
                        if (b >= 75 && b <= 777) check(encoded, reference[b-75]);
                        check(byte_ready, 1);
                        input_byte = encoded; ready = 1; decode_ready = 1;
                        cycle; ready = 0; decode_ready = 0;
                        if (valid) begin
                            check(sector, expected_sector);
                            check(decoded_addr, base(track, side, sides, expected_sector));
                            for (i = 0; i < 512; i = i + 1) begin
                                buf_addr = i; cycle;
                                check(buf_data, pattern(base(track, side, sides, expected_sector) + i));
                            end
                        end
                        repeat (4) cycle;
                    end
                    check(fetches, 512); check(commits, before_commits + 1);
                    check(rejects, 0); check(fmt_ds, sides);
                    if (expected_sector >= (12 - track / 16) - 2) expected_sector = !expected_sector[0];
                    else expected_sector = expected_sector + 2;
                end
            end
        end
    end
    // Independent known prolog/zero-tag symbols for track 0, side 0, sector 0.
    check(vector[59], 8'h96); check(vector[60], 8'h96); check(vector[61], 8'h96);
    check(vector[62], 8'h9a); check(vector[63], 8'h9a);
    for (i = 75; i < 87; i = i + 1) check(vector[i], 8'h96);
    track = 0; side = 0; sides = 0;
    for (n = 0; n < 4; n = n + 1) begin
        reset; before_commits = commits; before_rejects = rejects;
        for (b = 0; b < 782; b = b + 1) begin
            if ((n == 0 && b == 100) || (n == 2 && b == 778)) feed(0);
            else if (n == 1 && b == 774) feed(vector[b] == 8'h96 ? 8'h97 : 8'h96);
            else if (n == 3 && b == 74) feed(8'hff);
            else feed(vector[b]);
        end
        check(commits, before_commits); check(rejects, before_rejects + 1);
    end
    // Relay restarts the layout at the first written address field's sector.
    reset; wr_mark_sector = 3; wr_mark = 1; cycle; wr_mark = 0;
    repeat (7) begin wr_byte = 1; cycle; end
    wr_byte = 0; wr_end = 1; cycle; wr_end = 0;
    check(encoder.gap_cnt, 12 * 782 - 12);
    ready = 1;
    while (encoder.state != 1) cycle;
    ready = 0; check(enc_sector, 3); check(encoded, 8'hd5);
    repeat (4) begin ready = 1; cycle; ready = 0; end
    check(encoded, 8'h9b);
    $display("PASS: SWIM II GCR codecs, %0d checks, %0d sectors, %0d rejected", checks, commits, rejects);
    $finish;
end
initial begin
    #30000000;
    $fatal(1, "timeout");
end
endmodule
