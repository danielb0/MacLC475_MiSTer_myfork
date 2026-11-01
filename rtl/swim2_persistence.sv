// Raw-image sector snapshot and durable host completion.
module swim2_persistence (
    input        clk,
    input        nreset,       // Global abort only.
    input [12:0] image_blocks, // Stable while the media owner holds the mount.
    input  [7:0] sd_buf_addr,
    input [15:0] sd_buf_data,  // Even byte high, from the committer tap.
    input        sd_buf_wr,
    input        save_valid,   // Producer holds its buffer until save_ready.
    output       save_ready,
    input [21:0] save_addr,
    input        flush_req,
    output       flush_ack,
    output [31:0] sd_lba,
    output       sd_wr,
    input        sd_ack,       // Transfer only; does not prove a file write.
    input [12:0] sd_buff_addr,
    output [15:0] sd_buff_din,
    output       durable_req,  // Host must report successful durable file write.
    input        durable_ack,  // Four-phase level reply, separate from sd_ack.
    input        durable_error, // Valid throughout durable_ack; failure retains data.
    input        retry,
    output       fault,
    output       busy
);

localparam IDLE = 4'd0, START = 4'd1, TRANSFER = 4'd2,
           TRANSFER_TURN = 4'd3, DURABLE_START = 4'd4, DURABLE = 4'd5,
           DURABLE_TURN = 4'd6, COMPLETE = 4'd7, FAILED = 4'd8, FLUSH = 4'd9;
reg [3:0] state;
reg [12:0] sector;
reg valid_sector, failed;
reg [15:0] snapshot [0:255];
reg [15:0] host_data;

assign sd_lba = {19'd0, sector};
assign sd_wr = nreset && state == TRANSFER;
assign durable_req = nreset && state == DURABLE;
assign save_ready = nreset && state == COMPLETE;
assign flush_ack = nreset && state == FLUSH;
assign fault = nreset && state == FAILED;
assign busy = state != IDLE || save_valid;
assign sd_buff_din = host_data;

always @(posedge clk) begin
    // Repeated tap levels rewrite the same word. Ownership prevents overlap.
    if (nreset && state == IDLE && sd_buf_wr)
        snapshot[sd_buf_addr] <= sd_buf_data;
    host_data <= sd_buff_addr[12:8] == 0 ?
                 {snapshot[sd_buff_addr[7:0]][7:0], snapshot[sd_buff_addr[7:0]][15:8]} : 16'd0;
end

always @(posedge clk) begin
    if (!nreset) begin
        state <= IDLE;
        sector <= 0;
        valid_sector <= 0;
        failed <= 0;
    end else begin
        case (state)
            IDLE: if (save_valid) begin
                sector <= save_addr[21:9];
                valid_sector <= save_addr[8:0] == 0 && save_addr[21:9] < image_blocks;
                failed <= 0;
                state <= (save_addr[8:0] == 0 && save_addr[21:9] < image_blocks) ? START : FAILED;
            end else if (flush_req && !sd_ack && !durable_ack) state <= FLUSH;
            START: if (!sd_ack && !durable_ack) state <= TRANSFER;
            TRANSFER: if (sd_ack) state <= TRANSFER_TURN;
            TRANSFER_TURN: if (!sd_ack) state <= DURABLE_START;
            DURABLE_START: if (!durable_ack) state <= DURABLE;
            DURABLE: if (durable_ack) begin
                failed <= durable_error;
                state <= DURABLE_TURN;
            end
            DURABLE_TURN: begin
                if (durable_ack && durable_error) failed <= 1;
                if (!durable_ack) state <= failed ? FAILED : COMPLETE;
            end
            COMPLETE: if (save_valid) state <= IDLE;
            FAILED: if (retry && valid_sector) begin
                failed <= 0;
                state <= START;
            end
            FLUSH: if (!flush_req) state <= IDLE;
            default: state <= IDLE;
        endcase
    end
end

endmodule
