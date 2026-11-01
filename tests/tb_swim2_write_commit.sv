`timescale 1ns/1ps
module tb_swim2_write_commit;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, sector_valid = 0, wr_ack = 0;
reg [21:0] sector_addr = 0;
wire sector_ready, rejected, wr_req, busy, done, sd_buf_wr;
wire [21:0] wr_addr, committed_addr;
wire [15:0] wr_data, sd_buf_data;
wire [8:0] buf_addr;
wire [7:0] sd_buf_addr;
reg [7:0] buf_data;
reg [7:0] source [0:511];
integer checks = 0, i, w, delay_cycles;
reg [21:0] held_addr;
reg [15:0] held_data;

swim2_write_commit dut (.*);
always @(posedge clk) buf_data <= source[buf_addr];

task check(input [31:0] actual, input [31:0] expected);
    begin
        checks = checks + 1;
        if (actual !== expected)
            $fatal(1, "check %0d: got %08h expected %08h", checks, actual, expected);
    end
endtask

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

task offer(input [21:0] a, input accepted);
    begin
        sector_addr = a; sector_valid = 1;
        cycle;
        check(rejected, !accepted);
        if (accepted) check(busy, 1);
        sector_valid = 0;
        cycle; check(rejected, 0);
    end
endtask

task drain(input [21:0] base);
    begin
        for (w = 0; w < 256; w = w + 1) begin
            while (!wr_req) cycle;
            check(busy, 1); check(sector_ready, 0); check(done, 0);
            check(wr_addr, base + w * 2);
            check(wr_data, {source[w*2], source[w*2+1]});
            check(sd_buf_wr, 1); check(sd_buf_addr, w); check(sd_buf_data, wr_data);
            held_addr = wr_addr; held_data = wr_data;
            // Delayed and stalled replies must leave the request immutable.
            for (delay_cycles = 0; delay_cycles < w % 7; delay_cycles = delay_cycles + 1) begin
                cycle;
                check(wr_req, 1); check(wr_addr, held_addr); check(wr_data, held_data);
            end
            if (w == 20) begin
                offer(22'h1200, 0);
                check(committed_addr, base); check(wr_addr, held_addr); check(wr_data, held_data);
            end
            wr_ack = 1; cycle;
            check(wr_req, 0); check(sd_buf_wr, 0);
            // A stale level ACK cannot acknowledge the following word.
            repeat (5) begin
                cycle; check(wr_req, 0); check(busy, 1); check(done, 0); check(sector_ready, 0);
                check(wr_addr, held_addr); check(wr_data, held_data);
            end
            wr_ack = 0; cycle;
            check(done, w == 255);
        end
        check(busy, 0); check(sector_ready, 1); check(committed_addr, base);
        cycle; check(done, 0);
    end
endtask

initial begin
    for (i = 0; i < 512; i = i + 1) source[i] = i[7:0] ^ {7'd0, i[8]} ^ 8'h96;
    cycle; nreset = 1; cycle;
    check(sector_ready, 1); check(wr_req, 0); check(done, 0);
    offer(22'h201, 0); check(busy, 0); check(wr_req, 0);
    wr_ack = 1; offer(22'h200, 0); check(busy, 0);
    wr_ack = 0; cycle;
    offer(22'h200, 1); drain(22'h200);
    // Highest sector-aligned offset and back-to-back ownership.
    offer(22'h3ffe00, 1); drain(22'h3ffe00);
    offer(22'h400, 1);
    while (!wr_req) cycle;
    nreset = 0; cycle;
    check(wr_req, 0); check(busy, 0); check(done, 0); check(rejected, 0);
    // Reset is a global abort; a lingering reply still blocks a new owner.
    wr_ack = 1; nreset = 1; cycle; check(sector_ready, 0);
    wr_ack = 0; cycle; check(sector_ready, 1);
    offer(22'h600, 1); drain(22'h600);
    $display("PASS: SWIM II sector commit, %0d checks", checks);
    $finish;
end
initial begin
    #1000000;
    $fatal(1, "timeout");
end
endmodule
