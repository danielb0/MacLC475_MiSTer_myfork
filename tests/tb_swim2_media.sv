`timescale 1ns/1ps
module tb_swim2_media;
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
reg [6:0] track = 79;
reg side = 1;
reg [4:0] anchor_sector = 18;
reg anchor_valid = 1;
reg [7:0] write_data = 0;
reg write_mark = 0, write_strobe = 0, write_tick = 0;
wire stream_enable, write_fault, buffer_owned, wr_req, sd_buf_wr, save_valid, flush_req;
wire [21:0] wr_addr, save_addr;
wire [15:0] wr_data, sd_buf_data;
wire [7:0] sd_buf_addr;
reg wr_ack = 0, save_ready = 0, flush_ack = 0;
integer checks = 0, i, w, notifications = 0, completed_releases = 0;
reg [15:0] crc;
reg [21:0] expected_base;
reg [7:0] payload_seed = 8'h59;
reg [7:0] expected_seed;
reg [23:0] expected_image;

swim2_media dut (.*);

always @(posedge clk) begin
    if (nreset && save_valid && save_ready) notifications = notifications + 1;
    if (nreset && release_done) completed_releases = completed_releases + 1;
end

function [7:0] pattern(input integer offset, input [7:0] seed);
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

task check(input [31:0] actual, input [31:0] expected);
    begin
        checks = checks + 1;
        if (actual !== expected)
            $fatal(1, "check %0d at %0t: got %08h expected %08h", checks, $time, actual, expected);
    end
endtask

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

task mount_image(input hd, input readonly_image, input [23:0] base);
    begin
        mount_hd = hd; mount_readonly = readonly_image; mount_base = base;
        check(mount_ready, 1);
        mount_valid = 1; #1; check(media_changed, 1);
        cycle; mount_valid = 0;
        check(mounted, 1); check(mount_ready, 0);
        check(media_hd, hd); check(write_protect, readonly_image); check(image_base, base);
        cycle; check(media_changed, 0);
    end
endtask

task send(input [7:0] value, input mark);
    begin
        write_data = value; write_mark = mark; write_strobe = 1;
        cycle; write_strobe = 0; cycle;
    end
endtask

task begin_sector;
    begin
        send(8'ha1, 1); send(8'ha1, 1); send(8'ha1, 1);
        crc = 16'hffff;
        repeat (3) crc = crc_step(crc, 8'ha1);
        send(8'hfb, 0); crc = crc_step(crc, 8'hfb);
    end
endtask

task payload;
    begin
        for (i = 0; i < 512; i = i + 1) begin
            send(pattern(i, payload_seed), 0);
            crc = crc_step(crc, pattern(i, payload_seed));
        end
    end
endtask

task finish_sector;
    begin
        send(crc[15:8], 0); send(crc[7:0], 0);
        check(buffer_owned, 1); check(stream_enable, 0);
    end
endtask

task commit_sector;
    reg [21:0] held_addr;
    reg [15:0] held_data;
    begin
        for (w = 0; w < 256; w = w + 1) begin
            while (!wr_req) cycle;
            check(wr_addr, expected_base + w * 2);
            check(wr_data, {pattern(w*2, expected_seed), pattern(w*2+1, expected_seed)});
            check(sd_buf_wr, 1); check(sd_buf_addr, w); check(sd_buf_data, wr_data);
            held_addr = wr_addr; held_data = wr_data;
            if (w == 127 && releasing) begin
                guest_reset = 1; context_changed = 1; track = 42; side = 1;
                cycle;
                check(wr_req, 1); check(wr_addr, held_addr); check(wr_data, held_data);
                guest_reset = 0; context_changed = 0;
            end
            repeat (w % 5) begin
                cycle;
                check(wr_req, 1); check(wr_addr, held_addr); check(wr_data, held_data);
                check(image_base, expected_image); check(buffer_owned, 1); check(flush_req, 0);
            end
            wr_ack = 1; cycle;
            repeat (3) begin
                cycle; check(wr_req, 0); check(buffer_owned, 1); check(save_valid, 0);
            end
            wr_ack = 0; cycle;
        end
        while (!save_valid) cycle;
        // The sector is in image RAM and the persistence snapshot; the host
        // save no longer owns the decoder buffer.
        check(save_addr, expected_base); check(buffer_owned, 0);
    end
endtask

task drain_sector;
    begin
        commit_sector;
        repeat (4) begin
            cycle; check(save_valid, 1); check(save_addr, expected_base);
            check(buffer_owned, 0); check(flush_req, 0); check(wr_req, 0);
        end
        save_ready = 1; cycle; save_ready = 0;
        check(save_valid, 0); check(buffer_owned, 0);
    end
endtask

task release_image;
    integer old_releases;
    begin
        old_releases = completed_releases;
        release_request = 1;
        while (!flush_req) cycle;
        repeat (8) begin
            cycle; check(mounted, 1); check(mount_ready, 0); check(release_done, 0);
            check(image_base, expected_image); check(stream_enable, 0);
        end
        flush_ack = 1; cycle;
        check(flush_req, 0); check(mounted, 1);
        repeat (4) begin cycle; check(mounted, 1); check(release_done, 0); end
        flush_ack = 0; cycle;
        check(release_done, 1); check(media_changed, 1); check(mounted, 0);
        repeat (5) begin
            cycle; check(release_done, 0); check(flush_req, 0); check(mount_ready, 0);
        end
        check(completed_releases, old_releases + 1);
        release_request = 0; cycle; check(mount_ready, 1);
    end
endtask

initial begin
    cycle; nreset = 1; cycle;
    check(mounted, 0); check(stream_enable, 0);
    mount_image(1, 0, 24'h120000);
    check(read_enable, 1);
    expected_image = image_base; expected_base = 22'd1474048; expected_seed = payload_seed;
    // New host metadata cannot change the current mount.
    mount_base = 24'h340000; mount_hd = 0; mount_readonly = 1; mount_valid = 1;
    begin_sector; payload;
    wr_ack = 1; read_busy = 1;
    send(crc[15:8], 0);
    write_data = crc[7:0]; write_strobe = 1; cycle; write_strobe = 0;
    // Ownership closes on sector_valid before its pending register is set.
    check(buffer_owned, 1); check(stream_enable, 0);
    check(read_enable, 0);
    guest_reset = 1; context_changed = 1; track = 0; side = 0; anchor_sector = 1;
    release_request = 1; cycle;
    guest_reset = 0; context_changed = 0;
    check(read_discard, 1);
    repeat (5) begin cycle; check(wr_req, 0); check(buffer_owned, 1); end
    send(8'hff, 0); check(write_fault, 1);
    check(image_base, expected_image); check(media_hd, 1); check(write_protect, 0);
    // A stale flush ACK cannot satisfy a new flush request.
    flush_ack = 1; wr_ack = 0;
    repeat (5) begin cycle; check(wr_req, 0); check(buffer_owned, 1); end
    read_busy = 0;
    drain_sector;
    repeat (5) begin cycle; check(flush_req, 0); check(mounted, 1); end
    flush_ack = 0; release_image;
    check(notifications, 1); mount_valid = 0;

    mount_image(0, 1, 24'h340000); expected_image = image_base;
    check(stream_enable, 0); send(8'ha1, 1); check(write_fault, 1);
    check(buffer_owned, 0); check(wr_req, 0);
    release_image;

    mount_image(0, 0, 24'h560000); expected_image = image_base;
    track = 0; side = 0;
    read_busy = 1; cycle; check(read_enable, 0); check(read_discard, 0);
    context_changed = 1; #1; check(read_discard, 1); cycle;
    context_changed = 0; cycle; check(read_discard, 1);
    read_busy = 0; cycle; check(read_discard, 0); check(read_enable, 1);
    write_active = 0; cycle; write_active = 1; cycle;
    check(write_fault, 0); check(stream_enable, 1);
    // Invalid physical geometry cannot launch a decoder write.
    track = 80; cycle; check(stream_enable, 0);
    send(8'ha1, 1); check(write_fault, 1); check(buffer_owned, 0);
    track = 0; context_changed = 1; cycle; context_changed = 0; cycle;
    check(stream_enable, 1);
    // CRC failure reports a lost write without creating a persistence event.
    begin_sector; payload;
    send(crc[15:8], 0); send(crc[7:0] ^ 8'h01, 0); cycle;
    check(write_fault, 1); check(buffer_owned, 0); check(wr_req, 0); check(notifications, 1);
    write_active = 0; cycle; write_active = 1; cycle;
    // Guest reset abandons partial payloads, which must never reach memory.
    begin_sector;
    repeat (20) send(8'h34, 0);
    guest_reset = 1; cycle; guest_reset = 0;
    send(8'h00, 0); check(buffer_owned, 0); check(wr_req, 0);
    // Head changes also discard the partial parser and its previous ID anchor.
    begin_sector; send(8'h55, 0);
    context_changed = 1; track = 20; side = 1; cycle; context_changed = 0;
    send(8'h00, 0); check(buffer_owned, 0); check(wr_req, 0);
    expected_base = ((20 * 2 + 1) * 9) * 512;
    payload_seed = 8'hc3; expected_seed = payload_seed;
    begin_sector; payload; finish_sector;
    // The write engine may be gated, but its byte clock must keep running.
    write_tick = 1; cycle; write_tick = 0; check(write_fault, 1);
    // A second stream cannot overwrite the locked decoder buffer.
    send(8'ha1, 1); send(8'hfb, 0); send(8'h99, 0);
    check(write_fault, 1);
    drain_sector; check(notifications, 2);
    check(stream_enable, 0);
    write_active = 0; cycle; write_active = 1; cycle;
    check(stream_enable, 1); check(write_fault, 0);

    // Regression for MacTest Pro "Could not write fast enough" (-74): the
    // host's write and fsync of one sector take milliseconds, longer than the
    // gap before the next physical sector. That save must not stall the guest.
    payload_seed = 8'h3c; expected_seed = payload_seed; anchor_sector = 1;
    begin_sector; payload; finish_sector;
    commit_sector;
    check(save_valid, 1); check(read_enable, 1);
    // The driver ends ACTION, finds the next header, then writes again.
    write_active = 0; cycle; write_active = 1; cycle;
    check(stream_enable, 1);
    write_tick = 1; cycle; write_tick = 0; check(write_fault, 0);
    payload_seed = 8'h96; anchor_sector = 2;
    begin_sector; payload; finish_sector;
    check(write_fault, 0);
    // The second commit would refill the snapshot, so it waits for the save.
    repeat (20) begin
        cycle; check(wr_req, 0); check(save_valid, 1); check(save_addr, expected_base);
        check(buffer_owned, 1); check(read_enable, 0);
    end
    save_ready = 1; cycle; save_ready = 0; check(notifications, 3);
    expected_base = expected_base + 512; expected_seed = payload_seed;
    drain_sector; check(notifications, 4);
    write_active = 0; cycle; write_active = 1; cycle;
    check(stream_enable, 1); check(write_fault, 0);

    // Permission and drive gates abort incomplete streams.
    begin_sector; motor = 0; cycle; motor = 1; send(0, 0); check(buffer_owned, 0);
    begin_sector; selected = 0; cycle; selected = 1; send(0, 0); check(buffer_owned, 0);
    begin_sector; write_enable = 0; cycle; write_enable = 1; send(0, 0); check(buffer_owned, 0);
    check(wr_req, 0);
    // A read already issued still owns this image through its reply turnaround.
    read_busy = 1; release_request = 1;
    repeat (5) begin cycle; check(flush_req, 0); check(mounted, 1); check(read_enable, 0); end
    read_busy = 0;
    release_image;

    // Empty release requests complete once and block new mounts until withdrawn.
    release_request = 1;
    while (!flush_req) cycle;
    flush_ack = 1; cycle; flush_ack = 0; cycle; check(release_done, 1);
    repeat (4) begin cycle; check(flush_req, 0); check(release_done, 0); end
    release_request = 0; cycle; check(mount_ready, 1);
    $display("PASS: SWIM II media scheduling/ownership, %0d checks", checks);
    $finish;
end
initial begin
    #1000000;
    $fatal(1, "timeout");
end
endmodule
