// Directed bench for rtl/easc.sv: the registers the LC 475 ROM tests and
// programs, the FIFO status and interrupt, and the CD-XA decoder against a
// reference model.  Run with tests/run_easc.sh.
//
// +CHIME=<hex bytes> +CHIMEOUT=<file> plays a compressed sound the way the
// ROM's startup code does ($408BD334-$408BD3D8) and writes the left output
// at 44.1 kHz, one signed sample a line.
`timescale 1ns/1ps
module tb_easc;

reg clk = 0;
always #20 clk = ~clk;                 // 25 MHz

reg         nreset = 0;
reg         sel = 0, write = 0;
reg  [11:2] a = 0;
reg   [3:0] be = 0;
reg  [31:0] wdata = 0;
wire [31:0] rdata;
wire        irq;
wire signed [15:0] sl, sr;

easc dut (.clk(clk), .nreset(nreset), .ce(1'b1), .sel(sel), .write(write),
          .a(a), .be(be), .wdata(wdata), .rdata(rdata), .irq(irq),
          .sample_l(sl), .sample_r(sr));

integer errors = 0, checks = 0;
task automatic expect_eq(input string what, input integer got, input integer want);
	checks++;
	if (got !== want) begin
		errors++;
		if (errors < 30) $display("FAIL: %s: got %0d ($%0h), want %0d ($%0h) at %0t",
		                          what, got, got, want, want, $time);
	end
endtask

task automatic wr8(input [11:0] addr, input [7:0] d);
	@(negedge clk);
	sel = 1; write = 1; a = addr[11:2]; be = 4'b1000 >> addr[1:0]; wdata = {4{d}};
	@(negedge clk);
	sel = 0; write = 0; be = 0;
endtask

task automatic wr16(input [11:0] addr, input [15:0] d);
	@(negedge clk);
	sel = 1; write = 1; a = addr[11:2]; be = addr[1] ? 4'b0011 : 4'b1100; wdata = {2{d}};
	@(negedge clk);
	sel = 0; write = 0; be = 0;
endtask

task automatic rd8(input [11:0] addr, output [7:0] d);
	@(negedge clk);
	sel = 1; write = 0; a = addr[11:2]; be = 4'b1000 >> addr[1:0];
	#1;
	case (addr[1:0])
		2'd0: d = rdata[31:24];
		2'd1: d = rdata[23:16];
		2'd2: d = rdata[15:8];
		default: d = rdata[7:0];
	endcase
	@(negedge clk);
	sel = 0; be = 0;
endtask

task automatic check_reg(input string what, input [11:0] addr, input [7:0] want);
	reg [7:0] d;
	rd8(addr, d);
	expect_eq(what, d, want);
endtask

// write each value and read it back under a mask, as the ROM's test does
// ($40848548-$40848566)
task automatic rom_reg_test(input string what, input [11:0] addr, input [7:0] mask,
                            input integer n, input [7:0] vals [0:8]);
	reg [7:0] d;
	for (integer i = 0; i < n; i++) begin
		wr8(addr, vals[i]);
		rd8(addr, d);
		expect_eq(what, d & mask, vals[i]);
	end
endtask

// ---- reference models ------------------------------------------------------
function automatic integer sat(input integer v);
	if (v > 32767) return 32767;
	if (v < -32768) return -32768;
	return v;
endfunction

function automatic integer gain806(input [7:0] v);
	case (v[7:5])
		0: return 0;   1: return 37;  2: return 73;  3: return 110;
		4: return 146; 5: return 183; 6: return 219; default: return 256;
	endcase
endfunction

// what the mixer must show for the chip's present samples and gains
function automatic integer mix_ref(input integer sa, input integer sb,
                                   input integer ga, input integer gb, input [7:0] vol);
	integer m;
	m = sat((sa * ga + sb * gb) >>> 7);
	return (m * gain806(vol)) >>> 8;
endfunction

integer k0t [0:3] = '{0, 60, 115, 98};
integer k1t [0:3] = '{0, 0, -52, -55};

reg [7:0] stream [0:65535];
integer   stream_len;
integer   expect_s [0:131071];
integer   expect_n;

// decode stream[] into expect_s[] the CD-XA way
task automatic build_expect;
	integer s1, s2, rng, flt, n, v, b;
	s1 = 0; s2 = 0; expect_n = 0; rng = 0; flt = 0;
	for (integer i = 0; i < stream_len; i++) begin
		b = stream[i];
		if (i % 15 == 0) begin
			rng = b & 15; flt = (b >> 4) & 3;
		end
		else
			for (integer h = 0; h < 2; h++) begin
				n = h ? (b >> 4) : (b & 15);
				if (n >= 8) n -= 16;
				v = ((n <<< 12) >>> rng) + ((k0t[flt] * s1 + k1t[flt] * s2) >>> 6);
				v = sat(v);
				s2 = s1; s1 = v;
				expect_s[expect_n++] = v;
			end
	end
endtask

// ---- decoder monitor: each finished sample against the reference ------------
integer got_a = 0, got_b = 0;
reg     mon_on = 0, done_a = 0, done_b = 0;
always @(posedge clk) begin
	done_a <= mon_on && dut.st == 5'd7 && dut.shc == 0 && !dut.ch;
	done_b <= mon_on && dut.st == 5'd7 && dut.shc == 0 &&  dut.ch;
	if (done_a) begin
		if (got_a < expect_n) expect_eq($sformatf("XA sample A[%0d]", got_a), dut.s1_a, expect_s[got_a]);
		got_a++;
	end
	if (done_b) begin
		if (got_b < expect_n) expect_eq($sformatf("XA sample B[%0d]", got_b), dut.s1_b, expect_s[got_b]);
		got_b++;
	end
end

// ---- pop monitor for the raw FIFO -------------------------------------------
integer pops_a = 0, pops_b = 0;
always @(posedge clk) begin
	if (dut.pop_a) pops_a++;
	if (dut.pop_b) pops_b++;
end

// ---- 44.1 kHz output capture for +CHIME ---------------------------------------
integer outf = 0;
always @(posedge clk) if (outf != 0 && dut.base_tick) $fdisplay(outf, "%0d", sl);

// the ROM's pump: one byte to both FIFOs each time $804 bit 2 is set, then
// wait for bit 3
task automatic rom_pump;
	reg [7:0] st;
	for (integer i = 0; i < stream_len; i++) begin
		do rd8(12'h804, st); while (!st[2]);
		wr8(12'h000, stream[i]);
		wr8(12'h400, stream[i]);
	end
	do rd8(12'h804, st); while (!st[3]);
endtask

// the ROM's sound setup, $408042F8-$408043B4
task automatic rom_init;
	wr16(12'hF06, 16'h7F00); wr16(12'hF26, 16'h007F);
	wr8(12'hF09, 8'h01); wr8(12'hF29, 8'h01);
	wr8(12'h803, 8'h80); wr8(12'h803, 8'h00);
	wr8(12'h80A, 8'h02); wr8(12'h801, 8'h01);
	wr8(12'hF08, 8'h00); wr8(12'hF28, 8'h00);
	wr16(12'hF04, 16'h812F); wr16(12'hF24, 16'h812F);
	wr16(12'hF10, 16'h0000); wr16(12'hF12, 16'h003C);
	wr16(12'hF14, 16'hCC73); wr16(12'hF16, 16'hC962);
	wr16(12'hF30, 16'h0000); wr16(12'hF32, 16'h003C);
	wr16(12'hF34, 16'hCC73); wr16(12'hF36, 16'hC962);
	wr8(12'hF08, 8'h80); wr8(12'hF28, 8'h80);
endtask

reg [7:0] d;
reg [7:0] v9 [0:8];
integer   n0, seed, base_a, base_b;
longint   t0;
string    chime, chimeout;

initial begin
	repeat (8) @(negedge clk);
	nreset = 1;
	repeat (4) @(negedge clk);

	// ---- identity and idle status ($408BD252, $40849D74) -------------------
	check_reg("version", 12'h800, 8'hB0);
	check_reg("idle status", 12'h804, 8'h0F);

	// ---- the ROM's register test for a $B0 part ($4084871A) ----------------
	v9 = '{8'h00, 8'h01, 8'h00, 0, 0, 0, 0, 0, 0};
	rom_reg_test("$801", 12'h801, 8'h03, 3, v9);
	v9 = '{8'h00, 8'h20, 8'h40, 8'h60, 8'h80, 8'hA0, 8'hC0, 8'hE0, 0};
	rom_reg_test("$806", 12'h806, 8'hE0, 8, v9);
	v9 = '{8'h00, 8'h01, 8'h00, 0, 0, 0, 0, 0, 0};
	rom_reg_test("$80A", 12'h80A, 8'h01, 3, v9);
	v9 = '{8'h00, 8'h01, 8'h02, 8'h03, 8'h80, 8'h81, 8'h82, 8'h83, 8'h00};
	rom_reg_test("$F08", 12'hF08, 8'hFF, 9, v9);
	rom_reg_test("$F28", 12'hF28, 8'hFF, 9, v9);

	// ---- setup, then what it left behind -----------------------------------
	rom_init;
	check_reg("$F04", 12'hF04, 8'h81); check_reg("$F05", 12'hF05, 8'h2F);
	check_reg("$F24", 12'hF24, 8'h81); check_reg("$F25", 12'hF25, 8'h2F);
	check_reg("$F06", 12'hF06, 8'h7F); check_reg("$F07", 12'hF07, 8'h00);
	check_reg("$F26", 12'hF26, 8'h00); check_reg("$F27", 12'hF27, 8'h7F);
	check_reg("$F08", 12'hF08, 8'h80); check_reg("$F09", 12'hF09, 8'h01);
	check_reg("$F28", 12'hF28, 8'h80); check_reg("$F29", 12'hF29, 8'h01);
	begin
		reg [7:0] coef [0:7];
		coef = '{8'h00, 8'h00, 8'h00, 8'h3C, 8'hCC, 8'h73, 8'hC9, 8'h62};
		for (integer i = 0; i < 8; i++) begin
			check_reg("coefficient A", 12'hF10 + i, coef[i]);
			check_reg("coefficient B", 12'hF30 + i, coef[i]);
		end
	end
	check_reg("mode", 12'h801, 8'h01);
	check_reg("status, FIFO mode, empty", 12'h804, 8'h0F);

	// ---- raw FIFO: order, status bits, rate, panning ------------------------
	// 600 bytes to A, 700 to B (a longword carries four)
	base_a = pops_a; base_b = pops_b;
	for (integer i = 0; i < 600; i++) wr8(12'h000 + (i & 12'h3FF), 8'(i * 7 + 3));
	for (integer i = 0; i < 700; i += 4) begin
		@(negedge clk);
		sel = 1; write = 1; a = 10'h100; be = 4'b1111;
		wdata = {8'(i * 5 + 1), 8'(i * 5 + 6), 8'(i * 5 + 11), 8'(i * 5 + 16)};
		@(negedge clk);
		sel = 0; write = 0; be = 0;
		repeat (5) @(negedge clk);
	end
	rd8(12'h804, d);
	expect_eq("status above half", d, 8'h00);
	check_reg("write pointer A high", 12'hF00, 8'h02);
	check_reg("write pointer A low", 12'hF01, 8'h58);
	// follow each pop: the sample must be the next byte, and the output the mix
	begin
		integer ia, ib, want;
		ia = pops_a - base_a; ib = pops_b - base_b;
		t0 = $time; n0 = pops_a;
		while (dut.cap_a != 0 || dut.cap_b != 0) begin
			@(posedge clk);
			if (dut.pop_a) begin
				@(negedge clk);
				want = (((ia * 7 + 3) & 255) ^ 128) <<< 8;
				if (want >= 32768) want -= 65536;
				expect_eq("raw sample A", dut.s1_a, want);
				ia++;
			end
			if (dut.pop_b) begin
				@(negedge clk);
				want = (((ib * 5 + 1) & 255) ^ 128) <<< 8;
				if (want >= 32768) want -= 65536;
				expect_eq("raw sample B", dut.s1_b, want);
				ib++;
			end
			if (dut.st == 5'd16) begin         // S_M8: the mix is complete
				@(negedge clk);
				expect_eq("left = A", sl, mix_ref(dut.s1_a, dut.s1_b, 127, 0, 8'hE0));
				expect_eq("right = B", sr, mix_ref(dut.s1_a, dut.s1_b, 0, 127, 8'hE0));
			end
		end
		expect_eq("A bytes out", ia, 600);
		expect_eq("B bytes out", ib, 700);
		// $812F: 22254 Hz.  B's 700 pops take 31.45 ms, less the few during the fill.
		expect_eq("drain time within 1%", ($time - t0) > 31_100_000 && ($time - t0) < 31_600_000, 1);
	end
	check_reg("status, drained", 12'h804, 8'h0F);
	expect_eq("no interrupt while masked", irq, 0);

	// volume and panning on a held sample
	wr8(12'h806, 8'h60);
	wr16(12'hF06, 16'h4020); wr16(12'hF26, 16'h107F);
	wr8(12'h000, 8'hF0); wr8(12'h400, 8'h10);
	repeat (4000) @(negedge clk);
	expect_eq("mixed left", sl, mix_ref(dut.s1_a, dut.s1_b, 8'h40, 8'h10, 8'h60));
	expect_eq("mixed right", sr, mix_ref(dut.s1_a, dut.s1_b, 8'h20, 8'h7F, 8'h60));
	expect_eq("held sample A", dut.s1_a, 16'sh7000);
	wr8(12'h806, 8'hE0);
	wr16(12'hF06, 16'h7F00); wr16(12'hF26, 16'h007F);

	// ---- interrupt: the ROM's FIFO test for a $B0 part ($40849D94) -----------
	wr16(12'hF04, 16'h3FDB); wr16(12'hF24, 16'h3FDB);     // 11 kHz
	wr8(12'h803, 8'h80); wr8(12'h803, 8'h00);
	wr8(12'hF29, 8'h00);                                   // B unmasked, empty
	repeat (4) @(negedge clk);
	expect_eq("kick on an empty FIFO", irq, 1);
	rd8(12'h804, d);
	@(negedge clk);
	expect_eq("status read clears it", irq, 0);
	for (integer i = 0; i < 1001; i++) wr8(12'h400, 8'h80);
	expect_eq("no interrupt on filling", irq, 0);
	t0 = $time;
	while (!irq && $time - t0 < 80_000_000) @(negedge clk);
	expect_eq("half-empty interrupt B", irq, 1);
	// 1001 - 511 = 490 pops at 11000 Hz = 44.5 ms, less those during the fill
	expect_eq("its time", ($time - t0) > 38_000_000 && ($time - t0) < 45_000_000, 1);
	rd8(12'h804, d);
	expect_eq("status at the interrupt", d, 8'h07);
	@(negedge clk);
	expect_eq("cleared by the read", irq, 0);
	// $40871B84: mask, unmask raises it again while below half
	wr8(12'hF29, 8'h01); wr8(12'hF29, 8'h00);
	repeat (2) @(negedge clk);
	expect_eq("raised again by 1 then 0", irq, 1);
	wr8(12'hF29, 8'h01);
	repeat (2) @(negedge clk);
	expect_eq("masking drops it", irq, 0);
	t0 = $time;
	do rd8(12'h804, d); while (!d[3] && $time - t0 < 80_000_000);
	expect_eq("B empty", d, 8'h0F);
	// channel A the same way
	wr8(12'hF09, 8'h00);
	rd8(12'h804, d);
	for (integer i = 0; i < 1001; i++) wr8(12'h000, 8'h80);
	t0 = $time;
	while (!irq && $time - t0 < 80_000_000) @(negedge clk);
	expect_eq("half-empty interrupt A", irq, 1);
	rd8(12'h804, d);
	expect_eq("status at the interrupt A", d, 8'h0D);
	wr8(12'hF09, 8'h01);
	// not in mode 0
	wr8(12'h801, 8'h00);
	wr8(12'hF09, 8'h00);
	repeat (2) @(negedge clk);
	expect_eq("no interrupt outside FIFO mode", irq, 0);
	wr8(12'hF09, 8'h01);
	check_reg("mode change cleared the FIFOs", 12'h804, 8'h0F);

	// ---- CD-XA: random packets, every range and filter -----------------------
	seed = 32'h475;
	stream_len = 15 * 600;
	for (integer i = 0; i < stream_len; i++) begin
		seed = seed * 1103515245 + 12345;
		stream[i] = seed[23:16];
		// keep most packets from saturating: filter 0 half the time, small nibbles
		if (i % 15 == 0) begin
			if (stream[i][6]) stream[i][5:4] = 0;
		end
		else if ((i / 15) % 3 != 0) stream[i] = stream[i] & 8'h33 | {stream[i][1], stream[i][1], 2'b0, stream[i][5], stream[i][5], 2'b0};
	end
	build_expect;
	rom_init;
	wr16(12'hF04, 16'h7FFF); wr16(12'hF24, 16'h7FFF);
	wr8(12'hF08, 8'h82); wr8(12'hF28, 8'h82);
	mon_on = 1;
	t0 = $time;
	rom_pump;
	repeat (4000) @(negedge clk);
	expect_eq("XA samples A", got_a, expect_n);
	expect_eq("XA samples B", got_b, expect_n);
	// 16800 samples at 22050 Hz = 762 ms
	expect_eq("XA play time within 1%", ($time - t0) > 754_000_000 && ($time - t0) < 770_000_000, 1);
	expect_eq("XA left output", sl, mix_ref(expect_s[expect_n-1], expect_s[expect_n-1], 127, 0, 8'hE0));
	expect_eq("XA right output", sr, mix_ref(expect_s[expect_n-1], expect_s[expect_n-1], 0, 127, 8'hE0));
	mon_on = 0;
	rom_init;
	expect_eq("mode write clears the history", dut.s1_a, 0);

	// ---- optional: a real sound through the ROM's sequence ------------------
	if ($value$plusargs("CHIME=%s", chime) && $value$plusargs("CHIMEOUT=%s", chimeout)) begin
		integer f, c;
		f = $fopen(chime, "r");
		stream_len = 0;
		while ($fscanf(f, "%h", c) == 1) stream[stream_len++] = c[7:0];
		$fclose(f);
		build_expect;
		got_a = 0; got_b = 0;
		wr16(12'hF04, 16'h7FFF); wr16(12'hF24, 16'h7FFF);
		wr8(12'hF08, 8'h82); wr8(12'hF28, 8'h82);
		outf = $fopen(chimeout, "w");
		mon_on = 1;
		rom_pump;
		repeat (4000) @(negedge clk);
		mon_on = 0;
		$fclose(outf); outf = 0;
		expect_eq("chime samples A", got_a, expect_n);
		expect_eq("chime samples B", got_b, expect_n);
		$display("CHIME: %0d bytes, %0d samples", stream_len, expect_n);
	end

	if (errors == 0) $display("PASS: easc, %0d checks", checks);
	else             $display("FAILED: easc, %0d of %0d checks", errors, checks);
	$finish;
end

initial begin
	#8_000_000_000;
	$display("FAILED: easc bench timed out");
	$finish;
end

endmodule
