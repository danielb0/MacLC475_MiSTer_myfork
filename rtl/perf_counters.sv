// perf_counters — free-running 32-bit event counters for profiling on
// hardware, read through the DAFB hex overlay (OSD Debug page, debug builds).
//
// Every counter counts clk cycles (25 MHz) or bus beats while not frozen;
// clear zeroes them all.  Five pages of six counters; the overlay shows one
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
	input       [5:0] core,        // ap68040 dbg_perf

	input             c_req, c_ack, c_write, c_instr,
	input      [31:0] c_addr,
	input             m_req, m_ack,

	output     [63:0] row1,
	output     [31:0] row2,
	output     [63:0] row3,
	output     [63:0] row4
);

localparam N = 30;

wire [2:0] ecls = core[2:0];
wire rom  = c_addr[31:28] == 4'h4;
wire ram  = c_addr[31:30] == 2'b00;
wire vram = c_addr[31:21] == 11'b1111_1001_000;
wire io   = !rom && !ram && !vram;
wire beat = c_req && c_ack;

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

wire [2:0] pg = (page > 3'd4) ? 3'd4 : page;
wire [4:0] base = pg * 3'd6;

assign row1 = {cnt[base], cnt[base + 5'd1]};
assign row2 = {12'hC00, 1'b0, pg, 3'd0, freeze, 3'd0, ovf, 8'h00};
assign row3 = {cnt[base + 5'd2], cnt[base + 5'd3]};
assign row4 = {cnt[base + 5'd4], cnt[base + 5'd5]};

endmodule
