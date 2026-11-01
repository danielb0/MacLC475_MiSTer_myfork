module cuda_board #(
    parameter integer CLK_HZ = 25_000_000,
    parameter HOST_STORAGE = 0,
    parameter ROM_FILE = "local/software/cuda341s0788.hex"
) (
    input clk,
    input power_reset_n,
    input ce,
    input [32:0] timestamp,
    input pram_h_we,
    input [6:0] pram_h_addr,
    input [15:0] pram_h_wdata,
    output [15:0] pram_h_rdata,
    output pram_wr_stb,
    output storage_ready,
    input tip,
    input tack,
    input via_data_release,
    input adb_device_release,
    input adb_power_n,
    input fast_reset_n,
    input external_reset_n,
    input external_nmi_n,
    input iic_data_release,
    output adb_line,
    output treq,
    output via_clock,
    output via_data,
    output reset_n,
    output nmi_n,
    output iic_data,
    output iic_clock
);

wire [7:0] pa, pb, pa_ddr, pb_ddr;
wire [3:0] pc, pc_ddr;
// Primus sheet 12: PB0, PC1 and IRQ* share +5V_SENSE; main power is present.
wire power_sense = 1'b1;
// Primus sheet 12: PA7 drives Q1; PA6 senses its collector.
assign adb_line = adb_device_release && !(pa_ddr[7] && pa[7]);
assign treq = !pb_ddr[1] || pb[1];
assign via_clock = !pb_ddr[4] || pb[4];
assign via_data = via_data_release && (!pb_ddr[5] || pb[5]);
assign reset_n = external_reset_n && (!pc_ddr[3] || pc[3]);
assign nmi_n = external_nmi_n && (!pc_ddr[2] || pc[2]);
assign iic_data = iic_data_release && (!pb_ddr[6] || pb[6]);
assign iic_clock = !pb_ddr[7] || pb[7];

cuda_mcu #(.CLK_HZ(CLK_HZ), .HOST_STORAGE(HOST_STORAGE), .ROM_FILE(ROM_FILE)) mcu (
    .clk(clk), .nreset(power_reset_n), .ce(ce),
    .timestamp(timestamp), .pram_h_we(pram_h_we), .pram_h_addr(pram_h_addr),
    .pram_h_wdata(pram_h_wdata), .pram_h_rdata(pram_h_rdata),
    .pram_wr_stb(pram_wr_stb), .storage_ready(storage_ready),
    .pa_in({1'b0, adb_line, 2'b11, fast_reset_n, adb_power_n, 2'b11}),
    .pb_in({iic_clock, iic_data, via_data, via_clock, tip, tack, treq, power_sense}),
    .pc_in({reset_n, nmi_n, power_sense, 1'b1}), .irq_n(power_sense),
    .pa_out(pa), .pb_out(pb), .pc_out(pc),
    .pa_ddr(pa_ddr), .pb_ddr(pb_ddr), .pc_ddr(pc_ddr),
    .cpu_tick(), .cpu_addr(), .cpu_state(), .stopped(), .waiting()
);

endmodule
