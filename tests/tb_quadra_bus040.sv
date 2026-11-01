`timescale 1ns/1ps
module tb_quadra_bus040;
reg clk = 0, nreset = 0;
always #20 clk = ~clk;
reg [31:0] a = 0, dout = 32'h11223344, rdata = 32'hAABBCCDD;
reg a_oe = 0, rw_n = 1, ts_n = 1, ack = 0, berr = 0, stall_hold = 0;
reg [1:0] siz = 0, tt = 0;
reg [2:0] tm = 5;
wire req, wr, instr, ta_n, tea_n, tci_n, avec_n, stall, busy;
wire [1:0] size;
wire [2:0] fc;
wire [31:0] addr, wdata, din;
integer checks = 0;

quadra_bus040 #(.STALL_BITS(4)) dut (
    .clk(clk), .nreset(nreset), .stall_hold(stall_hold),
    .c_a(a), .c_do(dout), .c_a_oe(a_oe), .c_rw_n(rw_n),
    .c_ts_n(ts_n), .c_siz(siz), .c_tt(tt), .c_tm(tm),
    .c_di(din), .c_ta_n(ta_n), .c_tea_n(tea_n),
    .c_tci_n(tci_n), .c_avec_n(avec_n), .bus_req(req),
    .bus_write(wr), .bus_instr(instr), .bus_size(size), .bus_addr(addr),
    .bus_wdata(wdata), .bus_fc(fc), .bus_ack(ack), .bus_rdata(rdata),
    .berr(berr), .dbg_stall_flt(stall), .busy(busy)
);

task check(input bit ok, input string label);
    if (!ok) $fatal(1, "%s", label);
    checks++;
endtask

task start(input [31:0] address, input [1:0] width, input bit write_cycle);
    @(negedge clk);
    a = address; siz = width; rw_n = !write_cycle; a_oe = 1; ts_n = 0;
    dout = 32'h11223344;
    #1; check(req, "TS did not request transfer");
    @(negedge clk); ts_n = 1;
    #1; check(req && busy, "Transfer did not stay held after TS");
endtask

task finish_beat;
    ack = 1;
    #1; check(!ta_n && tea_n, "TA handshake");
    @(negedge clk); ack = 0;
endtask

task reset_adapter;
    @(negedge clk); nreset = 0; a_oe = 0; ts_n = 1; ack = 0; berr = 0;
    repeat (2) @(negedge clk);
    #1; check(!req && !busy && !stall && ta_n && tea_n, "Reset did not clear transfer");
    nreset = 1;
endtask

initial begin
    reset_adapter();
    for (int write_cycle = 0; write_cycle < 2; write_cycle++) begin
        for (int width = 0; width < 3; width++) begin
            for (int offset = 0; offset < 4; offset++) begin
                start(32'h50000000 + offset, width == 0 ? 1 : width == 1 ? 2 : 0, write_cycle);
                check(addr == a && size == width && wr == write_cycle && fc == tm,
                      "Single transfer fields");
                case (width)
                    0: begin
                        check(wdata[7:0] == ((dout >> (8*(3-offset))) & 32'hFF), "Byte write lane");
                        check(din == 32'hDDDDDDDD, "Byte read lanes");
                    end
                    1: begin
                        check(wdata == (offset < 2 ? 32'h1122 : 32'h3344), "Word write lane");
                        check(din == 32'hCCDDCCDD, "Word read lanes");
                    end
                    2: check(wdata == dout && din == rdata, "Long lanes");
                endcase
                repeat (3) begin
                    @(negedge clk); #1;
                    check(req && addr == a && ta_n && tea_n, "Wait changed transfer");
                end
                finish_beat();
                #1; check(!req && !busy, "Single transfer did not end");
            end
        end
        for (int first = 0; first < 4; first++) begin
            start(32'h1000 + first*4, 3, write_cycle);
            for (int beat = 0; beat < 4; beat++) begin
                #1; check(req && size == 2 && addr == 32'h1000 + ((first+beat)%4)*4,
                          "Burst critical word or wrap");
                dout = 32'h11223344 + beat;
                #1; check(wdata == dout, "Burst write data");
                @(negedge clk);
                finish_beat();
                #1; check(req == (beat != 3), "Burst request continuity");
            end
        end
    end
    for (int level = 0; level < 8; level++) begin
        tm = level; #1;
        check(instr == (level == 2 || level == 6) && fc == level, "Function code");
    end
    for (int region = 0; region < 16; region++) begin
        a = region << 28; #1;
        check(tci_n == (region <= 4), "Device cache inhibit");
    end
    for (int abort_beat = 0; abort_beat < 4; abort_beat++) begin
        start(32'h1008, 3, 0);
        for (int beat = 0; beat < abort_beat; beat++) finish_beat();
        berr = 1; ack = 1;
        #1; check(!tea_n && ta_n, "Bus error must suppress TA");
        @(negedge clk); berr = 0; ack = 0;
        #1; check(!req && !busy, "Bus error did not abort burst");
        start(32'h2000, 3, 1);
        for (int beat = 0; beat < abort_beat; beat++) finish_beat();
        reset_adapter();
    end
    @(negedge clk); tt = 3; a_oe = 1; ts_n = 0;
    #1; check(!req, "IACK reached memory bus");
    @(negedge clk); ts_n = 1;
    #1; check(!req && !ta_n && !avec_n, "Autovector acknowledge");
    @(negedge clk); tt = 0;
    #1; check(ta_n && avec_n, "IACK did not clear");
    start(32'h50000000, 0, 0);
    stall_hold = 1;
    repeat (40) begin
        @(negedge clk); check(!stall && tea_n && req, "HPS hold timed out");
    end
    stall_hold = 0;
    repeat (16) @(negedge clk);
    #1; check(stall && !tea_n, "Watchdog did not fire");
    @(negedge clk); #1; check(!req, "Watchdog did not abort transfer");
    reset_adapter();
    $display("PASS: pipelined CPU bus adapter %0d checks", checks);
    $finish;
end

initial begin
    #100000; $fatal(1, "Bus test timeout");
end
endmodule
