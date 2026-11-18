// Staged sector-buffer write scheduling and mount ownership.
module swim2_media (
    input        clk,
    input        nreset,       // Global abort only; guest reset must not abort commits.
    input        guest_reset,
    input        context_changed,
    input        mount_valid,
    output       mount_ready,
    input [23:0] mount_base,   // SDRAM word address; data ports use image byte offsets.
    input        mount_hd,
    input        mount_readonly,
    input        mount_gcr,
    input        mount_sides,
    output reg   mounted,
    output reg [23:0] image_base,
    output reg   media_hd,
    output reg   write_protect,
    output reg   media_gcr,
    output reg   media_sides,
    input        gcr,
    output       gcr_byte,
    output       gcr_mark,
    output [3:0] gcr_mark_sector,
    input        release_request, // Hold until release_done, then withdraw.
    output reg   release_done,
    output       releasing,
    output       media_changed,
    input        selected,
    input        motor,
    input        read_busy,    // Includes request, reply and ACK-low turnaround.
    output       read_enable,  // Permission to start an image fetch.
    output       read_discard, // Discard a reply invalidated by stream context.
    input        write_active,
    input        write_enable,
    input  [6:0] track,
    input        side,
    input  [4:0] anchor_sector,
    input        anchor_valid,
    input  [7:0] write_data,
    input        write_mark,
    input        write_tick,   // Deadline pulse even when stream_enable is low.
    input        write_strobe, // One full-clock pulse from the decoded write engine.
    output       stream_enable,
    output reg   write_fault,  // Sticky until ACTION ends or stream context is reset.
    output       buffer_owned,
    output [21:0] wr_addr,
    output [15:0] wr_data,
    output       wr_req,
    input        wr_ack,
    output [7:0] sd_buf_addr,
    output [15:0] sd_buf_data,
    output       sd_buf_wr,
    output reg   save_valid,   // Completed RAM sector notification, held until accepted.
    input        save_ready,
    output reg [21:0] save_addr,
    output       flush_req,    // ACK means all accepted notifications are durable.
    input        flush_ack
`ifdef SWIM2_TRACE
    , output [2:0] trace_events
    , output [21:0] trace_decode_addr, trace_commit_addr
`endif
);

localparam RUN = 3'd0, DRAIN = 3'd1, FLUSH = 3'd2,
           FLUSH_TURN = 3'd3, RELEASED = 3'd4;
reg [2:0] state;
reg pending;
reg read_stale;
reg buffer_gcr;
reg [21:0] pending_addr;
wire sector_valid, decode_reject;
wire [21:0] committed_addr;
wire mfm_valid, mfm_reject, gcr_valid, gcr_reject, gcr_ready;
wire [21:0] mfm_addr, gcr_addr;
wire [7:0] mfm_buf, gcr_buf;
wire [8:0] buf_addr;
wire [7:0] buf_data;
wire commit_ready, commit_busy, commit_done, commit_rejected;
// The persistence snapshot holds one sector until the host save completes, so
// the next commit (which refills that snapshot) waits for the notification to
// retire. The decoder buffer stays owned meanwhile.
wire commit_offer = pending && commit_ready && !read_busy && !save_valid && !commit_done;
wire mount_accept = mount_valid && mount_ready;
wire stream_reset = guest_reset || context_changed || !mounted ||
                    !selected || !motor || !write_active || !write_enable ||
                    write_protect || releasing || track > 79 || gcr != media_gcr ||
                    (gcr && side && !media_sides);
wire decode_reset = !nreset || stream_reset || write_fault;
wire decode_byte = write_strobe && stream_enable;

assign releasing = state != RUN || release_request;
assign mount_ready = nreset && !mounted && !releasing && !flush_ack && !wr_ack && !read_busy;
assign media_changed = nreset && (mount_accept || release_done);
// sector_valid closes the ownership gap before pending is registered.
// A sector whose save is outstanding is already in image RAM and in the
// persistence snapshot, so it no longer owns the decoder buffer. Holding the
// stream for the host write and fsync (milliseconds) made the next physical
// sector's write report underrun (.Sony wrUnderrun, -74).
assign buffer_owned = sector_valid || pending || commit_busy || commit_done;
assign stream_enable = nreset && !stream_reset && !buffer_owned && !write_fault &&
                       (!gcr || gcr_ready);
