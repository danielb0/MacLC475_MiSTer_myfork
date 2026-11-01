`timescale 1ns/1ps
module tb_swim2_control;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, ce = 1, sel = 0, write = 0;
reg [1:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, setup, mode;
reg [3:0] phase_in = 0;
reg [7:0] zero_count = 0, handshake = 0;
reg write_error = 0;
wire [3:0] phase_out, phase_oe;
integer checks = 0;
integer i;
reg [7:0] expected_mode;

swim2_control dut (.*);

task check(input [7:0] actual, input [7:0] expected);
    begin
        checks = checks + 1;
        if (actual !== expected)
            $fatal(1, "check %0d: got %02h expected %02h", checks, actual, expected);
    end
endtask

task wr(input [1:0] a, input [7:0] d);
    begin
        @(negedge clk);
        addr = a; wdata = d; sel = 1; write = 1;
        @(negedge clk);
        sel = 0; write = 0;
    end
endtask

task rd(input [1:0] a, input [7:0] expected);
    begin
        @(negedge clk);
        addr = a; sel = 1; write = 0;
        #1;
        check(rdata, expected);
        @(negedge clk);
        sel = 0;
    end
endtask

initial begin
    repeat (2) @(negedge clk);
    nreset = 1;
    rd(0, 8'hf0);
    rd(1, 0);
    rd(2, 8'h40);

    // Every phase direction and level combination, with independent inputs.
    for (i = 0; i < 256; i = i + 1) begin
        phase_in = ~i[3:0];
        wr(0, i[7:0]);
        rd(0, {i[7:4], (i[3:0] & i[7:4]) | (~i[3:0] & ~i[7:4])});
        check({4'd0, phase_out}, {4'd0, i[3:0]});
        check({4'd0, phase_oe}, {4'd0, i[7:4]});
    end

    // Test mode reads the datapath counter without changing phase outputs.
    wr(0, 8'hf5);
    for (i = 0; i < 256; i = i + 1) begin
        wr(1, i[7:0]);
        rd(1, i[7:0] & 8'h7f);
        zero_count = i[7:0] ^ 8'ha6;
        rd(0, i[4] ? zero_count : 8'hf5);
    end

    // Set and clear affect only selected bits. Bit 6 always reads as one.
    expected_mode = 8'h40;
    for (i = 0; i < 256; i = i + 1) begin
        wr(3, i[7:0]);
        expected_mode = expected_mode | i[7:0] | 8'h40;
        rd(2, expected_mode);
        wr(2, i[7:0]);
        expected_mode = (expected_mode & ~i[7:0]) | 8'h40;
        rd(2, expected_mode);
        handshake = i[7:0];
        rd(3, handshake);
        rd(2, expected_mode);
    end

    // FIFO clear is software controlled through mode bit 0.
    wr(2, 8'hff);
    wr(3, 8'h11);
    check(mode, 8'h51);
    wr(2, 8'h01);
    check(mode, 8'h50);
    wr(3, 8'h08);
    write_error = 1;
    wr(3, 8'h08);
    check(mode, 8'h50);
    write_error = 0;
    wr(2, 8'h10);
    wr(3, 8'h08);
    write_error = 1;
    @(negedge clk);
    check(mode, 8'h48);
    write_error = 0;

    // Clock enable pauses writes and hardware action cancellation.
    wr(3, 8'h10);
    ce = 0; write_error = 1;
    wr(2, 8'hff);
    check(mode, 8'h58);
    wr(0, 8'h00);
    check({phase_oe, phase_out}, 8'hf5);
    wr(1, 8'h00);
    check(setup, 8'h7f);
    ce = 1;
    @(negedge clk);
    check(mode, 8'h50);
    write_error = 0;

    // Deselected writes have no effect; reset works with CE stopped.
    addr = 3; wdata = 8'hff; write = 1; sel = 0;
    @(negedge clk);
    check(mode, 8'h50);
    ce = 0; nreset = 0;
    @(negedge clk);
    check(mode, 8'h40);
    check(setup, 0);
    check({phase_oe, phase_out}, 8'hf0);
    $display("PASS: SWIM II control registers, %0d checks", checks);
    $finish;
end

initial begin
    #200000;
    $fatal(1, "timeout");
end
endmodule
