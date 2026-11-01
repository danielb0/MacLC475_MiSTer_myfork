`timescale 1ns/1ps
module tb_lc040;
    reg clk = 0;
    always #5 clk = ~clk;
    reg nreset = 0;
    wire req, wr, instr;
    wire [1:0] size;
    wire [31:0] addr, wdata;
    wire [2:0] fc;
    reg ack = 0, berr = 0;
    reg [31:0] rdata = 0;
    wire [255:0] debug_status;
    wire halted;
`ifdef CPU_AP68040
    quadra_cpu040 #(.AP040_HAS_FPU(0)) dut (
`else
    wombat_cpu #(.AP040_HAS_FPU(0), .AP040_ENABLE_CACHE(0),
                 .AP040_STORE_BUFFER(0)) dut (
`endif
        .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(3'b111),
        .ipl_autovector(1'b1), .berr(berr), .stall_hold(1'b0), .dbg_stall_flt(),
        .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
        .store_buffer_ok(1'b0), .bus_req(req), .bus_write(wr), .bus_instr(instr),
        .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(fc),
        .bus_ack(ack), .bus_rdata(rdata), .walker_req(), .walker_we(),
        .walker_addr(), .walker_wdat(), .walker_ack(1'b0), .walker_data(32'd0),
        .walker_berr(1'b0), .snoop_stb(1'b0), .snoop_addr(32'd0),
        .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
        .debug_busy(), .debug_fault(), .debug_halted(halted),
        .debug_test_status(), .debug_instruction_pc(),
`ifdef CPU_AP68040
        .debug_status(), .debug_status2()
`else
        .debug_status(debug_status), .debug_status2()
`endif
    );
`ifdef CPU_AP68040
    // Observe architectural state without adding production register-file ports.
    function automatic [31:0] committed_reg(input [4:0] n);
        if (dut.cpu.be.rfb.lvt[n] == 0)
            return dut.cpu.be.rfb.g_w[0].g_r[0].bank.mem[n];
        return dut.cpu.be.rfb.g_w[1].g_r[0].bank.mem[n];
    endfunction
    wire [31:0] test_pc = dut.cpu.be.redir_v ? dut.cpu.be.redir_pc : 32'hFFFFFFFF;
    assign debug_status = {32'd0, committed_reg(8), committed_reg(2), committed_reg(1),
                           committed_reg(0), committed_reg(dut.cpu.sr[13] ?
                               (dut.cpu.sr[12] ? 5'd17 : 5'd16) : 5'd15),
                           16'd0, dut.cpu.sr, dut.cpu.be.wb_u.pc};
`else
    wire [31:0] test_pc = dut.core.pc_i;
`endif
    reg [7:0] mem [0:65535];
    integer phase = 0, delay_left = 0, transfers = 0, operand_reads = 0;
    reg pointer_fault = 0;
    function automatic [31:0] get32(input integer a);
        get32 = {mem[a], mem[a+1], mem[a+2], mem[a+3]};
    endfunction
    function automatic [15:0] get16(input integer a);
        get16 = {mem[a], mem[a+1]};
    endfunction
    task automatic put16(input integer a, input [15:0] v);
        mem[a] = v[15:8]; mem[a+1] = v[7:0];
    endtask
    task automatic put32(input integer a, input [31:0] v);
        put16(a, v[31:16]); put16(a+2, v[15:0]);
    endtask
    always @(posedge clk) begin : bus_model
        integer bytes;
        ack <= 0; berr <= 0;
        if (!nreset) begin
            delay_left <= 0; transfers <= 0; operand_reads <= 0;
        end
        else if (req && !ack && !berr) begin
            if (delay_left != 0) delay_left <= delay_left - 1;
            else begin
                if (addr > 65532) $fatal(1, "Unexpected bus address %h", addr);
                bytes = size == 0 ? 1 : size == 1 ? 2 : 4;
                if (pointer_fault && !wr && !instr && addr == 32'h5000) berr <= 1;
                else begin
                    ack <= 1;
                    if (wr) begin
                        if (addr >= 32'h5000 && addr < 32'h6000)
                            $fatal(1, "FP operand write at %h", addr);
                        if (addr >= 32'h6F00 && addr < 32'h7000 && fc != 3'd5)
                            $fatal(1, "Exception stack written in FC %0d", fc);
                        for (integer i = 0; i < bytes; i = i + 1)
                            mem[addr+i] = wdata[8*(bytes-i)-1 -: 8];
                    end
                    else begin
                        rdata <= size == 0 ? {24'd0, mem[addr]} :
                                 size == 1 ? {16'd0, get16(addr)} : get32(addr);
                        if (!instr && addr >= 32'h5000 && addr < 32'h6000)
                            operand_reads <= operand_reads + 1;
                    end
                end
                transfers <= transfers + 1;
                delay_left <= phase == 0 ? 0 : (transfers * 7 + 3) % 6;
            end
        end
    end

    integer fp_pc = 'h40A, end_pc, cases = 0;
    reg [15:0] expected_sr = 16'h2700;
    reg [31:0] return_sp = 32'h7000;
    task automatic setup(input [15:0] opcode, input [15:0] command,
                         input integer words);
        nreset = 0;
        fp_pc = 'h40A; expected_sr = 16'h2700; return_sp = 32'h7000;
        repeat (5) @(negedge clk);
        for (integer i = 0; i < 65536; i = i + 2) put16(i, 16'h4E71);
        for (integer v = 0; v < 256; v = v + 1) put32(v*4, 32'hA00);
        put32(0, 32'h7000); put32(4, 32'h400); put32(44, 32'h800);
        put16('h400, 16'h41F9); put32('h402, 32'h5000); // LEA
        put16('h406, 16'h7208); put16('h408, 16'h7403); // D1=8,D2=3
        put16('h40A, opcode);
        if (words > 1) put16('h40C, command);
        end_pc = 'h40A + 2*words;
        put16(end_pc, 16'h702A); // MOVEQ #42,D0 after RTE
        put16(end_pc+2, 16'h4E72); put16(end_pc+4, 16'h2700);
        put16('h800, 16'h4E73); // RTE
        put16('hA00, 16'h4E72); put16('hA02, 16'h2700);
        put32('h5000, 32'h5100);
        pointer_fault = 0;
    endtask
    task automatic user_mode(input [15:0] opcode, input [15:0] command,
                             input integer words);
        put16('h40A, 16'h227C); put32('h40C, 32'h6000); // MOVEA.L
        put16('h410, 16'h4E61); // MOVE A1,USP
        put16('h412, 16'h46FC); put16('h414, 16'h0700); // MOVE to SR
        fp_pc = 'h416; end_pc = fp_pc + 2*words;
        put16(fp_pc, opcode); if (words > 1) put16(fp_pc+2, command);
        put16(end_pc, 16'h702A); put16(end_pc+2, 16'h60FE);
        expected_sr = 16'h0700; return_sp = 32'h6000;
    endtask
    task automatic run_case(input string label, input [31:0] ea,
                            input integer reads, input integer format, input integer vector = 11);
        integer timeout_count, sp, handler;
        @(negedge clk); nreset = 1;
        handler = get32(vector*4);
        timeout_count = 0;
        while (test_pc != handler && timeout_count < 20000) begin
            @(negedge clk); timeout_count++;
            if (halted) $fatal(1, "%s: CPU halted %h", label, debug_status);
        end
        if (timeout_count == 20000) $fatal(1, "%s: handler timeout %h", label, debug_status);
        sp = debug_status[95:64];
        if (get16(sp+6) >> 12 != format)
            $fatal(1, "%s: format %h, expected %0d", label, get16(sp+6), format);
        if (format == 4) begin
            if (sp != 'h6FF0 || get16(sp) != expected_sr || get16(sp+6) != 16'h402C ||
                get32(sp+2) != end_pc || get32(sp+8) != ea || get32(sp+12) != fp_pc)
                $fatal(1, "%s: bad frame SP=%h SR=%h PC=%h fmt=%h EA=%h faultPC=%h",
                       label, sp, get16(sp), get32(sp+2), get16(sp+6), get32(sp+8), get32(sp+12));
            if (debug_status[223:192] != 32'h5000 || debug_status[159:128] != 8 ||
                debug_status[191:160] != 3)
                $fatal(1, "%s: register side effect", label);
            if (operand_reads != reads) $fatal(1, "%s: operand reads %0d", label, operand_reads);
            timeout_count = 0;
            // D0 survives reset; require fresh retirement in the pipelined core.
            while ((debug_status[127:96] != 42
`ifdef CPU_AP68040
                    || dut.retired_pc != end_pc
`endif
                   ) && timeout_count < 20000) begin
                @(negedge clk); timeout_count++;
                if (halted) $fatal(1, "%s: RTE halted", label);
            end
            if (timeout_count == 20000 || debug_status[95:64] != return_sp ||
                debug_status[47:40] != expected_sr[15:8])
                $fatal(1, "%s: RTE failed %h", label, debug_status);
        end
        else if (format == 0 && (get32(sp+2) != fp_pc || get16(sp+6) != vector*4))
            $fatal(1, "%s: bad generic F-line frame", label);
        else if (format == 7 && get32(sp+20) != 'h5000)
            $fatal(1, "%s: bad access-fault address %h", label, get32(sp+20));
        cases++;
    endtask
    initial begin
        for (phase = 0; phase < 2; phase++) begin
            setup(16'hF200, 16'h0000, 2); run_case("FP register", 0, 0, 4);
            setup(16'hF200, 16'h000E, 2); run_case("FSIN register", 0, 0, 4);
            setup(16'hF200, 16'h5C00, 2); run_case("FMOVECR", 0, 0, 4);
            setup(16'hF200, 16'h4000, 2); run_case("Dn source", 0, 0, 4);
            setup(16'hF210, 16'h4400, 2); run_case("(An) source", 'h5000, 0, 4);
            setup(16'hF218, 16'h4400, 2); run_case("(An)+ source", 'h5000, 0, 4);
            setup(16'hF220, 16'h5400, 2); run_case("-(An) double source", 'h4FF8, 0, 4);
            setup(16'hF21F, 16'h5800, 2); run_case("(A7)+ byte source", 'h7000, 0, 4);
            setup(16'hF227, 16'h5800, 2); run_case("-(A7) byte source", 'h6FFE, 0, 4);
            setup(16'hF228, 16'h4400, 3); put16('h40E, 16'hFFF8);
                run_case("d16(An)", 'h4FF8, 0, 4);
            setup(16'hF230, 16'h4400, 3); put16('h40E, 16'h1A04);
                run_case("brief indexed", 'h5014, 0, 4);
            setup(16'hF230, 16'h4400, 4); put16('h40E, 16'h0161); put16('h410, 0);
                run_case("indirect indexed", 'h5100, 1, 4);
            setup(16'hF230, 16'h4400, 4); put16('h40E, 16'h0161); put16('h410, 0);
                pointer_fault = 1; run_case("indirect access error", 0, 0, 7, 2);
            setup(16'hF238, 16'h4400, 3); put16('h40E, 16'h5004);
                run_case("absolute word", 'h5004, 0, 4);
            setup(16'hF239, 16'h4400, 4); put32('h40E, 32'h5008);
                run_case("absolute long", 'h5008, 0, 4);
            setup(16'hF23A, 16'h4400, 3); put16('h40E, 16'h0100);
                run_case("PC relative", 'h50E, 0, 4);
            setup(16'hF23C, 16'h5800, 3); put16('h40E, 16'h0012);
                run_case("byte immediate", 0, 0, 4);
            setup(16'hF23C, 16'h5000, 3); put16('h40E, 16'h0012);
                run_case("word immediate", 0, 0, 4);
            setup(16'hF23C, 16'h4000, 4); put32('h40E, 32'h12345678);
                run_case("long immediate", 0, 0, 4);
            setup(16'hF23C, 16'h5400, 6); put32('h40E, 32'h12345678); put32('h412, 0);
                run_case("double immediate", 0, 0, 4);
            setup(16'hF23C, 16'h4800, 8); put32('h40E, 32'h12345678); put32('h412, 0); put32('h416, 0);
                run_case("extended immediate", 0, 0, 4);
            setup(16'hF210, 16'h6400, 2); run_case("FP store", 'h5000, 0, 4);
            setup(16'hF200, 16'h9000, 2); run_case("control register", 0, 0, 4);
            setup(16'hF23C, 16'h9C00, 8); put32('h40E, 0); put32('h412, 0); put32('h416, 0);
                run_case("control immediate list", 0, 0, 4);
            setup(16'hF220, 16'hE003, 2); run_case("static FMOVEM predec", 'h4FE8, 0, 4);
            setup(16'hF220, 16'hE820, 2); run_case("dynamic FMOVEM predec", 'h4FE8, 0, 4);
            setup(16'hF220, 16'hE000, 2); run_case("empty FMOVEM predec", 'h5000, 0, 4);
            setup(16'hF248, 16'h0000, 3); put16('h40E, 16'h0020);
                run_case("FDBcc", 0, 0, 4);
            setup(16'hF250, 16'h0000, 2); run_case("FScc memory", 'h5000, 0, 4);
            setup(16'hF27A, 16'h0000, 3); put16('h40E, 0);
                run_case("FTRAP word", 0, 0, 4);
            setup(16'hF27B, 16'h0000, 4); put32('h40E, 0);
                run_case("FTRAP long", 0, 0, 4);
            setup(16'hF27C, 16'h0000, 2); run_case("FTRAP no operand", 0, 0, 4);
            setup(16'hF280, 16'h0020, 2); run_case("FBcc word", 0, 0, 4);
            setup(16'hF2C0, 16'h0000, 3); put16('h40E, 16'h0020);
                run_case("FBcc long", 0, 0, 4);
            setup(16'hF310, 0, 1); run_case("FSAVE", 'h5000, 0, 4);
            setup(16'hF320, 0, 1); run_case("FSAVE predec", 'h4FFC, 0, 4);
            setup(16'hF350, 0, 1); run_case("FRESTORE", 'h5000, 0, 4);
            setup(16'hF200, 16'h0000, 2); user_mode(16'hF200, 16'h0000, 2);
                run_case("user FP register", 0, 0, 4);
            setup(16'hF21F, 16'h5800, 2); user_mode(16'hF21F, 16'h5800, 2);
                run_case("user USP operand", 'h6000, 0, 4);
            setup(16'hF310, 0, 1); user_mode(16'hF310, 0, 1);
                run_case("user FSAVE privilege", 0, 0, 0, 8);
            setup(16'hF350, 0, 1); user_mode(16'hF350, 0, 1);
                run_case("user FRESTORE privilege", 0, 0, 0, 8);
            setup(16'hF23D, 0, 1); run_case("reserved primary", 0, 0, 0);
            setup(16'hF200, 16'h2000, 2); run_case("reserved class", 0, 0, 0);
            setup(16'hF200, 16'h0005, 2); run_case("reserved opmode", 0, 0, 0);
            setup(16'hF230, 16'h4005, 4); put16('h40E, 16'h0161); put16('h410, 0);
                pointer_fault = 1; run_case("reserved opmode before indirect fault", 0, 0, 0);
        end
        $display("PASS: LC040 %0d frame/EA/RTE/fault cases", cases);
        $finish;
    end
endmodule
