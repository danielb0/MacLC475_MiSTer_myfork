//--------------------------------------------------------------------------//
// AP68040 - pipelined MC68040                                            //
//                                                                          //
// ap68040_fetch.sv - instruction fetch: I-ATC, instruction cache and the   //
// instruction queue                                                        //
//                                                                          //
// Instruction cache (MC68040UM section 4): four ways of 2**CSB sets of   //
// 16-byte lines (pkg: 8 Kbytes; the 68040's 4 with CSB 6), physically     //
// tagged (PA31-CSH+1; the set is LA[CSH:4]), a                            //
// valid bit per line, replacement by the first invalid way, else a 2-bit  //
// counter.  Lines are filled by a burst (critical long word first, TBI    //
// handled by the BIU, TCI: the line is not allocated).  Cache-inhibited   //
// pages and CACR.IE = 0 fetch long words.  The data RAM holds a long word //
// per address: F1 reads its long word of each way, a fill writes each    //
// beat into the victim way as it arrives; the victim is invalidated and   //
// retagged as the fill starts and validated when it completes (a TCI or  //
// failed fill leaves it invalid, 4.6.1).                                  //
//                                                                          //
// I-ATC (3.3): 64 entries like the D-ATC, translating supervisor and user //
// program space; ITT0/ITT1 transparent translation.  An ATC miss asks the //
// DMU's engine for a table walk; the walk installs the entry here         //
// (iatc_wr) -- a failed search too, as a nonresident entry (3.3) -- and   //
// the fetch looks again.                                                   //
//                                                                          //
// Pipeline, one aligned long word (two words) per cycle -- D1 decodes at  //
// most one instruction a cycle, and the queue absorbs long ones:         //
//   F0  fpc: I-ATC and ITT lookup, cache tag and data RAM read            //
//   F1  translation, tag compare; a hit is the long word's words from    //
//       the fetch address on.  Anything else rolls fpc back and runs in   //
//       miss engine (walk, line fill, cache-inhibited stream, fault)      //
//   F2  predecode                                                          //
//   F3  append to the queue                                                //
//                                                                          //
// The queue holds QN words: slot 0 is always the next word D1 decodes.    //
// A redirect (D1 branch or WB) empties the queue and the pipeline.  A     //
// faulted fetch marks its words; D1 raises the fault only if it uses them //
// (8.2.1).  Only the first fetch of a redirected stream is a demand       //
// fetch; a fault on the lookahead after it is speculative, and the back   //
// end refetches it on demand before it becomes an access error.           //
//                                                                          //
// Branch target buffer: 256 entries (BTB_AW) looked up with the F0       //
// address; a hit (the long word holds the last word of a branch D1        //
// predicted taken) ends the chunk at that word, flags it, and sends F0 to //
// the target in F1 (one bubble): the entry's, or for a return the top of //
// the fetch's return stack (pushed by the calls it takes, resynchronized //
// from D1's on every redirect).  The flagged word's target travels in a  //
// FIFO; D1 checks every flagged word against its own decode.              //
//                                                                          //
// Target words (BTIC): beside each BTB entry, the long word its target    //
// starts in, as the cache answered the first fetch the entry sent there   //
// (a hit, with no BTB branch and no possible branch end in it).  A taken  //
// branch whose entry has them hands them to F2 in the cycle the redirect  //
// would lose, and F0 goes on at the long word after: the target reaches   //
// D1 a cycle sooner, often in time to pair with the branch.  They are a   //
// copy of the cache's: all dropped by whatever can change what the cache  //
// or the translation answers (CINV/CPUSH, a snooped invalidation, an      //
// I-ATC flush, a change of CACR.IE, TC, ITTn, CDIS or MDIS), tagged with  //
// the S bit and the target they were fetched at (used only while the     //
// entry names that target).  Returns have none.                           //
//                                                                          //
// CINV/CPUSH of the instruction cache arrive from the DMU (ic_inv): all   //
// in one cycle, a line in two, a page by a scan of the sets.  Bus        //
// snooping (sn_inv) invalidates a line the same way (MC68040UM table   //
// 4-3, V5/V6).                                                            //
//--------------------------------------------------------------------------//

module ap68040_fetch
	import ap68040_pkg::*, ap68040_upkg::*;
#(
	parameter bit BTIC = 1,         // the BTB entries' target words
	// A fetch is a half-line, four words, from its address to the half-line's
	// end (MC68040UM 4.7.1: a hit puts the half-line selected by address bit 3
	// on the instruction bus); 0: a long word, two.  Not with BTIC, whose
	// target words are a long word: BTIC keeps the long word.
	parameter bit HLF  = 1,
	// Both paths of a conditional branch (MC68040UM 1.x: "both execution
	// paths of the branch are fetched and decoded to minimize refilling of
	// the instruction pipeline"; 2.1: shadow registers).  D1 asks for the
	// path it did not choose (alt_req); F0 fetches its half-line in a slot
	// the stream does not need, F1-F3 carry it marked as a shadow chunk
	// (predecoded on the way), and F3 keeps it in one of SE entries.  A
	// back-end redirect for a wrong guess (redir_br) to an entry's address
	// loads its words into the queue in the redirect's clock, and F0 goes
	// on at the next half-line.  HLF only.
	parameter bit SHADOW = 0,
	parameter logic [2:0] S1_CLASSES = 3'b111,  // second-slot classes marked: {load, An, Dn}
	parameter logic [3:0] S1_LDMASK  = 4'b1111  // ... of the loads: {TST (Ay), ALU (Ay),Dx, MOVEA.L (Ay),Ax, MOVE (Ay),Dx}
)(
	input  logic        clk,
	input  logic        nreset,

	input  logic        redir_v,      // highest priority
	input  logic [31:0] redir_pc,
	input  logic        redir_br,     // ... for a wrong branch or jump guess (SHADOW)
	input  logic        alt_req,      // D1: a conditional branch's other path (SHADOW)
	input  logic [31:0] alt_pc,
	input  logic        d_redir_v,    // decoder (predicted branch)
	input  logic [31:0] d_redir_pc,
	input  logic        stop,         // do not start new fetches

	input  logic        smode,        // S bit: program space and TM 6/2
	input  logic [31:0] cacr,
	input  logic [31:0] tc,
	input  logic [31:0] itt0,
	input  logic [31:0] itt1,
	input  logic        cdis,         // CDIS: the cache is disabled (contents kept)
	input  logic        mdis,         // MDIS: no page translation

	// decoder side
	output logic [15:0] win [8],
	output logic  [7:0] win_flt,      // the word came from a faulted fetch
	output logic  [7:0] win_fdem,     // ... the first of a redirected stream
	output logic  [7:0] win_fatc,     // ... an ATC (MMU) fault, else bus error
	output logic  [7:0] win_bt,       // ... ends a branch the BTB took
	output logic  [7:0] win_s1,       // ... is a second-slot operation word (s1_dec)
	output logic [31:0] bt_tgt,       // the target of the first such word
	output pd_t         pd0,          // predecode of win[0]
	output pd_t         pd0_n,        // ... as it will be next cycle
	output logic  [3:0] qcnt,         // words available in win (0..8)
	output logic [31:0] qpc,
	input  logic  [2:0] consume,
	input  logic        consume_t,    // ... and a word past the BTB-taken branch's end
	output logic        q_odd,        // the stream starts at an odd address
	input  logic        btb_we,       // D1 writes a BTB entry
	input  logic [BTB_AW-1:0] btb_wi,
	input  logic        btb_wv,       // valid (0 drops the entry)
	input  logic [BTB_TW-1:0] btb_wtag,
	input  logic        btb_wslot,    // the branch ends at word 1 of the long word
	input  logic  [1:0] btb_wkind,    // 0 branch, 1 call, 2 return (target from the stack)
	input  logic [30:0] btb_wtgt,     // target[31:1]
	input  logic [30:0] d_ras,        // D1's return stack, its top entry: the
	input  logic  [2:0] d_ras_tp,     // ... fetch's pointer and top entry are
	input  logic  [3:0] d_ras_n,      // ... resynchronized on every redirect
	input  logic        d_ras_xp,     // ... and when D1 pops a spent entry after one

	// DMU: table walks for the I-ATC, I-ATC maintenance, cache invalidation
	output logic        iw_req,
	output logic [31:0] iw_va,
	output logic        iw_fc2,
	input  logic        iw_done,
	input  logic        iatc_wr,
	input  logic [31:0] iatc_wla,
	input  logic        iatc_wfc2,
	input  atce_t       iatc_went,
	input  logic        iatc_flush_all,
	input  logic        iatc_flush_page,
	input  logic        iatc_flush_ng,
	input  logic [31:0] iatc_flush_la,
	input  logic        iatc_flush_fc2,
	input  logic        ic_inv,
	input  logic  [1:0] ic_inv_scope,  // 1 line, 2 page, 3 all
	input  logic [31:0] ic_inv_pa,
	output logic        ic_inv_done,
	input  logic        sn_inv,        // snooper: invalidate the line at sn_inv_pa
	input  logic [31:0] sn_inv_pa,
	input  logic        sn_inv_all,    // ... or every line
	output logic        sn_inv_done,
	output logic        sn_ihit,       // ... and removed a valid line (or the line buffer)
	output logic [191:0] dbg_f,        // observation only (a system's logic analyser)

	// BIU client
	output logic        b_req,
	output busreq_t     b_breq,
	input  logic        b_gnt,
	input  logic        b_done,
	input  logic        b_err,
	input  logic        b_rvalid,
	input  logic [31:0] b_rdata,
	input  logic  [1:0] b_rbeat,
	input  logic        b_rtci
);

