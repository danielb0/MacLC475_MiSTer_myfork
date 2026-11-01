`timescale 1ns/1ps
module tb_swim2_registers;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, ce = 1, sel = 0, write = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, setup, mode, tx_data;
wire [3:0] phase_out, phase_oe, write_late, write_early;
wire tx_mark, tx_crc, tx_valid;
reg [7:0] zero_count = 0;
integer checks = 0;
integer i, j;

swim2 dut (
    .clk(clk), .nreset(nreset), .ce(ce), .sel(sel), .write(write),
    .addr(addr), .wdata(wdata), .rdata(rdata), .phase_in(4'h5),
    .zero_count(zero_count), .rddata(1'b0), .sense(1'b0),
    .context_changed(1'b0),
    .rx_valid(1'b0), .rx_data(8'd0), .rx_mark(1'b0), .rx_crc_zero(1'b0),
    .rx_short(1'b0), .rx_long(1'b0), .tx_fault(1'b0), .tx_take(1'b0),
    .rx_sector(5'd0), .write_sector(), .write_sector_valid(),
    .tx_data(tx_data), .tx_mark(tx_mark), .tx_crc(tx_crc), .tx_valid(tx_valid),
    .phase_out(phase_out), .phase_oe(phase_oe), .setup(setup), .mode(mode),
    .write_late(write_late), .write_early(write_early)
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

initial begin
    repeat (2) @(negedge clk);
    nreset = 1;
    rd(6, 8'h40); rd(5, 0); rd(4, 8'hf0);
    for (i = 0; i < 4; i = i + 1) rd(3, 0);

    // Four entries wrap. Low nibbles and Time0/Time1 do not feed timing.
    for (i = 0; i < 256; i = i + 1) begin
        wr(6, 0);
        wr(3, i[7:0]); wr(3, ~i[7:0]);
        wr(3, i[7:0] ^ 8'hf0); wr(3, i[7:0] ^ 8'h5a);
        check({4'd0, write_late}, {4'd0, i[7:4]});
        check({4'd0, write_early}, {4'd0, i[7:4] ^ 4'hf});
        rd(3, i[7:0]); rd(3, ~i[7:0]);
        rd(3, i[7:0] ^ 8'hf0); rd(3, i[7:0] ^ 8'h5a);
    end

    // A 16-byte SWIM parameter stream aliases the same four entries.
    wr(6, 0);
    for (i = 0; i < 16; i = i + 1) wr(3, 8'h80 + i);
    for (i = 0; i < 4; i = i + 1) rd(3, 8'h8c + i);
    check({write_late, write_early}, 8'h88);

    // Every ModeClr write resets the index, even with no mode-bit changes.
    for (i = 0; i < 4; i = i + 1) begin
        for (j = 0; j < i; j = j + 1) rd(3, 8'h8c + j);
        wr(6, 0); rd(3, 8'h8c); wr(6, 0);
    end

    // Status reads, ModeSet, FIFO clear and unrelated accesses preserve it.
    rd(3, 8'h8c); rd(6, 8'h40); wr(7, 1);
    wr(4, 8'ha5); wr(5, 8'h14);
    zero_count = 8'h6b; rd(4, 8'h6b);
    rd(5, 8'h14); rd(7, 0); rd(2, 0);
    rd(3, 8'h8d); wr(3, 8'h57); rd(3, 8'h8f);
    check({write_late, write_early}, 8'h85);
    wr(6, 0); rd(3, 8'h8c); rd(3, 8'h8d); rd(3, 8'h57); rd(3, 8'h8f);

    // CE pauses both parameter data and index, including ModeClr.
    rd(3, 8'h8c); ce = 0;
    wr(3, 8'hff); wr(6, 8'hff); rd(3, 8'h8d); rd(3, 8'h8d);
    ce = 1; rd(3, 8'h8d); rd(3, 8'h57);
    check({write_late, write_early}, 8'h85);

    // An address held while deselected cannot advance or alter parameters.
    @(negedge clk); addr = 3; wdata = 8'hff; write = 1;
    repeat (3) @(negedge clk);
    write = 0; rd(3, 8'h8f); rd(3, 8'h8c);

    // Reset clears state even while CE is stopped.
    ce = 0; nreset = 0;
    @(negedge clk); nreset = 1; ce = 1;
    check({write_late, write_early}, 0);
    for (i = 0; i < 4; i = i + 1) rd(3, 0);
    rd(6, 8'h40); rd(5, 0); rd(4, 8'hf0);
    $display("PASS: SWIM II register interface, %0d checks", checks);
    $finish;
end

initial begin
    #200000;
    $fatal(1, "timeout");
end
endmodule
