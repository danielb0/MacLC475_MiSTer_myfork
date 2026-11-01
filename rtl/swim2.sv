// Staged SWIM II register interface. sel pulses once per completed bus access.
module swim2 (
    input        clk,
    input        nreset,
    input        ce,
    input        sel,
    input        write,
    input  [2:0] addr,
    input  [7:0] wdata,
    output [7:0] rdata,
    input  [3:0] phase_in,
    input  [7:0] zero_count,
    input        rddata,
    input        sense,
    input        context_changed,
    input        rx_valid,
    input  [7:0] rx_data,
    input        rx_mark,
    input        rx_crc_zero,
    input  [4:0] rx_sector,
    input        rx_short,
    input        rx_long,
    input        tx_take,
    input        tx_fault,
    output [7:0] tx_data,
    output       tx_mark,
    output       tx_crc,
    output       tx_valid,
    output [3:0] phase_out,
    output [3:0] phase_oe,
    output [7:0] setup,
    output [7:0] mode,
    output [3:0] write_late,    // 7 is nominal; one clock per count
    output [3:0] write_early,
    output [4:0] write_sector,
    output       write_sector_valid
);

wire [7:0] control_rdata, data_rdata, handshake;
wire write_error;
reg [1:0] param_index;
reg [7:0] param_ram [0:3];
integer i;

assign rdata = addr[2] ? control_rdata :
               (addr == 3 ? param_ram[param_index] : data_rdata);
assign write_late = param_ram[0][7:4];
assign write_early = param_ram[2][7:4];

// ERS pp. 6-7: only the late/early high nibbles affect write timing.
// TODO: Qualify full-byte parameter readback and reset values on Q605.
// Time0 is fixed and Time1 unused; neither feeds the codec timing.
always @(posedge clk) begin
    if (!nreset) begin
        param_index <= 0;
        for (i = 0; i < 4; i = i + 1) param_ram[i] <= 0;
    end else if (ce && sel) begin
        if (write && addr == 6) param_index <= 0;
        else if (addr == 3) begin
            if (write) param_ram[param_index] <= wdata;
            param_index <= param_index + 2'd1;
        end
    end
end

swim2_control control (
    .clk(clk), .nreset(nreset), .ce(ce), .sel(sel && addr[2]), .write(write),
    .addr(addr[1:0]), .wdata(wdata), .rdata(control_rdata),
    .phase_in(phase_in), .zero_count(zero_count), .handshake(handshake),
    .write_error(write_error), .phase_out(phase_out), .phase_oe(phase_oe),
    .setup(setup), .mode(mode)
);

swim2_data data_path (
    .clk(clk), .nreset(nreset), .ce(ce), .sel(sel && addr <= 2), .write(write),
    .addr(addr[1:0]), .wdata(wdata), .rdata(data_rdata), .mode(mode), .gcr(setup[2]),
    .rddata(rddata), .sense(sense), .context_changed(context_changed),
    .rx_valid(rx_valid), .rx_data(rx_data),
    .rx_mark(rx_mark), .rx_crc_zero(rx_crc_zero), .rx_short(rx_short),
    .rx_sector(rx_sector), .write_sector(write_sector), .write_sector_valid(write_sector_valid),
    .rx_long(rx_long), .tx_take(tx_take), .tx_fault(tx_fault), .tx_data(tx_data), .tx_mark(tx_mark),
    .tx_crc(tx_crc), .tx_valid(tx_valid), .handshake(handshake), .write_error(write_error)
);

endmodule