assign sector_valid = gcr_valid || mfm_valid;
assign decode_reject = gcr ? gcr_reject : mfm_reject;
assign buf_data = buffer_gcr ? gcr_buf : mfm_buf;
assign gcr_byte = decode_byte && gcr;
assign read_enable = nreset && mounted && selected && motor && !guest_reset &&
                     !context_changed && !releasing && !buffer_owned && !read_busy &&
                     track <= 79 && (!media_gcr || media_sides || !side);
assign read_discard = read_stale || guest_reset || context_changed || releasing ||
                      !mounted || !selected || !motor;
assign flush_req = state == FLUSH;
`ifdef SWIM2_TRACE
assign trace_events = {decode_reject, commit_done, sector_valid};
assign trace_decode_addr = gcr_valid ? gcr_addr : mfm_addr;
assign trace_commit_addr = committed_addr;
`endif

mfm_write_decoder decoder (
    .clk(clk), .rst(decode_reset || gcr),
    .ready(decode_byte && !gcr), .idata(write_data), .imark(write_mark),
    .side(side), .track(track), .hd(media_hd),
    .anchor_sector(anchor_sector), .anchor_valid(anchor_valid),
    .sector_valid(mfm_valid), .sector(), .addr(mfm_addr), .reject(mfm_reject),
    .amark(), .amark_sector(), .amark_cyl(), .amark_head(),
    .buf_addr(buf_addr), .buf_data(mfm_buf)
);

floppy_track_decoder gcr_decoder (
    .clk(clk), .rst(decode_reset || !gcr), .ready(decode_byte && gcr), .byte_ready(gcr_ready),
    .idata(write_data), .side(side), .sides(media_sides), .track(track),
    .sector_valid(gcr_valid), .sector(), .addr(gcr_addr), .reject(gcr_reject),
    .amark(gcr_mark), .amark_sector(gcr_mark_sector), .fmt_mark(), .fmt_ds(),
    .buf_addr(buf_addr), .buf_data(gcr_buf)
);

swim2_write_commit committer (
    .clk(clk), .nreset(nreset), .sector_valid(commit_offer), .sector_addr(pending_addr),
    .sector_ready(commit_ready), .rejected(commit_rejected),
    .buf_addr(buf_addr), .buf_data(buf_data), .wr_addr(wr_addr), .wr_data(wr_data),
    .wr_req(wr_req), .wr_ack(wr_ack), .busy(commit_busy), .done(commit_done),
    .committed_addr(committed_addr), .sd_buf_addr(sd_buf_addr),
    .sd_buf_data(sd_buf_data), .sd_buf_wr(sd_buf_wr)
);

always @(posedge clk) begin
    release_done <= 0;
    if (!nreset) begin
        state <= RUN;
        mounted <= 0;
        image_base <= 0;
        media_hd <= 0;
        write_protect <= 1;
        pending <= 0;
        read_stale <= 0;
        buffer_gcr <= 0;
        media_gcr <= 0;
        media_sides <= 0;
        pending_addr <= 0;
        save_valid <= 0;
        save_addr <= 0;
        write_fault <= 0;
    end else begin
        if (!read_busy) read_stale <= 0;
        else if (read_discard) read_stale <= 1;
        if (guest_reset || context_changed || !write_active) write_fault <= 0;
        else if (((write_tick || write_strobe) && !stream_enable) ||
                 decode_reject || commit_rejected)
            write_fault <= 1;

        // A completed sector survives context changes; decoder reset preserves RAM.
        // Select a completion before a coincident codec/context change.
        if (gcr_valid || mfm_valid) begin
            pending <= 1;
            pending_addr <= gcr_valid ? gcr_addr : mfm_addr;
            buffer_gcr <= gcr_valid;
        end
        if (commit_offer) pending <= 0;
        if (save_valid && save_ready) save_valid <= 0;
        if (commit_done) begin
            save_valid <= 1;
            save_addr <= committed_addr;
        end

        if (mount_accept) begin
            mounted <= 1;
            image_base <= mount_base;
            media_hd <= mount_hd;
            write_protect <= mount_readonly;
            media_gcr <= mount_gcr;
            media_sides <= mount_sides;
        end
        case (state)
            RUN: if (release_request) state <= DRAIN;
            DRAIN: if (!buffer_owned && !save_valid && !read_busy && !wr_ack && !flush_ack) state <= FLUSH;
            FLUSH: if (flush_ack) state <= FLUSH_TURN;
            FLUSH_TURN: if (!flush_ack) begin
                mounted <= 0;
                release_done <= 1;
                state <= RELEASED;
            end
            RELEASED: if (!release_request) state <= RUN;
        endcase
    end
end

endmodule
