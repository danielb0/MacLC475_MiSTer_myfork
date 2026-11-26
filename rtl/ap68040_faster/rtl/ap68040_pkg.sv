//--------------------------------------------------------------------------//
// AP68040 - pipelined MC68040                                            //
//                                                                          //
// ap68040_pkg.sv - shared types and encodings                               //
//--------------------------------------------------------------------------//

package ap68040_pkg;

//--------------------------------------------------------------------------
// Register numbers (5 bits).  A7 never appears here: the decoder maps it
// to USP, ISP or MSP from the S and M bits current at decode time.
//--------------------------------------------------------------------------
localparam logic [4:0] R_D0  = 5'd0;
localparam logic [4:0] R_A0  = 5'd8;
localparam logic [4:0] R_USP = 5'd15;
localparam logic [4:0] R_ISP = 5'd16;
localparam logic [4:0] R_MSP = 5'd17;
localparam logic [4:0] R_T0  = 5'd18;   // T0..T13 = 18..31, microcode temps

//--------------------------------------------------------------------------
// Bus encodings (MC68040UM tables 5-2, 5-3, 7-1)
//--------------------------------------------------------------------------
localparam logic [1:0] SIZ_L    = 2'b00;
localparam logic [1:0] SIZ_B    = 2'b01;
localparam logic [1:0] SIZ_W    = 2'b10;
localparam logic [1:0] SIZ_LINE = 2'b11;

localparam logic [1:0] TT_NORMAL = 2'd0;
localparam logic [1:0] TT_MOVE16 = 2'd1;
localparam logic [1:0] TT_ALT    = 2'd2;
localparam logic [1:0] TT_ACK    = 2'd3;

localparam logic [2:0] TM_PUSH     = 3'd0;
localparam logic [2:0] TM_UDATA    = 3'd1;
localparam logic [2:0] TM_UCODE    = 3'd2;
localparam logic [2:0] TM_TBL_DATA = 3'd3;
localparam logic [2:0] TM_TBL_CODE = 3'd4;
localparam logic [2:0] TM_SDATA    = 3'd5;
localparam logic [2:0] TM_SCODE    = 3'd6;

// One internal bus transaction, as a requester hands it to the BIU.  The
// BIU only runs naturally aligned transfers; requesters split misaligned
// operands (MC68040UM 7.3).  For a line, addr[3:2] names the first long
// word and the slave wraps.
typedef struct packed {
	logic [31:0] addr;
	logic  [1:0] siz;     // SIZ_*
	logic        rd;      // 1 read, 0 write
	logic  [1:0] tt;
	logic  [2:0] tm;
	logic  [1:0] tln;
	logic  [1:0] upa;
	logic        ci;      // CIOUT
	logic        lock;    // LOCK for this transfer
	logic        locke;   // LOCKE: last transfer of the locked sequence
} busreq_t;

//--------------------------------------------------------------------------
// ATC entry (MC68040UM figure 3-21); pa is PA31-12 (PA12 comes from LA12
// with 8 Kbyte pages)
//--------------------------------------------------------------------------
typedef struct packed {
	logic [19:0] pa;
	logic        g;       // global
	logic  [1:0] upa;     // U1 U0
	logic        s;       // supervisor only
	logic  [1:0] cm;      // cache mode
	logic        m;       // modified
	logic        w;       // write protected (accumulated)
	logic        r;       // resident (table search succeeded)
	logic        b;       // the table search took a bus error
} atce_t;

//--------------------------------------------------------------------------
// Operation sizes
//--------------------------------------------------------------------------
localparam logic [1:0] SZ_B = 2'd0;
localparam logic [1:0] SZ_W = 2'd1;
localparam logic [1:0] SZ_L = 2'd2;
localparam logic [1:0] SZ_Q = 2'd3;   // line / double, context dependent

//--------------------------------------------------------------------------
// Micro-operations
//--------------------------------------------------------------------------
// operand sources
localparam logic [1:0] OS_REG  = 2'd0;
localparam logic [1:0] OS_IMM  = 2'd1;
localparam logic [1:0] OS_MEM  = 2'd2;   // the uop's load data
localparam logic [1:0] OS_ZERO = 2'd3;

// memory access of a uop
localparam logic [1:0] M_NONE = 2'd0;
localparam logic [1:0] M_LD   = 2'd1;
localparam logic [1:0] M_ST   = 2'd2;
localparam logic [1:0] M_RMW  = 2'd3;    // load, then store to the same place

// function code of a data access
localparam logic [2:0] MFC_NORM = 3'd0;  // user/supervisor data by S
localparam logic [2:0] MFC_SFC  = 3'd1;  // MOVES read
localparam logic [2:0] MFC_DFC  = 3'd2;  // MOVES write
localparam logic [2:0] MFC_SUP  = 3'd3;  // supervisor data (exception stacking)
localparam logic [2:0] MFC_IACK = 3'd4;  // interrupt acknowledge (TT=3)
localparam logic [2:0] MFC_EAP  = 3'd5;  // microcode: the EA's space (D2 maps it)
localparam logic [2:0] MFC_BKPT = 3'd6;  // breakpoint acknowledge read (TT=3, TM=0, A=0)

// control flow
// internal exception codes of instruction fetch faults (uop.exc); real
// vectors otherwise.  The back end turns them into vector 2.
// both caches: four ways of 2**CSB sets of 16-byte lines (CSB 6: 4 Kbytes,
// the MC68040's; 7: 8 Kbytes), set PA[CSH:4], physically tagged PA[31:CSH+1]
// (CSB <= 8: the set stays within the 4K page offset, LA = PA there)
localparam int CSB = 7;
localparam int CSH = CSB + 3;
localparam int CTW = 28 - CSB;

// fetch BTB: 2**BTB_AW entries indexed by PC[BTB_AW+1:2], tagged PC[31:BTB_AW+2]
localparam int BTB_AW = 8;
localparam int BTB_TW = 30 - BTB_AW;

