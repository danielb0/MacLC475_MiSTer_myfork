// Adapted LC ism_write_engine: docs/imports.json. Decoded MFM bytes only.
module swim2_mfm_write (
    input        clk,
    input        nreset,
    input        ce,
    input        active,
    input        tick,
    input  [7:0] q_data,
    input        q_mark,
    input        q_crc,
    input        q_valid,
    output       q_take,
    output reg [7:0] data,
    output reg   mark,
    output reg   strobe
);

localparam [15:0] CRC_SEED = 16'hcdb4; // CRC of three A1 marks
reg [15:0] crc;
reg crc_second;

function [15:0] crc16(input [15:0] c, input [7:0] d);
    integer i;
    reg [15:0] next_crc;
    begin
        next_crc = c ^ {d, 8'd0};
        for (i = 0; i < 8; i = i + 1)
            next_crc = next_crc[15] ? (next_crc << 1) ^ 16'h1021 : next_crc << 1;
        crc16 = next_crc;
    end
endfunction

// An empty request reaches the FIFO so it can report underrun and stop ACTION.
// The second CRC byte does not consume another token, even with an empty FIFO.
assign q_take = ce && active && tick && !crc_second;

always @(posedge clk) begin
    strobe <= 0;
    if (!nreset) begin
        crc <= CRC_SEED;
        crc_second <= 0;
        data <= 0;
        mark <= 0;
    end else if (ce) begin
        if (!active) begin
            crc <= CRC_SEED;
            crc_second <= 0;
        end else if (tick) begin
            if (crc_second || (q_valid && q_crc)) begin
                data <= crc[15:8];
                mark <= 0;
                strobe <= 1;
                crc <= crc16(crc, crc[15:8]);
                crc_second <= !crc_second;
            end else if (q_valid) begin
                data <= q_data;
                mark <= q_mark;
                strobe <= 1;
                crc <= q_mark ? CRC_SEED : crc16(crc, q_data);
            end
        end
    end
end

endmodule
