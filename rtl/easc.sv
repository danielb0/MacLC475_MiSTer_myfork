//============================================================================
//  easc — Enhanced Apple Sound Chip ("Batman"), as the IOSB / PrimeTime
//  carries it.  NOT the Mac LC's part (the V8's mono FIFO-only ASC).
//
//  WHAT THE CHIP IS, and what each statement rests on
//
//  [HO]  Macintosh Hardware Overview, Apple, Feb 1991, "Sound Output Hardware"
//        (pp. 44-45): Batman is an enhanced, pin-compatible ASC that REMOVES
//        the wavetable synthesizer modes and adds improved interrupts, one
//        channel of 8-bit sound input, full stereo mixing and panning,
//        sample rate conversion and CD-XA decompression.
//  [ROM] The LC 475 ROM (MD5 76FAB51D93F024D805FAFD8F5C8F46A3, base
//        $40800000).  Addresses below are in that image.
//  [EST] A reasoned estimate where neither says; named as one.
//
//  VERSION ($800) = $B0.  [ROM] $408042E8: for (version & $F0) == $B0 the
//  ROM programs the $F00 block, and the code for decoder kind $0D (the
//  MEMCjr machines, table $408A8680) sits INSIDE that branch ($40804328), so
//  this machine's chip is a $Bx part.  The ROM names three: $B0, $BB, $BC.
//  Only $B0 gets the $F08/$F28 register test ($4084871A) and the idle status
//  $0F ($40849D74).  [EST] $B0 rather than $BB/$BC: those two are tested as
//  parts without the $F08 mode registers, while the kind-$0D code writes the
//  $F20 block directly ($40804344, $50F14F2F).  No Apple document at hand
//  states the value.
//
//  WHAT THE ROM DOES AT STARTUP ($408BD250)
//    version 0      -> $40807052, the Mac II four-voice wavetable chime.
//    version $B0    -> a 'snd ' at $408C2722 (or $408BD4C4 if PRAM $89 bit 1):
//                      22050 Hz, compressionID 6, 15-byte packets, i.e.
//                      CD-XA ADPCM.  The ROM writes the rate to $F04/$F24
//                      (rate * $FFFF / 44100), $82 to $F08/$F28, then feeds
//                      the COMPRESSED bytes to both FIFOs, one byte each time
//                      $804 bit 2 is set, and ends when bit 3 is set.
//    other non-zero -> the same chime as raw 8-bit samples ($408C67BE).
//  So with $B0 the chime needs the decoder in the chip.  The decoder here was
//  checked against that: the decoded $408C2722 matches the raw copy at
//  $408C67BE sample for sample (correlation 0.9998, low nibble first).
//
//  REGISTERS (4 KB window; "ch" = $00 for A, $20 for B)
//    $000-$3FF FIFO A, $400-$7FF FIFO B: 1024 bytes each [HO].
//    $800 version   $B0.
//    $801 mode      bits 1:0 stored [ROM test mask $03]; 1 = FIFO.  No
//                   wavetable mode [HO]; the ROM never selects one on a
//                   non-zero version.
//    $802 control   stored, no function here [EST].
//    $803 bit 7     clears both FIFOs [ROM $40845C90 pulses it].
//    $804 status    LIVE, read-only: bit 0 A half-empty, 1 A empty,
//                   2 B half-empty, 3 B empty.  [ROM] $40849D74 waits for
//                   exactly $0F on an idle chip; the chime waits on bit 2 to
//                   write and on bit 3 to finish.  A read clears the
//                   interrupt [EST, as before].
//    $806 volume    bits 7:5, eight steps [ROM test mask $E0; $408042E4].
//    $807           stored only.
//    $80A           bits 1:0 stored [ROM test mask $01].  Bit 0 is record
//                   enable in the ROM's input test; there is NO sound input
//                   here, so that test ($40849F4E) cannot pass.
//    $F00+ch write pointer, $F02+ch read pointer (words, read-only) [EST;
//                   the ROM only saves and restores them, $408B4D08].
//    $F04+ch sample rate, word: rate * 65536 / 44100 [ROM $408BD342].  The
//                   ROM's idle value is $812F = 22254 Hz ($40804376).  The
//                   FIFO is popped at that rate and held between pops; the
//                   chip's interpolating conversion to 44.1 kHz [HO] is not
//                   modelled [EST].  Reset value $812F [EST].
//    $F06+ch gain of this FIFO into the LEFT output, $F07+ch into the RIGHT;
//                   $7F is full [ROM $408042F8 sets A = $7F,$00 and
//                   B = $00,$7F; $4088C490 is the volume-step table].  Taken
//                   as gain/128 [EST].
//    $F08+ch bits 1:0 = 0 raw 8-bit, 1 or 2 CD-XA (the ROM maps
//                   compressionID 5 -> 1, 6 -> 2, $408BD35A); bit 7 is set
//                   with every start.  Bits 7,1,0 stored [ROM test values
//                   $00-$03,$80-$83].  Modes 1, 2 and 3 decode alike here
//                   [EST]; a write restarts the decoder at a packet boundary
//                   with a cleared history [EST].
//    $F09+ch bit 0 = 1 masks this FIFO's interrupt [ROM $40845C7E, $40849ECC].
//                   Writing it 1 then 0 raises the interrupt again if the
//                   FIFO is below half [ROM $40871B84 does exactly that to
//                   restart it].  Reset 1 [EST].
//    $F10-$F17+ch  CD-XA filter coefficients.  The ROM always loads
//                   $0000,$003C,$CC73,$C962 ($40804382): K0 = 0,60,115,98 in
//                   the low bytes, K1 = 0,0,-52,-55 in the high bytes, the
//                   standard CD-XA set.  They are HARD-WIRED here and read
//                   back as those values; other values are not supported
//                   [EST, to save logic].
//
//  CD-XA [ROM data + the standard format]: 15-byte packets, byte 0 = filter
//  (bits 5:4) and range (bits 3:0), then 14 bytes = 28 four-bit samples, low
//  nibble first.  s = (nibble << 12 >> range) + (K0*s1 + K1*s2) / 64,
//  saturated to 16 bits.  A raw byte is offset binary in the top 8 bits.
//
//  INTERRUPT: an edge when a pop takes a FIFO below half, per FIFO, if not
//  masked; cleared by a read of $804 or by masking.  Only in FIFO mode [EST].
//
//  LOGIC: one 16x10 multiplier (a DSP block) is shared by the decoder, the
//  mixer and the volume, stepped by a small sequencer between samples, and
//  the range shift is done a bit a clock.  The four wavetable voices
//  (192 flip-flops, four 24-bit adders, two multipliers) are gone.
//
//  Beat slave: one aligned longword per sel pulse, big-endian byte lanes
//  (be[3] = byte at a+0).  A longword write to a FIFO carries up to four
//  bytes, drained one per clock in memory order.
//
//  Storage: four easc_bank block RAMs (128 x 32): banks 0,1 = FIFO A,
//  banks 2,3 = FIFO B.  Port A is the CPU's, or the push; port B free-runs at
//  the read pointer.
//============================================================================

