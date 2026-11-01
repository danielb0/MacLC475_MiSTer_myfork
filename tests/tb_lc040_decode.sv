`timescale 1ns/1ps
module tb_lc040_decode;
import ap68040_lc040_pkg::*;
reg clk = 0, nreset = 0, ex_v = 0, safe = 1, adv = 0, kill = 0;
always #5 clk = ~clk;
reg [3:0] sub = 0;
reg [15:0] ow = 0, ew = 0;
reg [31:0] ea = 32'h5000;
reg [31:0] pc = 32'h40A;
reg [7:0] list_mask = 0;
wire hold, xnext;
wire [7:0] xvec;
wire [3:0] xfmt;
wire [31:0] xaddr;
integer checks = 0;
lc040_dec_t decoded;

ap68040_lc040 dut (.*);

task check(input bit ok, input string label);
    if (!ok) $fatal(1, "%s", label);
    checks++;
endtask

task trap_case(input [15:0] opcode, command, input [31:0] expected_ea);
    @(negedge clk);
    ow = opcode; ew = command; sub = 0; ex_v = 1; adv = 0; safe = 0;
    #1; check(hold && xvec == 0, "Older uop did not hold LC040 check");
    safe = 1; #1; check(!hold && xvec == 0 && xaddr == pc, "Legal FP check lost its instruction PC");
    adv = 1;
    @(negedge clk); sub = 15; adv = 0;
    #1; check(xvec == 11 && xfmt == 4 && xnext && xaddr == expected_ea,
              "LC040 format/PC/EA selection");
    safe = 0; #1; check(hold && xvec == 0, "Trap ignored older uop");
    safe = 1; ex_v = 0;
endtask

task invalid_case(input [15:0] opcode, command);
    @(negedge clk);
    ow = opcode; ew = command; sub = 0; ex_v = 1; safe = 1; adv = 0;
    #1; check(xvec == 11 && xfmt == 0 && !xnext && xaddr == pc,
              "Reserved encoding did not take generic F-line");
    ex_v = 0;
endtask

initial begin
    repeat (2) @(negedge clk); nreset = 1;
    trap_case('hF200, 'h0000, 0); // register
    trap_case('hF200, 'h000E, 0); // software arithmetic
    trap_case('hF200, 'h5C00, 0); // FMOVECR
    trap_case('hF200, 'h4000, 0); // Dn source
    trap_case('hF210, 'h4400, 'h5000);
    trap_case('hF218, 'h4400, 'h5000);
    trap_case('hF220, 'h5400, 'h4FF8);
    trap_case('hF227, 'h5800, 'h4FFE); // A7 byte predecrement
    trap_case('hF210, 'h6400, 'h5000); // store address only
    trap_case('hF200, 'h9000, 0); // control register
    trap_case('hF23C, 'h9C00, 0); // control immediate list
    trap_case('hF220, 'hE003, 'h4FE8);
    trap_case('hF220, 'hE000, 'h5000); // empty list still has an EA
    trap_case('hF248, 0, 0); // FDBcc
    trap_case('hF250, 0, 'h5000); // FScc
    trap_case('hF27A, 0, 0); // FTRAP word
    trap_case('hF27B, 0, 0); // FTRAP long
    trap_case('hF27C, 0, 0); // FTRAP without operand
    trap_case('hF280, 'h20, 0);
    trap_case('hF2C0, 0, 0);
    trap_case('hF310, 0, 'h5000);
    trap_case('hF320, 0, 'h4FFC); // FSAVE predecrement
    trap_case('hF350, 0, 'h5000);
    invalid_case('hF23D, 0);
    invalid_case('hF200, 'h2000);
    invalid_case('hF200, 'h0005);
    invalid_case('hF210, 'h4005); // reserved opmode precedes EA
    invalid_case('hF200, 'h4800); // extended operand in Dn
    invalid_case('hF208, 'h4000); // An arithmetic source
    invalid_case('hF23A, 'h6400); // PC-relative destination
    invalid_case('hF200, 'h9C00); // multiple control registers in Dn
    invalid_case('hF218, 'hE001); // FMOVEM store postincrement
    invalid_case('hF220, 'hC001); // FMOVEM load predecrement
    invalid_case('hF318, 0); // FSAVE postincrement
    invalid_case('hF360, 0); // FRESTORE predecrement
    for (int mask = 0; mask < 256; mask++) begin
        list_mask = mask;
        check(lc040_list_bytes(mask) == 12*$countones(mask & 255), "FMOVEM mask byte count");
        trap_case('hF220, 'hE820, 32'h5000 - 12*$countones(mask & 255));
    end
    for (int format = 0; format < 8; format++) begin
        decoded = lc040_decode('hF220, 16'h4000 | (format << 10));
        case (format)
            0, 1: check(decoded.bytes == 4, "Long FP operand size");
            2, 3: check(decoded.bytes == 12, "Extended FP operand size");
            4: check(decoded.bytes == 2, "Word FP operand size");
            5: check(decoded.bytes == 8, "Double FP operand size");
            6: check(decoded.bytes == 1, "Byte FP operand size");
            7: check(!decoded.ea, "FMOVECR acquired an EA");
        endcase
    end
    @(negedge clk); kill = 1;
    @(negedge clk); kill = 0;
    check(dut.opword == 0 && dut.extension == 0, "Kill retained a previous FP command");
    $display("PASS: LC040 decode and trap unit %0d checks", checks);
    $finish;
end
endmodule
