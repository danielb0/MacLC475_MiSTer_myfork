// Staged SWIM II, one SuperDrive and decoded sector-image media path.
module swim2_subsystem (
    input        clk,
    input        nreset,
    input        guest_reset,
    input        ce,
    input        sel,
    input        write,
    input  [2:0] addr,
    input  [7:0] wdata,
    output [7:0] rdata,
    input        byte_tick,   // External byte deadline, qualified by CE here.
    input        write_tick,
    input        tach,
    input        mount_valid,
    output       mount_ready,
    input [23:0] mount_base,
    input        mount_hd,
    input        mount_readonly,
    input        mount_gcr,
    input        mount_sides,
    input        release_request,
    output       release_done,
    input        write_enable,
    output [23:0] image_base,
    output       loaded,
    output       motor,
    output [6:0] track,
    output       side,
    output [7:0] mode,
    output [7:0] setup,
    output reg [21:0] rd_addr,
    output       rd_req,
    input        rd_ack,
    input  [7:0] rd_data,
    output [21:0] wr_addr,
    output [15:0] wr_data,
    output       wr_req,
    input        wr_ack,
    output [7:0] sd_buf_addr,
    output [15:0] sd_buf_data,
    output       sd_buf_wr,
    output       save_valid,
    input        save_ready,
    output [21:0] save_addr,
    output       flush_req,
    input        flush_ack,
    output reg   read_fault,
    output       write_fault,
    output       buffer_owned
`ifdef SWIM2_TRACE
    , output [5:0] trace_events
    , output [31:0] trace_context
    , output [7:0] trace_error
    , output [21:0] trace_decode_addr, trace_commit_addr
`endif
);

wire [3:0] phase, phase_oe;
wire selected, sense, drive_context, eject_request, eject_done;
wire mounted, media_hd, media_gcr, media_sides, write_protect, owner_ready, releasing, media_changed;
reg guest_eject, eject_ack_pending, mount_allowed, context_pending;
reg [1:0] gcr_d;
wire eject_ack = guest_eject && (release_done || eject_ack_pending);
wire drive_mounted = mounted || eject_ack;
wire release_level = release_request || guest_eject || eject_request;
wire context_changed = drive_context || media_changed || context_pending || gcr_d != {setup[6], setup[2]};
wire spinning = loaded && (motor || mode[7]);
wire tick = ce && byte_tick;
wire tx_tick = ce && write_tick;
wire write_active = mode[3] && mode[4] && !mode[0];
wire media_selected = loaded && selected && (motor || mode[7]);
wire read_active = mode[3] && !mode[4] && !mode[0] && setup[2] == media_gcr;
wire stream_enable, read_enable, read_discard;
wire [7:0] tx_data, written_data, encoded_data, mfm_data, gcr_data, mfm_written_data;
wire tx_mark, tx_crc, tx_valid, tx_take, written_mark, written_strobe;
wire mfm_take, mfm_written_mark, mfm_written_strobe;
reg [7:0] gcr_written_data;
reg gcr_written_strobe;
wire mfm_mark, mfm_crc, mfm_needs, mfm_index, gcr_needs, gcr_index;
wire [21:0] mfm_addr, gcr_addr;
wire [4:0] mfm_sector;
wire [3:0] gcr_sector, gcr_mark_sector;
wire gcr_byte, gcr_mark;
reg write_active_d, write_end_d;
wire gcr_end = write_end_d;
wire [4:0] write_sector, encoded_sector;
wire write_sector_valid, encoded_mark, encoded_crc, encoded_needs, encoded_index;
wire [21:0] encoded_addr;
wire encoder_reset = !nreset || guest_reset || context_changed || !spinning || releasing;
wire encoder_tick = tick && spinning && !encoder_reset;
`ifdef SWIM2_TRACE
wire [2:0] media_trace_events;
reg trace_write_d, trace_fault_d;
wire trace_error_read = ce && sel && !write && addr == 2 && rdata != 0;
assign trace_events = {media_trace_events[2], media_trace_events[1:0],
                       trace_error_read || (write_fault && !trace_fault_d),
                       !write_active && trace_write_d, write_active && !trace_write_d};
assign trace_context = {mode, setup, track, side, write_sector,
                        write_sector_valid, buffer_owned, stream_enable};
assign trace_error = trace_error_read ? rdata : 8'd0;
always @(posedge clk) begin
    if (!nreset) begin trace_write_d <= 0; trace_fault_d <= 0; end
    else begin trace_write_d <= write_active; trace_fault_d <= write_fault; end
end
`endif