module easc
#(
	parameter SYS_CLK_HZ = 25_000_000,
	parameter BASE_HZ    = 44_100
)
(
	input         clk,
	input         nreset,
	input         ce,

	input         sel,
	input         write,
	input  [11:2] a,
	input   [3:0] be,
	input  [31:0] wdata,
	output [31:0] rdata,

	output        irq,                     // FIFO half-empty, active high

	output signed [15:0] sample_l,
	output signed [15:0] sample_r
);

reg  [1:0] mode;
reg  [7:0] control, fifomode, volume, clockreg;
reg  [1:0] recreg;
reg [15:0] rate_a, rate_b;
reg  [7:0] gl_a, gr_a, gl_b, gr_b;
reg  [2:0] xm_a, xm_b;                 // {$F08 bit 7, bits 1:0}
reg        dis_a, dis_b;

wire fifo_mode = (mode == 2'd1);

//----------------------------------------------------------------------------
// FIFO state
//----------------------------------------------------------------------------
reg  [9:0] wrptr_a, rdptr_a, wrptr_b, rdptr_b;
reg [10:0] cap_a, cap_b;               // 0..1024

wire half_a = (cap_a < 11'd512);
wire half_b = (cap_b < 11'd512);
wire [7:0] fifo_stat = {4'b0, (cap_b == 0), half_b, (cap_a == 0), half_a};

//----------------------------------------------------------------------------
// CPU write lane drain (FIFO mode only)
//----------------------------------------------------------------------------
reg [31:0] push_data;
reg  [3:0] push_be;
reg        push_to_b;
wire       push_busy = |push_be;
wire [1:0] push_lane = push_be[3] ? 2'd0 : push_be[2] ? 2'd1 :
                       push_be[1] ? 2'd2 : 2'd3;
wire [7:0] push_byte = (push_lane == 2'd0) ? push_data[31:24] :
                       (push_lane == 2'd1) ? push_data[23:16] :
                       (push_lane == 2'd2) ? push_data[15:8]  : push_data[7:0];
wire       fifo_full = push_to_b ? (cap_b >= 11'd1024) : (cap_a >= 11'd1024);
wire       push_do   = push_busy && !fifo_full;
wire [9:0] push_ptr  = push_to_b ? wrptr_b : wrptr_a;

//----------------------------------------------------------------------------
// sample RAM: bank = byte address [10:9], word = [8:2], lane = [1:0]
//----------------------------------------------------------------------------
wire [31:0] bank_qa [0:3];
wire [31:0] bank_qb [0:3];
wire        cpu_wr = ce && sel && write && !a[11] && !fifo_mode;

wire  [6:0] pa_addr = push_do ? push_ptr[8:2] : a[8:2];
wire  [3:0] pa_be   = push_do ? (4'b1000 >> push_ptr[1:0]) : be;
wire [31:0] pa_data = push_do ? {4{push_byte}} : wdata;
wire  [1:0] pa_bank = push_do ? {push_to_b, push_ptr[9]} : a[10:9];

generate
	genvar gi;
	for (gi = 0; gi < 4; gi = gi + 1) begin : banks
		easc_bank bank
		(
			.clk     (clk),
			.addr_a  (pa_addr),
			.wdata_a (pa_data),
			.be_a    (pa_be),
			.we_a    ((push_do && pa_bank == gi[1:0]) ||
			          (cpu_wr  && a[10:9] == gi[1:0])),
			.q_a     (bank_qa[gi]),
			.addr_b  (gi[1] ? rdptr_b[8:2] : rdptr_a[8:2]),
			.q_b     (bank_qb[gi])
		);
	end
endgenerate

function automatic [7:0] lane_byte(input [31:0] q, input [1:0] lane);
	case (lane)
		2'd0: lane_byte = q[31:24];
		2'd1: lane_byte = q[23:16];
		2'd2: lane_byte = q[15:8];
		default: lane_byte = q[7:0];
	endcase
endfunction

wire [7:0] fifo_a_byte = lane_byte(rdptr_a[9] ? bank_qb[1] : bank_qb[0], rdptr_a[1:0]);
wire [7:0] fifo_b_byte = lane_byte(rdptr_b[9] ? bank_qb[3] : bank_qb[2], rdptr_b[1:0]);

//----------------------------------------------------------------------------
// register read
//----------------------------------------------------------------------------
function automatic [7:0] rd_byte(input [11:0] ba);
	reg b;
	begin
		b = ba[5];
		rd_byte = 8'h00;
		if (ba[10:8] == 3'd0)
			case (ba[7:0])
				8'h00: rd_byte = 8'hB0;
				8'h01: rd_byte = {6'd0, mode};
				8'h02: rd_byte = control;
				8'h03: rd_byte = fifomode;
				8'h04: rd_byte = fifo_stat;
				8'h06: rd_byte = volume;
				8'h07: rd_byte = clockreg;
				8'h0A: rd_byte = {6'd0, recreg};
				default: ;
			endcase
		else if (ba[10:6] == 5'b11100)
			case (ba[4:0])
				5'h00: rd_byte = {6'd0, b ? wrptr_b[9:8] : wrptr_a[9:8]};
				5'h01: rd_byte = b ? wrptr_b[7:0] : wrptr_a[7:0];
				5'h02: rd_byte = {6'd0, b ? rdptr_b[9:8] : rdptr_a[9:8]};
				5'h03: rd_byte = b ? rdptr_b[7:0] : rdptr_a[7:0];
				5'h04: rd_byte = b ? rate_b[15:8] : rate_a[15:8];
				5'h05: rd_byte = b ? rate_b[7:0]  : rate_a[7:0];
				5'h06: rd_byte = b ? gl_b : gl_a;
				5'h07: rd_byte = b ? gr_b : gr_a;
				5'h08: rd_byte = b ? {xm_b[2], 5'd0, xm_b[1:0]} : {xm_a[2], 5'd0, xm_a[1:0]};
				5'h09: rd_byte = {7'd0, b ? dis_b : dis_a};
				5'h13: rd_byte = 8'h3C;
				5'h14: rd_byte = 8'hCC;
				5'h15: rd_byte = 8'h73;
				5'h16: rd_byte = 8'hC9;
				5'h17: rd_byte = 8'h62;
				default: ;
			endcase
	end
endfunction

assign rdata = a[11] ? {rd_byte({a, 2'd0}), rd_byte({a, 2'd1}),
                        rd_byte({a, 2'd2}), rd_byte({a, 2'd3})}
                     : bank_qa[a[10:9]];

wire stat_read = ce && sel && !write && a[11] &&
                 (({a, 2'd0} & 12'h7FC) == 12'h004);

//----------------------------------------------------------------------------
// sample clocks: 44.1 kHz scaled by each FIFO's rate word
//----------------------------------------------------------------------------
wire base_tick;
rate_enable #(.CLK_HZ(SYS_CLK_HZ), .RATE_HZ(BASE_HZ)) sample_rate (
	.clk(clk), .nreset(nreset), .ce(ce), .tick(base_tick)
);
reg  [15:0] nco_a, nco_b;
wire [16:0] nco_a_n = {1'b0, nco_a} + {1'b0, rate_a};
wire [16:0] nco_b_n = {1'b0, nco_b} + {1'b0, rate_b};

//----------------------------------------------------------------------------
// decoder / mixer sequencer around one multiplier
//----------------------------------------------------------------------------
localparam [4:0] S_IDLE = 5'd0,  S_FETCH = 5'd1, S_WAIT = 5'd2,
                 S_D0 = 5'd3, S_D1 = 5'd4, S_D2 = 5'd5, S_D3 = 5'd6, S_D4 = 5'd7,
                 S_M0 = 5'd8, S_M1 = 5'd9, S_M2 = 5'd10, S_M3 = 5'd11, S_M4 = 5'd12,
                 S_M5 = 5'd13, S_M6 = 5'd14, S_M7 = 5'd15, S_M8 = 5'd16;
reg  [4:0] st;
reg        ch;                         // channel in work: 0 = A, 1 = B
reg  [1:0] pend;                       // sample due
reg        need_mix;
reg signed [15:0] s1_a, s2_a, s1_b, s2_b;   // s1 = the FIFO's current sample
reg  [5:0] hdr_a, hdr_b;               // {filter, range}
reg  [3:0] pos_a, pos_b;               // byte within the 15-byte packet
reg  [3:0] hin_a, hin_b;               // high nibble waiting
reg        hav_a, hav_b;
reg        pshd_a, pshd_b;             // pushed last clock: q_b not yet valid

wire [7:0] f_byte = ch ? fifo_b_byte : fifo_a_byte;
wire       f_have = ch ? (cap_b != 0 && !pshd_b) : (cap_a != 0 && !pshd_a);
wire       f_none = ch ? (cap_b == 0) : (cap_a == 0);
wire       x_on   = ch ? |xm_b[1:0] : |xm_a[1:0];
wire [3:0] x_pos  = ch ? pos_b : pos_a;
wire       x_hav  = ch ? hav_b : hav_a;
wire [5:0] x_hdr  = ch ? hdr_b : hdr_a;
wire signed [15:0] x_s1 = ch ? s1_b : s1_a;
wire signed [15:0] x_s2 = ch ? s2_b : s2_a;

reg signed  [9:0] k0, k1;
always @* case (x_hdr[5:4])
	2'd0: begin k0 = 10'sd0;   k1 = 10'sd0;   end
	2'd1: begin k0 = 10'sd60;  k1 = 10'sd0;   end
	2'd2: begin k0 = 10'sd115; k1 = -10'sd52; end
	default: begin k0 = 10'sd98; k1 = -10'sd55; end
endcase

// $806 bits 7-5: eight steps, x*256/7 rounded, exactly unity at 7
reg [9:0] gvol;
always @* case (volume[7:5])
	3'd0: gvol = 10'd0;
	3'd1: gvol = 10'd37;
	3'd2: gvol = 10'd73;
	3'd3: gvol = 10'd110;
	3'd4: gvol = 10'd146;
	3'd5: gvol = 10'd183;
	3'd6: gvol = 10'd219;
	default: gvol = 10'd256;
endcase

reg signed [15:0] xr;
reg signed  [9:0] yr;
reg signed [25:0] prod;
reg signed [26:0] acc;
reg signed [15:0] nibt;                // nibble term, shifted down by the range
reg         [3:0] shc;
reg signed [15:0] out_l, out_r;

function automatic signed [15:0] sat16(input signed [26:0] v);
	if (v > 27'sd32767)       sat16 = 16'sh7FFF;
	else if (v < -27'sd32768) sat16 = 16'sh8000;
	else                      sat16 = v[15:0];
endfunction

wire signed [26:0] acc_d6  = acc >>> 6;
wire signed [26:0] acc_d7  = acc >>> 7;
wire signed [26:0] dec_v   = acc_d6 + {{11{nibt[15]}}, nibt};
wire signed [15:0] mix_sat = sat16(acc_d7);

assign sample_l = out_l;
assign sample_r = out_r;

// pops come from the sequencer, pushes from the lane drain
wire take  = (st == S_FETCH) && fifo_mode && f_have && !(x_on && x_hav);
wire pop_a = take && !ch;
wire pop_b = take &&  ch;
wire psh_a = push_do && !push_to_b;
wire psh_b = push_do &&  push_to_b;

reg  pend_irq_a, pend_irq_b;
assign irq = pend_irq_a | pend_irq_b;

//----------------------------------------------------------------------------
// register write
//----------------------------------------------------------------------------
task automatic wr_byte(input [11:0] ba, input [7:0] d);
	if (ba[10:8] == 3'd0)
		case (ba[7:0])
			8'h01: mode     <= d[1:0];
			8'h02: control  <= d;
			8'h03: fifomode <= d;
			8'h06: volume   <= d;
			8'h07: clockreg <= d;
			8'h0A: recreg   <= d[1:0];
			default: ;
		endcase
	else if (ba[10:6] == 5'b11100) begin
		if (!ba[5])
			case (ba[4:0])
				5'h04: rate_a[15:8] <= d;
				5'h05: rate_a[7:0]  <= d;
				5'h06: gl_a <= d;
				5'h07: gr_a <= d;
				5'h08: xm_a <= {d[7], d[1:0]};
				5'h09: dis_a <= d[0];
				default: ;
			endcase
		else
			case (ba[4:0])
				5'h04: rate_b[15:8] <= d;
				5'h05: rate_b[7:0]  <= d;
				5'h06: gl_b <= d;
				5'h07: gr_b <= d;
				5'h08: xm_b <= {d[7], d[1:0]};
				5'h09: dis_b <= d[0];
				default: ;
			endcase
	end
endtask

wire reg_wr      = ce && sel && write && a[11];
wire r800_wr     = reg_wr && (({a, 2'd0} & 12'h7FC) == 12'h000);
wire mode_change = r800_wr && be[2] && (wdata[17:16] != mode);
wire fifo_clear  = (r800_wr && be[0] && wdata[7]) || mode_change;
// $F08 (lane 0) and $F09 (lane 1) of the longword at $F08 / $F28
wire rf08_wr     = reg_wr && (({a, 2'd0} & 12'h7DC) == 12'h708);
wire xm_wr_a     = rf08_wr && !a[5] && be[3];
wire xm_wr_b     = rf08_wr &&  a[5] && be[3];
wire dis_wr_a    = rf08_wr && !a[5] && be[2];
wire dis_wr_b    = rf08_wr &&  a[5] && be[2];

always @(posedge clk) begin
	if (!nreset) begin
		mode <= 0; control <= 0; fifomode <= 0; volume <= 8'hE0; clockreg <= 0;
		recreg <= 0;
		rate_a <= 16'h812F; rate_b <= 16'h812F;
		gl_a <= 8'h7F; gr_a <= 8'h00; gl_b <= 8'h00; gr_b <= 8'h7F;
		xm_a <= 0; xm_b <= 0; dis_a <= 1'b1; dis_b <= 1'b1;
		nco_a <= 0; nco_b <= 0;
		wrptr_a <= 0; rdptr_a <= 0; cap_a <= 0;
		wrptr_b <= 0; rdptr_b <= 0; cap_b <= 0;
		push_be <= 0; push_data <= 0; push_to_b <= 0;
		pshd_a <= 0; pshd_b <= 0;
		st <= S_IDLE; ch <= 0; pend <= 0; need_mix <= 0;
		s1_a <= 0; s2_a <= 0; s1_b <= 0; s2_b <= 0;
		hdr_a <= 0; hdr_b <= 0; pos_a <= 0; pos_b <= 0;
		hin_a <= 0; hin_b <= 0; hav_a <= 0; hav_b <= 0;
		xr <= 0; yr <= 0; prod <= 0; acc <= 0; nibt <= 0; shc <= 0;
		out_l <= 0; out_r <= 0;
		pend_irq_a <= 0; pend_irq_b <= 0;
	end
	else begin
		prod <= xr * yr;
		if (shc != 0) begin
			nibt <= nibt >>> 1;
			shc  <= shc - 1'b1;
		end

		// ---- sample clocks ---------------------------------------------
		if (base_tick) begin
			nco_a <= nco_a_n[15:0];
			nco_b <= nco_b_n[15:0];
		end

		// ---- sequencer -------------------------------------------------
		case (st)
		S_IDLE:
			if (pend != 0) begin
				ch <= !pend[0];
				st <= S_FETCH;
			end
			else if (need_mix) st <= S_M0;

		// one sample for channel ch.  Mode 0 and an empty FIFO hold the
		// last sample: a hard 0 would click on every sound.
		S_FETCH:
			if (!fifo_mode || (f_none && !(x_on && x_hav))) begin
				pend[ch] <= 1'b0;
				st <= S_IDLE;
			end
			else if (x_on && x_hav) begin              // second half of a byte
				if (ch) hav_b <= 1'b0; else hav_a <= 1'b0;
				nibt <= {(ch ? hin_b : hin_a), 12'd0};
				shc  <= x_hdr[3:0];
				st   <= S_D0;
			end
			else if (f_have) begin
				if (!x_on) begin                       // raw 8-bit
					if (ch) s1_b <= {~f_byte[7], f_byte[6:0], 8'h00};
					else    s1_a <= {~f_byte[7], f_byte[6:0], 8'h00};
					pend[ch] <= 1'b0;
					need_mix <= 1'b1;
					st <= S_IDLE;
				end
				else if (x_pos == 4'd0) begin          // packet header
					if (ch) begin hdr_b <= f_byte[5:0]; pos_b <= 4'd1; end
					else    begin hdr_a <= f_byte[5:0]; pos_a <= 4'd1; end
					st <= S_WAIT;
				end
				else begin                             // low nibble first
					if (ch) begin
						hin_b <= f_byte[7:4]; hav_b <= 1'b1;
						pos_b <= (pos_b == 4'd14) ? 4'd0 : pos_b + 1'b1;
					end
					else begin
						hin_a <= f_byte[7:4]; hav_a <= 1'b1;
						pos_a <= (pos_a == 4'd14) ? 4'd0 : pos_a + 1'b1;
					end
					nibt <= {f_byte[3:0], 12'd0};
					shc  <= x_hdr[3:0];
					st   <= S_D0;
				end
			end
		S_WAIT: st <= S_FETCH;                         // q_b follows the pointer

		// s = nibble term + (K0*s1 + K1*s2) / 64
		S_D0: begin xr <= x_s1; yr <= k0; st <= S_D1; end
		S_D1: begin xr <= x_s2; yr <= k1; st <= S_D2; end
		S_D2: begin acc <= {prod[25], prod}; st <= S_D3; end
		S_D3: begin acc <= acc + {prod[25], prod}; st <= S_D4; end
		S_D4:
			if (shc == 0) begin
				if (ch) begin s2_b <= s1_b; s1_b <= sat16(dec_v); end
				else    begin s2_a <= s1_a; s1_a <= sat16(dec_v); end
				pend[ch] <= 1'b0;
				need_mix <= 1'b1;
				st <= S_IDLE;
			end

		// left = A*gl_a + B*gl_b, right = A*gr_a + B*gr_b, then $806
		S_M0: begin xr <= s1_a; yr <= {2'b0, gl_a}; st <= S_M1; end
		S_M1: begin xr <= s1_b; yr <= {2'b0, gl_b}; st <= S_M2; end
		S_M2: begin acc <= {prod[25], prod}; xr <= s1_a; yr <= {2'b0, gr_a}; st <= S_M3; end
		S_M3: begin acc <= acc + {prod[25], prod}; xr <= s1_b; yr <= {2'b0, gr_b}; st <= S_M4; end
		S_M4: begin xr <= mix_sat; yr <= gvol; acc <= {prod[25], prod}; st <= S_M5; end
		S_M5: begin acc <= acc + {prod[25], prod}; st <= S_M6; end
		S_M6: begin out_l <= prod[23:8]; xr <= mix_sat; yr <= gvol; st <= S_M7; end
		S_M7: st <= S_M8;
		S_M8: begin out_r <= prod[23:8]; need_mix <= 1'b0; st <= S_IDLE; end
		default: st <= S_IDLE;
		endcase

		// a due sample is latched after the sequencer so a tick is never lost
		if (base_tick && fifo_mode) begin
			if (nco_a_n[16]) pend[0] <= 1'b1;
			if (nco_b_n[16]) pend[1] <= 1'b1;
		end

		// ---- FIFO pointers -----------------------------------------------
		pshd_a <= psh_a;
		pshd_b <= psh_b;
		if (fifo_clear) begin
			wrptr_a <= 0; rdptr_a <= 0; cap_a <= 0;
			wrptr_b <= 0; rdptr_b <= 0; cap_b <= 0;
			push_be <= 0;
		end
		else begin
			if (pop_a) rdptr_a <= rdptr_a + 1'b1;
			if (pop_b) rdptr_b <= rdptr_b + 1'b1;
			if (psh_a) wrptr_a <= wrptr_a + 1'b1;
			if (psh_b) wrptr_b <= wrptr_b + 1'b1;

			case ({psh_a, pop_a})
				2'b10: cap_a <= cap_a + 1'b1;
				2'b01: cap_a <= cap_a - 1'b1;
				default: ;
			endcase
			case ({psh_b, pop_b})
				2'b10: cap_b <= cap_b + 1'b1;
				2'b01: cap_b <= cap_b - 1'b1;
				default: ;
			endcase

			// drain one lane per clock; a new write reloads the latch (the
			// CPU cannot return inside four clocks)
			if (ce && sel && write && !a[11] && fifo_mode) begin
				push_data <= wdata;
				push_be   <= be;
				push_to_b <= a[10];
			end
			else if (push_do)
				push_be <= push_be & ~(4'b1000 >> push_lane);
			else if (push_busy && fifo_full)
				push_be <= 4'd0;              // FIFO full: drop the rest
		end

		// ---- register writes ---------------------------------------------
		if (reg_wr) begin
			if (be[3]) wr_byte({a, 2'd0}, wdata[31:24]);
			if (be[2]) wr_byte({a, 2'd1}, wdata[23:16]);
			if (be[1]) wr_byte({a, 2'd2}, wdata[15:8]);
			if (be[0]) wr_byte({a, 2'd3}, wdata[7:0]);
		end

		// a mode write or a FIFO clear restarts the decoder at a packet
		// boundary; the mode write also clears its history
		if (xm_wr_a || fifo_clear) begin pos_a <= 0; hav_a <= 1'b0; end
		if (xm_wr_b || fifo_clear) begin pos_b <= 0; hav_b <= 1'b0; end
		if (xm_wr_a) begin s1_a <= 0; s2_a <= 0; need_mix <= 1'b1; end
		if (xm_wr_b) begin s1_b <= 0; s2_b <= 0; need_mix <= 1'b1; end

		// ---- interrupt ---------------------------------------------------
		// EDGE, not level: an idle chip left in FIFO mode is permanently
		// below half and must not become an interrupt source the guest
		// cannot switch off.
		if (stat_read || (dis_wr_a && wdata[16]))
			pend_irq_a <= 1'b0;
		else if (fifo_mode && ((pop_a && cap_a == 11'd512 && !dis_a) ||
		                       (dis_wr_a && !wdata[16] && dis_a && half_a)))
			pend_irq_a <= 1'b1;
		if (stat_read || (dis_wr_b && wdata[16]))
			pend_irq_b <= 1'b0;
		else if (fifo_mode && ((pop_b && cap_b == 11'd512 && !dis_b) ||
		                       (dis_wr_b && !wdata[16] && dis_b && half_b)))
			pend_irq_b <= 1'b1;
	end
end

endmodule

//============================================================================
//  easc_bank — one 512-byte quarter of the sample window as 128 x 32 block
//  RAM.  Port A: CPU or FIFO-push read/write with byte enables.  Port B:
//  the FIFO's read.  Both reads are registered (M10K
//  semantics).  Mixed-port read-during-write is DONT_CARE on hardware and
//  old-data in the sim branch — only reachable by a write racing a read of
//  the same longword.
//============================================================================
module easc_bank
(
	input         clk,
	input   [6:0] addr_a,
	input  [31:0] wdata_a,
	input   [3:0] be_a,
	input         we_a,
	output [31:0] q_a,
	input   [6:0] addr_b,
	output [31:0] q_b
);

`ifdef SIMULATION

	reg [31:0] mem [0:127];
	reg [31:0] q_a_r, q_b_r;
	always @(posedge clk) begin
		if (we_a) begin
			if (be_a[3]) mem[addr_a][31:24] <= wdata_a[31:24];
			if (be_a[2]) mem[addr_a][23:16] <= wdata_a[23:16];
			if (be_a[1]) mem[addr_a][15:8]  <= wdata_a[15:8];
			if (be_a[0]) mem[addr_a][7:0]   <= wdata_a[7:0];
		end
		q_a_r <= mem[addr_a];
		q_b_r <= mem[addr_b];
	end
	assign q_a = q_a_r;
	assign q_b = q_b_r;

`else

	altsyncram ram
	(
		.clock0    (clk),
		.address_a (addr_a),
		.data_a    (wdata_a),
		.wren_a    (we_a),
		.byteena_a (be_a),
		.q_a       (q_a),

		.address_b (addr_b),
		.data_b    (32'd0),
		.wren_b    (1'b0),
		.q_b       (q_b),

		.aclr0(1'b0),
		.aclr1(1'b0),
		.addressstall_a(1'b0),
		.addressstall_b(1'b0),
		.byteena_b(1'b1),
		.clock1(1'b1),
		.clocken0(1'b1),
		.clocken1(1'b1),
		.clocken2(1'b1),
		.clocken3(1'b1),
		.eccstatus(),
		.rden_a(1'b1),
		.rden_b(1'b1)
	);
	defparam
		ram.numwords_a = 128,
		ram.widthad_a  = 7,
		ram.width_a    = 32,
		ram.width_byteena_a = 4,
		ram.numwords_b = 128,
		ram.widthad_b  = 7,
		ram.width_b    = 32,
		ram.width_byteena_b = 1,
		ram.address_reg_b = "CLOCK0",
		ram.clock_enable_input_a = "BYPASS",
		ram.clock_enable_input_b = "BYPASS",
		ram.clock_enable_output_a = "BYPASS",
		ram.clock_enable_output_b = "BYPASS",
		ram.indata_reg_b = "CLOCK0",
		ram.intended_device_family = "Cyclone V",
		ram.lpm_type = "altsyncram",
		ram.operation_mode = "BIDIR_DUAL_PORT",
		ram.outdata_aclr_a = "NONE",
		ram.outdata_aclr_b = "NONE",
		ram.outdata_reg_a = "UNREGISTERED",
		ram.outdata_reg_b = "UNREGISTERED",
		ram.power_up_uninitialized = "FALSE",
		ram.ram_block_type = "M10K",
		ram.read_during_write_mode_mixed_ports = "DONT_CARE",
		ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
		ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
		ram.wrcontrol_wraddress_reg_b = "CLOCK0";

`endif

endmodule
