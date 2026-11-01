`timescale 1ns/1ps
module tb_lc040_ucode;
import ap68040_pkg::*, ap68040_upkg::*, ap68040_lc040_pkg::*;
localparam HAS_FPU = 0;
logic [119:0] urom [0:1023];
uword_t word;
integer checks = 0;
initial begin
    uword_t lc_word;
`include "gen/ap68040_ucode_init.svh"
    for (int i = LC_ENTRY; i < LC_FMT4+6; i++)
        if (urom[i] != 0) $fatal(1, "Donor ROM occupies an LC040 slot");
`include "ap68040_lc040_ucode.svh"
    word = uword_t'(urom[LC_ENTRY]);
    if (word.op != OP_FPU || word.a != S_EXT1 || word.b != S_OPW || word.ser || word.last)
        $fatal(1, "LC040 first micro-op");
    word = uword_t'(urom[LC_EA]);
    if (word.op != OP_FPU || word.ag != AGM_LEA0 || word.b != S_FPDL || word.ser || !word.last)
        $fatal(1, "LC040 EA micro-op");
    checks = 2;
    for (int i = 0; i < 5; i++) begin
        word = uword_t'(urom[LC_FMT4+i]);
        if (word.op != OP_MOV || word.mem != M_ST || word.mfc != MFC_SUP ||
            word.last || word.agb != S_SSP)
            $fatal(1, "Format-4 stack operation %0d", i);
        case (i)
            0: if (word.a != 48 || word.cval != 16'hFFFC || word.msz != 3) $fatal(1, "Fault PC");
            1: if (word.a != 54 || word.cval != 16'hFFF8 || word.msz != 3) $fatal(1, "Operand EA");
            2: if (word.a != 55 || word.cval != 16'hFFF6 || word.msz != 2) $fatal(1, "Format/vector");
            3: if (word.a != 52 || word.cval != 16'hFFF2 || word.msz != 3) $fatal(1, "Next PC");
            4: if (word.a != 53 || word.cval != 16'hFFF0 || word.msz != 2) $fatal(1, "Saved SR");
        endcase
        if (word.ag != (i == 4 ? AGM_BASEDU : AGM_BASED)) $fatal(1, "SSP commit position");
        checks++;
    end
    word = uword_t'(urom[LC_FMT4+5]);
    if (word.mem != M_LD || word.mfc != MFC_SUP || !word.last || word.br != BR_A)
        $fatal(1, "Exception vector fetch");
    checks++;
    $display("PASS: LC040 frame microcode %0d checks", checks);
    $finish;
end
endmodule