localparam RD_IDLE = 2'd0, RD_ADDRESS = 2'd1, RD_WAIT = 2'd2, RD_TURN = 2'd3;
reg [1:0] rd_state;
reg cache_valid, crc_bad;
reg [7:0] cache_data;
reg [21:0] cache_addr;
wire read_busy = rd_state != RD_IDLE;
wire data_ready = cache_valid && cache_addr == encoded_addr;
wire read_miss = encoder_tick && encoded_needs && !data_ready;
assign rd_req = rd_state == RD_WAIT;
assign mount_ready = owner_ready && mount_allowed;
assign encoded_addr = media_gcr ? gcr_addr : mfm_addr;
assign encoded_data = media_gcr ? gcr_data : mfm_data;
assign encoded_mark = !media_gcr && mfm_mark;
assign encoded_crc = !media_gcr && mfm_crc;
assign encoded_needs = media_gcr ? gcr_needs : mfm_needs;
assign encoded_index = media_gcr ? gcr_index : mfm_index;
assign encoded_sector = media_gcr ? 5'd0 : mfm_sector;
// The controller shifts bytes even when no disk receives its write output.
assign tx_take = setup[6] ? (tx_tick && write_active && !tx_crc) : mfm_take;
assign written_data = setup[6] ? gcr_written_data : mfm_written_data;
assign written_mark = !setup[6] && mfm_written_mark;
assign written_strobe = setup[6] ? gcr_written_strobe : mfm_written_strobe;

