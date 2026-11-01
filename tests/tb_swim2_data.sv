`timescale 1ns/1ps
module tb_swim2_data;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, ce = 1, sel = 0, write = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, mode, setup;
reg [3:0] phase_in = 0;
wire [3:0] phase_out, phase_oe;
reg [7:0] zero_count = 0;
reg rddata = 0, sense = 0;
reg rx_valid = 0, rx_mark = 0, rx_crc_zero = 0, rx_short = 0, rx_long = 0;
reg [7:0] rx_data = 0;
reg [4:0] rx_sector = 0;
wire [4:0] write_sector;
wire write_sector_valid;
reg tx_take = 0, tx_fault = 0;
reg context_changed = 0;
wire [7:0] tx_data;
wire tx_mark, tx_crc, tx_valid;
integer checks = 0;
integer i, n, events;
reg [7:0] expected;

swim2 dut (
    .clk(clk), .nreset(nreset), .ce(ce), .sel(sel), .write(write),
    .addr(addr), .wdata(wdata), .rdata(rdata),
    .phase_in(phase_in), .zero_count(zero_count), .phase_out(phase_out),
    .phase_oe(phase_oe), .setup(setup), .mode(mode),
    .write_late(), .write_early(),
    .rddata(rddata), .sense(sense), .context_changed(context_changed),
    .rx_valid(rx_valid), .rx_data(rx_data),
    .rx_mark(rx_mark), .rx_crc_zero(rx_crc_zero), .rx_short(rx_short),
    .rx_sector(rx_sector), .write_sector(write_sector), .write_sector_valid(write_sector_valid),
    .rx_long(rx_long), .tx_fault(tx_fault), .tx_take(tx_take), .tx_data(tx_data), .tx_mark(tx_mark),
    .tx_crc(tx_crc), .tx_valid(tx_valid)
);

task check(input [7:0] actual, input [7:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "check %0d: got %02h expected %02h", checks, actual, wanted);
    end
endtask

task wr(input [2:0] a, input [7:0] d);
    begin
        @(negedge clk); addr = a; wdata = d; sel = 1; write = 1;
        @(negedge clk); sel = 0; write = 0;
    end
endtask

task rd(input [2:0] a, input [7:0] wanted);
    begin
        @(negedge clk); addr = a; sel = 1; write = 0;
        #1; check(rdata, wanted);
        @(negedge clk); sel = 0;
    end
endtask

task receive(input [7:0] d, input mark, input crc_zero);
    begin
        @(negedge clk); rx_valid = 1; rx_data = d; rx_mark = mark; rx_crc_zero = crc_zero;
        @(negedge clk); rx_valid = 0; rx_mark = 0; rx_crc_zero = 0;
    end
endtask

task consume(input [7:0] d, input mark, input crc);
    begin
        @(negedge clk);
        check({7'd0, tx_valid}, 1);
        check(tx_data, d);
        check({6'd0, tx_crc, tx_mark}, {6'd0, crc, mark});
        tx_take = 1;
        @(negedge clk); tx_take = 0;
    end
endtask

task reset;
    begin
        @(negedge clk); nreset = 0;
        sel = 0; write = 0; rx_valid = 0; rx_short = 0; rx_long = 0; tx_take = 0; tx_fault = 0;
        @(negedge clk); nreset = 1;
    end
endtask

task flush;
    begin
        wr(7, 1); wr(6, 1);
    end
endtask

initial begin
    reset;
    rd(7, 0); rd(2, 0);
    for (i = 0; i < 4; i = i + 1) begin
        rddata = i[0]; sense = i[1];
        rd(7, {4'd0, i[1:0], 2'd0});
    end
    rddata = 0; sense = 0;

    // CRC error clears only when the oldest queued byte has a zero CRC.
    wr(7, 8);
    receive(8'h4e, 0, 0); rd(7, 0);
    receive(8'ha1, 1, 0); rd(7, 8'h83);
    receive(8'h5c, 0, 1); rd(7, 8'hc3);
    rd(1, 8'ha1); rd(7, 8'h80);
    rd(0, 8'h5c); rd(7, 0); rd(2, 0);

    receive(8'ha1, 1, 0);
    rd(0, 8'ha1); rd(2, 2); rd(2, 0);
    rd(0, 0); rd(2, 4); rd(2, 0);
    receive(8'h11, 0, 0); receive(8'h22, 0, 0); receive(8'h33, 0, 0);
    rd(7, 8'he2); rd(2, 1);
    rd(0, 8'h11); rd(0, 8'h22);

    // DATA returns zero without ACTION; MARK can drain residual data.
    receive(8'h69, 0, 0); wr(6, 8);
    rd(0, 0); rd(7, 8'h82); rd(1, 8'h69); rd(7, 0);
    wr(7, 8); receive(8'h4e, 0, 0); rd(7, 0);
    @(negedge clk); rx_short = 1;
    @(negedge clk); rx_short = 0;
    rd(2, 0);
    receive(8'ha1, 1, 0);
    @(negedge clk); rx_short = 1;
    @(negedge clk); rx_short = 0;
    @(negedge clk); rx_long = 1;
    @(negedge clk); rx_long = 0;
    rd(2, 8'h10); // First error remains until read.
    @(negedge clk); rx_long = 1;
    @(negedge clk); rx_long = 0;
    rd(2, 8'h20); check(mode, 8'h48);

    // GCR accepts bytes without mark hunting or MFM read errors.
    flush; wr(5, 4);
    receive(8'hd5, 1, 0); rd(0, 8'hd5); rd(0, 0); rd(2, 0);
    receive(1, 0, 0); receive(2, 0, 0); receive(3, 0, 0);
    rd(2, 0); rd(0, 1); rd(0, 2);

    // Prefill DATA, MARK and CRC tokens before arming writes.
    reset; wr(7, 8'h10); rd(7, 8'hc0);
    wr(1, 8'ha1); wr(2, 8'hfe); rd(7, 3);
    check({7'd0, tx_valid}, 0);
    wr(7, 8); consume(8'ha1, 1, 0); rd(7, 8'h82);
    consume(8'hfe, 0, 1); rd(7, 8'hc0);
    @(negedge clk); tx_take = 1;
    @(negedge clk); tx_take = 0;
    check(mode, 8'h50); rd(7, 8'he0); rd(2, 1);
    wr(0, 8'h12); wr(0, 8'h34); wr(0, 8'h56);
    rd(7, 8'ha2); // A write error forces DAT1BYTE to space available.
    wr(7, 8); check(mode, 8'h50);
    rd(2, 4); wr(7, 8);
    consume(8'h12, 0, 0); consume(8'h34, 0, 0);

    // Every write FIFO occupancy and simultaneous push/pop combination.
    for (n = 0; n <= 2; n = n + 1) begin
        for (events = 0; events < 4; events = events + 1) begin
            reset; wr(7, 8'h10);
            for (i = 0; i < n; i = i + 1) wr(0, 8'h40 + i);
            wr(7, 8);
            @(negedge clk);
            sel = events[0]; write = 1; addr = 0; wdata = 8'h77; tx_take = events[1];
            @(negedge clk); sel = 0; write = 0; tx_take = 0;
            expected = 0;
            if (events[1] && n == 0) expected = 1;
            else if (events[0] && !events[1] && n == 2) expected = 4;
            rd(2, expected);
            if (expected != 0) wr(7, 8);
            if (n > 0 && !events[1]) consume(8'h40, 0, 0);
            if (n == 2) consume(8'h41, 0, 0);
            if (events[0] && (n < 2 || events[1])) consume(8'h77, 0, 0);
            rd(7, 8'hc0);
        end
    end

    // Full read FIFO replacement preserves byte/metadata order.
    reset; wr(7, 8); receive(8'ha1, 1, 0); receive(8'h20, 0, 1);
    @(negedge clk); sel = 1; addr = 1; rx_valid = 1; rx_data = 8'h30;
    #1; check(rdata, 8'ha1);
    @(negedge clk); sel = 0; rx_valid = 0;
    rd(7, 8'hc0); rd(0, 8'h20); rd(7, 8'h82); rd(0, 8'h30); rd(2, 0);

    // Every read FIFO occupancy and simultaneous medium/CPU combination.
    for (n = 0; n <= 2; n = n + 1) begin
        for (events = 0; events < 4; events = events + 1) begin
            reset; wr(7, 8); receive(8'ha1, 1, 0); rd(1, 8'ha1);
            for (i = 0; i < n; i = i + 1) receive(8'h40 + i, 0, 0);
            @(negedge clk);
            sel = events[0]; addr = 0; rx_valid = events[1]; rx_data = 8'h77;
            #1; if (events[0]) check(rdata, n == 0 ? 0 : 8'h40);
            @(negedge clk); sel = 0; rx_valid = 0;
            expected = 0;
            if (events[1] && !events[0] && n == 2) expected = 1;
            else if (events[0] && n == 0) expected = 4;
            rd(2, expected);
            if (n > 0 && !events[0]) rd(0, 8'h40);
            if (n == 2) rd(0, 8'h41);
            if (events[1] && (n < 2 || events[0])) rd(0, 8'h77);
            rd(7, 0);
        end
    end

    // An error arriving with an error-register read is not lost.
    @(negedge clk); rx_short = 1;
    @(negedge clk); rx_short = 0;
    @(negedge clk); sel = 1; addr = 2; rx_long = 1;
    #1; check(rdata, 8'h10);
    @(negedge clk); sel = 0; rx_long = 0;
    rd(2, 8'h20); rd(2, 0);

    // CE pauses bus, medium and errors. FIFO clear wins over transfers.
    receive(8'h55, 0, 0);
    ce = 0; rx_long = 1;
    rd(0, 8'h55); rd(0, 8'h55); rd(2, 0);
    ce = 1; rx_long = 0;
    wr(7, 1);
    receive(8'ha1, 1, 1); rd(7, 0); rd(2, 0);
    wr(6, 1); receive(8'h66, 0, 0); rd(7, 0);
    receive(8'ha1, 1, 0); rd(1, 8'ha1);
    ce = 0; reset; check(mode, 8'h40); rd(7, 0); ce = 1;

    // Positional anchors follow CPU pops, not the newest or live media byte.
    reset; rx_sector = 3; wr(7, 8); receive(8'ha1, 1, 0);
    rx_sector = 4; receive(8'h20, 0, 0);
    rx_sector = 18;
    check({7'd0, write_sector_valid}, 0);
    rd(1, 8'ha1); check({3'd0, write_sector}, 3);
    check({7'd0, write_sector_valid}, 1);
    rd(0, 8'h20); check({3'd0, write_sector}, 4);
    wr(6, 8); wr(7, 8'h10); flush;
    check({3'd0, write_sector}, 4); check({7'd0, write_sector_valid}, 1);
    wr(6, 8'h10); wr(7, 8);
    @(negedge clk); check({7'd0, write_sector_valid}, 0);

    // Context invalidation wins over a simultaneous pop and arrival. It
    // revokes both queued tags without dropping software-visible bytes.
    reset; rx_sector = 3; wr(7, 8); receive(8'ha1, 1, 0);
    rx_sector = 4; receive(8'h24, 0, 0);
    @(negedge clk); context_changed = 1; sel = 1; addr = 1;
    rx_valid = 1; rx_mark = 1; rx_sector = 5; rx_data = 8'ha1;
    #1; check(rdata, 8'ha1);
    @(negedge clk); context_changed = 0; sel = 0; rx_valid = 0; rx_mark = 0;
    check({7'd0, write_sector_valid}, 0);
    rd(0, 8'h24); check({7'd0, write_sector_valid}, 0);
    rd(1, 8'ha1); check({7'd0, write_sector_valid}, 0);
    receive(8'ha1, 1, 0); rd(1, 8'ha1);
    check({3'd0, write_sector}, 5); check({7'd0, write_sector_valid}, 1);
    ce = 0; context_changed = 1;
    @(negedge clk); check({7'd0, write_sector_valid}, 1);
    ce = 1;
    @(negedge clk); context_changed = 0; check({7'd0, write_sector_valid}, 0);

    // A blocked outbound deadline stops ACTION even with queued FIFO data.
    reset; wr(7, 8'h10); wr(0, 8'h55); wr(7, 8);
    ce = 0; tx_fault = 1;
    @(negedge clk); check(mode[3], 1); rd(2, 0);
    ce = 1;
    @(negedge clk); tx_fault = 0;
    check(mode[3], 0); rd(7, 8'ha2); rd(2, 1); rd(2, 0);
    // Media write faults have no effect in read mode.
    reset; wr(7, 8); tx_fault = 1;
    @(negedge clk); tx_fault = 0;
    check(mode[3], 1); rd(2, 0);

    $display("PASS: SWIM II data/control integration, %0d checks", checks);
    $finish;
end

initial begin
    #200000;
    $fatal(1, "timeout");
end
endmodule
