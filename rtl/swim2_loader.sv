// Raw-image load-then-drain buffering, adapted from LC floppy_loader.
module swim2_loader (
    input        clk,
    input        nreset, // Global abort only.
    input        img_mounted,
    input [63:0] img_size,
    input        img_readonly,
    output       host_owned,
    output       mount_valid,
    input        mount_ready,
    output reg   mount_hd,
    output reg   mount_readonly,
    output reg   mount_gcr,
    output reg   mount_sides,
    output reg [12:0] image_blocks,
    input        release_done,
    output [31:0] sd_lba,
    output       sd_rd,
    input        sd_ack,
    input [12:0] sd_buff_addr,
    input [15:0] sd_buff_dout, // WIDE host order: even byte low.
    input        sd_buff_wr,
    output       mem_req,
    output [21:0] mem_addr, // Image byte offset, even aligned.
    output [15:0] mem_data, // Even byte high.
    input        mem_ack,
    input        mem_busy, // Includes posted writes not yet in SDRAM.
    output       host_req,
    input        host_ack,
    input        host_error,
    input        cancel, // Before publication only; drain active work first.
    output reg   cancel_done,
    input        retry,
    output       fault,
    output       busy
);

localparam IDLE = 4'd0, SD_START = 4'd1, SD_REQ = 4'd2,
           SD_TRANSFER = 4'd3, MEM_ADDRESS = 4'd4, MEM_REQ = 4'd5,
           MEM_TURN = 4'd6, NEXT = 4'd7, FENCE = 4'd8,
           OFFER = 4'd9, LIVE = 4'd10, RELEASE_TURN = 4'd11, FAILED = 4'd12,
           HOST_START = 4'd13, HOST_WAIT = 4'd14, HOST_TURN = 4'd15,
           CANCEL_DRAIN = 5'd16;
reg [4:0] state;
reg [12:0] sector;
reg [8:0] received;
reg [7:0] drain_idx;
reg transfer_bad, faulted, release_armed;
reg result_failed, cancelled;
reg [15:0] buffer [0:255];
reg [15:0] buffer_data;
wire geometry_ok = img_size == 64'd409600 || img_size == 64'd819200 ||
                   img_size == 64'd737280 || img_size == 64'd1474560;
wire capture = (state == SD_REQ || state == SD_TRANSFER) && sd_ack && sd_buff_wr;

wire cancelling = cancel || cancelled;
// Sampled cancellation keeps acquisition ownership independent of host feedback.
assign host_owned = nreset && (state != IDLE || (img_mounted && img_size != 0 && !cancelled));
assign mount_valid = nreset && state == OFFER && !cancelling;
assign host_req = nreset && state == HOST_WAIT;
assign sd_lba = {19'd0, sector};
assign sd_rd = nreset && state == SD_REQ;
assign mem_req = nreset && state == MEM_REQ;
assign mem_addr = {sector, drain_idx, 1'b0};
assign mem_data = buffer_data;
assign fault = nreset && faulted;
assign busy = nreset && state != IDLE && state != LIVE;

always @(posedge clk) begin
    if (nreset && capture && received < 256 && sd_buff_addr == {4'd0, received})
        buffer[received[7:0]] <= {sd_buff_dout[7:0], sd_buff_dout[15:8]};
    buffer_data <= buffer[drain_idx];
end

always @(posedge clk) begin
    cancel_done <= 0;
    if (!nreset) begin
        state <= IDLE;
        sector <= 0;
        received <= 0;
        drain_idx <= 0;
        transfer_bad <= 0;
        faulted <= 0;
        release_armed <= 0;
        result_failed <= 0;
        cancelled <= 0;
        mount_hd <= 0;
        mount_readonly <= 0;
        mount_gcr <= 0;
        mount_sides <= 0;
        image_blocks <= 0;
    end else begin
        if (cancel && state != IDLE && state != LIVE) cancelled <= 1;
        if (capture) begin
            if (received < 256 && sd_buff_addr == {4'd0, received})
                received <= received + 1'b1;
            else transfer_bad <= 1;
        end
        if (img_mounted && state != IDLE) faulted <= 1;
        case (state)
            IDLE: begin
                cancelled <= 0;
                if (img_mounted && !cancel) begin
                    faulted <= img_size != 0 && !geometry_ok;
                    if (geometry_ok) begin
                        mount_hd <= img_size == 64'd1474560;
                        mount_readonly <= img_readonly;
                        mount_gcr <= img_size == 64'd409600 || img_size == 64'd819200;
                        mount_sides <= img_size != 64'd409600;
                        image_blocks <= img_size[21:9];
                        sector <= 0;
                        state <= SD_START;
                    end
                end
            end
            SD_START: if (cancelling) state <= CANCEL_DRAIN;
            else if (!sd_ack && !mem_ack && !host_ack) begin
                received <= 0;
                transfer_bad <= 0;
                state <= SD_REQ;
            end
            SD_REQ: if (sd_ack) state <= SD_TRANSFER;
            SD_TRANSFER: if (!sd_ack) begin
                transfer_bad <= transfer_bad || received != 256;
                state <= HOST_START;
            end
            HOST_START: if (!host_ack) begin
                result_failed <= 0;
                state <= HOST_WAIT;
            end
            HOST_WAIT: if (host_ack) begin
                result_failed <= host_error;
                state <= HOST_TURN;
            end
            HOST_TURN: begin
                if (host_ack && host_error) result_failed <= 1;
                if (!host_ack) begin
                    if (cancelling) state <= CANCEL_DRAIN;
                    else if (result_failed || transfer_bad) begin
                        faulted <= 1;
                        state <= FAILED;
                    end else begin
                        drain_idx <= 0;
                        state <= MEM_ADDRESS;
                    end
                end
            end
            MEM_ADDRESS: if (cancelling) state <= CANCEL_DRAIN;
                         else if (!mem_ack) state <= MEM_REQ;
            MEM_REQ: if (mem_ack) state <= MEM_TURN;
            MEM_TURN: if (!mem_ack) begin
                if (cancelling) state <= CANCEL_DRAIN;
                else if (drain_idx == 255) state <= NEXT;
                else begin
                    drain_idx <= drain_idx + 1'b1;
                    state <= MEM_ADDRESS;
                end
            end
            NEXT: if (cancelling) state <= CANCEL_DRAIN;
                  else if (sector + 13'd1 == image_blocks) state <= FENCE;
                  else begin sector <= sector + 1'b1; state <= SD_START; end
            FENCE: if (cancelling) state <= CANCEL_DRAIN;
                   else if (!mem_busy && !mem_ack && !sd_ack && !host_ack) state <= OFFER;
            OFFER: if (cancelling) state <= CANCEL_DRAIN;
            else if (mount_ready) begin
                release_armed <= 0;
                state <= LIVE;
            end
            LIVE: if (!release_done) release_armed <= 1;
                  else if (release_armed) state <= RELEASE_TURN;
            RELEASE_TURN: if (!release_done && !sd_ack && !mem_ack && !mem_busy && !host_ack)
                state <= IDLE;
            FAILED: if (cancelling) state <= CANCEL_DRAIN;
            else if (retry && !sd_ack && !mem_ack && !host_ack) begin
                faulted <= 0;
                state <= SD_START;
            end
            CANCEL_DRAIN: if (!sd_ack && !mem_ack && !mem_busy && !host_ack) begin
                cancel_done <= 1;
                state <= IDLE;
            end
            default: state <= IDLE;
        endcase
    end
end

endmodule
