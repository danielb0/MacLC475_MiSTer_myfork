`timescale 1ns/1ps
module tb_swim2_bus;
reg clk = 0;
always #20 clk = ~clk;
reg nreset = 0, ce = 1, sel = 0, write = 0;
reg [27:2] addr = 0;
reg [3:0] be = 0;
reg [31:0] wdata = 0;
wire [31:0] rdata;
wire ack, floppy_sel, floppy_write;
wire [2:0] floppy_addr;
wire [7:0] floppy_wdata, floppy_rdata;
integer checks = 0, accesses = 0, expected_accesses = 0, i, polls;
reg [31:0] got;
wire [35:0] EXT_BUS;
assign EXT_BUS[35:33] = 3'd0;
assign EXT_BUS[31:16] = 16'd0;

iosb #(.CDROM(0)) bus (
    .clk(clk), .nreset(nreset), .ce(ce), .cuda_power_reset_n(nreset), .cuda_host_reset_n(nreset),
    .sel(sel), .write(write), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .ack(ack),
    .floppy_sel(floppy_sel), .floppy_write(floppy_write), .floppy_addr(floppy_addr),
    .floppy_wdata(floppy_wdata), .floppy_rdata(floppy_rdata),
    .vbl_irq(1'b0), .sonic_irq(1'b0), .scsi_irq(1'b0), .scsi_drq(1'b0), .asc_irq(1'b0),
    .scc_rxd_a(1'b1), .scc_cts_a(1'b1), .scc_rxd_b(1'b1),
    .img_mounted(3'd0), .img_size(64'd0), .io_ack(3'd0), .sd_buff_addr(13'd0),
    .sd_buff_dout(16'd0), .sd_buff_wr(1'b0), .ps2_key(11'd0), .ps2_mouse(25'd0),
    .timestamp(33'd0), .pram_h_we(1'b0), .pram_h_addr(7'd0), .pram_h_wdata(16'd0),
    .stall_flt(1'b0), .berr_active(1'b0), .berr_addr(30'd0),
    .cuda_reset_n(), .cuda_storage_ready(), .sdma_fault(),
    .scc_txd_a(), .scc_rts_a(), .scc_txd_b(), .ipl_n(), .audio_l(), .audio_r(),
    .cd_snd_l(), .cd_snd_r(), .io_lba(), .io_rd(), .io_wr(), .io_blk_cnt(),
    .sd_buff_din(), .debug_adb_mouse(), .debug_adb_host(), .pram_h_rdata(), .pram_wr_stb()
);
swim2_platform chip (
    .clk(clk), .nreset(nreset), .guest_reset(!nreset), .init(!nreset),
    .sdram_sz(16'd0), .EXT_BUS(EXT_BUS), .sel(floppy_sel), .write(floppy_write),
    .addr(floppy_addr), .wdata(floppy_wdata), .rdata(floppy_rdata),
    .img_mounted(1'b0), .img_size(64'd0), .img_readonly(1'b0),
    .sd_lba(), .sd_rd(), .sd_wr(), .sd_ack(1'b0), .sd_buff_addr(13'd0),
    .sd_buff_dout(16'd0), .sd_buff_wr(1'b0), .sd_buff_din(), .fault(),
    .cpu_req(1'b0), .cpu_we(1'b0), .cpu_addr(25'd0), .cpu_be(4'd0), .cpu_wdata(32'd0),
    .cpu_ack(), .cpu_rdata(), .beat_req(), .beat_we(), .beat_addr(), .beat_be(), .beat_wdata(),
    .beat_ack(1'b0), .beat_rdata(32'd0), .beat_busy(1'b0), .beat_line_pending(1'b0)
);
always @(posedge clk) if (floppy_sel) accesses = accesses + 1;
task check(input [31:0] actual, input [31:0] expected);
    begin
        checks = checks + 1;
        if (actual !== expected) $fatal(1, "check %0d: got %08h expected %08h", checks, actual, expected);
    end
endtask
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
task beat(input [27:0] a, input wr, input [3:0] lanes, input [31:0] value, input hit);
    begin
        addr = a[27:2]; write = wr; be = lanes; wdata = value; sel = 1;
        ce = 0; repeat (3) begin cycle; check(ack, 0); check(floppy_sel, 0); end
        ce = 1; cycle; check(ack, 1); got = rdata;
        cycle; check(ack, 0); sel = 0; cycle;
        if (hit) expected_accesses = expected_accesses + 1;
        check(accesses, expected_accesses);
    end
endtask
task regbeat(input [2:0] regnum, input wr, input [3:0] lanes, input [31:0] value);
    begin beat(28'h001e000 + regnum * 512, wr, lanes, value, 1); end
endtask
task rombeat(input [12:0] offset, input wr, input [7:0] value);
    begin beat(28'h0f1e000 + offset, wr, 8, {value, 24'd0}, 1); end
endtask
initial begin
    repeat (3) cycle; nreset = 1; repeat (3) cycle;
    regbeat(5, 1, 8, 32'h25000000); regbeat(5, 0, 8, 0); check(got, 32'h25002500);
    regbeat(5, 1, 4, 32'h00160000); regbeat(5, 0, 4, 0); check(got, 32'h16001600);
    regbeat(5, 1, 2, 32'h00003700); regbeat(5, 0, 2, 0); check(got, 32'h37003700);
    regbeat(5, 1, 1, 32'h00000048); regbeat(5, 0, 1, 0); check(got, 32'h48004800);
    regbeat(5, 1, 12, 32'h125a0000); regbeat(5, 0, 12, 0); check(got, 32'h5a005a00);
    regbeat(5, 1, 3, 32'h00001269); regbeat(5, 0, 3, 0); check(got, 32'h69006900);
    // Mode-clear resets the parameter index. Held requests must advance it once.
    regbeat(6, 1, 8, 0);
    for (i = 0; i < 4; i = i + 1) regbeat(3, 1, 1, 32'h80 + i);
    for (i = 0; i < 4; i = i + 1) begin
        regbeat(3, 0, 8, 0); check(got, (32'h80 + i) * 32'h01000100);
    end
    // MiB mirrors and register bit 12 alias; adjacent/high windows do not select.
    beat(28'h0f1fa00, 0, 8, 0, 1); check(got, 32'h69006900);
    beat(28'h001c000, 1, 8, 32'h12000000, 0);
    beat(28'h101ea00, 1, 8, 32'h12000000, 0);
    regbeat(5, 0, 8, 0); check(got, 32'h69006900);
    nreset = 0; sel = 1; cycle; check(floppy_sel, 0);
    sel = 0; repeat (3) cycle; nreset = 1; repeat (3) cycle;
    // FF7439EE ROM $40871C08 calibrates FIFO writes without a disk or motor.
    rombeat('ha00, 1, 'h20); rombeat('hc00, 1, 'h86); rombeat('hc00, 1, 'h18);
    rombeat('he00, 1, 'h10); rombeat('he00, 1, 1); rombeat('hc00, 1, 1);
    rombeat('h1400, 0, 0); rombeat(0, 1, 20); rombeat(0, 1, 20);
    rombeat('he00, 1, 8);
    for (i = 20; i >= 0; i = i - 1) begin
        polls = 0;
        do begin
            rombeat('h1e00, 0, 0); polls = polls + 1;
            if (polls > 1000) $fatal(1, "ROM $40871C64 FIFO wait, mode=%02h", chip.mode);
            check(got[29], 0);
        end while (!got[31]);
        rombeat(0, 1, i[7:0]);
    end
    rombeat('hc00, 1, 'h18); rombeat('h1c00, 0, 0); check(got[28:27], 0);
    $display("PASS: SWIM II PrimeTime bus, %0d checks", checks);
    $finish;
end
initial begin #2000000; $fatal(1, "timeout"); end
endmodule
