// SWIM2 ERS Rev. 3.2, pp. 7-10. Control registers only; no IWM mode.
module swim2_control (
    input        clk,
    input        nreset,
    input        ce,
    input        sel,
    input        write,
    input  [1:0] addr,          // registers 4-7
    input  [7:0] wdata,
    output reg [7:0] rdata,
    input  [3:0] phase_in,
    input  [7:0] zero_count,    // datapath test counter
    input  [7:0] handshake,
    input        write_error,
    output reg [3:0] phase_out,
    output reg [3:0] phase_oe,
    output reg [7:0] setup,
    output [7:0] mode
);

reg [7:0] mode_reg;
assign mode = mode_reg | 8'h40;

always @* begin
    case (addr)
        2'd0: rdata = setup[4] ? zero_count :
                      {phase_oe, (phase_out & phase_oe) | (phase_in & ~phase_oe)};
        2'd1: rdata = setup;
        2'd2: rdata = mode;
        2'd3: rdata = handshake;
    endcase
end

always @(posedge clk) begin
    if (!nreset) begin
        phase_out <= 0;
        phase_oe <= 4'hf;
        setup <= 0;
        mode_reg <= 0;
    end else if (ce) begin
        if (sel && write) begin
            case (addr)
                2'd0: begin
                    phase_out <= wdata[3:0];
                    phase_oe <= wdata[7:4];
                end
                2'd1: setup <= wdata & 8'h7f;
                2'd2: mode_reg <= mode_reg & ~wdata & 8'hbf;
                2'd3: mode_reg <= (mode_reg | wdata) & 8'hbf;
            endcase
        end
        // A write error stops action, including a coincident software set.
        if (write_error && mode_reg[4]) mode_reg[3] <= 0;
    end
end

endmodule
