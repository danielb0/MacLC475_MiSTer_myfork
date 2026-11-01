module adb_device #(parameter integer CLK_HZ = 25_000_000) (
	input  wire        clk,
	input  wire        reset,
	input  wire        host_line,
	output reg         dev_line,
	input  wire [10:0] ps2_key,
	input  wire [24:0] ps2_mouse,
	output wire [63:0] debug_mouse,
	output reg  [15:0] debug_mouse_listen
);

	reg capslock;

	// ADB bit cells are 100 us; stop-to-start is 200 us.
	localparam [17:0] T_ATTN = 18'(CLK_HZ / 2000);
	localparam [17:0] T_RESET = 18'(CLK_HZ / 1000 * 3);
	localparam [17:0] T_TIMEOUT = 18'(CLK_HZ / 1000);
	localparam [17:0] T_BITTH = 18'(CLK_HZ / 20000);
	localparam [17:0] D_SHORT = 18'(CLK_HZ / 1000000 * 35 - 1);
	localparam [17:0] D_LONG = 18'(CLK_HZ / 1000000 * 65 - 1);
	localparam [17:0] D_STOP = 18'(CLK_HZ / 1000000 * 65 - 1);
	localparam [17:0] D_T1T = 18'(CLK_HZ / 5000 - 1);
	localparam [17:0] D_SRQ = 18'(CLK_HZ / 10000 * 3 - 1);

	localparam [3:0] ADDR_KBD   = 4'd2;
	localparam [3:0] ADDR_MOUSE = 4'd3;
	reg [3:0] kbd_addr, mouse_addr;
	reg kbd_srq, mouse_srq;
	reg kbd_collision, mouse_collision;
	reg [3:0] random_id;
	reg [1:0] kbd_pop;
	reg mouse_pop;
	reg listen_r3;

	reg [7:0] resp0, resp1;
	reg [1:0] resp_len;

	(* ramstyle = "MLAB" *) reg  [7:0] kbdFifo [0:7];
	reg  [2:0] kbdFifoRd, kbdFifoWr;
	wire       kbdFifoEmpty = (kbdFifoRd == kbdFifoWr);

	reg signed [15:0] mouseX, mouseY;
	reg signed [6:0] mouse_send_x, mouse_send_y;
	reg mouse_report_id, mouse_event_id;
	reg        mouseButton;
	reg        mouse_evt;
	reg        mouse_init;

	reg        kstb_s1, kstb_s2, kstb_s3, kstb_d;
	reg  [9:0] keyRaw_s1, keyRaw_s2;
	reg  [7:0] keyData;
	reg        key_pending;
	wire       key_edge   = (kstb_s3 != kstb_d);
	wire [8:0] key_sc     = keyRaw_s2[8:0];
	wire       press      = keyRaw_s2[9];
	wire       capslock_key = (keyRaw_s2[8:0] == 9'h58);

	reg        mstb_s1, mstb_s2, mstb_s3, mstb_d;
	reg  [8:0] mX_s1, mX_s2, mY_s1, mY_s2;
	reg        mBtn_s1, mBtn_s2;
	wire       mouse_edge = (mstb_s3 != mstb_d);
	reg [7:0] mouse_inputs, mouse_talks, mouse_replies, last_command;
	reg [15:0] last_mouse_reply;
	assign debug_mouse = {mouse_inputs, mouse_talks, mouse_replies, last_command,
	                      kbd_addr, mouse_addr, mouse_srq, mouse_evt, mouse_init,
	                      mouseButton, mouse_collision, 3'b000, last_mouse_reply};
	wire signed [15:0] mouse_x_next = mouseX +
	    (mouse_edge ? {{7{mX_s2[8]}},mX_s2} : 16'd0);
	wire signed [15:0] mouse_y_next = mouseY -
	    (mouse_edge ? {{7{mY_s2[8]}},mY_s2} : 16'd0);
	function automatic [6:0] mouse_delta(input signed [15:0] value);
		if (value > 63) mouse_delta = 7'd63;
		else if (value < -64) mouse_delta = 7'h40;
		else mouse_delta = value[6:0];
	endfunction

	reg        hl_d;
	wire       fall = hl_d & ~host_line;
	wire       rise = ~hl_d & host_line;
	reg [17:0] dur;

	localparam [3:0]
		S_IDLE = 4'd0, S_ATTN = 4'd1, S_BITS = 4'd2, S_TSTOP = 4'd3,
		S_T1T  = 4'd4, S_SEND = 4'd5,

		S_LRX_WAIT = 4'd6, S_LRX_START = 4'd7, S_LRX_BITS = 4'd8, S_LRX_DONE = 4'd9,

		S_SRQ = 4'd10, S_STOP_WAIT = 4'd11;
	reg [3:0]  st;
	reg [7:0]  command;
	reg [3:0]  bitcnt;
	reg [17:0] sendtmr;
	reg [3:0]  send_stage;
	reg [7:0]  send_sr;
	reg [3:0]  send_bits;
	reg [1:0]  send_byte;
	reg        cur_bit;
	reg [15:0] lrx_sr;
	reg        lrx_target;

	wire [3:0] cmd_addr = command[7:4];
	wire [1:0] cmd_type = command[3:2];
	wire [1:0] cmd_reg  = command[1:0];

	wire srq_want = (mouse_srq && mouse_evt && cmd_addr != mouse_addr) ||
	                (kbd_srq && !kbdFifoEmpty && cmd_addr != kbd_addr);

	always @(posedge clk) begin
		if (reset) begin
			hl_d <= 1'b1; dur <= 0; st <= S_IDLE; dev_line <= 1'b1;
			command <= 0; bitcnt <= 0;
			kbd_addr <= ADDR_KBD; mouse_addr <= ADDR_MOUSE;
			kbd_srq <= 1; mouse_srq <= 1; random_id <= 1;
			kbd_collision <= 0; mouse_collision <= 0;
			mouse_send_x <= 0; mouse_send_y <= 0;
			mouse_report_id <= 0; mouse_event_id <= 0;
			mouse_inputs <= 0; mouse_talks <= 0; mouse_replies <= 0;
			last_command <= 0; last_mouse_reply <= 0; debug_mouse_listen <= 0;
			kbd_pop <= 0; mouse_pop <= 0; listen_r3 <= 0;
			resp_len <= 0; resp0 <= 0; resp1 <= 0;
			sendtmr <= 0; send_stage <= 0; send_sr <= 0; send_bits <= 0;
			send_byte <= 0; cur_bit <= 0;
			lrx_sr <= 0; lrx_target <= 0;
			kbdFifoRd <= 0; kbdFifoWr <= 0;
			mouseX <= 0; mouseY <= 0; mouseButton <= 0; mouse_evt <= 0; mouse_init <= 1'b1;
			kstb_s1 <= ps2_key[10]; kstb_s2 <= ps2_key[10]; kstb_s3 <= ps2_key[10]; kstb_d <= ps2_key[10];
			keyRaw_s1 <= 0; keyRaw_s2 <= 0; keyData <= 8'h7F; key_pending <= 0; capslock <= 0;
			mstb_s1 <= ps2_mouse[24]; mstb_s2 <= ps2_mouse[24]; mstb_s3 <= ps2_mouse[24]; mstb_d <= ps2_mouse[24];
			mX_s1 <= 0; mX_s2 <= 0; mY_s1 <= 0; mY_s2 <= 0; mBtn_s1 <= 0; mBtn_s2 <= 0;
		end else begin

			hl_d <= host_line;
			random_id <= {random_id[2:0], random_id[3] ^ random_id[2]};
			kstb_s1 <= ps2_key[10];   kstb_s2 <= kstb_s1;   kstb_s3 <= kstb_s2;
			keyRaw_s1 <= ps2_key[9:0]; keyRaw_s2 <= keyRaw_s1;
			mstb_s1 <= ps2_mouse[24];  mstb_s2 <= mstb_s1;   mstb_s3 <= mstb_s2;
			mX_s1 <= {ps2_mouse[4], ps2_mouse[15:8]};  mX_s2 <= mX_s1;
			mY_s1 <= {ps2_mouse[5], ps2_mouse[23:16]}; mY_s2 <= mY_s1;
			mBtn_s1 <= ps2_mouse[0];   mBtn_s2 <= mBtn_s1;

			if (fall || rise) dur <= 0;
			else if (dur != 18'h3FFFF) dur <= dur + 18'd1;

			key_pending <= 1'b0;
			if (key_edge) begin
				kstb_d <= kstb_s3;
				if (capslock_key && press) capslock <= ~capslock;
				key_pending <= 1'b1;
				case (key_sc)
			  9'h001: keyData[6:0] <= 7'h65;
			  9'h003: keyData[6:0] <= 7'h60;
			  9'h004: keyData[6:0] <= 7'h63;
			  9'h005: keyData[6:0] <= 7'h7A;
			  9'h006: keyData[6:0] <= 7'h78;
			  9'h009: keyData[6:0] <= 7'h6D;
			  9'h00a: keyData[6:0] <= 7'h64;
			  9'h00b: keyData[6:0] <= 7'h61;
			  9'h00c: keyData[6:0] <= 7'h76;
			  9'h00d: keyData[6:0] <= 7'h30;
			  9'h00e: keyData[6:0] <= 7'h32;
			  9'h011: keyData[6:0] <= 7'h37;
			  9'h012: keyData[6:0] <= 7'h38;
			  9'h014: keyData[6:0] <= 7'h36;
			  9'h015: keyData[6:0] <= 7'h0C;
			  9'h016: keyData[6:0] <= 7'h12;
			  9'h01a: keyData[6:0] <= 7'h06;
			  9'h01b: keyData[6:0] <= 7'h01;
			  9'h01c: keyData[6:0] <= 7'h00;
			  9'h01d: keyData[6:0] <= 7'h0D;
			  9'h01e: keyData[6:0] <= 7'h13;
			  9'h021: keyData[6:0] <= 7'h08;
			  9'h022: keyData[6:0] <= 7'h07;
			  9'h023: keyData[6:0] <= 7'h02;
			  9'h024: keyData[6:0] <= 7'h0E;
			  9'h025: keyData[6:0] <= 7'h15;
			  9'h026: keyData[6:0] <= 7'h14;
			  9'h029: keyData[6:0] <= 7'h31;
			  9'h02a: keyData[6:0] <= 7'h09;
			  9'h02b: keyData[6:0] <= 7'h03;
			  9'h02c: keyData[6:0] <= 7'h11;
			  9'h02d: keyData[6:0] <= 7'h0F;
			  9'h02e: keyData[6:0] <= 7'h17;
			  9'h031: keyData[6:0] <= 7'h2D;
			  9'h032: keyData[6:0] <= 7'h0B;
			  9'h033: keyData[6:0] <= 7'h04;
			  9'h034: keyData[6:0] <= 7'h05;
			  9'h035: keyData[6:0] <= 7'h10;
			  9'h036: keyData[6:0] <= 7'h16;
			  9'h03a: keyData[6:0] <= 7'h2E;
			  9'h03b: keyData[6:0] <= 7'h26;
			  9'h03c: keyData[6:0] <= 7'h20;
			  9'h03d: keyData[6:0] <= 7'h1A;
			  9'h03e: keyData[6:0] <= 7'h1C;
			  9'h041: keyData[6:0] <= 7'h2B;
			  9'h042: keyData[6:0] <= 7'h28;
			  9'h043: keyData[6:0] <= 7'h22;
			  9'h044: keyData[6:0] <= 7'h1F;
			  9'h045: keyData[6:0] <= 7'h1D;
			  9'h046: keyData[6:0] <= 7'h19;
			  9'h049: keyData[6:0] <= 7'h2F;
			  9'h04a: keyData[6:0] <= 7'h2C;
			  9'h04b: keyData[6:0] <= 7'h25;
			  9'h04c: keyData[6:0] <= 7'h29;
			  9'h04d: keyData[6:0] <= 7'h23;
			  9'h04e: keyData[6:0] <= 7'h1B;
			  9'h052: keyData[6:0] <= 7'h27;
			  9'h054: keyData[6:0] <= 7'h21;
			  9'h055: keyData[6:0] <= 7'h18;
			  9'h058: keyData[6:0] <= 7'h39;
			  9'h059: keyData[6:0] <= 7'h7B;
			  9'h05a: keyData[6:0] <= 7'h24;
			  9'h05b: keyData[6:0] <= 7'h1E;
			  9'h05d: keyData[6:0] <= 7'h2A;
			  9'h066: keyData[6:0] <= 7'h33;
			  9'h069: keyData[6:0] <= 7'h53;
			  9'h06b: keyData[6:0] <= 7'h56;
			  9'h06c: keyData[6:0] <= 7'h59;
			  9'h070: keyData[6:0] <= 7'h52;
			  9'h071: keyData[6:0] <= 7'h41;
			  9'h072: keyData[6:0] <= 7'h54;
			  9'h073: keyData[6:0] <= 7'h57;
			  9'h074: keyData[6:0] <= 7'h58;
			  9'h075: keyData[6:0] <= 7'h5B;
			  9'h076: keyData[6:0] <= 7'h35;
			  9'h077: keyData[6:0] <= 7'h47;
			  9'h078: keyData[6:0] <= 7'h67;
			  9'h079: keyData[6:0] <= 7'h45;
			  9'h07a: keyData[6:0] <= 7'h55;
			  9'h07b: keyData[6:0] <= 7'h4E;
			  9'h07c: keyData[6:0] <= 7'h43;
			  9'h07d: keyData[6:0] <= 7'h5C;
			  9'h083: keyData[6:0] <= 7'h62;
			  9'h111: keyData[6:0] <= 7'h37;
			  9'h11f: keyData[6:0] <= 7'h3A;
			  9'h14a: keyData[6:0] <= 7'h4B;
			  9'h15a: keyData[6:0] <= 7'h4C;
			  9'h169: keyData[6:0] <= 7'h77;
			  9'h16b: keyData[6:0] <= 7'h3B;
			  9'h16c: keyData[6:0] <= 7'h73;
			  9'h170: keyData[6:0] <= 7'h72;
			  9'h171: keyData[6:0] <= 7'h75;
			  9'h172: keyData[6:0] <= 7'h3D;
			  9'h174: keyData[6:0] <= 7'h3C;
			  9'h175: keyData[6:0] <= 7'h3E;
			  9'h17a: keyData[6:0] <= 7'h79;
			  9'h17c: keyData[6:0] <= 7'h69;
			  9'h17d: keyData[6:0] <= 7'h74;
			  9'h17e: keyData[6:0] <= 7'h71;
				default: keyData[6:0] <= 7'h7F;
				endcase
				keyData[7] <= ~press;
				if (capslock_key) begin key_pending <= press; keyData[7] <= capslock; end
			end

			if (key_pending && keyData[6:0] != 7'h7F && kbdFifoWr + 3'd1 != kbdFifoRd) begin
				kbdFifo[kbdFifoWr] <= keyData;
				kbdFifoWr <= kbdFifoWr + 3'd1;
			end

			if (mouse_edge) begin
				mouse_inputs <= mouse_inputs + 1'b1;
				mstb_d <= mstb_s3;
				if (mX_s2 != 9'd0 || mY_s2 != 9'd0 || mBtn_s2 != mouseButton) begin

					mouseX <= mouse_x_next; mouseY <= mouse_y_next;
					mouse_event_id <= !mouse_event_id;
					mouseButton <= mBtn_s2;
					mouse_evt   <= 1'b1;
				end
			end

			case (st)
			S_IDLE: begin
				dev_line <= 1'b1;
				if (rise && (dur > T_ATTN)) begin
					st <= S_ATTN; command <= 0; bitcnt <= 0;
				end
			end
			S_ATTN: begin
				if (fall) begin st <= S_BITS; command <= 0; bitcnt <= 0; end
			end
			S_BITS: begin
				if (fall) begin
					command <= {command[6:0], (dur > T_BITTH)};
					bitcnt  <= bitcnt + 4'd1;
					if (bitcnt == 4'd7) st <= S_TSTOP;
				end
			end
			S_TSTOP: begin
				last_command <= command;
				if (cmd_addr == mouse_addr && cmd_type == 3 && cmd_reg == 0)
					mouse_talks <= mouse_talks + 1'b1;
				resp_len <= 0; kbd_pop <= 0; mouse_pop <= 0;
				listen_r3 <= cmd_type == 2'b10 && cmd_reg == 3 &&
				    (cmd_addr == kbd_addr || cmd_addr == mouse_addr);
				lrx_target <= cmd_addr == mouse_addr;
				if (command == 0) begin
					kbd_addr <= ADDR_KBD; mouse_addr <= ADDR_MOUSE;
					kbd_srq <= 1; mouse_srq <= 1;
					kbd_collision <= 0; mouse_collision <= 0;
					kbdFifoRd <= kbdFifoWr; mouse_evt <= 0; mouse_init <= 1;
					mouseX <= 0; mouseY <= 0;
				end else if (cmd_type == 0 && cmd_reg == 1) begin
					if (cmd_addr == kbd_addr) kbdFifoRd <= kbdFifoWr;
					if (cmd_addr == mouse_addr) begin mouse_evt <= 0; mouseX <= 0; mouseY <= 0; end
				end else if (cmd_type == 3) begin
					if (cmd_addr == kbd_addr) begin
						case (cmd_reg)
						3: begin resp0 <= {2'b01,kbd_srq,1'b0,random_id}; resp1 <= 2; resp_len <= 2; end
						2: begin resp0 <= 8'hFF; resp1 <= 8'hFF; resp_len <= 2; end
						0: if (!kbdFifoEmpty) begin
							resp0 <= kbdFifo[kbdFifoRd];
							if (kbdFifoRd + 3'd1 != kbdFifoWr) begin
								resp1 <= kbdFifo[kbdFifoRd + 3'd1]; kbd_pop <= 2;
							end else begin resp1 <= 8'hFF; kbd_pop <= 1; end
							resp_len <= 2;
						end
						default: ;
						endcase
					end else if (cmd_addr == mouse_addr) begin
						case (cmd_reg)
						3: begin resp0 <= {2'b01,mouse_srq,1'b0,random_id}; resp1 <= 1; resp_len <= 2; end
						0: if (mouse_evt || mouse_init) begin
							resp0 <= {~mouseButton,mouse_delta(mouseY)};
							resp1 <= {1'b1,mouse_delta(mouseX)};
							mouse_send_x <= mouse_delta(mouseX); mouse_send_y <= mouse_delta(mouseY);
							mouse_report_id <= mouse_event_id;
							resp_len <= 2; mouse_pop <= 1;
						end
						default: ;
						endcase
					end
				end
				// Extend the command stop low; never start SRQ after its rising edge.
				if (cmd_type == 3 && srq_want) begin
					dev_line <= 0; sendtmr <= D_SRQ; st <= S_SRQ;
				end else st <= S_STOP_WAIT;
			end
			S_STOP_WAIT: if (rise) begin
				if (listen_r3) begin st <= S_LRX_WAIT; lrx_sr <= 0; bitcnt <= 0; end
				else begin st <= S_T1T; sendtmr <= D_T1T; end
			end
			S_SRQ: begin
				if (sendtmr != 0) sendtmr <= sendtmr - 18'd1;
				else begin dev_line <= 1; st <= S_STOP_WAIT; end
			end
			S_T1T: begin
				if (sendtmr != 0) sendtmr <= sendtmr - 18'd1;
				else if (resp_len == 0) begin st <= S_IDLE; dev_line <= 1'b1; end
				else begin
					st <= S_SEND; send_stage <= 0; send_byte <= 0;
					send_sr <= resp0; send_bits <= 4'd8;
					dev_line <= 1'b0; sendtmr <= D_SHORT;
				end
			end
			S_SEND: begin
				if (dev_line && !host_line) begin
					dev_line <= 1; st <= S_IDLE;
					if (cmd_addr == kbd_addr) kbd_collision <= 1;
					else mouse_collision <= 1;
				end else if (sendtmr != 0) sendtmr <= sendtmr - 18'd1;
				else case (send_stage)
					4'd0: begin dev_line <= 1'b1; sendtmr <= D_LONG; send_stage <= 4'd1; end
					4'd1: begin cur_bit <= send_sr[7]; dev_line <= 1'b0;
						sendtmr <= send_sr[7] ? D_SHORT : D_LONG; send_stage <= 4'd2; end
					4'd2: begin dev_line <= 1'b1; sendtmr <= cur_bit ? D_LONG : D_SHORT; send_stage <= 4'd3; end
					4'd3: begin
						if (send_bits == 4'd1) begin
							if (send_byte + 2'd1 < resp_len) begin
								send_byte <= send_byte + 2'd1; send_sr <= resp1; send_bits <= 4'd8;
								cur_bit <= resp1[7]; dev_line <= 1'b0;
								sendtmr <= resp1[7] ? D_SHORT : D_LONG; send_stage <= 4'd2;
							end else begin
								dev_line <= 1'b0; sendtmr <= D_STOP; send_stage <= 4'd4;
							end
						end else begin
							send_sr <= {send_sr[6:0],1'b0}; send_bits <= send_bits - 4'd1;
							cur_bit <= send_sr[6]; dev_line <= 1'b0;
							sendtmr <= send_sr[6] ? D_SHORT : D_LONG; send_stage <= 4'd2;
						end
					end
					4'd4: begin
						dev_line <= 1; sendtmr <= D_LONG; send_stage <= 5;
						kbdFifoRd <= kbdFifoRd + {1'b0,kbd_pop};
						if (cmd_addr == kbd_addr) kbd_collision <= 0;
						else mouse_collision <= 0;
						if (mouse_pop) begin
							mouse_replies <= mouse_replies + 1'b1;
							last_mouse_reply <= {resp0,resp1};
							mouseX <= mouse_x_next - {{9{mouse_send_x[6]}},mouse_send_x};
							mouseY <= mouse_y_next - {{9{mouse_send_y[6]}},mouse_send_y};
							mouse_evt <= mouse_edge || mouse_event_id != mouse_report_id ||
							    mouse_x_next != {{9{mouse_send_x[6]}},mouse_send_x} ||
							    mouse_y_next != {{9{mouse_send_y[6]}},mouse_send_y};
							mouse_init <= 0;
						end
					end
					default: begin dev_line <= 1'b1; st <= S_IDLE; end
				endcase
			end

			S_LRX_WAIT: begin
				if (rise && (dur > T_ATTN)) begin st <= S_ATTN; command <= 0; bitcnt <= 0; end
				else if (fall) st <= S_LRX_START;
			end
			S_LRX_START: begin
				if (rise && (dur > T_ATTN)) begin st <= S_ATTN; command <= 0; bitcnt <= 0; end
				else if (fall) begin st <= S_LRX_BITS; bitcnt <= 4'd0; end
			end
			S_LRX_BITS: begin
				if (rise && (dur > T_ATTN)) begin st <= S_ATTN; command <= 0; bitcnt <= 0; end
				else if (fall) begin
					lrx_sr <= {lrx_sr[14:0], (dur > T_BITTH)};
					bitcnt <= bitcnt + 4'd1;
					if (bitcnt == 4'd15) st <= S_LRX_DONE;
				end
			end
			S_LRX_DONE: begin
				if (lrx_target) debug_mouse_listen <= lrx_sr;
				if (lrx_sr[11:8] != 0 && (lrx_sr[7:0] == 0 ||
				    (lrx_sr[7:0] == 8'hFE && !(lrx_target ? mouse_collision : kbd_collision)))) begin
					if (lrx_target) begin
						mouse_addr <= lrx_sr[11:8];
						if (lrx_sr[7:0] == 0) mouse_srq <= lrx_sr[13];
					end else begin
						kbd_addr <= lrx_sr[11:8];
						if (lrx_sr[7:0] == 0) kbd_srq <= lrx_sr[13];
					end
				end
				st <= S_IDLE; dev_line <= 1;
			end
			default: st <= S_IDLE;
			endcase
			if (dev_line && rise && dur >= T_RESET) begin
				kbd_addr <= ADDR_KBD; mouse_addr <= ADDR_MOUSE;
				kbd_srq <= 1; mouse_srq <= 1;
				kbd_collision <= 0; mouse_collision <= 0;
				kbdFifoRd <= kbdFifoWr; mouse_evt <= 0; mouse_init <= 1;
				mouseX <= 0; mouseY <= 0;
				st <= S_IDLE; dev_line <= 1;
			end else if (dev_line && rise && dur > T_ATTN) begin
				st <= S_ATTN; command <= 0; bitcnt <= 0;
			end else if (st != S_IDLE && st != S_SEND && st != S_SRQ && dur > T_TIMEOUT) begin
				st <= S_IDLE; dev_line <= 1;
			end
		end
	end

endmodule