localparam logic [7:0] EXC_IFS  = 8'd1;    // speculative fetch, bus error
localparam logic [7:0] EXC_IFB  = 8'd2;    // demand fetch, bus error
localparam logic [7:0] EXC_IFSA = 8'hFD;   // speculative fetch, ATC fault
localparam logic [7:0] EXC_IFA  = 8'hFE;   // demand fetch, ATC fault
localparam logic [7:0] EXC_SNR  = 8'hFC;   // refetch: a snoop dropped code the
                                            // front end may have run ahead into

localparam logic [2:0] BR_NONE = 3'd0;
localparam logic [2:0] BR_COND = 3'd1;   // decision from the EX op (Bcc, DBcc, FBcc)
localparam logic [2:0] BR_IMM  = 3'd2;   // always, to uop.target
localparam logic [2:0] BR_EA   = 3'd3;   // always, to the effective address
localparam logic [2:0] BR_A    = 3'd4;   // always, to operand A (RTS: load data)
localparam logic [2:0] BR_B    = 3'd5;   // always, to operand B (JSR)

// EX operations
localparam logic [6:0]
	OP_MOV   = 7'd0,   // res = A                     N Z, V=C=0
	OP_ADD   = 7'd1,   // res = B + A
	OP_ADDX  = 7'd2,
	OP_SUB   = 7'd3,   // res = B - A
	OP_SUBX  = 7'd4,
	OP_CMP   = 7'd5,   // flags of B - A, no result
	OP_AND   = 7'd6,
	OP_OR    = 7'd7,
	OP_EOR   = 7'd8,
	OP_NOT   = 7'd9,   // res = ~B
	OP_NEG   = 7'd10,  // res = 0 - B
	OP_NEGX  = 7'd11,
	OP_CLR   = 7'd12,
	OP_EXT   = 7'd13,  // sz W: byte->word, sz L: word->long
	OP_EXTB  = 7'd14,  // byte->long
	OP_SWAP  = 7'd15,
	OP_TAS   = 7'd16,
	OP_ABCD  = 7'd17,
	OP_SBCD  = 7'd18,
	OP_NBCD  = 7'd19,
	OP_PACK  = 7'd20,  // A = adjustment, B = unpacked word
	OP_UNPK  = 7'd21,  // A = adjustment, B = packed byte
	OP_ASL   = 7'd22,  // B shifted by A[5:0]
	OP_ASR   = 7'd23,
	OP_LSL   = 7'd24,
	OP_LSR   = 7'd25,
	OP_ROL   = 7'd26,
	OP_ROR   = 7'd27,
	OP_ROXL  = 7'd28,
	OP_ROXR  = 7'd29,
	OP_BTST  = 7'd30,  // bit A of B
	OP_BCHG  = 7'd31,
	OP_BCLR  = 7'd32,
	OP_BSET  = 7'd33,
	OP_SCC   = 7'd34,  // res = cond ? $FF : 0
	OP_EA    = 7'd35,  // res = effective address
	OP_BCC   = 7'd36,  // branch decision from cond
	OP_DBCC  = 7'd37,  // res = B.w - 1; taken = !cond && res.w != -1
	OP_TRAPCC= 7'd38,  // exception 7 if cond
	OP_CHK   = 7'd39,  // B against 0..A, exception 6
	OP_CHK2A = 7'd40,  // CHK2/CMP2 step 1: compare B with lower bound A
	OP_CHK2B = 7'd41,  // step 2: compare with upper bound A; cond[0] = trap
	OP_CCRLOG= 7'd42,  // CCR = CCR (cond: 0 AND 1 OR 2 EOR 3 MOVE) A
	OP_SRLOG = 7'd43,  // res = SR (cond as above) A, written to SR at WB
	OP_SPR   = 7'd44,  // res = special register imm[7:0]
	OP_SPW   = 7'd45,  // special register imm[7:0] = A at WB
	OP_LATCH = 7'd46,  // EX latch = A (third operand for CAS and bit fields)
	OP_CAS   = 7'd47,  // compare B with latch; store A if equal
	OP_MUL   = 7'd48,  // cond[0] signed, cond[1] 64-bit
	OP_DIV   = 7'd49,  // cond[0] signed, cond[1] 64-bit dividend, sz W/L
	OP_MDHI  = 7'd50,  // multiply/divide high input = A
	OP_MDRES = 7'd51,  // res = remainder / product high
	OP_BF    = 7'd52,  // bit field, cond = BF op
	OP_BFSET = 7'd53,  // bit field offset/width setup
	OP_MISC  = 7'd54,  // WB-side operation in cond (RESET, STOP, NOP, CINV...)
	OP_FPU   = 7'd55,  // floating point, see the FPU interface
	OP_CHKSR = 7'd56,  // privilege/format checks for RTE etc (cond)
	OP_CAS2C = 7'd57,  // CAS2 compare: cond 0 first pair, 1 second (if equal so far)
	OP_CAS2W = 7'd58,  // CAS2 store: cond 0 A only if equal, 1 equal ? A : B
	OP_CAS2R = 7'd59,  // CAS2 register: B merged with A unless equal
	OP_RTEF  = 7'd60,  // RTE: frame length of format word A (exception 14)
	OP_RTE   = 7'd61,  // RTE: SR = A, jump to B (throwaway frame: this RTE)
	OP_IACKV = 7'd62;  // interrupt vector from the IACK data

