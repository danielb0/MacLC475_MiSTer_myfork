`timescale 1ns/1ps
// Clocks per instruction of cpu040 against MC68040UM section 10.
// Memory model: WAITS extra clocks before the first TA, BWAITS before each
// later beat of a line.
module tb_timing;
reg clk = 0, nreset = 0;
always #20 clk = ~clk;
wire req, wr, instr, halted, stall;
wire [1:0] size;
wire [31:0] addr, wdata;
reg ack = 0;
reg [31:0] rdata = 0;
reg [31:0] mem [0:(1<<17)-1];
integer WAITS = 0, BWAITS = 0, SB = 0, TRACE = -1, TPASS = 2, TMAX = 400, DM = 0;
reg tracing = 0, trun = 0;
integer tlines = 0;
integer cyc = 0, cnt = 0;
integer t_mark [0:127];
integer t_first [0:127];
reg [127:0] seen = 128'd0;      // (the first run of a test in the first pass: its cold time)
integer pass = 0;
integer nbus_i = 0, nbus_d = 0, nbus_w = 0;
reg [8*32-1:0] prog;

cpu040 #(.AP040_HAS_FPU(0)) dut (
    .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(3'b111),
    .ipl_autovector(1'b1), .berr(1'b0), .stall_hold(1'b0), .dbg_stall_flt(stall),
    .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
    .store_buffer_ok(SB != 0), .bus_req(req), .bus_write(wr), .bus_instr(instr),
    .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(),
    .bus_ack(ack), .bus_rdata(rdata), .bus_line_more(line_more), .walker_req(), .walker_we(),
    .walker_addr(), .walker_wdat(), .walker_ack(1'b0), .walker_data(32'd0),
    .walker_berr(1'b0), .snoop_stb(1'b0), .snoop_addr(32'd0),
    .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
    .debug_busy(), .debug_fault(), .debug_halted(halted),
    .debug_status(), .debug_status2(), .debug_test_status(),
    .debug_instruction_pc(),
    .perf_clear(1'b0), .perf_freeze(1'b0), .perf_page(3'd0), .perf_vram_ev(12'd0),
    .perf_rows(), .perf_rd_idx(6'd0), .perf_rd_data()
);

wire line_more;
wire [16:0] la = addr[18:2];
// lc475's line burst: in the clock a line read's beat is acknowledged with
// more beats to come, the next longword is looked up and its acknowledge
// registered for the next clock (BWAITS = 0 only)
wire burst = ack && req && !wr && line_more && (BWAITS == 0);
wire [1:0] nlw = addr[3:2] + 2'd1;
wire [31:0] ml = mem[burst ? {addr[18:4], nlw} : la];
reg first = 1;
always @(posedge clk) begin
    cyc <= cyc + 1;
    if (!nreset) begin ack <= 0; cnt <= 0; first <= 1; end
    else begin
        if (halted) begin $display("HALTED at cycle %0d", cyc); $finish; end
        if (ack) begin
            if (wr) begin
                nbus_w <= nbus_w + 1;
                if (addr == 32'h50000000) begin
                    if (wdata[6:0] == 7'h7F) pass <= pass + 1;
                    else if (wdata[6:0] == 7'h7E) begin
                        report(); $finish;
                    end
                    else begin
                        t_mark[wdata[6:0]] <= cyc;
                        // (a test runs twice in a row: the second, timed run is traced)
                        if (pass == TPASS && wdata[6:0] == 2*TRACE) begin tracing <= trun; trun <= 1; end
                        if (wdata[6:0] == 2*TRACE + 1) tracing <= 0;
                        if (pass == 0 && !seen[wdata[6:0]]) begin t_first[wdata[6:0]] <= cyc; seen[wdata[6:0]] <= 1'b1; end
                    end
                end
                else case (size)
                    0: mem[la][8*(3-addr[1:0]) +: 8] <= wdata[7:0];
                    1: mem[la][16*(1-addr[1]) +: 16] <= wdata[15:0];
                    default: mem[la] <= wdata;
                endcase
            end
            else if (instr) nbus_i <= nbus_i + 1; else nbus_d <= nbus_d + 1;
        end
`ifdef AP040_STORE_BUFFER_OFF
        // 68040 bus: TA may stay asserted through a burst (2-1-1-1)
        if (req && !(ack && tb_timing.dut.bus_adapter.last)) begin
            if (ack) begin first <= 0; cnt <= 0; end
            if (!ack && cnt < (first ? WAITS : BWAITS)) begin cnt <= cnt + 1; ack <= 0; end
            else if (ack && BWAITS != 0) ack <= 0;
            else ack <= 1;
        end
        else begin ack <= 0; cnt <= 0; first <= 1; end
`else
        // the machine-side contract behind wombat_store_buffer: one-clock
        // acknowledge pulses, the request seen with ack low in between
        if (burst) ack <= 1;
        else if (req && !ack) begin
            if (cnt < (first ? WAITS : BWAITS)) cnt <= cnt + 1;
            else begin ack <= 1; cnt <= 0; first <= tb_timing.dut.bus_adapter.last; end
        end
        else begin ack <= 0; if (!req) begin cnt <= 0; first <= 1; end end
`endif
    end
end
always @(posedge clk) begin
    case (size)
        0: rdata <= (ml >> (8*(3-addr[1:0]))) & 32'hFF;
        1: rdata <= (ml >> (16*(1-addr[1]))) & 32'hFFFF;
        default: rdata <= ml;
    endcase
