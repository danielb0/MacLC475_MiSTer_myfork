// One raw-image host slot and private SDRAM backing for the media owner.
module swim2_storage (
    input        clk,
    input        nreset,
    input        init,
    input [15:0] sdram_sz,
    inout [35:0] EXT_BUS,
    input        img_mounted,
    input [63:0] img_size,
    input        img_readonly,
    output       host_owned,
    output       mount_valid,
    input        mount_ready,
    output       mount_hd,
    output       mount_readonly,
    output       mount_gcr,
    output       mount_sides,
    output [12:0] image_blocks,
    input        release_done,
    output       release_request,
    input        rd_req,
    input [21:0] rd_addr,
    output       rd_ack,
    output [7:0] rd_data,
    input        wr_req,
    input [21:0] wr_addr,
    input [15:0] wr_data,
    output       wr_ack,
    input [7:0]  sd_buf_addr,
    input [15:0] sd_buf_data,
    input        sd_buf_wr,
    input        save_valid,
    output       save_ready,
    input [21:0] save_addr,
    input        flush_req,
    output       flush_ack,
    output [31:0] sd_lba,
    output       sd_rd,
    output       sd_wr,
    input        sd_ack,
    input [12:0] sd_buff_addr,
    input [15:0] sd_buff_dout,
    input        sd_buff_wr,
    output [15:0] sd_buff_din,
    input        loader_retry,
    input        loader_cancel,
    output       cancel_done,
    input        save_retry,
    output       loading,
    output       persist_busy,
    output       fault,
    output       memory_ready,
    output       mem_busy,
    input        cpu_req,
    input        cpu_we,
    input [26:2] cpu_addr,
    input [3:0]  cpu_be,
    input [31:0] cpu_wdata,
    output       cpu_ack,
    output [31:0] cpu_rdata,
    output       beat_req,
    output       beat_we,
    output [26:2] beat_addr,
    output [3:0]  beat_be,
    output [31:0] beat_wdata,
    input        beat_ack,
    input [31:0] beat_rdata,
    input        beat_busy,
    input        beat_line_pending
);

wire loader_rd, writer_wr, loader_fault, writer_fault, memory_fault;
wire [31:0] loader_lba, writer_lba;
wire load_req, load_ack;
wire [21:0] load_addr;
wire [15:0] load_data;
wire host_req, host_ack, host_error, read_selected;
wire [15:0] read_dout;
wire control_selected, host_cancel, host_loader_retry, host_save_retry;
wire [15:0] control_dout;
wire [35:0] writer_bus;
reg media_live;
localparam NONE = 2'd0, LOAD = 2'd1, SAVE = 2'd2;
reg [1:0] host_grant;
reg [31:0] host_lba;

assign sd_lba = host_lba;
assign sd_rd = nreset && host_grant == LOAD && loader_rd;
assign sd_wr = nreset && host_grant == SAVE && writer_wr;
assign fault = loader_fault || writer_fault || memory_fault;
assign writer_bus[35:33] = EXT_BUS[35:33];
assign writer_bus[31:16] = EXT_BUS[31:16];
assign EXT_BUS[32] = control_selected || read_selected || writer_bus[32];
assign EXT_BUS[15:0] = control_selected ? control_dout : read_selected ? read_dout : writer_bus[15:0];

always @(posedge clk) begin
    if (!nreset) begin
        media_live <= 0;
        host_grant <= NONE;
        host_lba <= 0;
    end else begin
        if (mount_valid && mount_ready) media_live <= 1;
        if (release_done) media_live <= 0;
        case (host_grant)
            NONE: if (!sd_ack) begin
                if (loader_rd) begin host_grant <= LOAD; host_lba <= loader_lba; end
                else if (media_live && writer_wr) begin host_grant <= SAVE; host_lba <= writer_lba; end
            end
            LOAD: if (!loader_rd && !sd_ack) host_grant <= NONE;
            SAVE: if (!writer_wr && !sd_ack) host_grant <= NONE;
            default: host_grant <= NONE;
        endcase
    end
