// One internal drive, checked host storage and shared SDRAM beat arbitration.
module swim2_platform #(
    parameter integer CLK_HZ = 25_000_000
) (
    input clk,
    input nreset,
    input guest_reset,
    input init,
    input [15:0] sdram_sz,
    inout [35:0] EXT_BUS,
    input sel,
    input write,
    input [2:0] addr,
    input [7:0] wdata,
    output [7:0] rdata,
    input img_mounted,
    input [63:0] img_size,
    input img_readonly,
    output [31:0] sd_lba,
    output sd_rd,
    output sd_wr,
    input sd_ack,
    input [12:0] sd_buff_addr,
    input [15:0] sd_buff_dout,
    input sd_buff_wr,
    output [15:0] sd_buff_din,
    output fault,
    input cpu_req,
    input cpu_we,
    input [26:2] cpu_addr,
    input [3:0] cpu_be,
    input [31:0] cpu_wdata,
    output cpu_ack,
    output [31:0] cpu_rdata,
    output beat_req,
    output beat_we,
    output [26:2] beat_addr,
    output [3:0] beat_be,
    output [31:0] beat_wdata,
    input beat_ack,
    input [31:0] beat_rdata,
    input beat_busy,
    input beat_line_pending
`ifdef SWIM2_TRACE
    , output trace_tx
`endif
);

wire mount_valid, mount_ready, mount_hd, mount_readonly, mount_gcr, mount_sides;
wire release_done, release_request, loaded, motor, side, byte_tick, write_tick, tach;
wire [6:0] track;
wire [7:0] mode, setup;
wire rd_req, rd_ack, wr_req, wr_ack;
wire [21:0] rd_addr, wr_addr, save_addr;
wire [7:0] rd_data, sd_buf_addr;
wire [15:0] wr_data, sd_buf_data;
wire sd_buf_wr, save_valid, save_ready, flush_req, flush_ack;
`ifdef SWIM2_TRACE
wire [5:0] trace_drive_events;
wire [31:0] trace_context;
wire [7:0] trace_error;
wire [21:0] trace_decode_addr, trace_commit_addr;
wire trace_read_fault, trace_write_fault;
reg trace_sd_wr_d, trace_fault_d, trace_reset_d, trace_ack_d, trace_save_transfer;
always @(posedge clk) begin
    if (!nreset) begin
        trace_sd_wr_d <= 0; trace_fault_d <= 0; trace_reset_d <= 0; trace_ack_d <= 0;
        trace_save_transfer <= 0;
    end else begin
        trace_sd_wr_d <= sd_wr; trace_fault_d <= fault;
        trace_reset_d <= guest_reset; trace_ack_d <= sd_ack;
        if (sd_wr) trace_save_transfer <= 1;
        else if (!sd_ack && trace_ack_d) trace_save_transfer <= 0;
    end
end
swim2_trace #(.CLK_HZ(CLK_HZ)) tracer (
    .clk(clk), .nreset(nreset), .tx(trace_tx),
    .events({2'd0, !sd_ack && trace_ack_d && trace_save_transfer,
             sd_ack && !trace_ack_d && trace_save_transfer,
             guest_reset && !trace_reset_d, release_done, mount_valid && mount_ready,
             fault && !trace_fault_d, save_valid && save_ready,
             sd_wr && !trace_sd_wr_d, trace_drive_events}),
    .context_data(trace_context), .error(trace_error),
    .decode_addr(trace_decode_addr), .commit_addr(trace_commit_addr), .host_lba(sd_lba),
    .status({loaded, release_request, trace_read_fault, trace_write_fault,
             fault, mount_hd, sd_wr, sd_ack})
);
`endif

swim2_timing #(.CLK_HZ(CLK_HZ)) timing (
    .clk(clk), .nreset(nreset), .ce(1'b1), .running(loaded && (motor || mode[7])),
    .gcr(mount_gcr), .hd(mount_hd), .track(track), .byte_tick(byte_tick), .tach(tach),
    .write_active(mode[3] && mode[4] && !mode[0] && !guest_reset),
    .write_div2(setup[3]), .write_tick(write_tick)
);

swim2_subsystem drive (
    .clk(clk), .nreset(nreset), .guest_reset(guest_reset), .ce(1'b1),
    .sel(sel), .write(write), .addr(addr), .wdata(wdata), .rdata(rdata),
    .byte_tick(byte_tick), .write_tick(write_tick), .tach(tach),
    .mount_valid(mount_valid), .mount_ready(mount_ready),
    .mount_base(24'd0), .mount_hd(mount_hd), .mount_readonly(mount_readonly),
    .mount_gcr(mount_gcr), .mount_sides(mount_sides), .release_request(release_request),
    .release_done(release_done), .write_enable(1'b1), .image_base(), .loaded(loaded),
    .motor(motor), .track(track), .side(side), .mode(mode), .setup(setup),
    .rd_addr(rd_addr), .rd_req(rd_req), .rd_ack(rd_ack), .rd_data(rd_data),
    .wr_addr(wr_addr), .wr_data(wr_data), .wr_req(wr_req), .wr_ack(wr_ack),
    .sd_buf_addr(sd_buf_addr), .sd_buf_data(sd_buf_data), .sd_buf_wr(sd_buf_wr),
    .save_valid(save_valid), .save_ready(save_ready), .save_addr(save_addr),
    .flush_req(flush_req), .flush_ack(flush_ack), .buffer_owned()
`ifdef SWIM2_TRACE
    , .read_fault(trace_read_fault), .write_fault(trace_write_fault),
    .trace_events(trace_drive_events), .trace_context(trace_context), .trace_error(trace_error),
    .trace_decode_addr(trace_decode_addr), .trace_commit_addr(trace_commit_addr)
`else
    , .read_fault(), .write_fault()
`endif
);

swim2_storage storage (
    .clk(clk), .nreset(nreset), .init(init), .sdram_sz(sdram_sz), .EXT_BUS(EXT_BUS),
    .img_mounted(img_mounted), .img_size(img_size), .img_readonly(img_readonly), .host_owned(),
    .mount_valid(mount_valid), .mount_ready(mount_ready), .mount_hd(mount_hd),
    .mount_readonly(mount_readonly), .mount_gcr(mount_gcr), .mount_sides(mount_sides), .image_blocks(),
    .release_done(release_done), .release_request(release_request),
    .rd_req(rd_req), .rd_addr(rd_addr), .rd_ack(rd_ack), .rd_data(rd_data),
    .wr_req(wr_req), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
    .sd_buf_addr(sd_buf_addr), .sd_buf_data(sd_buf_data), .sd_buf_wr(sd_buf_wr),
    .save_valid(save_valid), .save_ready(save_ready), .save_addr(save_addr),
    .flush_req(flush_req), .flush_ack(flush_ack), .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr),
    .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
    .sd_buff_wr(sd_buff_wr), .sd_buff_din(sd_buff_din),
    .loader_retry(1'b0), .loader_cancel(1'b0), .cancel_done(), .save_retry(1'b0),
    .loading(), .persist_busy(), .fault(fault), .memory_ready(), .mem_busy(),
    .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_be(cpu_be),
    .cpu_wdata(cpu_wdata), .cpu_ack(cpu_ack), .cpu_rdata(cpu_rdata),
    .beat_req(beat_req), .beat_we(beat_we), .beat_addr(beat_addr), .beat_be(beat_be),
    .beat_wdata(beat_wdata), .beat_ack(beat_ack), .beat_rdata(beat_rdata),
    .beat_busy(beat_busy), .beat_line_pending(beat_line_pending)
);

endmodule
