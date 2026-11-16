// Apple 343S0164-A, table 18; Primus schematic, sheet 5.
// Return {populated, SDRAM longword address}. RAS selects the physical bank;
// row/column pins use the CPU address, not an offset from its programmed base.
function automatic [30:0] ram_map;
	input [31:2] a;
	reg [11:0] row, col;
	reg [23:0] cell_addr;
	reg [29:0] backing;
	reg present, mode;
	integer n, selected;
	begin
		selected = -1;
		for (n = 0; n < 4; n = n + 1) begin
			if (a[29:20] >= memc_bank_base[n*10 +: 10] &&
			    a[29:20] < memc_bank_base[(n+1)*10 +: 10])
				selected = n;
		end
		if (a[29:20] >= memc_bank_base[40 +: 10]) selected = 4;
		present = (a[31:30] == 0) && (a[29:20] <= memc_memory_top);
		mode = 0;
		if (selected >= 0) mode = memc_bank_mode[selected];
		else present = 0;
		row = mode ? {a[23:22], a[20:11]} : {a[21:20], a[10], a[19:11]};
		col = mode ? {a[24:23], a[21], a[10:2]} : {a[24:23], a[25], a[22], a[9:2]};
		cell_addr = 0;
		backing = 0;
		if (selected == 0) begin
			cell_addr = {4'd0, row[9:0], col[9:0]};
		end else if (selected == 1 || selected == 2) begin
			// Representative x4 SIMMs: one or two 1/4/16 MB ranks, one 64 MB
			// rank (12x12, 16M x4 parts), or a 96 MB "tweener" with a 64 MB
			// rank 1 and a 32 MB rank 2.  The 64 MB rank lives in the top half
			// of a 128 MB SDRAM module, clear of the floppy image at 36 MB;
			// the 32 MB rank sits below the image.
			case (ram_cfg)
				4'd1, 4'd2: begin
					cell_addr = {6'd0, row[8:0], col[8:0]};
					backing = (selected == 1) ? 30'h0100000 : 30'h0140000;
				end
				4'd3, 4'd4: begin
					cell_addr = {4'd0, row[9:0], col[9:0]};
					backing = (selected == 1) ? 30'h0100000 : 30'h0200000;
				end
				4'd5, 4'd6: begin
					cell_addr = {2'd0, row[10:0], col[10:0]};
					backing = (selected == 1) ? 30'h0100000 : 30'h0500000;
				end
				4'd7: begin
					cell_addr = {row[11:0], col[11:0]};
					backing = 30'h1000000;
				end
				4'd8: begin
					if (selected == 1) begin
						cell_addr = {row[11:0], col[11:0]};
						backing = 30'h1000000;
					end else begin
						// Mod-32 MB decode: the ROM places this rank at 68 MB, so
						// it spans a 32 MB boundary and must ignore A25.
						cell_addr = {1'b0, a[24:2]};
						backing = 30'h0100000;
					end
				end
				default: present = 0;
			endcase
			if (selected == 2 && ram_cfg != 4'd2 && ram_cfg != 4'd4 &&
			    ram_cfg != 4'd6 && ram_cfg != 4'd8)
				present = 0;
		end else present = 0;
		ram_map = {present, backing + {6'd0, cell_addr}};
	end
endfunction
