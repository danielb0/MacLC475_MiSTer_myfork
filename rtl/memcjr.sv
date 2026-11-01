module memcjr #(
    parameter integer CLK_HZ = 25_000_000
) (
    input clk,
    input nreset,
    input ce,
    input sel,
    input write,
    input [12:2] addr,
    input [3:0] be,
    input [31:0] wdata,
    output reg ack,
    output reg [31:0] rdata,

    input video_read,
    input video_write,
    input [11:0] video_rdata,
    input [5:0] video_wdata,
    output [11:0] video_data,
    output [49:0] bank_base,
    output [4:0] bank_mode,
    output reg [9:0] memory_top
);

reg [5:0] holding;
reg [10:0] bank [0:4];
reg [9:0] config_r, refresh_interval;
reg [4:0] test_r;
reg [11:0] reg_data;
wire [11:0] write_data = {holding, wdata[5:0]};
assign video_data = {holding, video_wdata};

genvar b;
generate for (b = 0; b < 5; b = b + 1) begin : g_bank
    assign bank_base[b*10 +: 10] = bank[b][9:0];
    assign bank_mode[b] = bank[b][10];
end endgenerate

always @* begin
    reg_data = 0;
    case (addr)
        11'h000: reg_data = 12'h420;
        11'h001: reg_data = {1'b0, bank[0]};
        11'h002: reg_data = {1'b0, bank[1]};
        11'h003: reg_data = {1'b0, bank[2]};
        11'h004: reg_data = {1'b0, bank[3]};
        11'h005: reg_data = {1'b0, bank[4]};
        11'h006, 11'h007, 11'h008, 11'h009, 11'h00A: reg_data = 12'hFFF;
        11'h00B: reg_data = {2'd0, memory_top};
        11'h00C: reg_data = {2'd0, config_r};
        11'h00D: reg_data = {2'd0, refresh_interval};
        11'h00E: reg_data = {7'd0, test_r};
        11'h01F: reg_data = {6'd0, holding};
        default: ;
    endcase
end

always @(posedge clk) begin
    ack <= 0;
    if (!nreset) begin
        holding <= 0;
        bank[0] <= 11'h000;
        bank[1] <= 11'h040;
        bank[2] <= 11'h080;
        bank[3] <= 11'h0C0;
        bank[4] <= 11'h100;
        memory_top <= 10'h3FF;
        config_r <= 10'h00F | ((CLK_HZ >= 33_000_000) ? 10'h040 : 10'h000);
        refresh_interval <= 10'h081;
        test_r <= 0;
        rdata <= 0;
    end else if (ce) begin
        if (video_read) holding <= video_rdata[11:6];
        // MAME's MEMCjr model clears the holding latch after a video write.
        if (video_write) holding <= 0;
        if (sel && !ack) begin
            ack <= 1;
            rdata <= {26'd0, reg_data[5:0]};
            if (!write && addr != 11'h01F) holding <= reg_data[11:6];
            if (write && be[0]) begin
                if (addr == 11'h01F) holding <= wdata[5:0];
                else begin
                    case (addr)
                        11'h001: bank[0] <= {write_data[10], 10'd0};
                        11'h002: bank[1] <= write_data[10:0];
                        11'h003: bank[2] <= write_data[10:0];
                        11'h004: bank[3] <= write_data[10:0];
                        11'h005: bank[4] <= write_data[10:0];
                        11'h00B: memory_top <= write_data[9:0];
                        11'h00C: config_r <= (write_data[9:0] & 10'h39F) |
                            ((CLK_HZ >= 33_000_000) ? 10'h040 : 10'h000);
                        11'h00D: refresh_interval <= write_data[9:0];
                        11'h00E: test_r <= write_data[4:0];
                        default: ;
                    endcase
                end
            end
        end
    end
end

endmodule