end

swim2_loader loader (
    .clk(clk), .nreset(nreset), .img_mounted(img_mounted), .img_size(img_size),
    .img_readonly(img_readonly), .host_owned(host_owned), .mount_valid(mount_valid),
    .mount_ready(mount_ready), .mount_hd(mount_hd), .mount_readonly(mount_readonly),
    .mount_gcr(mount_gcr), .mount_sides(mount_sides), .image_blocks(image_blocks),
    .release_done(release_done), .sd_lba(loader_lba), .sd_rd(loader_rd),
    .sd_ack(sd_ack && host_grant == LOAD), .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr && host_grant == LOAD),
    .mem_req(load_req), .mem_addr(load_addr), .mem_data(load_data), .mem_ack(load_ack),
    .mem_busy(mem_busy), .retry(loader_retry || host_loader_retry), .fault(loader_fault), .busy(loading),
    .host_req(host_req), .host_ack(host_ack), .host_error(host_error),
    .cancel(loader_cancel || host_cancel), .cancel_done(cancel_done)
);

swim2_host_control control_host (
    .clk(clk), .nreset(nreset), .io_strobe(EXT_BUS[33]), .io_enable(EXT_BUS[34]),
    .io_din(EXT_BUS[31:16]), .io_selected(control_selected), .io_dout(control_dout),
    .host_owned(host_owned), .media_live(media_live), .loader_fault(loader_fault),
    .writer_fault(writer_fault), .cancel(host_cancel), .release_request(release_request),
    .loader_retry(host_loader_retry), .save_retry(host_save_retry)
);

swim2_host_read read_host (
    .clk(clk), .nreset(nreset), .io_strobe(EXT_BUS[33]), .io_enable(EXT_BUS[34]),
    .io_din(EXT_BUS[31:16]), .io_selected(read_selected), .io_dout(read_dout),
    .mount_owned(host_owned), .sd_lba(loader_lba), .sd_rd(loader_rd),
    .sd_ack(sd_ack && host_grant == LOAD), .result_req(host_req),
    .result_ack(host_ack), .result_error(host_error)
);

swim2_host_persistence persistence (
    .clk(clk), .nreset(nreset), .EXT_BUS(writer_bus), .mount_owned(host_owned),
    .image_blocks(image_blocks), .sd_buf_addr(sd_buf_addr), .sd_buf_data(sd_buf_data),
    .sd_buf_wr(sd_buf_wr && media_live), .save_valid(save_valid && media_live),
    .save_ready(save_ready), .save_addr(save_addr), .flush_req(flush_req), .flush_ack(flush_ack),
    .sd_lba(writer_lba), .sd_wr(writer_wr), .sd_ack(sd_ack && host_grant == SAVE),
    .sd_buff_addr(sd_buff_addr), .sd_buff_din(sd_buff_din), .retry(save_retry || host_save_retry),
    .fault(writer_fault), .busy(persist_busy)
);

swim2_memory memory (
    .clk(clk), .nreset(nreset), .init(init), .sdram_sz(sdram_sz), .image_blocks(image_blocks),
    .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_be(cpu_be),
    .cpu_wdata(cpu_wdata), .cpu_ack(cpu_ack), .cpu_rdata(cpu_rdata),
    .load_req(load_req), .load_addr(load_addr), .load_data(load_data), .load_ack(load_ack),
    .wr_req(wr_req && media_live), .wr_addr(wr_addr), .wr_data(wr_data), .wr_ack(wr_ack),
    .rd_req(rd_req && media_live), .rd_addr(rd_addr), .rd_ack(rd_ack), .rd_data(rd_data),
    .beat_req(beat_req), .beat_we(beat_we), .beat_addr(beat_addr), .beat_be(beat_be),
    .beat_wdata(beat_wdata), .beat_ack(beat_ack), .beat_rdata(beat_rdata),
    .beat_busy(beat_busy), .beat_line_pending(beat_line_pending),
    .memory_ready(memory_ready), .mem_busy(mem_busy), .fault(memory_fault)
);

endmodule
