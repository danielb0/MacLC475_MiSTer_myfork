`timescale 1ns/1ps
module tb_cpu040_mmu;
reg clk = 0, nreset = 0;
always #20 clk = ~clk;
wire req, wr, instr, halted, stall;
wire [1:0] size;
wire [2:0] fc;
wire [31:0] addr, wdata, retired_pc;
reg ack = 0, berr = 0;
reg [31:0] rdata = 0;
reg [7:0] mem [0:65535];
reg [31:0] expected [0:15];
integer pc, done_pc, fault_pc;
integer signatures = 0, expected_count = 0, cases = 0;
integer scenario = 0, delay_cycles = 0, delay_left = 0;
integer data_reads = 0, data_writes = 0, table_reads = 0, injected_errors = 0;
integer page_bytes = 4096;
localparam TRANSLATE = 0, INDIRECT = 1, USER_ROOT = 2, NONRESIDENT = 3,
           WRITE_PROTECT = 4, SUPERVISOR_ONLY = 5, TABLE_ERROR = 6, COPYBACK = 7;
localparam [31:0] VIRTUAL_DATA = 32'h01000000, MAILBOX = 32'h50000000;

cpu040 #(.AP040_HAS_FPU(0)) dut (
    .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(3'b111),
    .ipl_autovector(1'b1), .berr(berr), .stall_hold(1'b0), .dbg_stall_flt(stall),
    .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
    .store_buffer_ok(1'b0), .bus_req(req), .bus_write(wr), .bus_instr(instr),
    .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(fc),
    .bus_ack(ack), .bus_rdata(rdata), .walker_req(), .walker_we(),
    .walker_addr(), .walker_wdat(), .walker_ack(1'b0), .walker_data(32'd0),
    .walker_berr(1'b0), .snoop_stb(1'b0), .snoop_addr(32'd0),
    .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
    .debug_busy(), .debug_fault(), .debug_halted(halted),
    .debug_status(), .debug_status2(), .debug_test_status(),
    .debug_instruction_pc(retired_pc)
);

function automatic [15:0] get16(input integer a);
    return {mem[a], mem[a+1]};
endfunction
function automatic [31:0] get32(input integer a);
    return {mem[a], mem[a+1], mem[a+2], mem[a+3]};
endfunction
task automatic put16(input integer a, input [15:0] v);
    mem[a] = v[15:8]; mem[a+1] = v[7:0];
endtask
task automatic put32(input integer a, input [31:0] v);
    put16(a, v[31:16]); put16(a+2, v[15:0]);
endtask
task automatic emit16(input [15:0] v);
    put16(pc, v); pc += 2;
endtask
task automatic emit32(input [31:0] v);
    put32(pc, v); pc += 4;
endtask
task automatic movec(input [11:0] control, input [31:0] v);
    emit16('h203C); emit32(v); // MOVE.L #v,D0
    emit16('h4E7B); emit16({4'd0, control});
endtask
task automatic store(input [31:0] a, input [31:0] v);
    emit16('h23FC); emit32(v); emit32(a);
endtask
task automatic report_d0(input [31:0] v);
    emit16('h23C0); emit32(MAILBOX);
    expected[expected_count] = v; expected_count++;
endtask
task automatic read_check(input [31:0] a, input [31:0] v);
    emit16('h2039); emit32(a);
    report_d0(v);
endtask
task automatic marker(input [31:0] v);
    store(MAILBOX, v);
    expected[expected_count] = v; expected_count++;
endtask

task automatic report_signature;
    if (!wr || size != 2 || signatures >= expected_count || wdata !== expected[signatures])
        $fatal(1, "Case %0d signature %0d: %h expected %h", scenario, signatures,
               wdata, expected[signatures]);
    if (scenario == COPYBACK) begin
        case (signatures)
            0, 1, 2: if (get32('h8000) != 'hCAFEBABE || data_writes != 0 || data_reads != 4)
                $fatal(1, "Copyback store escaped before CPUSHL or cache hit missed");
            3: begin
                if (get32('h8000) != 'h11223344 || data_writes != 4)
                    $fatal(1, "CPUSHL did not write all four dirty-line beats");
                put32('h8000, 'hBBAA9988);
            end
            4, 5: if (get32('h8000) != 'hBBAA9988 || data_writes != 4 || data_reads != 8)
                $fatal(1, "CPUSHL refill or CINVL dirty discard failed");
            6: if (data_reads != 12 || data_writes != 4 || get32('h8000) != 'hBBAA9988)
                $fatal(1, "CINVL did not force a fresh memory read");
            default: $fatal(1, "Unexpected copyback signature");
        endcase
    end
    signatures++;
endtask

always @(posedge clk) begin : memory_bus
    integer bytes;
    ack <= 0; berr <= 0;
    if (!nreset) delay_left <= delay_cycles;
    else begin
        if (halted || stall) $fatal(1, "CPU halted/stalled in case %0d at %h", scenario, retired_pc);
        if (req && !ack && !berr) begin
            if (delay_left != 0) delay_left <= delay_left - 1;
            else begin
                delay_left <= delay_cycles;
                if (scenario == TABLE_ERROR && addr == 'h2800 && fc == 3 && !wr) begin
                    berr <= 1;
                    injected_errors++;
                end
                else begin
                    ack <= 1;
                    if (addr == MAILBOX) report_signature();
                    else begin
                        if (addr > 65532) $fatal(1, "Untranslated/unexpected bus address %h FC=%0d", addr, fc);
                        bytes = size == 0 ? 1 : size == 1 ? 2 : 4;
                        if (!wr && (fc == 3 || fc == 4)) table_reads++;
                        if (addr >= 'h8000 && addr < 'h8010) begin
                            if (wr) begin
                                data_writes++;
                                if (scenario == COPYBACK && (fc != 0 || size != 2))
                                    $fatal(1, "Dirty-line push has wrong FC/size");
                            end
                            else data_reads++;
                        end
                        if (wr) begin
                            for (integer i = 0; i < bytes; i++)
                                mem[addr+i] = wdata[8*(bytes-i)-1 -: 8];
                        end
                        else rdata <= size == 0 ? {24'd0, mem[addr]} :
                                      size == 1 ? {16'd0, get16(addr)} : get32(addr);
                    end
                end
            end
        end
    end
end

task automatic setup(input integer kind, input bit page8k, input integer delay_clocks);
    @(negedge clk); nreset = 0;
    scenario = kind; delay_cycles = delay_clocks;
    repeat (8) @(negedge clk);
    for (integer i = 0; i < 65536; i++) mem[i] = 0;
    signatures = 0; expected_count = 0; data_reads = 0; data_writes = 0;
    table_reads = 0; injected_errors = 0;
    page_bytes = page8k ? 8192 : 4096;
    put32(0, 'h7000); put32(4, 'h400); put32(8, 'h1800);
    put16('h1800, 'h4E72); put16('h1802, 'h2700);
    // Root -> pointer -> page tables. Low 64 KiB maps identically, uncached.
    put32('h2000, 'h2402); put32('h2400, 'h2602); put32('h2500, 'h2802);
    put32('h2200, 'h2A02); put32('h2A00, 'h2C02); put32('h2B00, 'h2E02);
    for (integer i = 0; i < 65536/page_bytes; i++) begin
        put32('h2600 + 4*i, 32'(i*page_bytes) | 'h41);
        put32('h2C00 + 4*i, 32'(i*page_bytes) | 'h41);
    end
    put32('h2800, 'h8001); put32('h2E00, 'hA001);
    put32('h8000, 'hCAFEBABE); put32('hA000, 'hAABBCCDD);
    if (kind == INDIRECT) begin
        put32('h2800, 'h2D02); put32('h2D00, 'h8001);
    end
    if (kind == NONRESIDENT) put32('h2800, 0);
    if (kind == WRITE_PROTECT) put32('h2800, 'h8005);
    if (kind == SUPERVISOR_ONLY) put32('h2E00, 'hA081);
    pc = 'h400;
    emit16('hF4D8); // CINVA BC: reset preserves caches.
    emit16('hF518); // PFLUSHA
    movec('h007, 'h5000C040); // DTT1: uncached mailbox, either privilege.
    if (kind != COPYBACK) begin
        movec('h807, 'h2000); // SRP
        movec('h806, 'h2200); // URP
        movec('h003, page8k ? 'hC000 : 'h8000); // TC
    end
endtask

task automatic finish_program;
    done_pc = pc;
    emit16('h60FE); // BRA.S *: valid in user and supervisor modes.
endtask

task automatic execute(input bit expect_fault);
    integer cycles, sp;
    reg [15:0] ssw, saved_sr;
    @(negedge clk); nreset = 1;
    cycles = 0;
    while (retired_pc != (expect_fault ? 'h1800 : done_pc) && cycles < 30000) begin
        @(negedge clk); cycles++;
    end
    if (cycles == 30000)
        $fatal(1, "Case %0d page=%0d delay=%0d timeout PC=%h bus=%h signatures=%0d",
               scenario, page_bytes, delay_cycles, retired_pc, addr, signatures);
    if (signatures != expected_count) $fatal(1, "Missing case %0d signatures", scenario);
    if (expect_fault) begin
        sp = 'h7000 - 60;
        ssw = scenario == WRITE_PROTECT ? 16'h0405 :
              scenario == SUPERVISOR_ONLY ? 16'h0501 : 16'h0505;
        saved_sr = scenario == SUPERVISOR_ONLY ? 16'h0700 : 16'h2700;
        // MOVE to SR is the final instruction before each faulting access.
        if (get16(sp) != saved_sr || get32(sp+2) != 32'(fault_pc) ||
            get16(sp+6) != 'h7008 || get32(sp+8) != VIRTUAL_DATA ||
            get16(sp+12) != ssw || get32(sp+20) != VIRTUAL_DATA)
            $fatal(1, "Case %0d bad format-7 frame: SR=%h PC=%h fmt=%h EA=%h SSW=%h FA=%h",
                   scenario, get16(sp), get32(sp+2), get16(sp+6), get32(sp+8),
                   get16(sp+12), get32(sp+20));
        if (data_reads != 0 || data_writes != 0 || get32('h8000) != 'hCAFEBABE)
            $fatal(1, "Faulting access reached operand memory");
        if (injected_errors != (scenario == TABLE_ERROR ? 1 : 0))
            $fatal(1, "Wrong number of descriptor bus errors");
    end
    else if (scenario == TRANSLATE || scenario == INDIRECT) begin
        if (get32('h2000) != 'h240A || get32('h2500) != 'h280A ||
            get32(scenario == INDIRECT ? 'h2D00 : 'h2800) !=
                (scenario == INDIRECT ? 'h8019 : 'hA009) || get32('h8000) != 'hD00DFEED)
            $fatal(1, "Descriptor U/M update or translated store failed");
        if (scenario == INDIRECT && get32('h2800) != 'h2D02)
            $fatal(1, "Indirect pointer was overwritten");
    end
    else if (scenario == USER_ROOT) begin
        if (get32('h2200) != 'h2A0A || get32('h2B00) != 'h2E0A || get32('h2E00) != 'hA009)
            $fatal(1, "User root descriptor updates failed");
    end
    if (scenario != COPYBACK && table_reads == 0) $fatal(1, "MMU test performed no table walks");
    cases++;
    $display("PASS: CPU040 case %0d page=%0d delay=%0d signatures=%0d", scenario,
             page_bytes, delay_cycles, signatures);
endtask

initial begin
    for (integer delay_mode = 0; delay_mode < 2; delay_mode++) begin
        for (integer page_mode = 0; page_mode < 2; page_mode++) begin
            for (integer kind = TRANSLATE; kind <= TABLE_ERROR; kind++) begin
                setup(kind, page_mode != 0, delay_mode*3);
                if (kind == TRANSLATE || kind == INDIRECT) begin
                    read_check(VIRTUAL_DATA, 'hCAFEBABE);
                    store(VIRTUAL_DATA, 'hD00DFEED);
                    read_check(VIRTUAL_DATA, 'hD00DFEED);
                    if (kind == TRANSLATE) begin
                        store('h2800, 'hA001);
                        emit16('hF518); // PFLUSHA: observe the replacement mapping.
                        read_check(VIRTUAL_DATA, 'hAABBCCDD);
                    end
                end
                else begin
                    if (kind == USER_ROOT || kind == SUPERVISOR_ONLY) begin
                        emit16('h227C); emit32('h6000); // MOVEA.L #$6000,A1
                        emit16('h4E61); // MOVE A1,USP
                    end
                    emit16('h46FC);
                    emit16((kind == USER_ROOT || kind == SUPERVISOR_ONLY) ? 'h0700 : 'h2700);
                    fault_pc = pc;
                    if (kind == WRITE_PROTECT) store(VIRTUAL_DATA, 'hDEADBEEF);
                    else if (kind == USER_ROOT) read_check(VIRTUAL_DATA, 'hAABBCCDD);
                    else begin emit16('h2039); emit32(VIRTUAL_DATA); end
                end
                finish_program();
                execute(kind >= NONRESIDENT);
            end
        end
        setup(COPYBACK, 0, delay_mode*3);
        movec('h006, 'h0000C020); // DTT0: low 16 MiB, copyback.
        movec('h002, 'h80008000); // CACR: enable I and D caches.
        read_check('h8000, 'hCAFEBABE);
        store('h8000, 'h11223344);
        marker(1);
        read_check('h8000, 'h11223344);
        emit16('h207C); emit32('h8000); // MOVEA.L #$8000,A0
        emit16('hF468); // CPUSHL DC,(A0)
        marker(2);
        read_check('h8000, 'hBBAA9988);
        store('h8000, 'h55667788);
        emit16('hF448); // CINVL DC,(A0): discard without pushing.
        marker(3);
        read_check('h8000, 'hBBAA9988);
        finish_program(); execute(0);
    end
    $display("PASS: CPU040 MMU translation, roots, U/M, ATC flush, faults and copyback (%0d cases)", cases);
    $finish;
end

initial begin
    #80000000;
    $fatal(1, "MMU suite timeout");
end
endmodule
