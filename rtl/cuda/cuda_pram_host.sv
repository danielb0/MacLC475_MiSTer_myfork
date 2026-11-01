module cuda_pram_host #(parameter integer SYS_CLK_HZ = 25_000_000) (
    input clk,
    input power_reset_n,
    input img_mounted,
    input [63:0] img_size,
    input OSD_STATUS,
    input pram_ack,
    input [12:0] sd_buff_addr,
    input sd_buff_wr,
    input pram_wr_stb,
    output reg pram_rd = 0,
    output reg pram_wr = 0,
    output pram_h_we,
    output [6:0] pram_h_addr,
    output reg pram_ready = 0,
    output reg pram_force_reset = 0
 );

localparam [2:0] P_IDLE = 3'd0, P_LD_RD = 3'd1, P_LD_KICK = 3'd2, P_LD_DAT = 3'd3,
                 P_SV_WR = 3'd4, P_SV_DAT = 3'd5, P_RST = 3'd6;
reg   [2:0] pst = P_IDLE;
// the load's words go into the CUDA PRAM as they arrive (words 128+ are the pad)
assign pram_h_we = (pst == P_LD_DAT) && pram_ack && sd_buff_wr && (sd_buff_addr[12:7] == 6'd0);
assign pram_h_addr = sd_buff_addr[6:0];
reg         pram_ena = 0;              // an image is mounted (size != 0)
reg         pram_dirty = 0;            // the guest wrote PRAM since the last save
reg         pram_load_pending = 0, pram_flush_pending = 0;
// the three timers count milliseconds from one shared prescaler
reg  [15:0] pram_ms_div = 0;
wire        pram_ms = (pram_ms_div == SYS_CLK_HZ / 1000 - 1);
reg  [11:0] pram_settle = 0;           // eager-flush settle timer
reg  [11:0] pram_ld_wd = 0;            // load watchdog
reg   [1:0] pram_ld_try = 0;
reg  [11:0] pram_rdy_cnt = 0;          // ready backstop
reg   [6:0] pram_rst_hold = 0;
reg         old_pack = 0, old_osd = 0, old_pmnt = 0;
localparam [11:0] PRAM_SETTLE  = 12'd2000;   // ms
localparam [11:0] PRAM_LD_WD   = 12'd2000;   // ms per load attempt
localparam [11:0] PRAM_RDY_MAX = 12'd3000;   // ms backstop

always @(posedge clk) begin
	if (!power_reset_n) begin
		pst <= P_IDLE; pram_rd <= 0; pram_wr <= 0;
		pram_ena <= 0; pram_dirty <= 0; pram_ready <= 0; pram_force_reset <= 0;
		pram_load_pending <= 0; pram_flush_pending <= 0;
		pram_ms_div <= 0;
		pram_settle <= 0; pram_ld_wd <= 0; pram_ld_try <= 0; pram_rdy_cnt <= 0;
		pram_rst_hold <= 0; old_pack <= 0; old_osd <= 0; old_pmnt <= 0;
	end
	else begin
		old_pack <= pram_ack;
		old_osd  <= OSD_STATUS;
		old_pmnt <= img_mounted;
		pram_ms_div <= pram_ms ? 16'd0 : pram_ms_div + 1'b1;

		if (pram_wr_stb) pram_dirty <= 1'b1;

		if (img_mounted && !old_pmnt) begin
			pram_ena <= (img_size != 0);
			if (img_size != 0) pram_load_pending <= 1'b1;
			else               pram_ready        <= 1'b1;   // no image: boot on defaults now
		end
		if (OSD_STATUS && !old_osd && pram_dirty && pram_ena) pram_flush_pending <= 1'b1;
		if (pram_wr_stb)                 pram_settle <= PRAM_SETTLE;
		else if (pram_ms && pram_settle > 12'd1) pram_settle <= pram_settle - 1'b1;
		else if (pram_ms && pram_settle == 12'd1) begin
			pram_settle <= 12'd0;
			if (pram_dirty && pram_ena) pram_flush_pending <= 1'b1;
		end
		if (!pram_ready && pram_ms) begin
			if (pram_rdy_cnt >= PRAM_RDY_MAX) pram_ready <= 1'b1;
			else pram_rdy_cnt <= pram_rdy_cnt + 1'b1;
		end
		if (pram_force_reset) begin
			if (pram_rst_hold == 0) pram_force_reset <= 1'b0;
			else pram_rst_hold <= pram_rst_hold - 1'b1;
		end

		case (pst)
		P_IDLE:
			if (pram_load_pending) begin
				pram_load_pending <= 0; pram_rd <= 1'b1;
				pram_ld_wd <= 0; pram_ld_try <= 0; pst <= P_LD_RD;
			end
			else if (pram_flush_pending) begin
				// a guest write from here on makes the image dirty again and
				// schedules another save after it settles
				pram_flush_pending <= 0; pram_dirty <= 0;
				pram_wr <= 1'b1; pst <= P_SV_WR;
			end

		// ---- LOAD: one sector, straight into the CUDA PRAM ----
		P_LD_RD:
			if (pram_ack) begin pram_rd <= 1'b0; pram_ld_wd <= 0; pst <= P_LD_DAT; end
			else if (pram_ld_wd == PRAM_LD_WD) begin
				pram_ld_wd <= 0;
				if (pram_ld_try == 2'd3) begin      // give up: boot on defaults
					pram_rd <= 1'b0; pram_ready <= 1'b1; pst <= P_IDLE;
				end
				else begin                          // drop and re-arm the request
					pram_ld_try <= pram_ld_try + 1'b1;
					pram_rd <= 1'b0; pst <= P_LD_KICK;
				end
			end
			else if (pram_ms) pram_ld_wd <= pram_ld_wd + 1'b1;
		P_LD_KICK: begin pram_rd <= 1'b1; pst <= P_LD_RD; end
		P_LD_DAT:
			if (old_pack && !pram_ack) begin
				pram_dirty <= 0; pram_ena <= 1'b1;
				// landed after the machine was released: restart it on the
				// loaded PRAM (a manual mount-then-reset, automated)
				if (pram_ready) pst <= P_RST;
				else begin pram_ready <= 1'b1; pst <= P_IDLE; end
			end
			else if (pram_ld_wd == PRAM_LD_WD) begin
				pram_ld_wd <= 0; pram_ready <= 1'b1; pst <= P_IDLE;   // wedged ack: boot as-is
			end
			else if (pram_ms) pram_ld_wd <= pram_ld_wd + 1'b1;

		// ---- SAVE: the CUDA PRAM read out through the host port ----
		P_SV_WR:  if (pram_ack) begin pram_wr <= 1'b0; pst <= P_SV_DAT; end
		P_SV_DAT: if (old_pack && !pram_ack) pst <= P_IDLE;

		P_RST: begin pram_force_reset <= 1'b1; pram_rst_hold <= 7'd127; pst <= P_IDLE; end
		default: pst <= P_IDLE;
		endcase
	end
end

endmodule