end


// +TRACE=n: one line a clock while test n runs in pass TPASS.  Stage columns
// are the uop's instruction PC (low 16 bits) and, for EX, its operation;
// F/L mark the first/last uop of an instruction.
`define CPU tb_timing.dut.cpu
function automatic string stg(input v, input [31:0] pc, input f, input l);
    if (v) stg = $sformatf("%04x%s%s", pc[15:0], f ? "f" : ".", l ? "l" : ".");
    else stg = "  --  ";
endfunction
string s_re, s_dr, s_ex, s_bus;
always @(posedge clk) if (tracing && tlines < TMAX) begin
    tlines <= tlines + 1;
    s_re = ""; s_dr = ""; s_ex = ""; s_bus = "";
    if (`CPU.redir_v)   s_re = $sformatf(" REDIR>%04x", `CPU.redir_pc[15:0]);
    if (`CPU.d_redir_v) s_dr = $sformatf(" dredir>%04x", `CPU.d_redir_pc[15:0]);
    if (`CPU.exc_go)    s_ex = $sformatf(" EXC%0d", `CPU.exc_kind);
    if (req) s_bus = $sformatf("%s%s %08x%s", wr ? "W" : "R", instr ? "i" : "d", addr, ack ? " ACK" : "");
    // +DM=1: the data memory unit's view of DC2 (ready; fast, sfast, hit; simple store; slow; stale DC1; pace hold)
    if (DM != 0) $display("TD %6d rdy%b fast%b sf%b hit%b simple%b slow%b fwait%b job%b done%b stale%b hold1%b exst%b pace%b",
        cyc, `CPU.dmu.dc2_rdy, `CPU.dmu.m2.fast, `CPU.dmu.m2.sfast, `CPU.dmu.m2.x.hit, `CPU.dmu.st_simple,
        `CPU.dmu.dc2_slow, `CPU.dmu.fast_wait, `CPU.dmu.e_job, `CPU.dmu.e_dc2_done, `CPU.dmu.m1_stale,
        `CPU.dmu.dm_hold1, `CPU.dmu.ex_st, `CPU.be.pace_hold);
    $display("T %6d q%0d@%04x rq%0d uq%0d | AG %s DC1 %s DC2 %s EX %s op%02d WB %s | adv %b%b%b%b%b%s%s%s%s | F:%s D:%s B:%0d %s",
        cyc, `CPU.qcnt, `CPU.qpc[15:0], `CPU.rq_n, `CPU.uq_n,
        stg(`CPU.be.ag_v, `CPU.be.ag_u.pc, `CPU.be.ag_u.first, `CPU.be.ag_u.last),
        stg(`CPU.be.dc1_v, `CPU.be.dc1_u.pc, `CPU.be.dc1_u.first, `CPU.be.dc1_u.last),
        stg(`CPU.be.dc2_v, `CPU.be.dc2_u.pc, `CPU.be.dc2_u.first, `CPU.be.dc2_u.last),
        stg(`CPU.be.ex_v, `CPU.be.ex_u.pc, `CPU.be.ex_u.first, `CPU.be.ex_u.last), `CPU.be.ex_u.op,
        stg(`CPU.be.wb_v, `CPU.be.wb_u.pc, `CPU.be.wb_u.first, `CPU.be.wb_u.last),
        `CPU.adv_ag, `CPU.adv_dc1, `CPU.adv_dc2, `CPU.adv_ex, `CPU.adv_wb,
        s_re, s_dr, s_ex, `CPU.dbg_retire ? " ret" : "",
        `CPU.fetch.st.name(), `CPU.dmu.e_st.name(), `CPU.biu.st, s_bus);
end

integer fd, u, um, k, base, base1;
reg [8*80-1:0] name;
task report;
    begin
        fd = $fopen("tests.txt", "r");
        k = 0; base = 0;
        $display("RESULT prog=%0s waits=%0d beat_waits=%0d store_buffer=%0d", prog, WAITS, BWAITS, SB);
        $display("RESULT warm|units|UM/unit|cold|name");
        while ($fscanf(fd, "%d|%d|", u, um) == 2) begin
            void'($fgets(name, fd));
            if (k == 0) begin base = t_mark[1] - t_mark[0]; base1 = t_first[1] - t_first[0]; end
            $display("RESULT %0d|%0d|%0d|%0d|%0s", t_mark[2*k+1] - t_mark[2*k] - base, u, um,
                     t_first[2*k+1] - t_first[2*k] - base, name);
            k = k + 1;
        end
        $display("RESULT bus beats: instr %0d data-read %0d write %0d, cycles %0d", nbus_i, nbus_d, nbus_w, cyc);
    end
endtask

initial begin
    prog = "prog_cb.hex";
    void'($value$plusargs("PROG=%s", prog));
    $readmemh(prog, mem);
    void'($value$plusargs("WAITS=%d", WAITS));
    void'($value$plusargs("BWAITS=%d", BWAITS));
    void'($value$plusargs("SB=%d", SB));
    void'($value$plusargs("TRACE=%d", TRACE));
    void'($value$plusargs("TPASS=%d", TPASS));
    void'($value$plusargs("DM=%d", DM));
    void'($value$plusargs("TMAX=%d", TMAX));
    repeat (4) @(negedge clk);
    nreset = 1;
    #80000000;
    $display("TIMEOUT pass=%0d cyc=%0d addr=%h", pass, cyc, addr);
    $finish;
end
endmodule