swim2 controller (
    .clk(clk), .nreset(nreset && !guest_reset), .ce(ce), .sel(sel), .write(write),
    .addr(addr), .wdata(wdata), .rdata(rdata), .phase_in(4'd0), .zero_count(8'd0),
    .rddata(1'b0), .sense(sense), .context_changed(context_changed),
    .rx_valid(encoder_tick && selected && read_active), .rx_data(encoded_data),
    .rx_mark(encoded_mark), .rx_crc_zero(encoded_crc && !crc_bad), .rx_sector(encoded_sector),
    .rx_short(1'b0), .rx_long(1'b0), .tx_take(tx_take),
    .tx_fault(tx_tick && write_active &&
              ((media_selected && !stream_enable) || (setup[6] && tx_valid && tx_crc))),
    .tx_data(tx_data), .tx_mark(tx_mark), .tx_crc(tx_crc), .tx_valid(tx_valid),
    .phase_out(phase), .phase_oe(phase_oe), .setup(setup), .mode(mode),
    .write_late(), .write_early(), .write_sector(write_sector),
    .write_sector_valid(write_sector_valid)
);

swim2_drive drive (
    .clk(clk), .nreset(nreset), .ce(ce), .phase(phase), .phase_oe(phase_oe), .mode(mode),
    .mounted(drive_mounted), .media_hd(media_hd), .write_protect(write_protect || !write_enable),
    .index_pulse(encoded_index), .tach(tach), .eject_ready(eject_ack),
    .eject_request(eject_request), .eject_done(eject_done), .loaded(loaded),
    .selected(selected), .motor(motor), .sense(sense), .track(track), .side(side),
    .context_changed(drive_context)
);

mfm_track_encoder encoder (
    .clk(clk), .ready(encoder_tick && !media_gcr), .rst(encoder_reset || media_gcr), .side(side), .track(track),
    .hd(media_hd), .addr(mfm_addr), .idata(data_ready ? cache_data : 8'd0),
    .odata(mfm_data), .omark(mfm_mark), .ocrc0(mfm_crc),
    .oneeds(mfm_needs), .oindex(mfm_index), .osector(mfm_sector)
);

floppy_track_encoder gcr_encoder (
    .clk(clk), .ready(encoder_tick && media_gcr), .rst(encoder_reset || !media_gcr),
    .side(side), .sides(media_sides), .track(track), .addr(gcr_addr),
    .idata(data_ready ? cache_data : 8'd0), .odata(gcr_data),
    .oneeds(gcr_needs), .oindex(gcr_index), .osector(gcr_sector),
    .wr_byte(gcr_byte), .wr_mark(gcr_mark), .wr_mark_sector(gcr_mark_sector), .wr_end(gcr_end)
);

swim2_mfm_write writer (
    .clk(clk), .nreset(nreset && !guest_reset && !context_changed), .ce(ce),
    .active(write_active && !setup[6]), .tick(write_tick),
    .q_data(tx_data), .q_mark(tx_mark), .q_crc(tx_crc), .q_valid(tx_valid),
    .q_take(mfm_take), .data(mfm_written_data), .mark(mfm_written_mark), .strobe(mfm_written_strobe)
);

swim2_media media (
    .clk(clk), .nreset(nreset), .guest_reset(guest_reset), .context_changed(context_changed),
    .mount_valid(mount_valid && mount_allowed), .mount_ready(owner_ready),
    .mount_base(mount_base), .mount_hd(mount_hd), .mount_readonly(mount_readonly),
    .mount_gcr(mount_gcr), .mount_sides(mount_sides), .media_gcr(media_gcr), .media_sides(media_sides),
    .gcr(setup[6]), .gcr_byte(gcr_byte), .gcr_mark(gcr_mark), .gcr_mark_sector(gcr_mark_sector),
    .mounted(mounted), .image_base(image_base), .media_hd(media_hd), .write_protect(write_protect),
    .release_request(release_level), .release_done(release_done), .releasing(releasing),
    .media_changed(media_changed), .selected(selected), .motor(motor || mode[7]),
    .read_busy(read_busy), .read_enable(read_enable), .read_discard(read_discard),
    .write_active(write_active && media_selected), .write_enable(write_enable), .track(track), .side(side),
    .anchor_sector(write_sector), .anchor_valid(write_sector_valid),
    .write_data(written_data), .write_mark(written_mark), .write_tick(tx_tick && write_active),
    .write_strobe(written_strobe), .stream_enable(stream_enable), .write_fault(write_fault),
    .buffer_owned(buffer_owned), .wr_addr(wr_addr), .wr_data(wr_data), .wr_req(wr_req), .wr_ack(wr_ack),
    .sd_buf_addr(sd_buf_addr), .sd_buf_data(sd_buf_data), .sd_buf_wr(sd_buf_wr),
    .save_valid(save_valid), .save_ready(save_ready), .save_addr(save_addr),
    .flush_req(flush_req), .flush_ack(flush_ack)
`ifdef SWIM2_TRACE
    , .trace_events(media_trace_events), .trace_decode_addr(trace_decode_addr),
    .trace_commit_addr(trace_commit_addr)
`endif
);

always @(posedge clk) begin
    if (!nreset) begin
        guest_eject <= 0;
        eject_ack_pending <= 0;
        mount_allowed <= 1;
        context_pending <= 0;
        gcr_d <= 0;
        write_active_d <= 0;
        write_end_d <= 0;
        gcr_written_data <= 0;
        gcr_written_strobe <= 0;
    end else begin
        gcr_d <= {setup[6], setup[2]};
        gcr_written_strobe <= 0;
        write_active_d <= write_active && setup[6];
        write_end_d <= write_active_d && !(write_active && setup[6]);
        if (!guest_reset && !context_changed && setup[6] && tx_take && tx_valid) begin
            gcr_written_data <= tx_data;
            gcr_written_strobe <= 1;
        end
        if (ce) context_pending <= 0;
        if ((media_changed || gcr_d != {setup[6], setup[2]}) && !ce) context_pending <= 1;
        if (eject_request) guest_eject <= 1;
        if (release_done && guest_eject) eject_ack_pending <= 1;
        if (eject_done) begin
            guest_eject <= 0;
            eject_ack_pending <= 0;
        end
        if (!mounted && !drive_mounted && ce) mount_allowed <= 1;
        if (release_level) mount_allowed <= 0;
    end
end

always @(posedge clk) begin
    if (!nreset) begin
        rd_state <= RD_IDLE;
        rd_addr <= 0;
        cache_addr <= 0;
        cache_data <= 0;
        cache_valid <= 0;
        crc_bad <= 0;
        read_fault <= 0;
    end else begin
        if (encoder_reset) begin
            cache_valid <= 0;
            crc_bad <= 0;
        end else if (encoder_tick) begin
            if (encoded_mark) crc_bad <= 0;
            if (encoded_needs) cache_valid <= 0;
            if (read_miss) crc_bad <= 1;
        end
        if (write_active || buffer_owned) cache_valid <= 0;
        if (guest_reset || context_changed || !read_active) read_fault <= 0;
        else if (read_miss) read_fault <= 1;

        case (rd_state)
            RD_IDLE: if (read_enable && spinning && !encoder_reset && !write_active &&
                         encoded_needs && !data_ready && !rd_ack) begin
                rd_addr <= encoded_addr;
                rd_state <= RD_ADDRESS;
            end
            RD_ADDRESS: rd_state <= RD_WAIT;
            RD_WAIT: if (rd_ack) begin
                if (!read_discard && !encoder_reset && !write_active && !buffer_owned &&
                    rd_addr == encoded_addr &&
                    !(encoder_tick && encoded_needs)) begin
                    cache_data <= rd_data;
                    cache_addr <= rd_addr;
                    cache_valid <= 1;
                end
                rd_state <= RD_TURN;
            end
            RD_TURN: if (!rd_ack) rd_state <= RD_IDLE;
        endcase
    end
end

endmodule
