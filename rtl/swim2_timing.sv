// LC media rotation and nominal SWIM II controller byte pacing.
module swim2_timing #(
    parameter integer CLK_HZ = 25_000_000
) (
    input clk,
    input nreset,
    input ce,
    input running,
    input gcr,
    input hd,
    input [6:0] track,
    input write_active,
    input write_div2,
    output byte_tick,
    output write_tick,
    output reg tach
);

wire drive_tick;
wire write_byte;
reg write_half;
reg write_div2_d;
wire write_clock_reset = !nreset || !write_active || write_div2 != write_div2_d;
reg [8:0] byte_count;
reg [14:0] tach_count;
reg [14:0] tach_limit;
reg [1:0] format_d;
wire [8:0] byte_limit = gcr ? 9'd127 : hd ? 9'd129 : 9'd259;
wire format_changed = format_d != {gcr, hd};

rate_enable #(.CLK_HZ(CLK_HZ), .RATE_HZ(8_125_000)) drive_rate (
    .clk(clk), .nreset(nreset && running && !format_changed), .ce(ce), .tick(drive_tick)
);

// Nominal decoded-byte timing; physical cell/precompensation timing is separate.
rate_enable #(.CLK_HZ(CLK_HZ), .RATE_HZ(62_500)) write_rate (
    .clk(clk), .nreset(!write_clock_reset), .ce(ce), .tick(write_byte)
);

assign byte_tick = drive_tick && running && !format_changed && byte_count == byte_limit;
assign write_tick = write_byte && (!write_div2 || write_half);

always @(posedge clk) begin
    if (!nreset) begin
        write_half <= 0;
        write_div2_d <= 0;
    end else begin
        write_div2_d <= write_div2;
        if (write_clock_reset) write_half <= 0;
        else if (write_byte) write_half <= !write_half;
    end
end

always @* begin
    if (!gcr) tach_limit = 15'd16660;
    else case (track[6:4])
        0: tach_limit = 15'd9996;
        1: tach_limit = 15'd9122;
        2: tach_limit = 15'd8292;
        3: tach_limit = 15'd7463;
        default: tach_limit = 15'd6634;
    endcase
end

always @(posedge clk) begin
    if (!nreset) begin
        byte_count <= 0;
        tach_count <= 0;
        tach <= 0;
        format_d <= 0;
    end else begin
        format_d <= {gcr, hd};
        if (!running || format_changed) begin
            byte_count <= 0;
            tach_count <= 0;
            tach <= 0;
        end else if (drive_tick) begin
            byte_count <= byte_tick ? 9'd0 : byte_count + 9'd1;
            if (tach_count >= tach_limit) begin
                tach_count <= 0;
                tach <= !tach;
            end else tach_count <= tach_count + 15'd1;
        end
    end
end

endmodule
