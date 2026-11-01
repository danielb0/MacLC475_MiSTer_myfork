`timescale 1ns/1ps
module tb_swim2_timing;
reg clk = 0;
always #20 clk = ~clk;
reg nreset = 0, ce = 1, running = 0, gcr = 0, hd = 1;
reg write_active = 0, write_div2 = 0;
reg [6:0] track = 0;
wire byte_tick, write_tick, tach;
integer checks = 0, clocks, edges, previous_edges, bytes, changes, k, zone;
integer period, half_period;
reg last_tach;
reg [63:0] elapsed;

swim2_timing dut (.*);

task check(input [63:0] got, input [63:0] expected);
    begin
        checks = checks + 1;
        if (got !== expected) $fatal(1, "check %0d: got %0d expected %0d", checks, got, expected);
    end
endtask
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

task measure(input integer limit, input integer half_limit);
    begin
        running = 0; repeat (3) cycle;
        check(byte_tick, 0); check(tach, 0);
        running = 1; clocks = 0; bytes = 0; changes = 0; last_tach = 0;
        previous_edges = 0;
        // Independent absolute-time reference; include two complete tach periods.
        for (k = 0; k < (half_limit * 4 * 40 / 13) + 12; k = k + 1) begin
            ce = (k % 19 != 6 && k % 19 != 7);
            if (ce) clocks = clocks + 1;
            elapsed = clocks;
            edges = elapsed * 8_125_000 / 25_000_000;
            #1;
            check(byte_tick, (edges / limit != previous_edges / limit));
            if (byte_tick) bytes = bytes + 1;
            cycle;
            check(tach, (edges / half_limit) & 1);
            if (tach != last_tach) changes = changes + 1;
            last_tach = tach;
            previous_edges = edges;
        end
        check(bytes, edges / limit); check(changes >= 3, 1);
        // Motor stop and reset must work with CE stopped.
        ce = 0; running = 0; cycle; check(tach, 0); check(byte_tick, 0);
        ce = 1;
    end
endtask

task measure_write(input slow);
    integer n, active_clocks, last_bytes, expected_bytes;
    begin
        write_active = 0; write_div2 = slow; ce = 1;
        repeat (3) cycle; check(write_tick, 0);
        write_active = 1; active_clocks = 0; last_bytes = 0;
        for (n = 0; n < 6000; n = n + 1) begin
            ce = n % 17 != 3 && n % 17 != 4;
            // Media geometry and motor changes cannot change controller timing.
            running = n % 1300 > 300;
            gcr = n % 1100 > 200;
            hd = n % 900 > 400;
            if (ce) active_clocks = active_clocks + 1;
            expected_bytes = active_clocks / (slow ? 800 : 400);
            #1; check(write_tick, expected_bytes != last_bytes);
            cycle; last_bytes = expected_bytes;
        end
        ce = 0; write_active = 0; cycle; check(write_tick, 0);
        ce = 1;
    end
endtask

initial begin
    repeat (3) cycle; nreset = 1;
    measure(130, 16661);
    hd = 0; measure(260, 16661);
    gcr = 1;
    for (zone = 0; zone < 5; zone = zone + 1) begin
        track = zone * 16;
        case (zone)
            0: half_period = 9997;
            1: half_period = 9123;
            2: half_period = 8293;
            3: half_period = 7464;
            4: half_period = 6635;
        endcase
        measure(128, half_period);
    end
    // A zone transition must not wait for a counter wrap.
    track = 0; running = 1; repeat (25000) cycle;
    track = 79; repeat (21000) cycle; check(dut.tach_count < 6635, 1);
    measure_write(0); measure_write(1);
    // Divider changes discard a partial byte, including while CE is stopped.
    write_active = 1; ce = 1; repeat (237) cycle;
    ce = 0; write_div2 = 0; cycle; check(write_tick, 0);
    ce = 1;
    for (k = 1; k <= 1200; k = k + 1) begin
        #1; check(write_tick, k % 400 == 0); cycle;
    end
    repeat (91) cycle; write_div2 = 1;
    #1; check(write_tick, 0); cycle;
    for (k = 1; k <= 1600; k = k + 1) begin
        #1; check(write_tick, k % 800 == 0); cycle;
    end
    ce = 0; nreset = 0; cycle; check(tach, 0); check(byte_tick, 0);
    check(write_tick, 0);
    $display("PASS: SWIM II 25 MHz byte/tach pacing, %0d checks", checks);
    $finish;
end
endmodule