// The clocks an instruction takes in the MC68040's execute stage, from its
// operation word and first extension word: MC68040UM section 10 (10.4 MOVE
// Instruction Timing, 10.5 Miscellaneous Integer Unit Instruction Timings,
// 10.6 Integer Unit Instruction Timings), the Execute column with its
// interlocked clocks added (nL + m = n + m), cache hits and aligned
// operands.  0: not listed here -- the instruction is not paced.
//  * Bcc and DBcc: the longer case (branch not taken; DBcc with the
//    condition true or the count expired).  The back end takes a clock off
//    a taken Bcc and a DBcc that loops (2 and 3 clocks).
//  * Where the tables give two figures for an immediate and a register
//    count or bit number, each form has its own.
//  * (d8,An,Xn) and (d8,PC,Xn) are taken at the brief extension word's
//    figure whatever the format: the base-displacement and memory-indirect
//    forms take longer, and the figure is a floor.
//  * Not listed: the instructions that synchronize the processor or run
//    locked (MOVE to SR, ORI/ANDI/EORI to SR, MOVEC, MOVES, MOVEP, CAS,
//    CAS2, CHK2, CMP2, TAS on memory, PACK, UNPK, RTE, STOP, RESET, the
//    cache and MMU instructions), the traps, and the floating point.
// um_ea: the addressing mode as the tables' rows --
//   0 Dn  1 An  2 (An)  3 (An)+  4 -(An)  5 (d16,An)  6 (d8,An,Xn)
//   7 (xxx).W/.L  8 (d16,PC)  9 (d8,PC,Xn)  10 #<xxx>
function automatic logic [3:0] um_ea(input logic [2:0] m, input logic [2:0] r);
	um_ea = (m != 3'd7) ? {1'b0, m} :
	        (r == 3'd0 || r == 3'd1) ? 4'd7 :
	        (r == 3'd2) ? 4'd8 : (r == 3'd3) ? 4'd9 : 4'd10;
endfunction
// ADD, AND, EOR, OR, SUB, TST, CMP, CLR, NEG, NEGX, NOT (10-13, 10-18, 10-26)
function automatic logic [5:0] um_alu(input logic [3:0] e);
	um_alu = (e == 4'd6 || e == 4'd8) ? 6'd3 : (e == 4'd9) ? 6'd5 : 6'd1;
endfunction
// MOVE (10-9, 10-10): source row, destination column
function automatic logic [5:0] um_move(input logic [3:0] s, input logic [3:0] d);
	logic [5:0] t;
	t = 6'd1;
	case (d)
	4'd0:       t = (s == 4'd8 || s == 4'd6) ? 6'd3 : (s == 4'd9) ? 6'd5 : 6'd1;       // Dn
	4'd2:       t = (s == 4'd3 || s == 4'd4 || s == 4'd5) ? 6'd2 : (s == 4'd8) ? 6'd3 : // (An)
	                (s == 4'd6) ? 6'd4 : (s == 4'd9) ? 6'd5 : 6'd1;
	4'd3, 4'd4: t = (s <= 4'd1) ? 6'd1 : (s == 4'd8) ? 6'd3 : (s == 4'd6) ? 6'd5 :      // (An)+, -(An)
	                (s == 4'd9) ? 6'd6 : 6'd2;
	4'd5:       t = (s <= 4'd1) ? 6'd1 : (s == 4'd8) ? 6'd4 : (s == 4'd6) ? 6'd5 :      // (d16,An)
	                (s == 4'd9) ? 6'd6 : 6'd2;
	4'd7:       t = (s <= 4'd2) ? 6'd1 : (s == 4'd8) ? 6'd4 : (s == 4'd6) ? 6'd5 :      // (xxx)
	                (s == 4'd9) ? 6'd6 : 6'd2;
	4'd6:       t = (s <= 4'd1 || s == 4'd10) ? 6'd3 : (s == 4'd8 || s == 4'd6) ? 6'd8 : // (d8,An,Xn)
	                (s == 4'd9) ? 6'd9 : 6'd4;
	default:    t = 6'd1;
	endcase
	um_move = t;
endfunction
// the bits set in a byte (MOVEM's register counts)
function automatic logic [3:0] um_ones(input logic [7:0] b);
	um_ones = 4'(b[0]) + 4'(b[1]) + 4'(b[2]) + 4'(b[3]) + 4'(b[4]) + 4'(b[5]) + 4'(b[6]) + 4'(b[7]);
endfunction
function automatic logic [5:0] um_clocks(input logic [15:0] w, input logic [15:0] x);
	logic [2:0] m, r;
	logic [3:0] e;
	logic       idx, pcd, pci, mem;
	logic [5:0] t;
	m   = w[5:3]; r = w[2:0];
	e   = um_ea(m, r);
	idx = (e == 4'd6);
	pcd = (e == 4'd8);
	pci = (e == 4'd9);
	mem = (e >= 4'd2);
	t   = 6'd0;
	case (w[15:12])
	4'h0: begin
		if (w[8] && m != 3'd1) begin
			// bit number in a register: BTST 2, BCHG/BCLR/BSET 4 (10-15, 10-17)
			if (w[7:6] == 2'b00) t = (e == 4'd5 || e == 4'd7) ? 6'd3 : idx ? 6'd4 : pcd ? 6'd4 : pci ? 6'd6 : 6'd2;
			else                 t = (e == 4'd5 || e == 4'd7) ? 6'd5 : idx ? 6'd6 : 6'd4;
		end
		else if (w[11:8] == 4'h8) begin
			// immediate bit number: BTST 1, BCHG/BCLR/BSET 3
			if (w[7:6] == 2'b00) t = (e == 4'd5 || e == 4'd7) ? 6'd2 : idx ? 6'd3 : pcd ? 6'd3 : pci ? 6'd5 : 6'd1;
			else                 t = (e == 4'd5 || e == 4'd7) ? 6'd4 : idx ? 6'd5 : 6'd3;
		end
		else if (!w[8] && w[7:6] != 2'b11 && (w[11:9] == 3'b000 || w[11:9] == 3'b001 ||
		         w[11:9] == 3'b010 || w[11:9] == 3'b011 || w[11:9] == 3'b101)) begin
			// ORI, ANDI, SUBI, ADDI, EORI (10-13); to CCR 4 (10-11); to SR not listed
			if (e == 4'd10) t = (w[7:6] == 2'b00) ? 6'd4 : 6'd0;
			else            t = (e == 4'd0 || e == 4'd2) ? 6'd1 : idx ? 6'd3 : 6'd2;
		end
		else if (w[11:8] == 4'hC && w[7:6] != 2'b11)
			// CMPI (10-19)
			t = (e == 4'd0 || e == 4'd2) ? 6'd1 : (idx || pcd) ? 6'd3 : pci ? 6'd6 : 6'd2;
	end
	4'h1, 4'h2, 4'h3: begin
		logic [3:0] d;
		d = um_ea(w[8:6], w[11:9]);
		if (w[8:6] == 3'd1)
			// MOVEA.L (10-23): 1; MOVEA.W a clock more except from Dn, An, #<xxx>
			t = (pcd ? 6'd3 : idx ? 6'd4 : pci ? 6'd5 : 6'd1) +
			    ((w[13:12] == 2'b11 && e >= 4'd2 && e != 4'd10) ? 6'd1 : 6'd0);
		else
			t = um_move(e, d);
	end
	4'h4: begin
		if (w == 16'h4E71)                          t = 6'd8;    // NOP            1L + 7
		else if (w == 16'h4E75)                     t = 6'd5;    // RTS            5
		else if (w == 16'h4E74)                     t = 6'd6;    // RTD            1L + 5
		else if (w == 16'h4E77)                     t = 6'd7;    // RTR            1L + 6
		else if (w == 16'h4E76)                     t = 6'd5;    // TRAPV not taken 5
		else if (w[15:3] == 13'b0100_1110_0101_0)   t = 6'd3;    // LINK.W         2L + 1
		else if (w[15:3] == 13'b0100_1000_0000_1)   t = 6'd3;    // LINK.L
		else if (w[15:3] == 13'b0100_1110_0101_1)   t = 6'd2;    // UNLK           1L + 1
		else if (w[15:3] == 13'b0100_1000_0100_0)   t = 6'd2;    // SWAP           2
		else if (w[15:3] == 13'b0100_1000_1000_0)   t = 6'd2;    // EXT.W          2
		else if (w[15:3] == 13'b0100_1000_1100_0)   t = 6'd1;    // EXT.L          1
		else if (w[15:3] == 13'b0100_1001_1100_0)   t = 6'd1;    // EXTB           1
		else if (w[15:7] == 9'b0100_1110_1) begin               // JSR, JMP (10-20, 10-21: the same)
			t = (e == 4'd2) ? 6'd3 :                             //   (An)        2L + 1
			    (e == 4'd5) ? 6'd4 :                             //   (d16,An)    3L + 1
			    idx         ? 6'd6 :                             //   (d8,An,Xn)  6
			    pcd         ? 6'd6 :                             //   (d16,PC)    5L + 1
			    pci         ? 6'd7 : 6'd3;                       //   (d8,PC,Xn)  1L + 6; (xxx) 2L + 1
		end
		else if (w[8:6] == 3'b111) begin                        // LEA (10-21)
			t = (e == 4'd5) ? 6'd2 : idx ? 6'd4 : pcd ? 6'd4 : pci ? 6'd5 : 6'd1;
		end
		else if (w[8:6] == 3'b110 || w[8:6] == 3'b100)          // CHK (10-17), in bounds
			t = (e == 4'd0 || e == 4'd10) ? 6'd8 : idx ? 6'd10 : pcd ? 6'd10 : pci ? 6'd11 : 6'd9;
		else if (w[11:6] == 6'b0000_11)                         // MOVE from SR (10-22)
			t = idx ? 6'd5 : 6'd3;
		else if (w[11:6] == 6'b0010_11 || w[11:6] == 6'b0100_11) // MOVE from CCR (10-21), to CCR (10-22)
			t = (idx || pcd) ? 6'd4 : pci ? 6'd5 : 6'd2;
		else if ((w[11:8] == 4'h0 || w[11:8] == 4'h2 || w[11:8] == 4'h4 || w[11:8] == 4'h6 ||
		          w[11:8] == 4'hA) && w[7:6] != 2'b11)          // NEGX, CLR, NEG, NOT, TST
			t = um_alu(e);
		else if (w[11:6] == 6'b1010_11)                         // TAS (10-28): Dn 2; memory runs locked
			t = (e == 4'd0) ? 6'd2 : 6'd0;
		else if (w[11:6] == 6'b1000_00)                         // NBCD (10-25)
			t = (e == 4'd0) ? 6'd3 : idx ? 6'd4 : 6'd2;
		else if (w[11:6] == 6'b1000_01)                         // PEA (10-26)
			t = (idx || pcd) ? 6'd4 : pci ? 6'd6 : 6'd2;
		else if (w[11:7] == 5'b1000_1) begin                    // MOVEM <list>,<ea> (10-23): 1L + 1 + D' + A'
			logic [3:0] nd, na;
			// -(An): the mask is reversed, D0 in bit 15
			nd = (e == 4'd4) ? um_ones(x[15:8]) : um_ones(x[7:0]);
			na = (e == 4'd4) ? um_ones(x[7:0])  : um_ones(x[15:8]);
			if (nd == 4'd0) nd = 4'd1;
			t = (idx ? 6'd9 : 6'd2) + {2'd0, nd} + {2'd0, na};
		end
		else if (w[11:7] == 5'b1100_1) begin                    // MOVEM <ea>,<list>: 1L + 2 + D' + A'
			logic [3:0] nd, na;                                  //   (.W: N more for N address registers)
			nd = um_ones(x[7:0]); na = um_ones(x[15:8]);
			if (nd == 4'd0) nd = 4'd1;
			t = (idx ? 6'd10 : pcd ? 6'd4 : pci ? 6'd11 : 6'd3) + {2'd0, nd} + {2'd0, na} +
			    (w[6] ? 6'd0 : {2'd0, na});
		end
		else if (w[11:6] == 6'b1100_00)                         // MULU.L, MULS.L 20 (10-25)
			t = 6'd20 + (idx ? 6'd2 : pci ? 6'd4 : 6'd0);
		else if (w[11:6] == 6'b1100_01)                         // DIVU.L, DIVS.L, DIVUL, DIVSL 44 (10-20)
			t = 6'd44 + (idx ? 6'd3 : pci ? 6'd4 : 6'd0);
	end
	4'h5: begin
		if (w[7:6] != 2'b11)                                    // ADDQ, SUBQ (10-14)
			t = (e == 4'd3 || e == 4'd4 || e == 4'd5) ? 6'd2 : idx ? 6'd3 : 6'd1;
		else if (m == 3'd1)                     t = 6'd4;        // DBcc           3 looping, 4 else
		else if (e <= 4'd7)                                     // Scc (10-27)
			t = idx ? 6'd5 : 6'd2;
	end
	4'h6: t = (w[11:8] == 4'h0 || w[11:8] == 4'h1) ? 6'd2 : 6'd3;   // BRA 2, BSR 1L + 1, Bcc 2 taken / 3 not
	4'h7: t = 6'd1;                                              // MOVEQ
	4'h8: begin
		if (w[7:6] == 2'b11)                                    // DIVU.W, DIVS.W 27 (10-20)
			t = 6'd27 + (idx ? 6'd3 : pci ? 6'd4 : 6'd0);
		else if (w[8:4] == 5'b1_0000)           t = m[0] ? 6'd4 : 6'd3;   // SBCD
		else if (w[8] && w[5:4] == 2'b00)       t = 6'd0;        // PACK, UNPK: not listed
		else                                    t = um_alu(e);   // OR
	end
	4'h9, 4'hD: begin
		if (w[7:6] == 2'b11) begin
			if (w[15:12] == 4'hD)                               // ADDA (10-13)
				t = (e == 4'd1 || e == 4'd10) ? 6'd1 : (e == 4'd3 || e == 4'd4 || e == 4'd5) ? 6'd3 :
				    pcd ? 6'd4 : idx ? 6'd5 : pci ? 6'd6 : 6'd2;
			else                                                // SUBA (10-27)
				t = (e == 4'd0) ? 6'd1 : (e == 4'd3 || e == 4'd4 || e == 4'd5) ? 6'd3 :
				    pcd ? 6'd4 : idx ? 6'd5 : pci ? 6'd6 : 6'd2;
		end
		else if (w[8] && w[5:4] == 2'b00)       t = m[0] ? 6'd3 : 6'd1;   // ADDX, SUBX
		else                                    t = um_alu(e);   // ADD, SUB
	end
	4'hB: begin
		if (w[7:6] == 2'b11)                                    // CMPA (10-19)
			t = (e == 4'd3 || e == 4'd4 || e == 4'd5) ? 6'd2 : (idx || pcd) ? 6'd3 : pci ? 6'd5 : 6'd1;
		else if (w[8] && m == 3'd1)             t = 6'd3;        // CMPM           1L + 2
		else                                    t = um_alu(e);   // CMP, EOR
	end
	4'hC: begin
		if (w[7:6] == 2'b11)                                    // MULU.W 14, MULS.W 16 (10-25)
			t = (w[8] ? 6'd16 : 6'd14) + (idx ? 6'd2 : pci ? 6'd4 : 6'd0);
		else if (w[8:4] == 5'b1_0000)           t = m[0] ? 6'd4 : 6'd3;   // ABCD
		else if (w[8:3] == 6'b1_0100_0)         t = 6'd1;        // EXG Dx,Dy
		else if (w[8:3] == 6'b1_0100_1)         t = 6'd2;        // EXG Ax,Ay      1L + 1
		else if (w[8:3] == 6'b1_1000_1)         t = 6'd1;        // EXG Dx,Ay
		else                                    t = um_alu(e);   // AND
	end
	4'hE: begin
		if (w[7:6] != 2'b11) begin
			// shifts and rotates of a data register (10-14, 10-26, 10-27),
			// immediate / register count: ASL 3/4; ASR, LSL, LSR 2/3;
			// ROL, ROR 3/4; ROXL, ROXR 5/6
			case (w[4:3])
			2'b00:   t = w[8] ? (w[5] ? 6'd4 : 6'd3) : (w[5] ? 6'd3 : 6'd2);
			2'b01:   t = w[5] ? 6'd3 : 6'd2;
			2'b10:   t = w[5] ? 6'd6 : 6'd5;
			default: t = w[5] ? 6'd4 : 6'd3;
			endcase
		end
		else if (!w[11]) begin
			// ... of memory: ASL 3; ASR, LSL, LSR 2; ROXL, ROXR 2; ROL, ROR 3
			case (w[10:9])
			2'b00:   t = w[8] ? 6'd3 : 6'd2;
			2'b01:   t = 6'd2;
			2'b10:   t = 6'd2;
			default: t = 6'd3;
			endcase
			if (idx) t = t + 6'd2;
		end
		else begin
			// bit fields (10-15, 10-16), immediate offset and width: Dn /
			// memory.  BFTST 3/9, BFEXTU and BFEXTS 4/9, BFCHG, BFCLR and
			// BFSET 6/10, BFFFO 6/11, BFINS 5/9
			case (w[10:8])
			3'd0:             t = mem ? 6'd9  : 6'd3;
			3'd1, 3'd3:       t = mem ? 6'd9  : 6'd4;
			3'd2, 3'd4, 3'd6: t = mem ? 6'd10 : 6'd6;
			3'd5:             t = mem ? 6'd11 : 6'd6;
			default:          t = mem ? 6'd9  : 6'd5;
			endcase
		end
	end
	default: t = 6'd0;
	endcase
	um_clocks = t;
endfunction

// D1's return stack pointer as an instruction found it, and what the
// instruction did to it: a WB redirect puts it back (after the
// instruction, or before it for a refetch), so wrong-path calls and
// returns that D1 decoded leave no trace
typedef struct packed {
	logic        v;
	logic  [1:0] k;         // 1 pushed (BSR/JSR), 2 popped (RTS)
	logic  [2:0] tp;
	logic  [3:0] n;
} ras_snap_t;

typedef struct packed {
	logic [31:0] pc;        // address of the 68040 instruction
	logic  [3:0] ilen;     // the instruction's length in words (npc = pc + 2 ilen)
	ras_snap_t   ras;       // see ras_snap_t
	logic        first;     // first uop of the instruction
	logic        last;      // last uop: the instruction completes with it
	logic  [5:0] tmin;      // the instruction's documented clocks (um_clocks; 0: none)
	// execution
	logic  [6:0] op;
	logic  [1:0] sz;
	logic  [3:0] cond;
	logic  [4:0] ccr_we;    // X N Z V C
	// operands
	logic  [1:0] a_src;
	logic  [4:0] a_reg;
	logic        a_sxw;     // sign-extend operand A from a word
	logic  [1:0] b_src;
	logic  [4:0] b_reg;
	logic [31:0] imm;       // operand A immediate (or a constant)
	logic [16:0] imm_b;     // operand B immediate: a 16-bit word with its sign
	                        // (the B symbols are 16-bit constants and words,
	                        // sign- or zero-extended: bit 16 extends it)
	// address generation: EA = base + idx*scale + disp
	logic        ag;        // compute an effective address
	logic        base_v;
	logic  [4:0] base;
	logic        idx_v;
	logic  [4:0] idx;
	logic        idx_l;
	logic  [1:0] scale;
	logic [31:0] disp;
	logic        dmv;       // AG adds dma to disp as the uop enters it (a
	logic  [7:0] dma;       // deferred update merged by the sequencer; signed)
	logic        pinc;      // postincrement: EA = base, update = base + amt
	logic        upd_v;     // AG write: upd_reg = pinc ? base + amt : EA
	logic  [4:0] upd_reg;
	logic  [7:0] upd_amt;   // signed: postincrement amount (and a deferred offset)
	logic        upd2_v;    // AG write: upd2_reg += upd2_amt
	logic  [4:0] upd2_reg;
	logic  [7:0] upd2_amt;  // signed
	// memory
	logic  [1:0] mem;
	logic  [1:0] msz;
	logic  [2:0] mfc;
	logic        mlock;
	logic        mlocke;    // last transfer of the locked sequence
	logic        mprog;     // program space (PC-relative operand)
	// result
	logic        d_v;
	logic  [4:0] d_reg;
	// control flow
	logic  [2:0] br;
	logic [31:0] target;
	logic        pred;      // the front end followed target
	logic        bst;       // Bcc: static prediction, and the history counter
	logic  [1:0] bhc;       // D1 read (trained in EX)
	// exceptions and control
	logic  [7:0] exc;       // decode-time exception vector, 0 = none
	logic        exr;        // an exception routine's uop: pc/npc are not an
	                        // instruction's (never refetched from them)
	logic        ser;       // serialize: flush and refetch npc after WB
	logic        t0cof;     // the instruction is on the 68040 T0 trace list
	logic        b_upd;     // operand B is this uop's own (An)+/-(An) register:
	                        // it reads the updated value (source EA updates)
	logic        a_upd;     // the same for operand A (MOVES An,(An)+ / -(An))
	logic  [2:0] dyn;       // cancelled at AG by run-time state (FPU transfers)
	logic  [4:0] dynk;      // ... its slot / word index
} uop_t;

//--------------------------------------------------------------------------
// Dual issue: the second slot.  A one-word instruction on data registers
// that follows a single-uop instruction (D1 takes its operation word with
// the record: dinst_t.c_v/c_opw) runs beside that uop through the back end,
// in step with it: it reads at most two registers at AG, has no address,
// no memory access, no branch and no exception, and its ALU op is one of
// S1_*.  It is younger than the uop beside it and depends on none of its
// registers; it commits at WB only when that uop does without a redirect.
// Address-register forms (agop: ADDQ/SUBQ #q,An, MOVEA Ry,Ax) are AG's, as
// in the microcode: Ax = a_reg (its low word sign-extended with sxw) + imm,
// written to the front file as the pair leaves AG and to the back file at
// WB; in EX they are a MOV of that value with no register write.
// Loads (ld: MOVE/MOVEA.L/ALU/TST (Ay)) go beside a uop that has no memory
// access of its own: the pair's access is theirs, at the address a_reg
// (read at AG as operand A), and the load data is operand A in EX.  Only
// the data cache's fast path answers it (a hit, nothing in the way): for
// anything else the DMU reports a fault at once, and WB commits the first
// slot and fetches the load again, to run alone.
//--------------------------------------------------------------------------
localparam logic [3:0]
	S1_MOV  = 4'd0,  S1_ADD  = 4'd1,  S1_SUB  = 4'd2,  S1_CMP  = 4'd3,
	S1_AND  = 4'd4,  S1_OR   = 4'd5,  S1_EOR  = 4'd6,  S1_NOT  = 4'd7,
	S1_NEG  = 4'd8,  S1_CLR  = 4'd9,  S1_EXT  = 4'd10, S1_EXTB = 4'd11,
	S1_SWAP = 4'd12;

typedef struct packed {
	logic        v;         // the slot holds an instruction
	logic  [3:0] op;        // S1_*
	logic  [1:0] sz;
	logic  [4:0] ccr_we;    // X N Z V C
	logic        a_imm;     // operand A is imm (else a_reg, if a_v; else zero)
	logic        a_v;
	logic  [4:0] a_reg;
	logic  [7:0] imm;       // signed
	logic        b_v;       // operand B is b_reg (else zero)
	logic  [4:0] b_reg;
	logic        d_v;       // EX writes d_reg (data register forms)
	logic  [4:0] d_reg;
	logic        agop;      // AG writes d_reg (address register forms)
	logic        sxw;       // ... from a_reg's low word, sign-extended
	logic        ld;        // a load: operand A is the data at (a_reg)
} s1_t;

//--------------------------------------------------------------------------
// Decoded instruction (D1 -> D2)
//--------------------------------------------------------------------------
// EA mode index, MC68040 order
localparam logic [3:0] EM_DN = 4'd0, EM_AN = 4'd1, EM_AI = 4'd2, EM_AIP = 4'd3,
                       EM_APD = 4'd4, EM_AD16 = 4'd5, EM_AX = 4'd6,
                       EM_ABSW = 4'd7, EM_ABSL = 4'd8, EM_PC16 = 4'd9,
                       EM_PCX = 4'd10, EM_IMM = 4'd11, EM_NONE = 4'd15;

typedef struct packed {
	logic  [3:0] m;       // EM_*
	logic  [2:0] r;       // register field
	logic  [2:0] xoff;    // word offset of the first extension word
	// index modes (brief or full extension word)
	logic        xa;      // index is an address register
	logic  [2:0] xr;
	logic        xl;      // long index
	logic  [1:0] sc;
	logic        bs;      // base suppressed
	logic        is;      // index suppressed
	logic  [1:0] mi;      // 0 none, 1 preindexed, 2 postindexed memory indirect
	logic [31:0] bd;      // displacement / absolute address / immediate
	logic [31:0] od;      // outer displacement
} ea_t;

// predecode of a queue word taken as an operation word (computed as the
// word enters the instruction queue, so D1 never decodes in its loop)
typedef struct packed {
	logic        legal;   // a legal operation word
	logic  [8:0] ent;     // decoder entry
	logic  [1:0] sz;
	logic  [2:0] b;       // operation word + fixed words + immediate (1..5)
	logic  [2:0] p1;      // first extension word of EA1 (b + EA0 words)
	logic  [3:0] tot;     // length assuming brief index extensions
	logic        x0;      // EA0 has an index extension (at b)
	logic        x1;      // EA1 has an index extension (at p1)
	logic        slow;    // parsed in several cycles (FPU immediate)
	logic  [3:0] i0;      // EA0 mode index, EM_NONE when absent
	logic  [3:0] i1;
} pd_t;

typedef struct packed {
	logic [31:0] pc;
	logic  [3:0] ilen;     // the instruction's length in words (npc = pc + 2 ilen)
	logic [15:0] opw;
	logic [15:0] ext1;
	logic [15:0] ext2;
	logic  [9:0] rt;      // first micro-instruction
	logic  [6:0] eop;
	logic  [3:0] econd;
	logic  [4:0] ccr;
	logic  [1:0] sz;
	logic  [7:0] exc;     // decode-time exception vector, 0 none
	logic [31:0] imm;     // immediate field
	ea_t         ea0;
	ea_t         ea1;
	logic [31:0] target;  // PC-relative branch target
	logic        pred;    // the front end followed target
	logic        t0;      // on the 68040 T0 trace list
	logic        bst;     // Bcc: the static prediction (backward taken)
	logic  [1:0] bhc;     // Bcc: its history counter as D1 read it
	ras_snap_t   ras;     // D1's return stack before this instruction
	logic        c_v;     // a companion: the one-word instruction that follows,
	logic [15:0] c_opw;   // ... its operation word (see s1_t),
	logic        c_tk;    // ... at the target (a branch the fetch BTB took), else pc + 2 ilen
} dinst_t;

// the companion's operation word as a second-slot instruction: the same
// uop the microcode makes of it (the sequencer checks the two agree in
// simulation for every such instruction it runs from the microcode).
// v = 0: not one of them.  Register An with n = 7 is given as 7 + 8: the
// sequencer maps it to USP, ISP or MSP.
function automatic s1_t s1_dec(input logic [15:0] w);
	s1_t s;
	logic [1:0] z;
	logic [4:0] dx, dy, ry, ay;
	s = '0;
	z  = w[7:6];
	dx = {2'b00, w[11:9]};
	dy = {2'b00, w[2:0]};
	ry = {1'b0, w[3], w[2:0]};              // mode 000 Dy, 001 Ay
	ay = {2'b01, w[2:0]};                   // mode 010 (Ay)
	s.imm = w[7:0];
	case (w[15:12])
		4'h7: if (!w[8]) begin                                   // MOVEQ
			s.v = 1'b1; s.op = S1_MOV; s.sz = SZ_L; s.ccr_we = 5'h0F;
			s.a_imm = 1'b1; s.d_v = 1'b1; s.d_reg = dx;
		end
		4'h5: if (z != 2'd3 && w[5:3] == 3'd0) begin            // ADDQ/SUBQ #q,Dy
			s.v = 1'b1; s.op = w[8] ? S1_SUB : S1_ADD; s.sz = z; s.ccr_we = 5'h1F;
			s.a_imm = 1'b1; s.imm = (w[11:9] == 3'd0) ? 8'd8 : {5'd0, w[11:9]};
			s.b_v = 1'b1; s.b_reg = dy; s.d_v = 1'b1; s.d_reg = dy;
		end
		else if ((z == SZ_W || z == SZ_L) && w[5:3] == 3'd1) begin   // ADDQ/SUBQ #q,Ay
			logic [7:0] q;
			q = (w[11:9] == 3'd0) ? 8'd8 : {5'd0, w[11:9]};
			s.v = 1'b1; s.agop = 1'b1; s.op = S1_MOV; s.sz = SZ_L;
			s.a_v = 1'b1; s.a_reg = ry; s.imm = w[8] ? -q : q; s.d_reg = ry;
		end
		4'h8, 4'h9, 4'hB, 4'hC, 4'hD:
			if (z != 2'd3 && !w[8] &&
			    (w[5:3] == 3'd0 || w[5:3] == 3'd2 ||
			     (w[5:3] == 3'd1 && z != SZ_B && (w[15:12] == 4'h9 || w[15:12] == 4'hB || w[15:12] == 4'hD)))) begin
				// OR/SUB/CMP/AND/ADD Dy, Ay or (Ay),Dx
				s.v = 1'b1; s.sz = z;
				case (w[15:12])
					4'h8: begin s.op = S1_OR;  s.ccr_we = 5'h0F; end
					4'h9: begin s.op = S1_SUB; s.ccr_we = 5'h1F; end
					4'hB: begin s.op = S1_CMP; s.ccr_we = 5'h0F; end
					4'hC: begin s.op = S1_AND; s.ccr_we = 5'h0F; end
					default: begin s.op = S1_ADD; s.ccr_we = 5'h1F; end
				endcase
				s.a_v = 1'b1; s.a_reg = ry; s.b_v = 1'b1; s.b_reg = dx;
				s.d_v = (w[15:12] != 4'hB); s.d_reg = dx;
				if (w[5:3] == 3'd2) begin s.ld = 1'b1; s.a_reg = ay; end
			end
			else if (w[15:12] == 4'hB && z != 2'd3 && w[8] && w[5:3] == 3'd0) begin
				// EOR Dx,Dy
				s.v = 1'b1; s.op = S1_EOR; s.sz = z; s.ccr_we = 5'h0F;
				s.a_v = 1'b1; s.a_reg = dx; s.b_v = 1'b1; s.b_reg = dy;
				s.d_v = 1'b1; s.d_reg = dy;
			end
		4'h1, 4'h2, 4'h3:                                         // MOVE Dy/Ay,Dx
			if (w[8:6] == 3'd1 && w[15:12] != 4'h1 && w[5:4] == 2'd0) begin
				// MOVEA Dy/Ay,Ax
				s.v = 1'b1; s.agop = 1'b1; s.op = S1_MOV; s.sz = SZ_L;
				s.a_v = 1'b1; s.a_reg = ry; s.imm = 8'd0; s.sxw = (w[15:12] == 4'h3);
				s.d_reg = {2'b01, w[11:9]};
			end
			else if (w[8:6] == 3'd0 && (w[5:3] == 3'd0 || (w[5:3] == 3'd1 && w[15:12] != 4'h1))) begin
				s.v = 1'b1; s.op = S1_MOV; s.ccr_we = 5'h0F;
				s.sz = (w[15:12] == 4'h1) ? SZ_B : (w[15:12] == 4'h3) ? SZ_W : SZ_L;
				s.a_v = 1'b1; s.a_reg = ry;
				s.b_v = 1'b1; s.b_reg = dx;
				s.d_v = 1'b1; s.d_reg = dx;
			end
			else if (w[8:6] == 3'd0 && w[5:3] == 3'd2) begin        // MOVE (Ay),Dx
				s.v = 1'b1; s.ld = 1'b1; s.op = S1_MOV; s.ccr_we = 5'h0F;
				s.sz = (w[15:12] == 4'h1) ? SZ_B : (w[15:12] == 4'h3) ? SZ_W : SZ_L;
				s.a_v = 1'b1; s.a_reg = ay;
				s.b_v = 1'b1; s.b_reg = dx;
				s.d_v = 1'b1; s.d_reg = dx;
			end
			else if (w[8:6] == 3'd1 && w[15:12] == 4'h2 && w[5:3] == 3'd2) begin   // MOVEA.L (Ay),Ax
				s.v = 1'b1; s.ld = 1'b1; s.op = S1_MOV; s.sz = SZ_L;
				s.a_v = 1'b1; s.a_reg = ay;
				s.d_v = 1'b1; s.d_reg = {2'b01, w[11:9]};
			end
		4'h4: if (w[5:3] == 3'd2) begin
			if (w[11:8] == 4'hA && z != 2'd3) begin                  // TST (Ay)
				s.v = 1'b1; s.ld = 1'b1; s.op = S1_MOV; s.sz = z; s.ccr_we = 5'h0F;
				s.a_v = 1'b1; s.a_reg = ay;
			end
		end
		else if (w[5:3] == 3'd0) begin
			if (w[11:8] == 4'hA && z != 2'd3) begin                  // TST Dy
				s.v = 1'b1; s.op = S1_MOV; s.sz = z; s.ccr_we = 5'h0F;
				s.a_v = 1'b1; s.a_reg = dy;
			end
			else if ((w[11:8] == 4'h2 || w[11:8] == 4'h4 || w[11:8] == 4'h6) && z != 2'd3) begin
				// CLR / NEG / NOT Dy
				s.v = 1'b1; s.sz = z;
				s.op = (w[11:8] == 4'h2) ? S1_CLR : (w[11:8] == 4'h4) ? S1_NEG : S1_NOT;
				s.ccr_we = (w[11:8] == 4'h4) ? 5'h1F : 5'h0F;
				s.b_v = 1'b1; s.b_reg = dy; s.d_v = 1'b1; s.d_reg = dy;
			end
			else if (w[11:6] == 6'b100010 || w[11:6] == 6'b100011 || w[11:6] == 6'b100111 ||
			         w[11:6] == 6'b100001) begin
				// EXT.W, EXT.L, EXTB.L, SWAP Dy
				s.v = 1'b1; s.ccr_we = 5'h0F;
				s.op = (w[8:6] == 3'd7) ? S1_EXTB : (w[8:6] == 3'd1) ? S1_SWAP : S1_EXT;
				s.sz = (w[8:6] == 3'd2 || w[8:6] == 3'd1) ? SZ_W : SZ_L;
				s.b_v = 1'b1; s.b_reg = dy; s.d_v = 1'b1; s.d_reg = dy;
			end
		end
		default: ;
	endcase
	s1_dec = s;
endfunction

endpackage
