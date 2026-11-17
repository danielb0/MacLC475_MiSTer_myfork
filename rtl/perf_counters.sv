// perf_counters — free-running 32-bit event counters for profiling on
// hardware, read through the DAFB hex overlay (OSD Debug page, debug builds).
//
// Every counter counts clk cycles (25 MHz) or bus beats while not frozen;
// clear zeroes them all.  Seven pages of six counters; the overlay shows one
// page as four rows:
//   row 1 (64 bits): counters 0, 1     row 3 (64 bits): counters 2, 3
//   row 2 (32 bits): header            row 4 (64 bits): counters 4, 5
// header = C 0 0 p | f 0 0 o: p = page, f = frozen, o = a counter wrapped.
//
// Page 0: cycles, instructions retired, decoder queue empty, DC2 held,
//         WB held, engine class 7 (maintenance and done states)
// Page 1: engine cycles by class: lookup/load (E_S_*), store (E_SP_*,
//         E_W_*), line fill, dirty push, single bus transfer, table walk.
//         Idle = cycles minus classes 1-7.
// Page 2: CPU-side bus beats: ROM ifetch, RAM ifetch, ROM data read,
//         RAM data read, RAM data write, I/O (everything else, r/w)
// Page 3: CPU-side bus request cycles (request held, acked or not), same
//         order as page 2
// Page 4: VRAM read beats, VRAM read cycles, VRAM write beats, VRAM write
//         cycles, machine-side (after the store buffer) request cycles,
//         machine-side request cycles without an ack
// Page 5: VRAM controller (vram_ddr3) hits in the line cache and line
//         fills issued; CPU frame buffer reads sent straight to the bus
//         and reads through the engine's general path; VRAM read-wait
//         cycles under a DMA burst; general-path reads that are split
// Page 6: table walks started; CPU frame buffer stores posted and
//         stores through the general path; PFLUSHes (any scope);
//         CINV/CPUSHes reaching the instruction cache; lines pushed by
//         CPUSH (the four MMU/cache counts replaced VRAM controller ones
//         on 2026-11-13: fill-beat waits, prefetches issued and used,
//         split general-path stores)
// The CPU-side counts on pages 5 and 6 are accesses as the data engine
// takes them (ap68040_dmu dbg_perf), one each however many bus beats; they
// replaced VRAM wait counters, so captures before 2026-11-13 read
// differently in slots 32, 33, 35, 37, 38 and 41.
//
// Slots 32 and 37 (frame buffer reads sent straight to the bus, stores
// posted) read 0 since the DMU lost those paths.  They now count RAM data
// beats the CPU marked cache-inhibited (CIOUT asserted): slot 32 reads,
// slot 37 writes.  RAM data reads that are neither these nor line-fill
// beats point at something else keeping RAM out of the data cache.
//
// rd_idx/rd_data read any one counter by number (0-41, page * 6 + slot) for
// the DDR3 snapshot (MacLC475.sv perf_ddr_*): no clear or freeze needed,
// the reader differences successive snapshots.
//
// The CPU side is the CPU's own bus, before the store buffer: a request
// cycle there is a cycle the CPU's bus unit waits.  Beats are acked
// longwords; a line fill is four.

module perf_counters (
	input             clk,
	input             clear,       // level: hold all counters at zero
	input             freeze,      // level: stop counting
	input       [2:0] page,

	input             retire, retire2,
	input      [15:0] core,        // ap68040 dbg_perf

	input             c_req, c_ack, c_write, c_instr,
	input             c_ci,            // the cycle's CIOUT (cache-inhibited)
	input      [31:0] c_addr,
	input             m_req, m_ack,
	input      [11:0] vram_ev,         // vram_ddr3 event strobes, pages 5-6
	input     [255:0] trap,            // ap68040 dbg_trap: read as 42-49

	output     [63:0] row1,
	output     [31:0] row2,
	output     [63:0] row3,
	output     [63:0] row4,

	input       [5:0] rd_idx,
	output     [31:0] rd_data
);

localparam N = 42;

wire [2:0] ecls = core[2:0];
wire rom  = c_addr[31:28] == 4'h4;
wire ram  = c_addr[31:30] == 2'b00;
wire vram = c_addr[31:21] == 11'b1111_1001_000;
wire io   = !rom && !ram && !vram;
wire beat = c_req && c_ack;
wire ram_rd_ci = beat && ram && !c_instr && !c_write && c_ci;   // slot 32
wire ram_wr_ci = beat && ram && !c_instr &&  c_write && c_ci;   // slot 37

// one request-cycle event per category; beats are the same and c_ack
wire [5:0] cat = {
	c_req && io,
	c_req && ram && !c_instr &&  c_write,
	c_req && ram && !c_instr && !c_write,
	c_req && rom && !c_instr,
	c_req && ram &&  c_instr,
	c_req && rom &&  c_instr
};

wire [N-1:0] ev = {
	// pages 5 and 6: vram_ddr3's events, six replaced by the core's
	core[15:13], core[10], ram_wr_ci, core[12],
	core[8], vram_ev[4], core[7], ram_rd_ci, vram_ev[1:0],
	// page 4
	m_req && !m_ack, m_req,
	c_req && vram && c_write, beat && vram && c_write,
	c_req && vram && !c_write, beat && vram && !c_write,
	// page 3, page 2
	cat, cat & {6{c_ack}},
	// page 1
	ecls == 3'd6, ecls == 3'd5, ecls == 3'd4,
	ecls == 3'd3, ecls == 3'd2, ecls == 3'd1,
	// page 0
	ecls == 3'd7, core[4], core[3], core[5], 1'b0, 1'b1
};

reg  [31:0] cnt [0:N-1];
wire [N-1:0] wrap;
reg         ovf = 1'b0;

genvar g;
generate for (g = 0; g < N; g = g + 1) begin : g_cnt
	// counter 1 (retired) can step by two in a dual-issue clock
	wire  [1:0] inc = (g == 1) ? {retire && retire2, retire ^ retire2} :
	                             {1'b0, ev[g]};
	wire [32:0] nxt = {1'b0, cnt[g]} + {31'd0, inc};
	initial cnt[g] = 32'd0;
	always @(posedge clk)
		if (clear) cnt[g] <= 32'd0;
		else if (!freeze) cnt[g] <= nxt[31:0];
	assign wrap[g] = !clear && !freeze && nxt[32];
end endgenerate

always @(posedge clk)
	if (clear) ovf <= 1'b0;
	else if (|wrap) ovf <= 1'b1;

wire [2:0] pg = (page > 3'd6) ? 3'd6 : page;
wire [5:0] base = pg * 3'd6;

assign row1 = {cnt[base], cnt[base + 6'd1]};
assign row2 = {12'hC00, 1'b0, pg, 3'd0, freeze, 3'd0, ovf, 8'h00};
assign row3 = {cnt[base + 6'd2], cnt[base + 6'd3]};
assign row4 = {cnt[base + 6'd4], cnt[base + 6'd5]};

// 42-49 are not counters: the CPU's last F-line / illegal trap capture
wire [5:0] trap_k = rd_idx - 6'd42;
assign rd_data = (rd_idx < N)      ? cnt[rd_idx] :
                 (rd_idx < 6'd50)  ? trap[trap_k[2:0] * 32 +: 32] : 32'd0;

endmodule
