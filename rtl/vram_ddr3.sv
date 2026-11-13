//============================================================================
//  vram_ddr3.sv — 1 MB / 2 MB DDR3-backed VRAM Controller with Ping-Pong
//  Scanline Cache for Mac Quadra 800.
//
//  Replaces ~260 M10K blocks of on-chip BRAM with a 1 MB DDR3 framebuffer
//  and an 8-block M10K ping-pong scanline cache.
//============================================================================

`timescale 1ns/1ps

module vram_ddr3 #(
	parameter [28:0] DDR_VRAM_BASE   = 29'h0500_0000, // 64-bit word address (byte 0x2800_0000 >> 3)
	parameter        VRAM_1MB        = 1              // 1 = 1 MB wrap (ROM probe advertises 1 MB)
)(
	input             clk_sys,         // 33.33 MHz system clock
	input             reset,           // synchronous reset on clk_sys

	//---------------------------------------------------------
	// CPU / quadra800 bus interface (clk_sys)
	//---------------------------------------------------------
	input             mem_req,
	input             mem_is_vram,
	input             mem_write,
	input      [31:2] mem_addr,
	input       [3:0] mem_be,
	input      [31:0] mem_wdata,
	input             mem_vram_wp,     // 1-cycle direct write strobe from store buffer
	output reg        vram_ack,
	output reg [31:0] vram_rdata,
	output            vram_wq_room,    // write queue has room
	// second lookup port into the read line cache, from the CPU bus address
	// before the machine has registered a request (see fast_hit below)
	input      [31:2] fast_addr,
	input             fast_take,       // the machine answers from fast_data
	output            fast_hit,
	output     [31:0] fast_data,
	// one-clock event strobes for rtl/perf_counters.sv pages 5-6
	output     [11:0] perf_ev,

	//---------------------------------------------------------
	// Video Scanout interface (clk_vid)
	//---------------------------------------------------------
	input             clk_vid,         // 25.175 MHz pixel dot clock
	input             reset_vid,
	input       [9:0] vid_col_word,    // word index (0..1023) within the scanline
	input      [13:0] vid_stride,      // row stride in bytes (e.g. 1024)
	input             vid_line_req,    // pulse at hcnt==0: fetch upcoming scanline
	input      [20:0] vid_line_addr,   // byte address of upcoming scanline
	input             vid_line_swap,   // pulse at hcnt==H_TOT-3: swap ping-pong buffers
	output     [31:0] vid_rdata,       // pixel data to DAFB (1-cycle registered latency)

	//---------------------------------------------------------
	// DDR3 Arbiter client interface (clk_sys)
	//---------------------------------------------------------
	output reg        vram_ddr_req,
	output reg        vram_ddr_we,
	output reg [28:0] vram_ddr_addr,
	output reg  [7:0] vram_ddr_burstcnt,
	output wire [63:0] vram_ddr_din,
	output wire  [7:0] vram_ddr_be,
	input             vram_ddr_busy,
	input             vram_ddr_ack,
	input      [63:0] vram_ddr_dout,
	input             vram_ddr_rvalid
);

//----------------------------------------------------------------------------
// Address mapping: relative 64-bit word address within VRAM
// 1 MB = 131,072 64-bit words -> addressed by mem_addr[19:3] (17 bits)
//----------------------------------------------------------------------------
wire [16:0] cpu_w64_addr = mem_addr[19:3];
wire [63:0] cpu_w64_din  = mem_addr[2] ? {mem_wdata, 32'd0} : {32'd0, mem_wdata};
wire  [7:0] cpu_w64_be   = mem_addr[2] ? {mem_be, 4'b0000}  : {4'b0000, mem_be};

//----------------------------------------------------------------------------
// Ping-Pong Scanline Cache (8 M10K blocks total: 2 banks of 1024 x 32-bit)
// Bank Even: holds words with col[0] == 0 (DDR3 bits [31:0])
// Bank Odd:  holds words with col[0] == 1 (DDR3 bits [63:32])
// Each bank has 1024 entries: [9] is buffer select (0 or 1), [8:0] is word64 index
//----------------------------------------------------------------------------
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_even_b0 [0:1023];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_even_b1 [0:1023];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_even_b2 [0:1023];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_even_b3 [0:1023];

(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_odd_b0  [0:1023];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_odd_b1  [0:1023];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_odd_b2  [0:1023];
(* ramstyle = "M10K, no_rw_check" *) reg [7:0] line_odd_b3  [0:1023];

reg        buf_display_vid = 1'b1;
reg        buf_prefetch_sys = 1'b0;
reg        buf_display_sys = 1'b1;

// Read side on clk_vid
reg  [9:0] vid_col_word_d;
reg [31:0] vid_rdata_even, vid_rdata_odd;

wire eff_buf_display = vid_line_swap ? ~buf_display_vid : buf_display_vid;
wire [9:0] line_rd_addr = {eff_buf_display, vid_col_word[9:1]};

always @(posedge clk_vid) begin
	vid_col_word_d <= vid_col_word;
	vid_rdata_even <= {line_even_b3[line_rd_addr], line_even_b2[line_rd_addr],
	                   line_even_b1[line_rd_addr], line_even_b0[line_rd_addr]};
	vid_rdata_odd  <= {line_odd_b3[line_rd_addr],  line_odd_b2[line_rd_addr],
	                   line_odd_b1[line_rd_addr],  line_odd_b0[line_rd_addr]};
end

assign vid_rdata = vid_col_word_d[0] ? vid_rdata_odd : vid_rdata_even;

// Buffer swap on clk_vid
always @(posedge clk_vid) begin
	if (reset_vid) begin
		buf_display_vid <= 1'b1;
	end
	else if (vid_line_swap) begin
		buf_display_vid <= ~buf_display_vid;
	end
end

// Directly synchronize buf_display_vid level to clk_sys domain
// Prefetch buffer is strictly the complement of display buffer, preventing any phase desync
reg buf_disp_meta, buf_disp_s1, buf_disp_s2;
always @(posedge clk_sys) begin
	if (reset) begin
		buf_disp_meta    <= 1'b1;
		buf_disp_s1      <= 1'b1;
		buf_disp_s2      <= 1'b1;
		buf_display_sys  <= 1'b1;
		buf_prefetch_sys <= 1'b0;
	end
	else begin
		buf_disp_meta    <= buf_display_vid;
		buf_disp_s1      <= buf_disp_meta;
		buf_disp_s2      <= buf_disp_s1;
		buf_display_sys  <= buf_disp_s1;
		buf_prefetch_sys <= ~buf_disp_s1;
	end
end
wire swap_pulse_sys = buf_disp_s1 ^ buf_disp_s2;

// Synchronize line_fetch_req from clk_vid to clk_sys
reg fetch_tog_vid = 1'b0;
always @(posedge clk_vid) begin
	if (reset_vid) fetch_tog_vid <= 1'b0;
	else if (vid_line_req) fetch_tog_vid <= ~fetch_tog_vid;
end

reg fetch_meta, fetch_s1, fetch_s2;
always @(posedge clk_sys) begin
	fetch_meta <= fetch_tog_vid;
	fetch_s1   <= fetch_meta;
	fetch_s2   <= fetch_s1;
end
wire line_req_sys = fetch_s1 ^ fetch_s2;

// Track active line base addresses for DMA & snoop
reg [16:0] cur_display_line_word64;
reg [16:0] cur_prefetch_line_word64;
reg [13:0] vid_stride_sys;

always @(posedge clk_sys) begin
	if (reset) begin
		cur_display_line_word64  <= 17'd0;
		cur_prefetch_line_word64 <= 17'd0;
		vid_stride_sys           <= 14'd1024;
	end
	else begin
		vid_stride_sys <= vid_stride;
		if (swap_pulse_sys) begin
			cur_display_line_word64 <= cur_prefetch_line_word64;
		end
		if (line_req_sys) begin
			cur_prefetch_line_word64 <= vid_line_addr[19:3];
		end
	end
end

//----------------------------------------------------------------------------
// CPU Write FIFO (16 entries deep, 64-bit wide)
// The data is eight byte-wide arrays with one write port and one read, at
// the read pointer (the old code had a second 16-way 64-bit read for the
// combine's merge).  They are held in logic: asked for as MLABs, Quartus
// built them as M10Ks with a retimed read address and bypass registers,
// and that build (b48a3f4 seed 41) drew horizontal lines on the box and
// lost 14 % on graphics.  The addresses and byte enables stay in
// flip-flops too (every slot is compared on a read, a combine ORs the
// enables).
//----------------------------------------------------------------------------
localparam FIFO_DEPTH = 16;
reg  [16:0] fifo_addr [0:FIFO_DEPTH-1];
reg   [7:0] fifo_be   [0:FIFO_DEPTH-1];
// fifo_seq[i]: slot i's address is one past the slot before it, as written.
// Only read for slots behind the read pointer, whose predecessor is still
// queued, so it is current wherever the burst scanner looks.
reg [FIFO_DEPTH-1:0] fifo_seq = {FIFO_DEPTH{1'b0}};
reg   [4:0] fifo_count = 5'd0;
reg   [3:0] fifo_wptr  = 4'd0;
reg   [3:0] fifo_rptr  = 4'd0;

// Pop condition is combinational: asserted the exact cycle the DDR3 arbiter acks a write
wire fifo_pop = (state == S_CPU_WRITE) && vram_ddr_ack;

assign vram_wq_room = (fifo_count < (FIFO_DEPTH - 4));

// Detect CPU write condition
reg vram_wr_ph = 1'b0;
wire cpu_vram_write = mem_vram_wp || (mem_req && mem_is_vram && mem_write && !vram_wr_ph);

// Write Combining: merge adjacent CPU writes to the same 64-bit word in FIFO
wire [3:0] last_wptr = fifo_wptr - 1'b1;
wire can_combine = cpu_vram_write &&
                   (fifo_count > 0) &&
                   (fifo_addr[last_wptr] == cpu_w64_addr) &&
                   !((state == S_CPU_WRITE) && (fifo_rptr == last_wptr));
wire is_new_entry = cpu_vram_write && !can_combine && (fifo_count < FIFO_DEPTH);

// One write port: a combine writes its bytes into the last slot, a new
// entry all eight bytes of the next.  The DDR3 takes the head slot's data
// combinationally on the clocks it acks; a combine never targets the slot
// being drained (can_combine), so the head needs no merge bypass -- the old
// one only ever applied on clocks the DDR3 was not sampling.
wire        fifo_we    = can_combine || is_new_entry;
wire  [3:0] fifo_waddr = can_combine ? last_wptr : fifo_wptr;
wire  [7:0] fifo_wbe   = can_combine ? cpu_w64_be : 8'hFF;
wire [63:0] fifo_rdata;

// (declared here, not in a generate loop: Quartus drops a ramstyle on an
// array inside one, and b48a3f4's and 45c3a8b's netlists were identical)
(* ramstyle = "logic" *) reg [63:0] fifo_din [0:FIFO_DEPTH-1];
integer fb;
always @(posedge clk_sys)
	if (!reset && fifo_we)
		for (fb = 0; fb < 8; fb = fb + 1)
			if (fifo_wbe[fb]) fifo_din[fifo_waddr][8*fb +: 8] <= cpu_w64_din[8*fb +: 8];
assign fifo_rdata = fifo_din[fifo_rptr];

// Driven directly to DDR3 interface for maximum throughput without pipeline bubbles
assign vram_ddr_din = fifo_rdata;
assign vram_ddr_be  = fifo_be[fifo_rptr];

// Burst scanner: detect contiguous sequential addresses in FIFO (up to 8
// beats) from the slots' fifo_seq bits, rotated to start at the head
wire [2*FIFO_DEPTH-1:0] seq_dbl = {fifo_seq, fifo_seq};
wire [FIFO_DEPTH-1:0]   seq_rot = seq_dbl[fifo_rptr +: FIFO_DEPTH];

wire contig_1 = (fifo_count >= 5'd2) && seq_rot[1];
wire contig_2 = contig_1 && (fifo_count >= 5'd3) && seq_rot[2];
wire contig_3 = contig_2 && (fifo_count >= 5'd4) && seq_rot[3];
wire contig_4 = contig_3 && (fifo_count >= 5'd5) && seq_rot[4];
wire contig_5 = contig_4 && (fifo_count >= 5'd6) && seq_rot[5];
wire contig_6 = contig_5 && (fifo_count >= 5'd7) && seq_rot[6];
wire contig_7 = contig_6 && (fifo_count >= 5'd8) && seq_rot[7];

wire [3:0] burst_beats = contig_7 ? 4'd8 :
                         contig_6 ? 4'd7 :
                         contig_5 ? 4'd6 :
                         contig_4 ? 4'd5 :
                         contig_3 ? 4'd4 :
                         contig_2 ? 4'd3 :
                         contig_1 ? 4'd2 : 4'd1;

reg [3:0] drain_beats_rem = 4'd0;

// (the read-after-write conflict check lives with the read line cache below:
//  line_pending / fifo_conflict)

// Write FIFO push, coalesce, and pop logic
always @(posedge clk_sys) begin
	if (reset) begin
		fifo_count <= 5'd0;
		fifo_wptr  <= 4'd0;
		fifo_rptr  <= 4'd0;
	end
	else begin
		case ({is_new_entry, fifo_pop})
		2'b10: fifo_count <= fifo_count + 1'b1;
		2'b01: fifo_count <= fifo_count - 1'b1;
		default: ; // 2'b11 or 2'b00: count unchanged
		endcase

		if (can_combine) begin
			fifo_be[last_wptr] <= fifo_be[last_wptr] | cpu_w64_be;
		end
		else if (cpu_vram_write && (fifo_count < FIFO_DEPTH)) begin
			fifo_addr[fifo_wptr] <= cpu_w64_addr;
			fifo_be[fifo_wptr]   <= cpu_w64_be;
			fifo_seq[fifo_wptr]  <= (cpu_w64_addr == fifo_addr[last_wptr] + 17'd1);
			fifo_wptr            <= fifo_wptr + 1'b1;
		end

		if (fifo_pop) begin
			fifo_rptr <= fifo_rptr + 1'b1;
		end
	end
end

//----------------------------------------------------------------------------
// CPU Write Snoop into Ping-Pong Line Buffer
// Updates visible scanline immediately so CPU writes never tear or drop
//----------------------------------------------------------------------------
wire [16:0] snoop_disp_diff = cpu_w64_addr - cur_display_line_word64;
wire        snoop_disp_hit  = (cpu_w64_addr >= cur_display_line_word64) &&
                              (snoop_disp_diff < {6'd0, vid_stride_sys[13:3]});
wire  [9:0] snoop_disp_addr = {buf_display_sys, snoop_disp_diff[8:0]};

wire [16:0] snoop_pref_diff = cpu_w64_addr - cur_prefetch_line_word64;
wire        snoop_pref_hit  = (cpu_w64_addr >= cur_prefetch_line_word64) &&
                              (snoop_pref_diff < {6'd0, vid_stride_sys[13:3]});
wire  [9:0] snoop_pref_addr = {buf_prefetch_sys, snoop_pref_diff[8:0]};

//----------------------------------------------------------------------------
// DDR3 DMA Burst Engine for Line Pre-fetch
//----------------------------------------------------------------------------
localparam DMA_IDLE      = 1'b0;
localparam DMA_BURST_REQ = 1'b1;

reg        dma_state = DMA_IDLE;
reg  [8:0] dma_word64_idx;
reg  [7:0] dma_total_bursts;
reg  [7:0] dma_burst_idx;
reg  [5:0] dma_beats_left;
reg [16:0] dma_cur_addr;

// 4-Way Associative 32-Byte Read Line Cache (4 ways x 4 beats = 128 bytes total)
reg [14:0] rd_cache_tag_0 = 15'd0, rd_cache_tag_1 = 15'd0;
reg [14:0] rd_cache_tag_2 = 15'd0, rd_cache_tag_3 = 15'd0;
reg [63:0] rd_cache_line_0 [0:3];
reg [63:0] rd_cache_line_1 [0:3];
reg [63:0] rd_cache_line_2 [0:3];
reg [63:0] rd_cache_line_3 [0:3];
// Valid bits are per BYTE (4 beats x 8 = 32 per way).  A CPU write clears
// only the bytes it wrote, so the other 32-bit half of the beat and the rest
// of the line stay servable.  QuickDraw's read-modify-write walks a row as
// read lo / write lo / read hi / write hi ...: with per-beat valid bits and a
// FIFO-conflict gate on hits, every second read of that stream missed, drained
// the write FIFO and re-fetched the whole line (profile of 2026-10-26).
reg [31:0] rd_cache_val_0 = 32'd0, rd_cache_val_1 = 32'd0;
reg [31:0] rd_cache_val_2 = 32'd0, rd_cache_val_3 = 32'd0;
reg  [1:0] rd_victim = 2'd0;
reg  [1:0] rd_burst_beat;
// the prefetch buffer, a fifth line only prefetches fill (see PREFETCH below)
reg [14:0] pb_tag   = 15'd0;
reg [63:0] pb_line [0:3];
reg [31:0] pb_val   = 32'd0;
reg        pb_used  = 1'b0;    // a read has been answered from pb
reg        pb_fresh = 1'b0;    // filled by a prefetch, not read yet (perf)
reg        fill_pb  = 1'b0;    // the fill in flight targets pb

wire [14:0] cur_rd_tag  = cpu_w64_addr[16:2];
wire  [1:0] cur_rd_beat = cpu_w64_addr[1:0];
// the 32-bit half the CPU is reading: bytes {beat, addr[2]}*4 .. +3 of the line
wire  [4:0] cur_rd_half = {cur_rd_beat, mem_addr[2], 2'b00};

wire hit_way_0 = (&rd_cache_val_0[cur_rd_half +: 4]) && (rd_cache_tag_0 == cur_rd_tag);
wire hit_way_1 = (&rd_cache_val_1[cur_rd_half +: 4]) && (rd_cache_tag_1 == cur_rd_tag);
wire hit_way_2 = (&rd_cache_val_2[cur_rd_half +: 4]) && (rd_cache_tag_2 == cur_rd_tag);
wire hit_way_3 = (&rd_cache_val_3[cur_rd_half +: 4]) && (rd_cache_tag_3 == cur_rd_tag);

// A hit needs no FIFO-conflict check: a byte with a write still queued is
// either invalid or already holds that write's data (the write updates the
// held line), and a fill is only issued once the FIFO holds nothing for the
// line (line_conflict below).
wire hit_pb    = (&pb_val[cur_rd_half +: 4])         && (pb_tag         == cur_rd_tag);
wire rd_cache_hit = hit_way_0 || hit_way_1 || hit_way_2 || hit_way_3 || hit_pb;

// A fill is issued only when the FIFO holds no write for the 32-byte line
// being read: 16 tag compares, the same scan the old per-word check did.
// Every byte a fill brings in is then current and may be marked valid, so
// the cache never holds stale data.  (A per-byte pending map was tried
// first: its 16-way indexed OR cost about 1,200 ALUTs.)
function slot_used(input [3:0] s);
	slot_used = (fifo_count != 5'd0) &&
	            ((fifo_wptr > fifo_rptr) ? ((s >= fifo_rptr) && (s < fifo_wptr)) :
	             (fifo_wptr < fifo_rptr) ? ((s >= fifo_rptr) || (s < fifo_wptr)) : 1'b1);
endfunction
reg line_conflict;
integer f_i;
always @(*) begin
	line_conflict = 1'b0;
	for (f_i = 0; f_i < FIFO_DEPTH; f_i = f_i + 1)
		if (slot_used(f_i[3:0]) && (fifo_addr[f_i][16:2] == cur_rd_tag))
			line_conflict = 1'b1;
end
wire fifo_conflict = line_conflict;
// bytes of a fill beat that may be marked valid: all of them, except those
// written since the fill was issued.  The beat that satisfies the CPU's read
// releases it, and the DDR3 bridge may split a burst (the HDMI scaler shares
// the DDR3), so the later beats can land tens of clocks after the CPU has
// gone on to store into the same line; their data predates those stores.
// fill_wr_mask collects the bytes written while the fill is in flight,
// wr_now_be covers a write landing on the very clock of its beat.
reg  [31:0] fill_wr_mask = 32'd0;
wire        fill_active  = (state == S_CPU_READ) || (state == S_CPU_DATA);
// the line being filled: rd_victim's tag, kept in its own register so the
// read acknowledge below compares against a flop instead of a 4-way mux
reg  [14:0] fill_tag     = 15'd0;
// a pending read takes a fill beat only from its own line: with the
// next-line prefetch, the line in flight is often not the one the CPU is
// waiting for
wire        fill_mine    = (cur_rd_tag == fill_tag);

// Next-line prefetch.  89 % of fills in the Graphics test were for the line
// after the last one filled (capture of 2026-11-12): QuickDraw walks a row
// of VRAM 32 bytes at a time.  Every VRAM read of line N asks for line N+1
// (pf_want, pf_tag), and when the bus is free and no demand read waits,
// N+1 is fetched like a demand fill.  It is skipped when the cache already
// holds that tag, or the write FIFO holds a write for it (same rule as a
// demand fill: the fill must not predate a queued write).
//
// A prefetch lands in its own line, the prefetch buffer (pb_*), not in a
// way: filling the next way evicted lines still in use, and with a source
// and a destination stream only 56 % of prefetches were used (A14).  The
// buffer is looked up like a fifth way.  Once a read has used it (pb_used),
// the next prefetch moves it into the victim way before refilling it, so
// a line enters the four ways only after it has proved useful.
//
// PF_SEQ: prefetch N+1 only while N-1 is still held, i.e. once a walk is
// under way, so lone reads do not spend DDR3 time on lines never read.
localparam PREFETCH = 1'b1;
localparam PF_SEQ   = 1'b0;
reg         pf_want = 1'b0;
reg  [14:0] pf_tag  = 15'd0;
function tag_held(input [14:0] t);
	tag_held = (t == rd_cache_tag_0) || (t == rd_cache_tag_1) ||
	           (t == rd_cache_tag_2) || (t == rd_cache_tag_3) ||
	           (t == pb_tag);
endfunction
wire        pf_held = tag_held(pf_tag);
wire        pf_seq  = !PF_SEQ || tag_held(pf_tag - 15'd2);
reg pf_conflict;
integer p_i;
always @(*) begin
	pf_conflict = 1'b0;
	for (p_i = 0; p_i < FIFO_DEPTH; p_i = p_i + 1)
		if (slot_used(p_i[3:0]) && (fifo_addr[p_i][16:2] == pf_tag))
			pf_conflict = 1'b1;
end
wire [7:0] wr_now_be  = cpu_vram_write ? cpu_w64_be : 8'h00;
wire [7:0] fill_val_0 = ~((cur_rd_beat == 2'd0) ? wr_now_be : 8'h00) & ~fill_wr_mask[7:0];
wire [7:0] fill_val_b = ~((cur_rd_beat == rd_burst_beat) ? wr_now_be : 8'h00) & ~fill_wr_mask[{rd_burst_beat, 3'b000} +: 8];

// a CPU write merged into a held cache beat
function [63:0] wr_merge(input [63:0] old);
	integer b;
	for (b = 0; b < 8; b = b + 1)
		wr_merge[b*8 +: 8] = cpu_w64_be[b] ? cpu_w64_din[b*8 +: 8] : old[b*8 +: 8];
endfunction

wire [63:0] hit_data = hit_way_0 ? rd_cache_line_0[cur_rd_beat] :
                       hit_way_1 ? rd_cache_line_1[cur_rd_beat] :
                       hit_way_2 ? rd_cache_line_2[cur_rd_beat] :
                       hit_way_3 ? rd_cache_line_3[cur_rd_beat] :
                                   pb_line[cur_rd_beat];
wire [31:0] hit_word = mem_addr[2] ? hit_data[63:32] : hit_data[31:0];

// The fast port: the same lookup on the CPU's bus address, combinational,
// so the machine can register its acknowledge in the clock the request
// appears.  The rules are those of a hit above; a read that misses here
// comes back as mem_req.  Not on the clock of a write to the same longword:
// the write is older than the read in bus order and lands in the line at
// the clock edge.  A write to any other longword leaves this one's bytes
// and their valid bits alone, so the read is answered beside it (the
// machine acknowledges a queued write and takes the next read in
// consecutive clocks).
wire [14:0] fast_tag  = fast_addr[19:5];
wire  [1:0] fast_beat = fast_addr[4:3];
wire  [4:0] fast_half = {fast_beat, fast_addr[2], 2'b00};

wire fast_way_0 = (&rd_cache_val_0[fast_half +: 4]) && (rd_cache_tag_0 == fast_tag);
wire fast_way_1 = (&rd_cache_val_1[fast_half +: 4]) && (rd_cache_tag_1 == fast_tag);
wire fast_way_2 = (&rd_cache_val_2[fast_half +: 4]) && (rd_cache_tag_2 == fast_tag);
wire fast_way_3 = (&rd_cache_val_3[fast_half +: 4]) && (rd_cache_tag_3 == fast_tag);
wire fast_pb    = (&pb_val[fast_half +: 4])         && (pb_tag         == fast_tag);

wire [63:0] fast_beat_data = fast_way_0 ? rd_cache_line_0[fast_beat] :
                             fast_way_1 ? rd_cache_line_1[fast_beat] :
                             fast_way_2 ? rd_cache_line_2[fast_beat] :
                             fast_way_3 ? rd_cache_line_3[fast_beat] :
                                          pb_line[fast_beat];
assign fast_hit  = (fast_way_0 || fast_way_1 || fast_way_2 || fast_way_3 || fast_pb) &&
                   !(cpu_vram_write && (mem_addr[19:2] == fast_addr[19:2]));
assign fast_data = fast_addr[2] ? fast_beat_data[63:32] : fast_beat_data[31:0];

// DDR3 Request & Arbitration FSM States
localparam S_IDLE      = 3'd0;
localparam S_CPU_READ  = 3'd1;
localparam S_CPU_DATA  = 3'd2;
localparam S_DMA_BURST = 3'd3;
localparam S_DMA_DATA  = 3'd4;
localparam S_CPU_WRITE = 3'd5;

reg [2:0] state = S_IDLE;
reg       cpu_rd_pend = 1'b0;

wire dma_writing = (state == S_DMA_DATA) && vram_ddr_rvalid;
wire [9:0] dma_wr_addr = {buf_prefetch_sys, dma_word64_idx};

// Line prefetch pacing.  A line request is taken when no DMA burst is in
// flight; one that arrives under a burst is held and taken once that burst
// has landed, and the rest of the old line is dropped (it is late anyway).
// Resetting the bookkeeping under a live burst, as the old code did, sent
// the burst's remaining beats to index 0.. of the new buffer and shifted
// the new line right by that many words: the sheared "Starting Up" lines
// seen on the box on 2026-10-27.  A prefetch that has waited 128 clocks
// for the DDR3 goes ahead of the CPU's traffic (dma_late): the CPU can
// stall a little, a scanline cannot.
reg         line_req_held = 1'b0;
reg  [16:0] held_addr = 17'd0;
reg   [7:0] dma_wait = 8'd0;
wire        dma_inflight = (state == S_DMA_BURST) || (state == S_DMA_DATA);
wire        dma_take     = (line_req_sys || line_req_held) && !dma_inflight;
wire        dma_late     = dma_wait[7];
function [7:0] dma_bursts_for(input [13:0] stride);
	dma_bursts_for = {2'd0, stride[13:8]} + (stride[7:0] != 8'd0 ? 8'd1 : 8'd0);
endfunction

// Single multiplexed Write Port on clk_sys for M10K BRAM inference
wire        line_wr_dma = dma_writing;
wire        line_wr_cpu = cpu_vram_write && (snoop_disp_hit || snoop_pref_hit);
wire        line_wr_en  = line_wr_dma || line_wr_cpu;

wire  [9:0] line_wr_addr = line_wr_dma ? dma_wr_addr :
                           snoop_disp_hit ? snoop_disp_addr : snoop_pref_addr;

wire [63:0] line_wr_din  = line_wr_dma ? vram_ddr_dout : cpu_w64_din;
wire  [7:0] line_wr_be   = line_wr_dma ? 8'hFF : cpu_w64_be;

always @(posedge clk_sys) begin
	if (line_wr_en) begin
		if (line_wr_be[0]) line_even_b0[line_wr_addr] <= line_wr_din[7:0];
		if (line_wr_be[1]) line_even_b1[line_wr_addr] <= line_wr_din[15:8];
		if (line_wr_be[2]) line_even_b2[line_wr_addr] <= line_wr_din[23:16];
		if (line_wr_be[3]) line_even_b3[line_wr_addr] <= line_wr_din[31:24];

		if (line_wr_be[4]) line_odd_b0[line_wr_addr]  <= line_wr_din[39:32];
		if (line_wr_be[5]) line_odd_b1[line_wr_addr]  <= line_wr_din[47:40];
		if (line_wr_be[6]) line_odd_b2[line_wr_addr]  <= line_wr_din[55:48];
		if (line_wr_be[7]) line_odd_b3[line_wr_addr]  <= line_wr_din[63:56];
	end
end

// Prefetch buffer use.  pb_use: a read is answered from pb this clock, by
// a hit on either port (the ways win a tie in the data muxes, so only when
// no way hits) or by one of pb's fill beats.  It sets pb_used, which lets
// the next prefetch promote the line; the first use after a prefetch also
// counts as a used prefetch (perf event 10, pb_fresh).
wire        pe_rd_hit   = mem_req && mem_is_vram && !mem_write && !vram_ack &&
                          rd_cache_hit;
wire        pe_hit_pb   = pe_rd_hit ? (hit_pb &&
                                       !(hit_way_0 || hit_way_1 || hit_way_2 || hit_way_3)) :
                          fast_take ? (fast_pb &&
                                       !(fast_way_0 || fast_way_1 || fast_way_2 || fast_way_3)) :
                                      1'b0;
wire        pe_fill_ack = !reset && cpu_rd_pend && fill_mine && vram_ddr_rvalid &&
                          (((state == S_CPU_READ) && vram_ddr_ack &&
                            (cur_rd_beat == 2'd0)) ||
                           ((state == S_CPU_DATA) && (cur_rd_beat == rd_burst_beat)));
wire        pb_use      = pe_hit_pb || (pe_fill_ack && fill_pb);

// S_IDLE branch 2b's condition, shared with its perf event
wire        pf_go       = PREFETCH && pf_want && !cpu_rd_pend && !cpu_vram_write &&
                          !pf_held && !pf_conflict && pf_seq;

//----------------------------------------------------------------------------
// DDR3 Request & Arbitration FSM
// Priority:
//   1. CPU Read (on-demand probe / CopyBits read; bypasses FIFO if !fifo_conflict)
//   2. High-priority CPU Write Drain (if queue >= 8 or CPU read has conflicting write)
//   3. Line DMA Burst (pre-fetches next scanline during horizontal period)
//   4. Normal CPU Write Drain (drains FIFO to DDR3 when DMA is idle)
//----------------------------------------------------------------------------
always @(posedge clk_sys) begin
	vram_ack <= 1'b0;
	if (state != S_CPU_WRITE) vram_ddr_req <= 1'b0;

	if (reset) begin
		state           <= S_IDLE;
		dma_state       <= DMA_IDLE;
		cpu_rd_pend     <= 1'b0;
		vram_wr_ph      <= 1'b0;
		vram_ddr_req    <= 1'b0;
		vram_ddr_we     <= 1'b0;
		dma_word64_idx  <= 9'd0;
		rd_cache_val_0  <= 32'd0;
		rd_cache_val_1  <= 32'd0;
		rd_cache_val_2  <= 32'd0;
		rd_cache_val_3  <= 32'd0;
		rd_victim       <= 2'd0;
		rd_burst_beat   <= 2'd0;
		drain_beats_rem <= 4'd0;
		fill_wr_mask    <= 32'd0;
		line_req_held   <= 1'b0;
		dma_wait        <= 8'd0;
		pf_want         <= 1'b0;
		pb_val          <= 32'd0;
		pb_used         <= 1'b0;
		pb_fresh        <= 1'b0;
		fill_pb         <= 1'b0;
	end
	else begin
		// prefetch bookkeeping: a VRAM read of line N asks for N+1 (the
		// fill branches below may clear the request or set a mark; theirs
		// win, being later in this block)
		if (fast_take) begin
			pf_want <= 1'b1;
			pf_tag  <= fast_tag + 15'd1;
		end
		else if (mem_req && mem_is_vram && !mem_write) begin
			pf_want <= 1'b1;
			pf_tag  <= cur_rd_tag + 15'd1;
		end
		else if (pf_want && pf_held && (state == S_IDLE))
			pf_want <= 1'b0;
		if (pb_use) begin
			pb_used  <= 1'b1;
			pb_fresh <= 1'b0;
		end

		// Normal write handshake with quadra800 bus
		if (mem_req && mem_is_vram && mem_write) begin
			vram_wr_ph <= !vram_wr_ph;
			if (vram_wr_ph) vram_ack <= 1'b1;
		end
		else begin
			vram_wr_ph <= 1'b0;
		end

		// A CPU write updates the bytes it wrote in a held line and marks them
		// valid, so QuickDraw's read-modify-write of one longword hits on the
		// re-read instead of draining the write FIFO and refetching the line.
		// The cache then holds data newer than the DDR3 until the FIFO
		// drains, which is fine: a fill is only issued for a line with no
		// write queued (line_conflict).  The one exception is the way being
		// filled: its fill beats overwrite whole beats with data that may
		// predate the write, so there the bytes are only invalidated and
		// kept out of the fill (fill_wr_mask).
		if (cpu_vram_write) begin
			if (fill_active && (cur_rd_tag == fill_tag))
				fill_wr_mask[{cur_rd_beat, 3'b000} +: 8] <= fill_wr_mask[{cur_rd_beat, 3'b000} +: 8] | cpu_w64_be;
			if (cur_rd_tag == pb_tag) begin
				if (fill_active && fill_pb)
					pb_val[{cur_rd_beat, 3'b000} +: 8] <= pb_val[{cur_rd_beat, 3'b000} +: 8] & ~cpu_w64_be;
				else begin
					pb_line[cur_rd_beat] <= wr_merge(pb_line[cur_rd_beat]);
					pb_val[{cur_rd_beat, 3'b000} +: 8] <= pb_val[{cur_rd_beat, 3'b000} +: 8] | cpu_w64_be;
				end
			end
			if (cur_rd_tag == rd_cache_tag_0) begin
				if (fill_active && !fill_pb && rd_victim == 2'd0)
					rd_cache_val_0[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_0[{cur_rd_beat, 3'b000} +: 8] & ~cpu_w64_be;
				else begin
					rd_cache_line_0[cur_rd_beat] <= wr_merge(rd_cache_line_0[cur_rd_beat]);
					rd_cache_val_0[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_0[{cur_rd_beat, 3'b000} +: 8] | cpu_w64_be;
				end
			end
			if (cur_rd_tag == rd_cache_tag_1) begin
				if (fill_active && !fill_pb && rd_victim == 2'd1)
					rd_cache_val_1[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_1[{cur_rd_beat, 3'b000} +: 8] & ~cpu_w64_be;
				else begin
					rd_cache_line_1[cur_rd_beat] <= wr_merge(rd_cache_line_1[cur_rd_beat]);
					rd_cache_val_1[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_1[{cur_rd_beat, 3'b000} +: 8] | cpu_w64_be;
				end
			end
			if (cur_rd_tag == rd_cache_tag_2) begin
				if (fill_active && !fill_pb && rd_victim == 2'd2)
					rd_cache_val_2[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_2[{cur_rd_beat, 3'b000} +: 8] & ~cpu_w64_be;
				else begin
					rd_cache_line_2[cur_rd_beat] <= wr_merge(rd_cache_line_2[cur_rd_beat]);
					rd_cache_val_2[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_2[{cur_rd_beat, 3'b000} +: 8] | cpu_w64_be;
				end
			end
			if (cur_rd_tag == rd_cache_tag_3) begin
				if (fill_active && !fill_pb && rd_victim == 2'd3)
					rd_cache_val_3[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_3[{cur_rd_beat, 3'b000} +: 8] & ~cpu_w64_be;
				else begin
					rd_cache_line_3[cur_rd_beat] <= wr_merge(rd_cache_line_3[cur_rd_beat]);
					rd_cache_val_3[{cur_rd_beat, 3'b000} +: 8] <= rd_cache_val_3[{cur_rd_beat, 3'b000} +: 8] | cpu_w64_be;
				end
			end
		end

		// DMA trigger: a line request starts the prefetch (32-beat bursts),
		// or is held under a live burst (see line_req_held above)
		if (line_req_sys && dma_inflight) begin
			line_req_held <= 1'b1;
			held_addr     <= vid_line_addr[19:3];
		end
		if (dma_take) begin
			line_req_held     <= 1'b0;
			dma_cur_addr      <= line_req_held ? held_addr : vid_line_addr[19:3];
			dma_total_bursts  <= dma_bursts_for(vid_stride_sys);
			dma_burst_idx     <= 8'd0;
			dma_word64_idx    <= 9'd0;
			dma_state         <= DMA_BURST_REQ;
		end
		if ((dma_state == DMA_BURST_REQ) && !dma_inflight && !dma_take) begin
			if (!dma_wait[7]) dma_wait <= dma_wait + 1'b1;
		end
		else dma_wait <= 8'd0;

		// CPU Read detection & Instant Cache Hit
		if (mem_req && mem_is_vram && !mem_write && !vram_ack) begin
			if (rd_cache_hit) begin
				vram_rdata  <= hit_word;
				vram_ack    <= 1'b1;
				cpu_rd_pend <= 1'b0;
			end
			else begin
				cpu_rd_pend <= 1'b1;
			end
		end

		// DDR3 bus state machine
		case (state)
		S_IDLE: begin
			// 0. A line prefetch that has waited 128 clocks goes first.
			// Neither DMA branch issues on a dma_take clock: dma_cur_addr
			// still holds where the old line's fetch stopped, and the burst
			// would land that data in slots 0-31 of the new line (the first
			// fifth of a 16-bit row from the wrong place, on random lines,
			// whenever a line was still fetching when the next was asked for)
			if (dma_late && (dma_state == DMA_BURST_REQ) && !dma_take) begin
				vram_ddr_req      <= 1'b1;
				vram_ddr_we       <= 1'b0;
				vram_ddr_addr     <= DDR_VRAM_BASE + {12'd0, dma_cur_addr};
				vram_ddr_burstcnt <= 8'd32;
				state             <= S_DMA_BURST;
			end
			// 1. CPU Read (burst of 4 beats = 32 bytes into 4-way line cache).
			// Not on a write's clock: that write is not in the FIFO yet, so
			// line_conflict cannot see it, and the fill would predate it.
			else if (cpu_rd_pend && !fifo_conflict && !cpu_vram_write) begin
				vram_ddr_req      <= 1'b1;
				vram_ddr_we       <= 1'b0;
				vram_ddr_addr     <= DDR_VRAM_BASE + {12'd0, cur_rd_tag, 2'b00};
				vram_ddr_burstcnt <= 8'd4;
				case (rd_victim)
				2'd0: begin rd_cache_tag_0 <= cur_rd_tag; rd_cache_val_0 <= 32'd0; end
				2'd1: begin rd_cache_tag_1 <= cur_rd_tag; rd_cache_val_1 <= 32'd0; end
				2'd2: begin rd_cache_tag_2 <= cur_rd_tag; rd_cache_val_2 <= 32'd0; end
				2'd3: begin rd_cache_tag_3 <= cur_rd_tag; rd_cache_val_3 <= 32'd0; end
				endcase
				fill_tag          <= cur_rd_tag;
				fill_pb           <= 1'b0;
				fill_wr_mask      <= 32'd0;
				rd_burst_beat     <= 2'd0;
				state             <= S_CPU_READ;
			end
			// 2. High-priority CPU Write drain (FIFO >= 8, or CPU read waiting on conflicting write)
			else if ((fifo_count > 0) && (cpu_rd_pend || (fifo_count >= 5'd8))) begin
				vram_ddr_req      <= 1'b1;
				vram_ddr_we       <= 1'b1;
				vram_ddr_addr     <= DDR_VRAM_BASE + {12'd0, fifo_addr[fifo_rptr]};
				vram_ddr_burstcnt <= {4'd0, burst_beats};
				drain_beats_rem   <= burst_beats;
				state             <= S_CPU_WRITE;
			end
			// 2b. Next-line prefetch into pb (pf_go): a fill like branch
			// 1's, for pf_tag.  Not with a read pending (branch 1 or 2 owns
			// that clock), not on a write's clock (that write is not in the
			// FIFO yet, and the promotion below copies pb as it stands), and
			// not for a line already held.  A pb line a read has used moves
			// into the victim way first; an unused one is dropped.
			else if (pf_go) begin
				vram_ddr_req      <= 1'b1;
				vram_ddr_we       <= 1'b0;
				vram_ddr_addr     <= DDR_VRAM_BASE + {12'd0, pf_tag, 2'b00};
				vram_ddr_burstcnt <= 8'd4;
				if (pb_used || pb_use) begin
					case (rd_victim)
					2'd0: begin rd_cache_tag_0 <= pb_tag; rd_cache_val_0 <= pb_val;
					            rd_cache_line_0[0] <= pb_line[0]; rd_cache_line_0[1] <= pb_line[1];
					            rd_cache_line_0[2] <= pb_line[2]; rd_cache_line_0[3] <= pb_line[3]; end
					2'd1: begin rd_cache_tag_1 <= pb_tag; rd_cache_val_1 <= pb_val;
					            rd_cache_line_1[0] <= pb_line[0]; rd_cache_line_1[1] <= pb_line[1];
					            rd_cache_line_1[2] <= pb_line[2]; rd_cache_line_1[3] <= pb_line[3]; end
					2'd2: begin rd_cache_tag_2 <= pb_tag; rd_cache_val_2 <= pb_val;
					            rd_cache_line_2[0] <= pb_line[0]; rd_cache_line_2[1] <= pb_line[1];
					            rd_cache_line_2[2] <= pb_line[2]; rd_cache_line_2[3] <= pb_line[3]; end
					2'd3: begin rd_cache_tag_3 <= pb_tag; rd_cache_val_3 <= pb_val;
					            rd_cache_line_3[0] <= pb_line[0]; rd_cache_line_3[1] <= pb_line[1];
					            rd_cache_line_3[2] <= pb_line[2]; rd_cache_line_3[3] <= pb_line[3]; end
					endcase
					rd_victim     <= rd_victim + 1'b1;
				end
				pb_tag            <= pf_tag;
				pb_val            <= 32'd0;
				pb_used           <= 1'b0;
				pb_fresh          <= 1'b1;
				fill_tag          <= pf_tag;
				fill_pb           <= 1'b1;
				fill_wr_mask      <= 32'd0;
				rd_burst_beat     <= 2'd0;
				pf_want           <= 1'b0;
				state             <= S_CPU_READ;
			end
			// 3. Line DMA burst read (32-beat bursts)
			else if ((dma_state == DMA_BURST_REQ) && !dma_take) begin
				vram_ddr_req      <= 1'b1;
				vram_ddr_we       <= 1'b0;
				vram_ddr_addr     <= DDR_VRAM_BASE + {12'd0, dma_cur_addr};
				vram_ddr_burstcnt <= 8'd32;
				state             <= S_DMA_BURST;
			end
			// 4. Normal CPU Write drain when DMA is idle
			else if (fifo_count > 0) begin
				vram_ddr_req      <= 1'b1;
				vram_ddr_we       <= 1'b1;
				vram_ddr_addr     <= DDR_VRAM_BASE + {12'd0, fifo_addr[fifo_rptr]};
				vram_ddr_burstcnt <= {4'd0, burst_beats};
				drain_beats_rem   <= burst_beats;
				state             <= S_CPU_WRITE;
			end
		end

		S_CPU_READ: begin
			vram_ddr_req <= 1'b1;
			if (vram_ddr_ack) begin
				vram_ddr_req <= 1'b0;
				if (vram_ddr_rvalid) begin
					if (fill_pb) begin
						pb_line[2'd0] <= vram_ddr_dout; pb_val[7:0] <= fill_val_0;
					end
					else case (rd_victim)
					2'd0: begin rd_cache_line_0[2'd0] <= vram_ddr_dout; rd_cache_val_0[7:0] <= fill_val_0; end
					2'd1: begin rd_cache_line_1[2'd0] <= vram_ddr_dout; rd_cache_val_1[7:0] <= fill_val_0; end
					2'd2: begin rd_cache_line_2[2'd0] <= vram_ddr_dout; rd_cache_val_2[7:0] <= fill_val_0; end
					2'd3: begin rd_cache_line_3[2'd0] <= vram_ddr_dout; rd_cache_val_3[7:0] <= fill_val_0; end
					endcase
					rd_burst_beat <= 2'd1;
					if (cpu_rd_pend && fill_mine && (cur_rd_beat == 2'd0)) begin
						vram_rdata  <= mem_addr[2] ? vram_ddr_dout[63:32] : vram_ddr_dout[31:0];
						vram_ack    <= 1'b1;
						cpu_rd_pend <= 1'b0;
					end
					state <= S_CPU_DATA;
				end
				else begin
					state <= S_CPU_DATA;
				end
			end
		end

		S_CPU_DATA: begin
			if (vram_ddr_rvalid) begin
				if (fill_pb) begin
					pb_line[rd_burst_beat] <= vram_ddr_dout; pb_val[{rd_burst_beat, 3'b000} +: 8] <= fill_val_b;
				end
				else case (rd_victim)
				2'd0: begin rd_cache_line_0[rd_burst_beat] <= vram_ddr_dout; rd_cache_val_0[{rd_burst_beat, 3'b000} +: 8] <= fill_val_b; end
				2'd1: begin rd_cache_line_1[rd_burst_beat] <= vram_ddr_dout; rd_cache_val_1[{rd_burst_beat, 3'b000} +: 8] <= fill_val_b; end
				2'd2: begin rd_cache_line_2[rd_burst_beat] <= vram_ddr_dout; rd_cache_val_2[{rd_burst_beat, 3'b000} +: 8] <= fill_val_b; end
				2'd3: begin rd_cache_line_3[rd_burst_beat] <= vram_ddr_dout; rd_cache_val_3[{rd_burst_beat, 3'b000} +: 8] <= fill_val_b; end
				endcase
				rd_burst_beat <= rd_burst_beat + 1'b1;
				if (cpu_rd_pend && fill_mine && (cur_rd_beat == rd_burst_beat)) begin
					vram_rdata  <= mem_addr[2] ? vram_ddr_dout[63:32] : vram_ddr_dout[31:0];
					vram_ack    <= 1'b1;
					cpu_rd_pend <= 1'b0;
				end
				if (rd_burst_beat == 2'd3) begin
					if (!fill_pb) rd_victim <= rd_victim + 1'b1;
					state     <= S_IDLE;
				end
			end
		end

		S_DMA_BURST: begin
			vram_ddr_req <= 1'b1;
			if (vram_ddr_ack) begin
				vram_ddr_req   <= 1'b0;
				dma_beats_left <= 6'd32;
				state          <= S_DMA_DATA;
			end
		end

		S_DMA_DATA: begin
			if (vram_ddr_rvalid) begin
				dma_word64_idx <= dma_word64_idx + 1'b1;
				dma_cur_addr   <= dma_cur_addr + 1'b1;
				dma_beats_left <= dma_beats_left - 1'b1;
				if (dma_beats_left == 6'd1) begin
					dma_burst_idx <= dma_burst_idx + 1'b1;
					// done, or the next line is already due: the held request
					// is taken next clock and the rest of this line dropped
					if (line_req_held || line_req_sys || (dma_burst_idx + 1'b1 >= dma_total_bursts))
						dma_state <= DMA_IDLE;
					else
						dma_state <= DMA_BURST_REQ;
					state <= S_IDLE;
				end
			end
		end

		S_CPU_WRITE: begin
			vram_ddr_req <= 1'b1;
			vram_ddr_we  <= 1'b1;
			if (vram_ddr_ack) begin
				drain_beats_rem <= drain_beats_rem - 1'b1;
				if (drain_beats_rem == 4'd1) begin
					vram_ddr_req <= 1'b0;
					vram_ddr_we  <= 1'b0;
					state        <= S_IDLE;
				end
			end
		end

		default: state <= S_IDLE;
		endcase
	end
end

// ---- perf events (pages 5 and 6 of rtl/perf_counters.sv) ----
// a read answered from the line cache, through either port
wire pe_hit  = (mem_req && mem_is_vram && !mem_write && !vram_ack &&
                rd_cache_hit) || fast_take;
// a line fill issued for a pending read (S_IDLE branch 1)
wire pe_fill = !reset && (state == S_IDLE) &&
               !(dma_late && (dma_state == DMA_BURST_REQ) && !dma_take) &&
               cpu_rd_pend && !fifo_conflict && !cpu_vram_write;
// a next-line prefetch issued (S_IDLE branch 2b, pf_go)
wire pe_pf_issue = !reset && (state == S_IDLE) &&
                   !(dma_late && (dma_state == DMA_BURST_REQ) && !dma_take) &&
                   !(fifo_count >= 5'd8) && pf_go;
reg [14:0] pe_last_tag = 15'd0;
always @(posedge clk_sys) if (pe_fill) pe_last_tag <= cur_rd_tag;

assign perf_ev = {
	// page 6
	// 11: waits under another line's fill tail
	cpu_rd_pend && (state == S_CPU_DATA) && (cur_rd_tag != fill_tag),
	// 10: prefetched lines used (first read answered from one)
	pb_use && pb_fresh,
	// 9: next-line prefetches issued
	pe_pf_issue,
	// 8: fill of the line after the last one filled
	pe_fill && (cur_rd_tag == pe_last_tag + 15'd1),
	// 7: wait: FIFO holds a write for the line
	cpu_rd_pend && (state == S_IDLE) && fifo_conflict,
	// 6: wait: fill data beats
	cpu_rd_pend && (state == S_CPU_DATA),
	// page 5
	// 5: wait: DDR3 accepting the fill
	cpu_rd_pend && (state == S_CPU_READ),
	// 4: wait: scanline DMA burst
	cpu_rd_pend && ((state == S_DMA_BURST) || (state == S_DMA_DATA)),
	// 3: wait: write FIFO drain
	cpu_rd_pend && (state == S_CPU_WRITE),
	// 2: wait: idle (conflict, write clock, turnaround)
	cpu_rd_pend && (state == S_IDLE),
	// 1: fills issued (misses)
	pe_fill,
	// 0: hits
	pe_hit
};

endmodule
