// Adapted LC floppy_write_committer: docs/imports.json.
// The producer must hold its sector buffer unchanged while busy.
module swim2_write_commit (
    input        clk,
    input        nreset,
    input        sector_valid,
    input [21:0] sector_addr,
    output       sector_ready,
    output reg   rejected,
    output [8:0] buf_addr,
    input  [7:0] buf_data, // Synchronous read, one clock after buf_addr.
    output reg [21:0] wr_addr,
    output reg [15:0] wr_data,
    output reg   wr_req,
    input        wr_ack,
    output       busy,
    output reg   done,
    output [21:0] committed_addr,
    output [7:0] sd_buf_addr,
    output [15:0] sd_buf_data,
    output       sd_buf_wr
);

localparam IDLE = 3'd0, FETCH_LO = 3'd1, FETCH_HI = 3'd2,
           ASSERT = 3'd3, WAIT_ACK = 3'd4, TURN = 3'd5;
reg [2:0] state;
reg [21:0] base_addr;
reg [7:0] word_idx, byte_hi;

assign busy = state != IDLE;
assign sector_ready = nreset && !busy && !wr_ack;
assign committed_addr = base_addr;
assign buf_addr = {word_idx, state == FETCH_HI};
assign sd_buf_addr = word_idx;
assign sd_buf_data = wr_data;
assign sd_buf_wr = wr_req;

always @(posedge clk) begin
    done <= 0;
    rejected <= 0;
    if (!nreset) begin
        state <= IDLE;
        base_addr <= 0;
        word_idx <= 0;
        byte_hi <= 0;
        wr_addr <= 0;
        wr_data <= 0;
        wr_req <= 0;
    end else begin
        // A second offer cannot replace a sector already owned by this path.
        if (sector_valid && (!sector_ready || sector_addr[8:0] != 0)) rejected <= 1;
        case (state)
            IDLE: if (sector_valid && sector_ready && sector_addr[8:0] == 0) begin
                base_addr <= sector_addr;
                word_idx <= 0;
                state <= FETCH_LO;
            end
            FETCH_LO: state <= FETCH_HI;
            FETCH_HI: begin
                byte_hi <= buf_data;
                state <= ASSERT;
            end
            ASSERT: begin
                wr_addr <= base_addr + {13'd0, word_idx, 1'b0};
                wr_data <= {byte_hi, buf_data};
                wr_req <= 1;
                state <= WAIT_ACK;
            end
            WAIT_ACK: if (wr_ack) begin
                wr_req <= 0;
                state <= TURN;
            end
            // Complete the level handshake before reusing the memory port.
            TURN: if (!wr_ack) begin
                if (word_idx == 255) begin
                    done <= 1;
                    state <= IDLE;
                end else begin
                    word_idx <= word_idx + 8'd1;
                    state <= FETCH_LO;
                end
            end
            default: begin
                state <= IDLE;
                wr_req <= 0;
            end
        endcase
    end
end

endmodule