// The queue's words.  F1 to F3 cannot wait, so F0 fetches only while the
// queue has room for everything on its way (room, below): six words with
// each stage full.  At 8 that left room for a fetch only with the queue
// empty, and an instruction of three words or more waited for the fetch
// pipeline's latency again each time (2.45 clocks for three words, 5.47
// for five); at 16 the fetch runs without a break, a long word a clock.
localparam int QN = 16;

// The instruction cache's own geometry, in place of the package's (which
// the data cache keeps): CSB 8, 16 Kbytes, the largest whose set stays in
// the page offset (an experiment: does QuickDraw's ROM code miss at 8K?).
localparam int CSB = 6;
localparam int CSH = CSB + 3;
localparam int CTW = 28 - CSB;

// the fetch's chunk: FW words, a word's place in it FWL bits
localparam bit HL  = HLF && !BTIC;
localparam int FW  = HL ? 4 : 2;
localparam int FWL = HL ? 2 : 1;

wire tc_e  = tc[15] && !mdis;
wire tc_p  = tc[14];
wire ic_en = cacr[15] && !cdis;

function automatic logic ttr_hit(input logic [31:0] t, input logic [31:0] a,
                                 input logic s);
	ttr_hit = t[15] && (((a[31:24] ^ t[31:24]) & ~t[23:16]) == 8'd0) &&
	          (t[14] || (t[13] == s));
endfunction

//--------------------------------------------------------------------------
// queue
//--------------------------------------------------------------------------
logic [15:0]   qw [QN];
// the words' predecode: D1 reads only the head's, so it is a ring (no
// shift) with the head in a register (qp0) -- loaded as D1 consumes from
// the ring, or from F3 when the queue empties into it
// (FW LUT RAM banks by the slot's low bits: F3's words land in consecutive
// slots, one per bank, so each bank has one write a cycle)
logic [$bits(pd_t)-1:0] qpr_q [FW];     // each bank at the next head's row
logic [FW-1:0]          qpr_we;
logic [3-FWL:0]         qpr_wa [FW];
logic [$bits(pd_t)-1:0] qpr_wd [FW];
logic                   f3_go;          // F3 moves on this cycle
logic                   f3_q;           // ... and its words join the queue
// SHADOW: a redirect loads a shadow entry into the queue (sh_use, sh_e)
logic                   sh_use;
logic  [1:0]            sh_e;
// (the words a matching redirect loads: an entry's, or the shadow chunk
// in F3 this very clock)
logic  [2:0]            ld_n;
logic [15:0]            ld_w [4];
pd_t                    ld_p [4];
logic  [3:0]            ld_s, ld_b;
logic [30:0]            ld_t, ld_pc;
logic  [3:0]            qh_n;
logic  [3:0]   qh;             // the ring's head
pd_t           qp0;
// synthesis translate_off
pd_t           qps [QN];       // (simulation: the shifting model, checked)
// synthesis translate_on
logic [QN-1:0] qf, qd, qa;     // faulted, demand fetch, ATC fault
logic [QN-1:0] qb;             // ends a branch the BTB took
logic [QN-1:0] qs;             // a second-slot operation word, taken as one
logic [30:0]   tq [4];         // their targets, in queue order
logic  [2:0]   tq_n;
logic  [4:0]   cnt;
logic [31:0]   qpc_r;
logic          odd;

assign qcnt  = (cnt > 5'd8) ? 4'd8 : cnt[3:0];
assign qpc   = qpc_r;
assign q_odd = odd;
assign pd0   = qp0;
// the head's predecode as it will be next cycle (qp0's load): D1's
// attribute ROM reads it a cycle ahead
assign qh_n = qwrap(5'(qh) + {2'b00, consume});            // the head next cycle
pd_t       qpr_rd;
assign qpr_rd = pd_t'(qpr_q[qh_n[FWL-1:0]]);
always_comb begin
	qpr_we = '0;
	for (int b = 0; b < FW; b++) begin qpr_wa[b] = '0; qpr_wd[b] = '0; end
	for (int j = 0; j < FW; j++) begin
		logic [3:0] w;
		w = qwrap(5'(qh) + cnt + 5'(j));
		if (3'(j) < f3_n && f3_q && !sh_use) begin
			qpr_we[w[FWL-1:0]] = 1'b1;
			qpr_wa[w[FWL-1:0]] = w[3:FWL];
			qpr_wd[w[FWL-1:0]] = f3_p[j];
		end
	end
	// (the shadow's words at the new head: the queue is emptied by the
	// redirect, so they take the first slots, one per bank)
	for (int j = 0; j < FW; j++) begin
		logic [3:0] w;
		w = qwrap(5'(qh_n) + 5'(j));
		if (sh_use && 3'(j) < ld_n) begin
			qpr_we[w[FWL-1:0]] = 1'b1;
			qpr_wa[w[FWL-1:0]] = w[3:FWL];
			qpr_wd[w[FWL-1:0]] = ld_p[j];
		end
	end
end
genvar gq;
generate
	for (gq = 0; gq < FW; gq++) begin : g_qpr
		(* ramstyle = "MLAB, no_rw_check" *) logic [$bits(pd_t)-1:0] m [16 / FW];
		always_ff @(posedge clk) if (nreset && qpr_we[gq]) m[qpr_wa[gq]] <= qpr_wd[gq];
		assign qpr_q[gq] = m[qh_n[3:FWL]];
	end
endgenerate
// (SHADOW: a redirect that loads a shadow entry: its first word's)
assign pd0_n = sh_use ? ld_p[0] :
               (cnt == {2'b00, consume} && !f3_alt) ? f3_p[0] : qpr_rd;
function automatic logic [3:0] qwrap(input logic [4:0] x);   // x mod QN, x < 2*QN
	qwrap = (x >= 5'(QN)) ? 4'(x - 5'(QN)) : x[3:0];
endfunction

always_comb begin
	for (int i = 0; i < 8; i++) begin
		win[i]      = qw[i];
		win_flt[i]  = qf[i];
		win_fdem[i] = qd[i];
		win_fatc[i] = qa[i];
		win_bt[i]   = qb[i];
		win_s1[i]   = qs[i];
	end
end
assign bt_tgt = {tq[0], 1'b0};

// F2: the words of a chunk, their table words read (ap68040_pdrom, the
// words a cycle after their addresses); F3: predecoded from the table
// words and appended this cycle
logic  [2:0]  f2_n;
logic [15:0]  f2_w [FW];
logic         f2_f, f2_d, f2_a;
logic [FW-1:0] f2_b;           // the word ends a BTB-taken branch
logic [30:0]  f2_t;
logic  [2:0]  f3_n;
logic [15:0]  f3_w [FW];
pdw_t         f3_r [FW];       // the table's words for f3_w
pd_t          f3_p [FW];
logic         f3_f, f3_d, f3_a;
logic [FW-1:0] f3_b;
logic [FW-1:0] f3_s;           // s1_dec(f3_w[i]).v, decoded in F2
// (each word's s1_dec a named result: Vivado 2023.2 synthesizes the
// member of a function call's result, `s1_dec(w).v`, as a constant 0 --
// f3_s_reg removed, no second-slot word ever marked, dual issue off on
// the board while every simulator paired)
s1_t          f2_s1 [FW];
always_comb for (int i = 0; i < FW; i++) f2_s1[i] = s1_dec(f2_w[i]);
// a second-slot load's kind, for S1_LDMASK: 0 MOVE (Ay),Dx, 1 MOVEA.L (Ay),Ax,
// 2 ADD/SUB/AND/OR/CMP (Ay),Dx, 3 TST (Ay)
function automatic logic [1:0] s1_ldk(input s1_t s);
	s1_ldk = !s.d_v && s.op == S1_MOV ? 2'd3 : s.op != S1_MOV ? 2'd2 : s.d_reg[3] ? 2'd1 : 2'd0;
endfunction
logic [30:0]  f3_t;
// SHADOW: the shadow entries, the requests waiting for F0, and the shadow
// chunk's marks in F1-F3
localparam int SE = 4;
logic [SE-1:0] sh_v;
logic [30:0]   sh_pc [SE];
logic  [2:0]   sh_n  [SE];
logic [15:0]   sh_w  [SE][FW];
pd_t           sh_p  [SE][FW];
logic [FW-1:0] sh_s  [SE];
logic [FW-1:0] sh_b  [SE];     // the word that ends a branch the BTB takes (plain branches)
logic [30:0]   sh_t  [SE];     // ... its target
logic  [1:0]   sh_rr;          // the next entry to fill
logic  [1:0]   sh_blk;         // clocks a capture is refused after an invalidation
logic  [1:0]   ap_v;           // requests (a FIFO of two)
logic [30:0]   ap_pc [2];
logic          f1_alt, f2_alt, f3_alt;
logic  [1:0]   f1_ai, f2_ai, f3_ai;
genvar gp;
generate
	// (a table per pair of words: it has two reads)
	for (gp = 0; gp < FW / 2; gp++) begin : g_pdrom
		ap68040_pdrom pdrom (.clk(clk), .a0(f2_w[2*gp][15:3]), .a1(f2_w[2*gp+1][15:3]),
		                     .q0(f3_r[2*gp]), .q1(f3_r[2*gp+1]));
	end
	for (gp = 0; gp < FW; gp++) begin : g_pd
		ap68040_predec pd (.op(f3_w[gp]), .w(f3_r[gp]), .pd(f3_p[gp]));
		// synthesis translate_off
		// (the table form against the parallel pattern decoder)
		pd_t pd_ref;
		ap68040_predec_pla pdr (.op(f3_w[gp]), .pd(pd_ref));
		always_ff @(posedge clk)
			if (nreset && f3_n > 3'(gp) && f3_p[gp] !== pd_ref) begin
				$display("FAIL: fetch: the table predecode of %04x is %h, the pattern decoder's %h", f3_w[gp], f3_p[gp], pd_ref);
				$finish;
			end
		// synthesis translate_on
	end
endgenerate

//--------------------------------------------------------------------------
// I-ATC
//--------------------------------------------------------------------------
logic [31:0] fpc;              // F0 fetch address (A0 clear)
// A redirect's own clock is the F0 of its target: the lookups below take the
// target's address then (fa), and F1 has it the clock after -- where the
// redirect first loaded fpc and F0 ran a clock later.  One clock off every
// redirect; the address is a flip-flop's either way (rf0, below).
logic [31:0] fa;

// BTB: one array per word of the long word (a branch ending at word 0,
// one ending at word 1), each valid, tag, kind, target[31:1]: two taken
// branches in one long word (BSR then RTS, a short branch then RTS) no
// longer evict each other
localparam int BTB_DW = 1 + BTB_TW + 2 + 31;
logic [31:0] f1_pc;              // F1's address
// (block RAM: F0 presents fpc, F1 compares with f1_pc; an entry D1 writes
// at the edge F0's read registers it is not trusted -- no prediction)
// (a half-line's fetch: four arrays of half the rows, the entry's row
// PC[BTB_AW+1:3] and its array PC[2:1] -- the same entries, the same tags)
localparam int BTB_RW = BTB_AW + 1 - FWL;
logic [BTB_DW-1:0] btb_qa [FW];
logic [BTB_DW-1:0] btb_q;
logic        btb_cf;
wire [BTB_RW-1:0] btb_wa = btb_wi[BTB_AW-1 -: BTB_RW];
wire [BTB_RW-1:0] btb_ra = fa[BTB_AW+1 -: BTB_RW];
wire [FWL-1:0]    btb_ws = FWL'({btb_wi[0], btb_wslot});
genvar gb;
generate
	for (gb = 0; gb < FW; gb++) begin : g_btb
		ap68040_sdpr #(.AW(BTB_RW), .DW(BTB_DW)) btb (
			.clk(clk), .we(btb_we && btb_ws == FWL'(gb)), .waddr(btb_wa),
			.wdata({btb_wv, btb_wtag, btb_wkind, btb_wtgt}),
			.raddr(btb_ra), .q(btb_qa[gb])
		);
	end
endgenerate
always_ff @(posedge clk) btb_cf <= btb_we && (btb_wa == btb_ra);
// the first branch of the fetch: the first that ends at or after its start
logic           btb_hit;
logic [FWL-1:0] btb_hslot;
always_comb begin
	btb_hit = 1'b0; btb_hslot = '0;
	for (int i = FW - 1; i >= 0; i--)
		if (!btb_cf && btb_qa[i][BTB_DW-1] && btb_qa[i][BTB_DW-2 -: BTB_TW] == f1_pc[31:BTB_AW+2] &&
		    FWL'(i) >= f1_pc[FWL:1]) begin
			btb_hit = 1'b1; btb_hslot = FWL'(i);
		end
end
wire btb_qslot = btb_hslot[0];           // (the target words': BTIC, a long word)
assign btb_q   = btb_qa[btb_hslot];

// the target words: {S, target[31:1], the long word} per entry in block
// RAM beside the BTB's (read with it), their valid bits in LUT RAM
// (dropped all at once by a sweep of the entries, which keeps the words
// out of use while it runs); a write at the edge F0's read registers is
// not trusted
logic [63:0] tw_q0, tw_q1;
(* ramstyle = "MLAB, no_rw_check" *) logic twv0 [1<<BTB_AW];
(* ramstyle = "MLAB, no_rw_check" *) logic twv1 [1<<BTB_AW];
logic        twq0, twq1, tw_cf;
logic        tw_sw;              // the sweep runs
logic [BTB_AW-1:0] tw_si;        // ... at this entry
logic        tw_we;              // the fill (registered)
logic [BTB_AW-1:0] tw_wi;
logic        tw_wslot;
logic [63:0] tw_wd;
logic        pf_v;               // the BTB sent F0 to a target without words:
logic [BTB_AW-1:0] pf_i;         // ... fill this entry's
logic        pf_slot;
logic [30:0] pf_t;               // ... from the first fetch there
logic        tj_v;               // target words for F2 (the redirect's cycle)
logic        tj_n2;              // ... both words of the long word (else the low)
logic [31:0] tj_w;
ap68040_sdpr #(.AW(BTB_AW), .DW(64)) tw0 (
	.clk(clk), .we(BTIC && tw_we && !tw_wslot), .waddr(tw_wi), .wdata(tw_wd),
	.raddr(fpc[BTB_AW+1:2]), .q(tw_q0)
);
ap68040_sdpr #(.AW(BTB_AW), .DW(64)) tw1 (
	.clk(clk), .we(BTIC && tw_we && tw_wslot), .waddr(tw_wi), .wdata(tw_wd),
	.raddr(fpc[BTB_AW+1:2]), .q(tw_q1)
);
// what the cache and the translation answer: a change drops every entry's
// words (as do CINV/CPUSH, snooped invalidations and I-ATC flushes)
// (the TTRs' fields that match and set the cache mode)
logic [44:0] tw_cfg;
wire  [44:0] tw_cfg_n = {ic_en, tc_e, tc_p, itt0[31:13], itt0[6:5], itt1[31:13], itt1[6:5]};
wire         tw_clr = ic_inv || sn_inv || iatc_flush_all || iatc_flush_page ||
                      iatc_flush_ng || (tw_cfg != tw_cfg_n);
always_ff @(posedge clk) begin
	logic [BTB_AW-1:0] a;
	twq0  <= twv0[fpc[BTB_AW+1:2]];
	twq1  <= twv1[fpc[BTB_AW+1:2]];
	tw_cf <= tw_clr || tw_sw || (tw_we && tw_wi == fpc[BTB_AW+1:2]);
	tw_cfg <= tw_cfg_n;
	if (!nreset || tw_clr) begin
		tw_sw <= 1'b1;
		tw_si <= '0;
	end
	else if (tw_sw) begin
		tw_si <= tw_si + 1'd1;
		if (&tw_si) tw_sw <= 1'b0;
	end
	// (one write a cycle per array: the sweep's, else a fill's)
	a = tw_sw ? tw_si : tw_wi;
	if (nreset && (tw_sw || (tw_we && !tw_wslot))) twv0[a] <= !tw_sw;
	if (nreset && (tw_sw || (tw_we &&  tw_wslot))) twv1[a] <= !tw_sw;
end
initial for (int i = 0; i < (1 << BTB_AW); i++) begin twv0[i] = 1'b0; twv1[i] = 1'b0; end
// a word that could be the last of a change of flow D1 predicts (or of
// any F-line instruction): a target long word with one keeps the fetch
// there, where the BTB sees the branches that end in it
function automatic logic cof_w(input logic [15:0] w);
	cof_w = (w[15:12] == 4'h6) || (w[15:12] == 4'hF) ||
	        (w[15:7] == 9'b0100_1110_1) ||               // JSR, JMP
	        (w[15:3] == 13'b0100_1110_0111_0) ||         // RTE, RTS, RTR, ...
	        (w[15:12] == 4'h5 && w[7:3] == 5'b11001);    // DBcc
endfunction

// the fetch's return stack: pushed by calls the BTB takes, popped by the
// returns it takes (their target), resynchronized from D1's on redirects
// (a LUT RAM: one write a cycle -- a call's push, or the top entry on a
// redirect -- and the top read; the entries below the top are the fetch's
// own: only predictions, EX checks every return)
(* ramstyle = "MLAB, no_rw_check" *) logic [30:0] fras [8];
logic  [2:0] fras_tp;
logic  [3:0] fras_n;
logic        atc_hit;
atce_t       atc_e;
ap68040_atc #(.SAME_SEARCH(0)) iatc (
	.clk(clk), .nreset(nreset), .p8k(tc_p),
	.la(iatc_flush_page ? iatc_flush_la : fa),
	.fc2(iatc_flush_page ? iatc_flush_fc2 : smode), .set_m(4'd0),
	.hit(atc_hit), .ent(atc_e), .hv(), .wpa(),
	.la_d(32'd0), .fc2_d(1'b0), .set_d(4'd0), .hv_d(), .wpa_d(),
	.wr(iatc_wr), .wla(iatc_wla), .wfc2(iatc_wfc2), .went(iatc_went),
	.wsame(1'b0), .wsame_hv(4'd0),
	.flush_all(iatc_flush_all), .flush_page(iatc_flush_page),
	.flush_nonglobal(iatc_flush_ng)
);

//--------------------------------------------------------------------------
// cache arrays: tags and data in block RAM (read address registered in
// F0), valid bits in flip-flops
//--------------------------------------------------------------------------
// line valid, per set and way: a word of the four ways per set in LUT
// RAMs written at the edge and read without a clock -- one copy at F1's
// set, one at the fill's set or the invalidation's (they never run at
// once).  The second is read at the set every write goes to, so it forms
// the word written (the ways not written keep their bits).  Clearing every
// line (CINVA, a snooped clear, reset) runs the invalidation over the sets
(* ramstyle = "MLAB, no_rw_check" *) logic [3:0] ivf [1<<CSB];
(* ramstyle = "MLAB, no_rw_check" *) logic [3:0] ivo [1<<CSB];
wire   [3:0]   ivf_q, ivo_q;
logic [CSB-1:0] ivo_ra;
logic          inv_rst;         // the invalidation is reset's clear
// synthesis translate_off
logic  [3:0]   iv [1<<CSB];      // (simulation: the flip-flop model, checked)
// synthesis translate_off
initial for (int i = 0; i < (1 << CSB); i++) iv[i] = 4'd0;
// synthesis translate_on
// synthesis translate_on
logic  [1:0]   rr;
logic [CSB-1:0] c_raddr;
logic          c_we;
logic [CSB-1:0] c_waddr;
logic  [1:0]   c_wway;
logic [CTW-1:0] c_wtag;
logic [63:0]   cd [4];        // each way's long word (half-line: HL) at F1's address
logic [23:0]   ct [4];

logic [31:0] m_cw;               // the fill's first long word (the one fetched)
logic  [3:0] m_got;              // ... the long words of it that arrived
logic        m_vclr;             // the fill's victim line is still to be invalidated
logic        m_rrinc;            // ... the set was full: the replacement counter moves
// The data RAMs hold a long word per address ({set, A3:A2}): F1 reads its
// long word of each way directly, and a fill writes each beat into the
// victim way as it arrives.  The victim is invalidated and given its new
// tag as the fill starts, and validated when the line is complete (a
// failed or TCI fill leaves it invalid, MC68040UM 4.6.1): the line is in
// the cache for the first fetch after it -- no line buffer.  The long word
// being fetched (the burst's first) is kept for a fill that is not
// allocated (TCI, a later beat's bus error), which delivers it alone.
wire         c_dwe = (st == S_FILL) && b_rvalid && m_alloc && !m_vclr;
// Each way's write enable is a bit of a one-hot vector (c_dwe_w with m_way, c_we_w), not a
// `== 2'(genvar)` compare in the port list: Vivado 2023.2 synthesis
// evaluates that compare wrongly for some ways, finds their write enables
// equal (or constant 0), and merges or removes the RAMs (Synth 8-223
// decloning, 8-7257), so a fill of one way lands in another.
wire [3:0] c_we_w  = c_we  ? 4'b0001 << c_wway : 4'b0000;
genvar gw;
generate
	for (gw = 0; gw < 4; gw++) begin : g_way
		if (HL) begin : g_hl
			// a half-line per address ({set, A3}), its long words in two
			// memories: a beat is written to its own
			ap68040_sdp_be #(.AW(CSB+1), .NB(4), .OREG(0)) dram_h (
				.clk(clk), .we(c_dwe_w[gw] && !b_rbeat[0]), .waddr({m_pa[CSH:4], b_rbeat[1]}),
				.wbe(4'hF), .wdata(b_rdata), .raddr(fa[CSH:3]), .oce(1'b1), .q(cd[gw][63:32])
			);
			ap68040_sdp_be #(.AW(CSB+1), .NB(4), .OREG(0)) dram_l (
				.clk(clk), .we(c_dwe_w[gw] && b_rbeat[0]), .waddr({m_pa[CSH:4], b_rbeat[1]}),
				.wbe(4'hF), .wdata(b_rdata), .raddr(fa[CSH:3]), .oce(1'b1), .q(cd[gw][31:0])
			);
		end
		else begin : g_lw
			ap68040_sdp_be #(.AW(CSB+2), .NB(4), .OREG(0)) dram (
				.clk(clk), .we(c_dwe_w[gw]), .waddr({m_pa[CSH:4], b_rbeat}),
				.wbe(4'hF), .wdata(b_rdata), .raddr(fa[CSH:2]), .oce(1'b1), .q(cd[gw][31:0])
			);
			assign cd[gw][63:32] = 32'd0;
		end
		ap68040_sdp_be #(.AW(CSB), .NB(3), .OREG(0)) tram (
			.clk(clk), .we(c_we_w[gw]), .waddr(c_waddr),
			.wbe(3'b111), .wdata(24'(c_wtag)), .raddr(c_raddr), .oce(1'b1), .q(ct[gw])
		);
	end
endgenerate

//--------------------------------------------------------------------------
// state
//--------------------------------------------------------------------------
typedef enum logic [2:0] {
	S_RUN,     // pipelined fetch
	S_WALK,    // waiting for the DMU's table walk
	S_FILL,    // line fill burst
	S_CI,      // cache-inhibited long word stream
	S_HALT     // a fault was queued: wait for a redirect
} st_t;
st_t st;

logic        fnew;             // the next F0 starts a redirected stream

// F1
logic        f1_v;
logic        f1_btok;           // F0 had room for a taken branch's target
wire         f1_bt    = f1_btok && btb_hit;   // the BTB hit (in F1)
wire [FWL-1:0] f1_bslot = btb_hslot;          // ... where the branch ends
wire   [1:0] f1_bkind = btb_q[32:31];
wire  [30:0] f1_btgt  = btb_q[30:0];
logic        f1_s, f1_dem;
logic        f1_hit;
atce_t       f1_e;

logic        m_tci;            // the fill in progress was answered with TCI

// miss engine
logic        b_req_r;          // request pending (not granted yet)
logic        busy;             // a bus transaction is latched
logic        stale;            // ... for a stream that was redirected away
logic [31:0] m_la;             // the fetch address
logic [31:0] m_pa;
logic  [1:0] m_upa;
logic        m_s, m_dem, m_ci, m_alloc;
logic  [1:0] m_way;
wire [3:0] c_dwe_w = c_dwe ? 4'b0001 << m_way  : 4'b0000;

// invalidation
logic        inv_busy, inv_hold, inv_ph;
logic [CSB:0] inv_i;
logic        inv_sn;           // the running invalidation is the snooper's
logic        inv_lbh;          // ... and the line buffer held its line
logic  [1:0] inv_scope;
logic [31:0] inv_pa;

wire        redir_any = redir_v || d_redir_v;
wire [31:0] redir_npc = redir_v ? redir_pc : d_redir_pc;
// SHADOW: a back-end redirect for a wrong guess to a shadow entry's address
// (the entries hold words as the cache answered them in this mode: every
// other back-end redirect, and anything that can change what the cache or
// the translation answers, empties them)
logic [SE-1:0] sh_m;
always_comb begin
	sh_e = 2'd0;
	for (int e = 0; e < SE; e++) begin
		sh_m[e] = sh_v[e] && sh_pc[e] == redir_pc[31:1];
		if (sh_m[e]) sh_e = 2'(e);
	end
end
// (the shadow chunk in F3 matches as well: it would be an entry next clock)
wire        f3m    = f3_alt && f3_n != 3'd0 && sh_blk == 2'd0 && sh_pc[f3_ai] == redir_pc[31:1];
wire        sh_hit = SHADOW && redir_v && redir_br && ((sh_m != '0) || f3m);
always_comb begin
	ld_n  = f3m ? f3_n : sh_n[sh_e];
	ld_s  = f3m ? f3_s : sh_s[sh_e];
	ld_b  = f3m ? f3_b : sh_b[sh_e];
	ld_t  = f3m ? f3_t : sh_t[sh_e];
	ld_pc = sh_pc[f3m ? f3_ai : sh_e];
	for (int i = 0; i < FW; i++) begin
		ld_w[i] = f3m ? f3_w[i] : sh_w[sh_e][i];
		ld_p[i] = f3m ? f3_p[i] : sh_p[sh_e][i];
	end
end
// (the half-line after the entry's: its words ran to its half-line's end)
wire [31:0] sh_nx  = (ld_b != '0) ? {ld_t, 1'b0} :
                     {ld_pc[30:2], 3'b000} + 32'd8;
// (or the target of a branch the BTB took inside it, where its words end)
logic       alt_go;            // F0 fetches a shadow chunk (below)
assign      fa = redir_any ? (sh_use ? sh_nx : {redir_npc[31:1], 1'b0}) :
                 alt_go    ? {ap_pc[0], 1'b0} : fpc;

//--------------------------------------------------------------------------
// F1 evaluation
//--------------------------------------------------------------------------
logic        x_ok, x_flt, x_walk, x_cach, x_hit;
logic [31:0] x_pa;
logic  [1:0] x_cm, x_upa, x_way;
logic [63:0] x_hl;             // the hit way's long word (HL: half-line)
logic [31:0] x_chunk;          // the long word at F1's address
logic [15:0] x_w [FW];         // the chunk's words, by their place in it
logic  [3:0] x_mj;
// the ITT matches are formed in F0 (the TTRs change only by MOVEC, which
// serializes and refetches), so F1 starts from them
logic        f1_tt0, f1_tt1;
// ... and whether translation is on (TCR.E, MDIS), taken with them: F1's
// translation and its tag compare select both start from flip-flops
logic        f1_tce;
always_comb begin
	logic tt0, tt1, use_t;
	logic [CTW-1:0] tg;
	x_ok = 1'b0; x_flt = 1'b0; x_walk = 1'b0;
	x_pa = f1_pc; x_cm = 2'b00; x_upa = 2'b00;
	tt0 = f1_tt0;
	tt1 = f1_tt1;
	if (tt0 || tt1) begin
		x_ok  = 1'b1;
		x_cm  = tt0 ? itt0[6:5] : itt1[6:5];
		x_upa = tt0 ? itt0[9:8] : itt1[9:8];
	end
	else if (!f1_tce)
		x_ok = 1'b1;               // cachable (MC68040UM 3.1.2)
	else if (f1_hit) begin
		x_pa  = {f1_e.pa[19:1], tc_p ? f1_pc[12] : f1_e.pa[0], f1_pc[11:0]};
		x_cm  = f1_e.cm;
		x_upa = f1_e.upa;
		if (!f1_e.r || (f1_e.s && !f1_s)) x_flt = 1'b1;   // nonresident, supervisor only
		else x_ok = 1'b1;
	end
	else x_walk = 1'b1;
	x_cach = x_ok && ic_en && !x_cm[1];
	// the tags compare with both candidate addresses, the logical one (a
	// TTR or no translation) and the ATC's, and the translation selects
	// the outcome: it stays off the front of the compare (the ATC's
	// address matters only with a hit, x_cach is clear without one)
	use_t  = !(tt0 || tt1) && f1_tce;
	// (LA[11:CSH+1] is zero bits wide at CSB 8: a shift keeps the select legal)
	tg     = (CTW'({f1_e.pa[19:1], tc_p ? f1_pc[12] : f1_e.pa[0]}) << (11 - CSH)) |
	         CTW'(f1_pc[11:0] >> (CSH + 1));
	x_hit  = 1'b0;
	x_way  = 2'd0;
	for (int i = 3; i >= 0; i--) begin
		x_mj[i] = ivf_q[i] && (use_t ? (ct[i][CTW-1:0] == tg) : (ct[i][CTW-1:0] == f1_pc[31:CSH+1]));
		if (x_mj[i]) begin x_hit = 1'b1; x_way = 2'(i); end
	end
	x_hit  = x_hit && x_cach;
	// (the chunk by the one-hot match, AND-OR: no encoded way on the path;
	// at most one way holds a line)
	x_hl = '0;
	for (int i = 0; i < 4; i++) if (x_mj[i]) x_hl = x_hl | cd[i];
	x_chunk = (HL && !f1_pc[2]) ? x_hl[63:32] : x_hl[31:0];
	for (int i = 0; i < FW; i++) x_w[i] = x_hl[(FW-1-i)*16 +: 16];
end
// the chunk F1 delivers: from its address to the chunk's end, or to the
// last word of the branch the BTB takes
wire [FWL-1:0] f1_o   = f1_pc[FWL:1];
wire     [2:0] f1_nsq = 3'(FW) - 3'(f1_o);
wire     [2:0] f1_ntk = 3'(f1_bslot) - 3'(f1_o) + 3'd1;
wire f1_go      = f1_v && !redir_any;
wire f1_deliver = f1_go && x_hit && !f1_alt;
// F1 holds a stream chunk with a BTB hit: F0's sequential fetch of this
// clock is dropped -- F1 sends F0 to the target (a hit) or rolls it back (a
// miss) -- so a shadow fetch there costs the stream nothing.  (Not from the
// cache's tag compare: that would sit in front of F0's address.  A return
// with the fetch's stack empty is the one case the stream goes on.)
wire f1_btk     = f1_go && !f1_alt && f1_bt;
// a shadow chunk that hits goes on to F2; anything else drops it
wire f1_adlv    = f1_go && x_hit && f1_alt;
// the hit entry has words, for this mode
wire [63:0] tw_q   = btb_qslot ? tw_q1 : tw_q0;
wire        tw_hit = BTIC && !tw_cf && (btb_qslot ? twq1 : twq0) &&
                     tw_q[63] == f1_s && tw_q[62:32] == f1_btgt;
wire [31:0] tw_lw  = tw_q[31:0];
// the first fetch at a target the BTB sent F0 to: its words for the entry
wire tw_fill = BTIC && pf_v && f1_deliver && f1_pc[31:1] == pf_t && !btb_hit && !tw_clr && !tw_sw &&
               !cof_w(x_chunk[15:0]) && !(!f1_pc[1] && cof_w(x_chunk[31:16]));

//--------------------------------------------------------------------------
// F0 issue: room for this chunk and those in flight
//--------------------------------------------------------------------------
wire [5:0] inflight0 = (f1_v ? 6'(FW) : 6'd0) + {3'd0, f2_n} + {3'd0, f3_n};
wire [5:0] inflight  = inflight0 + (tj_v ? 6'd2 : 6'd0);
// the target FIFO cannot overflow: count the flagged words on their way
// (a shadow chunk's flag goes to its entry, not the list)
wire       bt_room  = ({1'b0, tq_n} + {3'd0, f1_v && f1_bt && !f1_alt} + {3'd0, |f2_b && !f2_alt} +
                       {3'd0, |f3_b && !f3_alt}) < 4'd4;
// (HL: F3 waits when the queue cannot take its words, so F0 needs room
// only for the words ahead of its own chunk -- which then is the one chunk
// that can wait, with nothing behind it)
wire       room     = {1'b0, cnt} + inflight <= (HL ? 6'(QN) : 6'(QN - 2));
// F3's words join the queue (HL: when they fit)
wire [4:0] keep_w   = cnt - {2'b00, consume};
assign     f3_go    = !HL || f3_alt || ({1'b0, keep_w} + {3'd0, f3_n} <= 6'(QN));
// (a shadow chunk in F3 goes to its entry, never into the queue)
assign     f3_q     = f3_go && !f3_alt;
// target words wait for room as a fetch would (F0 waits behind them)
wire       tj_go    = tj_v && f3_go && ({1'b0, cnt} + inflight0 <= 6'(QN - 2));
// a snooped invalidation goes first (the snooper has priority, 4.5)
// (and F0 waits for a place in the target FIFO: a fetch issued without one
// could not take a BTB hit, ran on past the branch and was redirected by the
// decoder -- with half-line fetches a short loop got far enough ahead to
// meet that every fourth turn in the queue)
wire       f0_go_s  = (st == S_RUN) && !odd && !stop && !redir_any &&
                      !iatc_flush_page && !inv_busy && !sn_inv && room && (bt_room || !HL);
// SHADOW: a request takes F0 in a slot the stream does not need: F1 drops
// F0's fetch this clock (f1_btk), the stream would not fetch, or the queue
// holds four words already.  Taking the stream's slot otherwise costs it a
// clock every time an instruction straddles a half-line after a branch
// target (64 taken BNE.W in a row: 2.14 -> 2.42 clocks; Norton's Branches
// -1%).  It needs the same room, as its chunk passes F2 and F3 (it does not
// join the queue).
assign     alt_go   = SHADOW && HL && ap_v[0] && (st == S_RUN) && !stop && !redir_any &&
                      !iatc_flush_page && !inv_busy && !sn_inv && room &&
                      (f1_btk || !f0_go_s || cnt >= 5'd4);
wire       f0_go    = f0_go_s && !alt_go;
// the redirect's clock as its target's F0 (the queue and the target list
// are emptied by the redirect itself: there is room)
wire       rf0      = redir_any && (st == S_RUN) && !redir_npc[0] && !stop &&
                      !iatc_flush_page && !inv_busy && !sn_inv;
assign     sh_use   = sh_hit && rf0;

assign c_raddr = inv_busy ? inv_i[CSB-1:0] : fa[CSH:4];

//--------------------------------------------------------------------------
// BIU request
//--------------------------------------------------------------------------
assign b_req = b_req_r;
always_comb begin
	b_breq = '0;
	b_breq.addr = {m_pa[31:2], 2'b00};
	b_breq.rd   = 1'b1;
	b_breq.tt   = TT_NORMAL;
	b_breq.tm   = m_s ? TM_SCODE : TM_UCODE;
	b_breq.upa  = m_upa;
	if (st == S_FILL) begin
		b_breq.siz = SIZ_LINE;
		b_breq.tln = m_way;
	end
	else begin
		b_breq.siz = SIZ_L;
		b_breq.ci  = m_ci;
	end
end

assign iw_va  = m_la;
assign iw_fc2 = m_s;

// a transaction still outstanding after this cycle
wire out_next = (b_req_r && !b_gnt) || b_gnt || (busy && !(b_done || b_err));

//--------------------------------------------------------------------------
// sequential
//--------------------------------------------------------------------------
always_ff @(posedge clk) begin
	logic        frw;              // the return stack's write (below)
	logic  [2:0] frwa;
	logic [30:0] frwd;
	logic [CSB-1:0] iw_set;        // the valid RAMs' write (below)
	logic  [3:0] iw_m;
	logic        iw_v;
	frw = 1'b0; frwa = '0; frwd = '0;
	iw_set = '0; iw_m = '0; iw_v = 1'b0;
	if (!nreset) begin
		cnt   <= '0;
		qf    <= '0; qd <= '0; qa <= '0;
		qpc_r <= '0;
		odd   <= 1'b0;
		fpc   <= '0;
		fnew  <= 1'b1;
		st    <= S_RUN;
		f1_v  <= 1'b0; f1_pc <= '0; f1_s <= 1'b0; f1_dem <= 1'b0; f1_hit <= 1'b0; f1_e <= '0;
		f1_tt0 <= 1'b0; f1_tt1 <= 1'b0; f1_tce <= 1'b0;
		f1_btok <= 1'b0;
		fras_tp <= '0; fras_n <= '0;
		tw_we <= 1'b0; tw_wi <= '0; tw_wslot <= 1'b0; tw_wd <= '0;
		pf_v  <= 1'b0; pf_i <= '0; pf_slot <= 1'b0; pf_t <= '0;
		tj_v  <= 1'b0; tj_n2 <= 1'b0; tj_w <= '0;
		f2_b  <= '0; f2_t <= '0; f3_b <= '0; f3_t <= '0;
		qb    <= '0; tq_n <= '0;
		qs    <= '0; f3_s <= '0;
		for (int i = 0; i < 4; i++) tq[i] <= '0;
		f2_n  <= '0; f2_f <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
		for (int i = 0; i < FW; i++) f2_w[i] <= '0;
		f3_n  <= '0; f3_f <= 1'b0; f3_d <= 1'b0; f3_a <= 1'b0;
		for (int i = 0; i < FW; i++) f3_w[i] <= '0;
		m_tci <= 1'b0;
		busy  <= 1'b0; stale <= 1'b0; b_req_r <= 1'b0;
		m_la  <= '0; m_pa <= '0; m_upa <= '0; m_s <= 1'b0; m_dem <= 1'b0; m_ci <= 1'b0;
		m_alloc <= 1'b0; m_way <= '0; m_cw <= '0; m_vclr <= 1'b0; m_rrinc <= 1'b0;
		iw_req <= 1'b0;
		c_we  <= 1'b0; c_waddr <= '0; c_wway <= '0; c_wtag <= '0;
		rr    <= '0;
		// (reset leaves the cache alone, 5.3: its valid bits have their
		// power-up values from their initial blocks)
		inv_busy <= 1'b0; inv_hold <= 1'b0; inv_ph <= 1'b0; inv_i <= '0;
		inv_sn <= 1'b0; inv_scope <= 2'd3; inv_pa <= '0; inv_lbh <= 1'b0;
		inv_rst <= 1'b0;
		sn_ihit <= 1'b0;
		ic_inv_done <= 1'b0;
		sn_inv_done <= 1'b0;
		for (int i = 0; i < QN; i++) qw[i] <= '0;
		qh  <= '0;
		qp0 <= '0;
		sh_v <= '0; sh_rr <= '0; sh_blk <= '0; ap_v <= '0;
		f1_alt <= 1'b0; f2_alt <= 1'b0; f3_alt <= 1'b0;
		f1_ai <= '0; f2_ai <= '0; f3_ai <= '0;
		for (int i = 0; i < 2; i++) ap_pc[i] <= '0;
	end
	else begin
		logic [4:0] keep;
		c_we        <= 1'b0;
		ic_inv_done <= 1'b0;
		sn_inv_done <= 1'b0;
		sn_ihit     <= 1'b0;
		inv_hold    <= 1'b0;

		//------------------------------------------------------------------
		// queue: shift out what D1 consumed, append F3; F2 -> F3
		//------------------------------------------------------------------
		keep = cnt - {2'b00, consume};
		for (int i = 0; i < QN; i++) begin
			logic [5:0] src;
			logic [4:0] k;
			src = 6'(i) + {3'b000, consume};
			k   = 5'(i) - keep;
			if (5'(i) < keep) begin
				// synthesis translate_off
				qps[i] <= qps[src[4:0]];
				// synthesis translate_on
				qw[i] <= qw[src[4:0]];
				qf[i] <= qf[src[4:0]];
				qd[i] <= qd[src[4:0]];
				qa[i] <= qa[src[4:0]];
				qb[i] <= qb[src[4:0]];
				qs[i] <= qs[src[4:0]];
			end
			else if (k < {2'b00, f3_n} && f3_q) begin
				// synthesis translate_off
				qps[i] <= f3_p[k[FWL-1:0]];
				// synthesis translate_on
				qw[i] <= f3_w[k[FWL-1:0]];
				qf[i] <= f3_f;
				qd[i] <= f3_d;
				qa[i] <= f3_a;
				qb[i] <= f3_b[k[FWL-1:0]];
				qs[i] <= f3_s[k[FWL-1:0]];
			end
		end
		cnt   <= keep + (f3_q ? {2'b00, f3_n} : 5'd0);
		// the predecode ring: appended at head + count (wherever D1's
		// consume puts the head), the head moved by consume
		begin
			// (the banks' writes: g_qpr)
			qh  <= qh_n;
			qp0 <= pd0_n;
		end
		// D1 consumed the end of a BTB-taken branch: the stream continues
		// at its target (the words after it in the queue came from there)
		begin
			logic        cfl;
			logic  [2:0] cj;
			logic [30:0] tqn [4];
			logic  [2:0] n;
			cfl = 1'b0; cj = 3'd0;
			for (int i = 6; i >= 0; i--)
				if (3'(i) < consume && qb[i]) begin cfl = 1'b1; cj = 3'(i); end
			// (a decode that ran past the flag is refetched at WB: the PC
			// of what follows it does not matter)
			// (D1 may take one word of the target with the branch: a companion)
qpc_r <= cfl ? {tq[0], 1'b0} + {30'd0, consume_t, 1'b0} : qpc_r + {28'd0, consume, 1'b0};
			for (int i = 0; i < 4; i++) tqn[i] = tq[i];
			n = tq_n;
			if (cfl && n != 3'd0) begin
				for (int i = 0; i < 3; i++) tqn[i] = tqn[i + 1];
				n = n - 3'd1;
			end
			if (f3_n != 3'd0 && f3_q && f3_b != '0 && n != 3'd4) begin
				tqn[n[1:0]] = f3_t;
				n = n + 3'd1;
			end
			for (int i = 0; i < 4; i++) tq[i] <= tqn[i];
			tq_n <= n;
		end
		if (f3_go) begin
			f3_n  <= f2_n;
			f3_alt <= f2_alt;
			f3_ai  <= f2_ai;
			f3_f  <= f2_f; f3_d <= f2_d; f3_a <= f2_a;
			f3_b  <= f2_b; f3_t <= f2_t;
			for (int i = 0; i < FW; i++) f3_w[i] <= f2_w[i];
			for (int i = 0; i < FW; i++)
				f3_s[i] <= f2_s1[i].v && (f2_s1[i].ld ? S1_CLASSES[2] && S1_LDMASK[s1_ldk(f2_s1[i])] :
				                          f2_s1[i].agop ? S1_CLASSES[1] : S1_CLASSES[0]);
		end
		// synthesis translate_off
		else if (f2_n != 3'd0 || f1_v) begin
			$display("FAIL: fetch: F3 waits for the queue with a chunk behind it");
			$finish;
		end
		// synthesis translate_on
		f2_n  <= '0;
		f2_b  <= '0;
		f2_alt <= 1'b0;
		// the target words of the BTB-taken branch F1 delivered (when
		// there is room for them)
		if (tj_go) begin
			tj_v    <= 1'b0;
			f2_n    <= tj_n2 ? 3'd2 : 3'd1;
			f2_w[0] <= tj_n2 ? tj_w[31:16] : tj_w[15:0];
			f2_w[1] <= tj_w[15:0];
			f2_f <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
		end
		// the fill of an entry's target words; F1 ends the wait for it
		tw_we    <= tw_fill;
		tw_wi    <= pf_i;
		tw_wslot <= pf_slot;
		tw_wd    <= {f1_s, pf_t, x_chunk};
		if (f1_v || tw_clr)
			pf_v <= 1'b0;

		//------------------------------------------------------------------
		// F0 -> F1
		//------------------------------------------------------------------
		f1_v  <= 1'b0;
		f1_btok <= 1'b0;
		f1_alt <= 1'b0;
		if (f0_go) begin
			f1_v   <= 1'b1;
			f1_btok <= bt_room;
			f1_pc  <= fpc;
			f1_s   <= smode;
			f1_tt0 <= ttr_hit(itt0, fpc, smode);
			f1_tt1 <= ttr_hit(itt1, fpc, smode);
			f1_tce <= tc_e;
			f1_dem <= fnew;
			f1_hit <= atc_hit;
			f1_e   <= atc_e;
			fnew   <= 1'b0;
			fpc    <= HL ? {fpc[31:3], 3'b000} + 32'd8 : {fpc[31:2], 2'b00} + 32'd4;
		end
		// SHADOW: a request's half-line into an entry (the stream's fpc and
		// demand marks untouched)
		if (alt_go) begin
			f1_v    <= 1'b1;
			f1_alt  <= 1'b1;
			f1_ai   <= sh_rr;
			f1_btok <= 1'b1;
			f1_pc   <= fa;
			f1_s    <= smode;
			f1_tt0  <= ttr_hit(itt0, fa, smode);
			f1_tt1  <= ttr_hit(itt1, fa, smode);
			f1_tce  <= tc_e;
			f1_dem  <= 1'b0;
			f1_hit  <= atc_hit;
			f1_e    <= atc_e;
			sh_v[sh_rr]  <= 1'b0;
			sh_pc[sh_rr] <= ap_pc[0];
			sh_rr   <= sh_rr + 2'd1;
		end
		// the requests: D1 pushes, F0 pops
		begin
			logic [1:0]  v;
			logic [30:0] a0, a1;
			logic        dup;
			logic [SE-1:0] held;
			// (a request for a path already held, on its way or waiting is
			// dropped: a loop asks for the same one every turn)
			held = sh_v;
			if (f1_v && f1_alt)          held[f1_ai] = 1'b1;
			if (f2_alt && f2_n != 3'd0)  held[f2_ai] = 1'b1;
			if (f3_alt && f3_n != 3'd0)  held[f3_ai] = 1'b1;
			dup = (ap_v[0] && ap_pc[0] == alt_pc[31:1]) || (ap_v[1] && ap_pc[1] == alt_pc[31:1]);
			for (int e = 0; e < SE; e++) if (held[e] && sh_pc[e] == alt_pc[31:1]) dup = 1'b1;
			v = ap_v; a0 = ap_pc[0]; a1 = ap_pc[1];
			if (alt_go) begin v = {1'b0, v[1]}; a0 = a1; end
			if (SHADOW && alt_req && !alt_pc[0] && !dup) begin
				if (!v[0])      begin v[0] = 1'b1; a0 = alt_pc[31:1]; end
				else if (!v[1]) begin v[1] = 1'b1; a1 = alt_pc[31:1]; end
			end
			ap_v <= v; ap_pc[0] <= a0; ap_pc[1] <= a1;
		end

		//------------------------------------------------------------------
		// F1: a hit goes to F2; anything else to the miss engine, and F0
		// rolls back to the missed address
		//------------------------------------------------------------------
		if (f1_adlv) begin
			f2_n    <= f1_nsq;
			for (int i = 0; i < FW; i++) f2_w[i] <= x_w[FWL'(f1_o + FWL'(i))];
			f2_f <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
			f2_alt <= 1'b1;
			f2_ai  <= f1_ai;
			// a plain branch the BTB takes in it: its words end there, flagged,
			// and the stream would go on at its target (calls and returns,
			// which move the fetch's return stack, are left to D1)
			if (f1_bt && f1_bkind == 2'd0) begin
				f2_n <= f1_ntk;
				f2_b <= FW'(1) << (f1_ntk - 3'd1);
				f2_t <= f1_btgt;
			end
		end
		else if (f1_deliver) begin
			f2_n    <= f1_nsq;
			for (int i = 0; i < FW; i++) f2_w[i] <= x_w[FWL'(f1_o + FWL'(i))];
			f2_f <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
			if (f1_bt && !(f1_bkind == 2'd2 && fras_n == 4'd0)) begin
				// a predicted taken branch ends in this chunk: the words up
				// to its last, that one flagged; F0 goes to the target (a
				// return's from the stack) and its sequential fetch of this
				// cycle is dropped; a call pushes its return address.  With
				// the entry's target words, the first joins a one-word chunk
				// (where D1 looks for a companion), the rest go to F2 next
				// (or once there is room), and F0 to the long word after
				// them; without, the first fetch at the target fills them
				logic [30:0] t;
				logic        tu, one;
				t   = (f1_bkind == 2'd2) ? fras[fras_tp] : f1_btgt;
				tu  = tw_hit && f1_bkind != 2'd2;
				one = (f1_ntk == 3'd1);
				f2_n <= (one && tu) ? 3'd2 : f1_ntk;
				f2_b <= FW'(1) << (f1_ntk - 3'd1);
				if (one && tu) f2_w[1] <= t[0] ? tw_lw[15:0] : tw_lw[31:16];
				f2_t <= t;
				// (F0's sequential chunk of this clock is dropped; a shadow
				// chunk is not the stream's and goes on)
				if (!alt_go) begin f1_v <= 1'b0; f1_btok <= 1'b0; end
				fpc  <= tu ? {t[30:1] + 30'd1, 2'b00} : {t, 1'b0};
				fnew <= 1'b0;
				tj_v  <= tu && !(one && t[0]);
				tj_n2 <= !t[0] && !one;
				tj_w  <= tw_lw;
				if (BTIC && !tw_hit && f1_bkind != 2'd2) begin
					pf_v    <= 1'b1;
					pf_i    <= f1_pc[BTB_AW+1:2];
					pf_slot <= f1_bslot[0];
					pf_t    <= t;
				end
				if (f1_bkind == 2'd1) begin
					frw  = 1'b1;
					frwa = fras_tp + 3'd1;
					frwd = {f1_pc[31:FWL+1], f1_bslot} + 31'd1;
					fras_tp <= fras_tp + 3'd1;
					if (fras_n != 4'd8) fras_n <= fras_n + 4'd1;
				end
				else if (f1_bkind == 2'd2) begin
					fras_tp <= fras_tp - 3'd1;
					fras_n  <= fras_n - 4'd1;
				end
			end
		end
		else if (f1_go && !f1_alt) begin
			if (!alt_go) f1_v <= 1'b0;
			fpc    <= f1_pc;
			fnew   <= f1_dem;
			m_la   <= f1_pc;
			m_pa   <= x_pa;
			m_upa  <= x_upa;
			m_s    <= f1_s;
			m_dem  <= f1_dem;
			m_ci   <= x_cm[1];
			if (x_walk) begin
				st     <= S_WALK;
				iw_req <= 1'b1;
			end
			else if (x_flt) begin
				// ATC fault: the chunk's words carry it
				f2_n <= f1_nsq;
				for (int i = 0; i < FW; i++) f2_w[i] <= 16'd0;
				f2_f <= 1'b1; f2_d <= f1_dem; f2_a <= 1'b1;
				st   <= S_HALT;
			end
			else if (x_cach) begin
				logic [3:0] vv;
				vv = ivf_q;
				st      <= S_FILL;
				m_got   <= 4'd0;
				m_alloc <= 1'b1;
				m_tci   <= 1'b0;
				m_way   <= !vv[0] ? 2'd0 : !vv[1] ? 2'd1 : !vv[2] ? 2'd2 : !vv[3] ? 2'd3 : rr;
				m_vclr  <= 1'b1;
				m_rrinc <= (vv == 4'hF);
				b_req_r <= 1'b1;
			end
			else begin
				st      <= S_CI;
				b_req_r <= 1'b1;
			end
		end

		//------------------------------------------------------------------
		// miss engine
		//------------------------------------------------------------------
		if (b_gnt) begin
			b_req_r <= 1'b0;
			busy    <= 1'b1;
		end
		case (st)
		S_WALK:
			if (iw_done) begin
				iw_req <= 1'b0;
				st     <= S_RUN;
			end
		S_FILL: begin
			logic [31:0] lw0;
			// the long word being fetched: arriving now, or kept
			lw0 = (b_rvalid && b_rbeat == m_pa[3:2]) ? b_rdata : m_cw;
			// (the fill's first cycle: no beat has arrived yet) the victim
			// invalid, its tag the new line's
			if (m_vclr && !inv_busy) begin
				m_vclr  <= 1'b0;
				iw_set = m_pa[CSH:4]; iw_m[m_way] = 1'b1; iw_v = 1'b0;
				c_we    <= 1'b1;
				c_waddr <= m_pa[CSH:4];
				c_wway  <= m_way;
				c_wtag  <= m_pa[31:CSH+1];
			end
			// (a beat before the victim is invalid is not written: the
			// line is not allocated then)
			if (b_rvalid && m_vclr) m_alloc <= 1'b0;
			if (b_rvalid) begin
				if (b_rbeat == m_pa[3:2]) m_cw <= b_rdata;
				m_got[b_rbeat] <= 1'b1;
				if (b_rtci) begin m_alloc <= 1'b0; m_tci <= 1'b1; end
			end
			if (busy && b_done) begin
				busy  <= 1'b0;
				stale <= 1'b0;
				if (m_alloc && !(b_rvalid && b_rtci)) begin
					iw_set = m_pa[CSH:4]; iw_m[m_way] = 1'b1; iw_v = 1'b1;
					if (m_rrinc) rr <= rr + 2'd1;
				end
				st    <= S_RUN;
				if (m_tci || (b_rvalid && b_rtci)) begin
					// a TCI line is not kept (5.7.1: sequential access only
					// until the burst's last long word arrives): the long word
					// being fetched goes straight to the decoder, the next one
					// is fetched anew (unless a redirect takes the stream)
					if (!stale && !redir_any) begin
						logic [31:0] lw, nla;
						lw  = lw0;
						nla = {m_la[31:2], 2'b00} + 32'd4;
						if (m_la[1]) begin
							f2_n    <= 3'd1;
							f2_w[0] <= lw[15:0];
						end
						else begin
							f2_n    <= 3'd2;
							f2_w[0] <= lw[31:16];
							f2_w[1] <= lw[15:0];
						end
						f2_f  <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
						m_la  <= nla;
						m_pa  <= {m_pa[31:2], 2'b00} + 32'd4;
						m_dem <= 1'b0;
						fpc   <= nla;
						fnew  <= 1'b0;
					end
				end
			end
			if (busy && b_err) begin
				busy  <= 1'b0;
				stale <= 1'b0;
				if (stale) st <= S_RUN;
				else if (m_got[m_pa[3:2]]) begin
					// a later beat failed, the long word being fetched had
					// arrived (the burst starts with it): it is used, the line
					// is not allocated, and no exception (MC68060UM 7.9.1,
					// 5.7.1).  The next long word is fetched anew.
					logic [31:0] lw, nla;
					lw  = lw0;
					nla = {m_la[31:2], 2'b00} + 32'd4;
					if (m_la[1]) begin
						f2_n    <= 3'd1;
						f2_w[0] <= lw[15:0];
					end
					else begin
						f2_n    <= 3'd2;
						f2_w[0] <= lw[31:16];
						f2_w[1] <= lw[15:0];
					end
					f2_f  <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
					m_la  <= nla;
					m_pa  <= {m_pa[31:2], 2'b00} + 32'd4;
					m_dem <= 1'b0;
					fpc   <= nla;
					fnew  <= 1'b0;
					st    <= S_RUN;
				end
				else begin
					f2_n <= m_la[1] ? 3'd1 : 3'd2;
					for (int i = 0; i < FW; i++) f2_w[i] <= 16'd0;
					f2_f <= 1'b1; f2_d <= m_dem; f2_a <= 1'b0;
					st   <= S_HALT;
				end
			end
		end
		S_CI: begin
			if (busy && b_rvalid && !stale) begin
				if (m_la[1]) begin
					f2_n    <= 3'd1;
					f2_w[0] <= b_rdata[15:0];
				end
				else begin
					f2_n    <= 3'd2;
					f2_w[0] <= b_rdata[31:16];
					f2_w[1] <= b_rdata[15:0];
				end
				f2_f <= 1'b0; f2_d <= 1'b0; f2_a <= 1'b0;
			end
			if (busy && b_done) begin
				logic [31:0] nla;
				nla   = {m_la[31:2], 2'b00} + 32'd4;
				busy  <= 1'b0;
				stale <= 1'b0;
				if (stale) st <= S_RUN;
				else begin
					m_la  <= nla;
					m_pa  <= {m_pa[31:2], 2'b00} + 32'd4;
					m_dem <= 1'b0;
					fpc   <= nla;
					fnew  <= 1'b0;
					// the page ends (or the cache mode changed): translate again
					if (nla[11:0] == 12'd0 || (!m_ci && ic_en)) st <= S_RUN;
				end
			end
			else if (busy && b_err) begin
				busy  <= 1'b0;
				stale <= 1'b0;
				if (!stale) begin
					f2_n    <= m_la[1] ? 3'd1 : 3'd2;
					f2_w[0] <= 16'd0;
					f2_w[1] <= 16'd0;
					f2_f <= 1'b1; f2_d <= m_dem; f2_a <= 1'b0;
					st   <= S_HALT;
				end
				else st <= S_RUN;
			end
			else if (!busy && !b_req_r && !b_gnt && !redir_any && !stop &&
			         {1'b0, cnt} + {3'd0, f2_n} + {3'd0, f3_n} <= 6'(QN - 2))
				b_req_r <= 1'b1;        // the next long word of the stream
		end
		default: ;
		endcase

		//------------------------------------------------------------------
		// redirect: empty the queue and the pipeline.  A walk runs to its
		// end (the entry is installed); a line fill completes and is
		// installed; a cache-inhibited read completes and is discarded.
		//------------------------------------------------------------------
		if (d_ras_xp) begin
			frw  = 1'b1;
			frwa = d_ras_tp;
			frwd = d_ras;
			fras_tp <= d_ras_tp;
			fras_n  <= d_ras_n;
		end
		if (redir_any) begin
			cnt   <= '0;
			f2_n  <= '0;
			f3_n  <= '0;
			f2_b  <= '0;
			f3_b  <= '0;
			tq_n  <= '0;
			tj_v  <= 1'b0;
			pf_v  <= 1'b0;
			f1_v  <= 1'b0;
			f1_btok <= 1'b0;
			frw  = 1'b1;
			frwa = d_ras_tp;
			frwd = d_ras;
			fras_tp <= d_ras_tp;
			fras_n  <= d_ras_n;
			fpc   <= {redir_npc[31:1], 1'b0};
			qpc_r <= redir_npc;
			odd   <= redir_npc[0];
			fnew  <= 1'b1;
			if (rf0) begin
				// (this clock was the target's F0: see fa)
				f1_v    <= 1'b1;
				f1_btok <= 1'b1;
				f1_pc   <= fa;
				f1_s    <= smode;
				f1_tt0  <= ttr_hit(itt0, fa, smode);
				f1_tt1  <= ttr_hit(itt1, fa, smode);
				f1_tce  <= tc_e;
				// (after a shadow's words this fetch is the lookahead: a
				// fault on it is speculative, as any fetch after the first)
				f1_dem  <= !sh_use;
				f1_hit  <= atc_hit;
				f1_e    <= atc_e;
				fnew    <= 1'b0;
				fpc     <= HL ? {fa[31:3], 3'b000} + 32'd8 : {fa[31:2], 2'b00} + 32'd4;
			end
			if (sh_use) begin
				// the shadow entry's words are the queue (its predecode: the
				// ring's writes, and the head)
				cnt <= 5'(ld_n);
				tq[0] <= ld_t;
				tq_n  <= (ld_b != '0) ? 3'd1 : 3'd0;
				for (int i = 0; i < FW; i++) begin
					qw[i] <= ld_w[i];
					qf[i] <= 1'b0; qd[i] <= 1'b0; qa[i] <= 1'b0;
					qb[i] <= ld_b[i];
					qs[i] <= ld_s[i];
					// synthesis translate_off
					qps[i] <= ld_p[i];
					// synthesis translate_on
				end
			end
			if (st == S_FILL || st == S_CI) begin
				if (out_next) stale <= 1'b1;
				else st <= S_RUN;
			end
			if (st == S_HALT) st <= S_RUN;
		end

		//------------------------------------------------------------------
		// SHADOW: F3's shadow chunk into its entry; the entries emptied by
		// every back-end redirect (after a matching one loaded the queue)
		// and by anything that can change what the cache or the translation
		// answers -- a chunk on its way then is not kept either (sh_blk)
		//------------------------------------------------------------------
		if (sh_blk != 2'd0) sh_blk <= sh_blk - 2'd1;
		if (SHADOW && f3_alt && f3_n != 3'd0 && sh_blk == 2'd0) begin
			sh_v[f3_ai] <= 1'b1;
			sh_n[f3_ai] <= f3_n;
			for (int j = 0; j < FW; j++) begin
				sh_w[f3_ai][j] <= f3_w[j];
				sh_p[f3_ai][j] <= f3_p[j];
			end
			sh_s[f3_ai] <= f3_s;
			sh_b[f3_ai] <= f3_b;
			sh_t[f3_ai] <= f3_t;
		end
		if (redir_v || ic_inv || sn_inv || inv_busy || iatc_flush_all || iatc_flush_page || iatc_wr) begin
			sh_v <= '0;
			if (!redir_v) sh_blk <= 2'd3;
		end
		if (redir_v) ap_v <= '0;

		//------------------------------------------------------------------
		// CINV/CPUSH of the instruction cache
		//------------------------------------------------------------------
		if ((ic_inv || sn_inv) && !inv_busy && !inv_hold && st != S_FILL && !c_we) begin
			inv_sn    <= !ic_inv;
			inv_scope <= ic_inv ? ic_inv_scope : 2'd1;
			inv_pa    <= ic_inv ? ic_inv_pa : sn_inv_pa;
			inv_lbh   <= 1'b0;
			if (ic_inv ? (ic_inv_scope == 2'd3) : sn_inv_all) begin
				// every line: the sweep below (scope 3 matches every way)
				inv_scope <= 2'd3;
				sn_ihit   <= !ic_inv;
				inv_busy  <= 1'b1;
				inv_ph    <= 1'b0;
				inv_i     <= '0;
			end
			else begin
				inv_busy <= 1'b1;
				inv_ph   <= 1'b0;
				inv_i    <= (!ic_inv || ic_inv_scope == 2'd1) ?
				            {1'b0, (ic_inv ? ic_inv_pa[CSH:4] : sn_inv_pa[CSH:4])} : '0;
			end
		end
		if (inv_busy) begin
			// this cycle reads set inv_i; the previous set's tags compare
			if (inv_ph) begin
				logic [CSB-1:0] s;
				s = (inv_scope == 2'd1) ? inv_pa[CSH:4] : CSB'(inv_i - 1'd1);
				for (int w = 0; w < 4; w++) begin
					logic m;
					if (inv_scope == 2'd3)
						m = 1'b1;
					else if (inv_scope == 2'd1)
						m = ct[w][CTW-1:0] == inv_pa[31:CSH+1];
					else if (tc_p)
						m = ct[w][CTW-1:12-CSH] == inv_pa[31:13];
					else
						m = ct[w][CTW-1:11-CSH] == inv_pa[31:12];
					if (m) begin iw_set = s; iw_m[w] = 1'b1; iw_v = 1'b0; end
					if (m && ivo_q[w] && inv_sn) sn_ihit <= 1'b1;   // (ivo_ra: s)
				end
				if (inv_sn && inv_lbh) sn_ihit <= 1'b1;
			end
			inv_ph <= 1'b1;
			if (inv_scope == 2'd1) begin
				if (inv_ph) begin
					inv_busy    <= 1'b0;
					ic_inv_done <= !inv_sn;
					sn_inv_done <= inv_sn;
					inv_hold    <= 1'b1;
				end
			end
			else begin
				inv_i <= inv_i + 1'd1;
				if (inv_i == (CSB+1)'(1 << CSB)) begin
					inv_busy    <= 1'b0;
					ic_inv_done <= !inv_sn && !inv_rst;
					sn_inv_done <= inv_sn;
					inv_hold    <= 1'b1;
					inv_rst     <= 1'b0;
				end
			end
		end
	end
	// the return stack's one write port
	if (nreset && frw) fras[frwa] <= frwd;
	// the valid RAMs' one write (both copies)
	if (nreset) begin
		dbg_iw <= {iw_v, iw_m, 7'(iw_set)};
		if (iw_m != 4'd0) begin
			ivf[iw_set] <= (ivo_q & ~iw_m) | (iw_m & {4{iw_v}});
			ivo[iw_set] <= (ivo_q & ~iw_m) | (iw_m & {4{iw_v}});
		end
		// synthesis translate_off
		for (int j = 0; j < 4; j++) if (iw_m[j]) iv[iw_set][j] <= iw_v;
		if (iw_m != 4'd0 && iw_set != ivo_ra) begin
			$display("FAIL: fetch: a valid write at set %0d, the second copy read at %0d", iw_set, ivo_ra);
			$finish;
		end
		// synthesis translate_on
	end
end

// the valid copies' reads: F1's set; the invalidation's, else the fill's
wire [CSB-1:0] inv_s = (inv_scope == 2'd1) ? inv_pa[CSH:4] : CSB'(inv_i - 1'd1);
always_comb ivo_ra = inv_busy ? inv_s : m_pa[CSH:4];
assign ivf_q = ivf[f1_pc[CSH:4]];
assign ivo_q = ivo[ivo_ra];
initial for (int i = 0; i < (1 << CSB); i++) begin ivf[i] = 4'd0; ivo[i] = 4'd0; end
// synthesis translate_off
always_ff @(posedge clk)
	if (nreset && !inv_rst && (ivf_q != iv[f1_pc[CSH:4]] || ivo_q != iv[ivo_ra])) begin
		$display("FAIL: fetch: valid RAM %b/%b, model %b/%b", ivf_q, ivo_q, iv[f1_pc[CSH:4]], iv[ivo_ra]);
		$finish;
	end
// synthesis translate_on

// synthesis translate_off
always_ff @(posedge clk)
	if (nreset && cnt != 5'd0 && qp0 != qps[0]) begin
		$display("FAIL: fetch: the predecode ring's head %h, the queue's %h", qp0, qps[0]);
		$finish;
	end
// synthesis translate_on

// observation only: what F0/F1 and the miss engine are doing
logic [11:0] dbg_iw;   // the valid RAMs' write as it was made: {v, ways, set}
assign dbg_f = {13'd0, f0_go, tw_hit, f1_go, f1_deliver, f1_bkind, f1_bt, f1_v,
                fras_n, fras_tp, fnew, busy, stale, 3'(st),
                // (bits 96..157: the head of the queue as D1 sees it)
                12'd0, cnt, qh, qp0.legal, qp0.slow, qp0.b, qp0.tot, qw[1], qw[0],
                m_la, f1_pc,
                // (bits 0..31: the cache's writes, in place of F0's address)
                c_dwe, m_way, m_vclr, m_alloc, m_tci, c_we, c_wway, inv_busy,
                dbg_iw, rr, ivo_q, b_rvalid, b_rbeat, 1'b0};

endmodule
