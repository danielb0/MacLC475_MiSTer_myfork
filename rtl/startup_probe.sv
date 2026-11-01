module startup_probe (
    input clk,
    input nreset,
    input ce,
    input [31:0] pc, // opcode address, not the fetch cursor
    input [15:0] ir,
    input [63:0] test_status,
    output reg [63:0] error_status,
    output reg [7:0] flags
);

reg [2:0] timeout_stage;

// Native FF7439EE ROM: Error1Handler and TMEntry1, before sound playback.
always @(posedge clk) begin
    if (!nreset) begin
        error_status <= 0;
        flags <= 0;
        timeout_stage <= 0;
    end else if (ce) begin
        // Unconditional CUDA timeout branches; the shared exit also serves sends.
        if (!flags[0] && timeout_stage == 0) begin
            if (pc == 32'h408A9FAA && ir == 16'h60FF) timeout_stage <= 1;
            if (pc == 32'h408A9FD6 && ir == 16'h60FF) timeout_stage <= 2;
            if (pc == 32'h408A9FF4 && ir == 16'h60FF) timeout_stage <= 3;
            if (pc == 32'h408AA0EC && ir == 16'h7E30) timeout_stage <= 4;
            if (pc == 32'h40814DD4 && ir == 16'h3E3C) timeout_stage <= 5;
        end
        if (!flags[0] && pc == 32'h4084AA4A && ir == 16'h3E7C) begin
            error_status <= test_status;
            flags[0] <= 1;
            flags[2] <= test_status[26];
            flags[4] <= test_status[24];
            if (test_status[15:0] == 16'h0030) flags[7:5] <= timeout_stage;
        end
        if (!flags[1] && pc == 32'h408B98BC && ir == 16'h7400) begin
            flags[1] <= 1;
            flags[3] <= test_status[26];
        end
    end
end

endmodule
