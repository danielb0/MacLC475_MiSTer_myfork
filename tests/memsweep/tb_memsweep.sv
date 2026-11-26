`timescale 1ns/1ps
// Runs a gen.py program on cpu040 and compares the memory it leaves with
// the model's image (exp.hex).  The bus is the machine-side contract of
// wombat_store_buffer: one-clock acknowledge pulses, with lc475's line
// burst when BWAITS is 0.  WAITS / BWAITS / SB as in tests/timing.
module tb_memsweep;
reg clk = 0, nreset = 0;
always #20 clk = ~clk;
wire req, wr, instr, halted, line_more;
wire [1:0] size;
wire [31:0] addr, wdata;
reg ack = 0;
reg [31:0] rdata = 0;
reg [31:0] mem [0:(1<<17)-1];
reg [31:0] exp [0:(1<<17)-1];
integer WAITS = 0, BWAITS = 0, SB = 0, JIT = 0;
integer cyc = 0, cnt = 0, bad = 0, i, lim;
reg [31:0] lfsr = 32'hC0FFEE11;

cpu040 #(.AP040_HAS_FPU(0)) dut (
    .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(3'b111),
    .ipl_autovector(1'b1), .berr(1'b0), .stall_hold(1'b0), .dbg_stall_flt(),
    .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
    .store_buffer_ok(SB != 0), .bus_req(req), .bus_write(wr), .bus_instr(instr),
    .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(),
    .bus_ack(ack), .bus_rdata(rdata), .bus_line_more(line_more),
    .walker_req(), .walker_we(),
    .walker_addr(), .walker_wdat(), .walker_ack(1'b0), .walker_data(32'd0),
    .walker_berr(1'b0), .snoop_stb(1'b0), .snoop_addr(32'd0),
    .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
    .debug_busy(), .debug_fault(), .debug_halted(halted),
    .debug_status(), .debug_status2(), .debug_test_status(),
    .debug_instruction_pc(),
    .perf_clear(1'b0), .perf_freeze(1'b0), .perf_page(3'd0), .perf_vram_ev(12'd0),
    .perf_rows(), .perf_rd_idx(6'd0), .perf_rd_data()
);

wire [16:0] la = addr[18:2];
wire burst = ack && req && !wr && line_more && (BWAITS == 0) && (JIT == 0);
wire [1:0] nlw = addr[3:2] + 2'd1;
wire [31:0] ml = mem[burst ? {addr[18:4], nlw} : la];
reg first = 1;

task finish_run;
    begin
        for (i = 0; i < (1<<17); i = i + 1)
            if (mem[i] !== exp[i]) begin
                if (bad < 12) $display("MISMATCH %05x: got %08x expected %08x", i*4, mem[i], exp[i]);
                bad = bad + 1;
            end
        if (bad == 0) $display("PASS cycles %0d", cyc);
        else $display("FAIL %0d long words differ, cycles %0d", bad, cyc);
        $finish;
    end
endtask

always @(posedge clk) begin
    cyc <= cyc + 1;
    lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    if (!nreset) begin ack <= 0; cnt <= 0; first <= 1; end
    else begin
        if (halted) begin $display("FAIL halted at cycle %0d", cyc); $finish; end
        if (ack && wr) begin
            if (addr == 32'h50000000) finish_run;
            else case (size)
                0: mem[la][8*(3-addr[1:0]) +: 8] <= wdata[7:0];
                1: mem[la][16*(1-addr[1]) +: 16] <= wdata[15:0];
                default: mem[la] <= wdata;
            endcase
        end
        if (burst) ack <= 1;
        else if (req && !ack) begin
            // JIT: a random number of extra clocks before each acknowledge
            lim = (first ? WAITS : BWAITS) + ((JIT != 0) ? (lfsr[2:0] % (JIT + 1)) : 0);
            if (cnt < lim) cnt <= cnt + 1;
            else begin ack <= 1; cnt <= 0; first <= tb_memsweep.dut.bus_adapter.last; end
        end
        else begin ack <= 0; if (!req) begin cnt <= 0; first <= 1; end end
    end
end
always @(posedge clk) begin
    case (size)
        0: rdata <= (ml >> (8*(3-addr[1:0]))) & 32'hFF;
        1: rdata <= (ml >> (16*(1-addr[1]))) & 32'hFFFF;
        default: rdata <= ml;
    endcase
end

initial begin
    $readmemh("prog.hex", mem);
    $readmemh("exp.hex", exp);
    void'($value$plusargs("WAITS=%d", WAITS));
    void'($value$plusargs("BWAITS=%d", BWAITS));
    void'($value$plusargs("SB=%d", SB));
    void'($value$plusargs("JIT=%d", JIT));
    repeat (4) @(negedge clk);
    nreset = 1;
    #400000000;
    $display("FAIL timeout cyc=%0d addr=%h", cyc, addr);
    $finish;
end
endmodule
