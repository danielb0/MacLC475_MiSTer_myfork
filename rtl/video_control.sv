module video_control (
    input clk_sys,
    input clk_vid,
    input [6:0] control,
    output reg [6:0] control_v = 0
);
reg [6:0] control_hold = 0;
reg control_toggle = 0, control_seen = 0;
reg control_meta = 0, control_sync = 0;
reg ack_meta = 0, ack_sync = 0;

// Hold each menu update until the pixel domain acknowledges it.
always @(posedge clk_sys) begin
    ack_meta <= control_seen;
    ack_sync <= ack_meta;
    if (control_toggle == ack_sync && control_hold != control) begin
        control_hold <= control;
        control_toggle <= ~control_toggle;
    end
end
always @(posedge clk_vid) begin
    control_meta <= control_toggle;
    control_sync <= control_meta;
    if (control_sync != control_seen) begin
        control_v <= control_hold;
        control_seen <= control_sync;
    end
end
endmodule
