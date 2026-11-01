module video_probe #(
    parameter WINDOW_BITS = 22,
    parameter TIMEOUT_BITS = 20,
    parameter HEARTBEAT_BITS = 8
) (
    input clk,
    input clk_vid,
    input de,
    input [23:0] rgb,
    input enable,
    input osd_open,
    input pll_locked,
    input settling,
    input video_reset_n,
    input machine_reset,
    input halted,
    output reg request = 0,
    output reg [3:0] result = 0
);
reg [HEARTBEAT_BITS-1:0] heartbeat = 0;
reg de_old = 0, de_toggle = 0;
reg color_line = 0, color_toggle = 0;
always @(posedge clk_vid) begin
    heartbeat <= heartbeat + 1'b1;
    de_old <= de;
    if (de && !de_old) de_toggle <= ~de_toggle;
    if (de && |rgb) color_line <= 1;
    if (!de && de_old) begin
        if (color_line) color_toggle <= ~color_toggle;
        color_line <= 0;
    end
end
reg heartbeat_meta = 0, heartbeat_sync = 0, heartbeat_old = 0;
reg de_meta = 0, de_sync = 0, de_seen_old = 0, de_seen = 0;
reg color_meta = 0, color_sync = 0, color_old = 0, color_seen = 0;
reg [TIMEOUT_BITS:0] idle = 0;
reg [WINDOW_BITS-1:0] window = 0;
reg enable_old = 0;
reg osd_meta = 0, osd_sync = 0, pending = 0;
reg reset_meta = 0, reset_sync = 0;
reg [3:0] report = 0;
always @* begin
    if (idle[TIMEOUT_BITS]) report = 1;
    else if (!pll_locked) report = 2;
    else if (settling) report = 3;
    else if (!reset_sync) report = 4;
    else if (!de_seen) report = 5;
    else if (machine_reset) report = 6;
    else if (halted) report = 7;
    else if (!color_seen) report = 8;
    else report = 0;
end
always @(posedge clk) begin
    reset_meta <= video_reset_n;
    reset_sync <= reset_meta;
    osd_meta <= osd_open;
    osd_sync <= osd_meta;
    heartbeat_meta <= heartbeat[HEARTBEAT_BITS-1];
    heartbeat_sync <= heartbeat_meta;
    heartbeat_old <= heartbeat_sync;
    de_meta <= de_toggle;
    de_sync <= de_meta;
    de_seen_old <= de_sync;
    color_meta <= color_toggle;
    color_sync <= color_meta;
    color_old <= color_sync;
    if (heartbeat_sync != heartbeat_old) idle <= 0;
    else if (!idle[TIMEOUT_BITS]) idle <= idle + 1'b1;
    if (de_sync != de_seen_old) de_seen <= 1;
    if (color_sync != color_old) color_seen <= 1;
    window <= window + 1'b1;
    request <= 0;
    if (&window) begin
        result <= report;
        if (!enable) pending <= 0;
        else begin
            if (!enable_old || result != report || osd_sync) pending <= 1;
            if (pending && !osd_sync) begin
                request <= 1;
                pending <= 0;
            end
        end
        enable_old <= enable;
        de_seen <= 0;
        color_seen <= 0;
    end
end
endmodule
