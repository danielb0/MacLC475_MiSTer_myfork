// Staged raw-image persistence and its host result transport (slot 6).
module swim2_host_persistence (
    input        clk,
    input        nreset,
    inout [35:0] EXT_BUS,
    input        mount_owned,
    input [12:0] image_blocks,
    input  [7:0] sd_buf_addr,
    input [15:0] sd_buf_data,
    input        sd_buf_wr,
    input        save_valid,
    output       save_ready,
    input [21:0] save_addr,
    input        flush_req,
    output       flush_ack,
    output [31:0] sd_lba,
    output       sd_wr,
    input        sd_ack,
    input [12:0] sd_buff_addr,
    output [15:0] sd_buff_din,
    input        retry,
    output       fault,
    output       busy
);

wire durable_req, durable_ack, durable_error;

swim2_persistence persistence (.*);
swim2_host host (
    .clk(clk), .nreset(nreset), .EXT_BUS(EXT_BUS), .mount_owned(mount_owned),
    .sd_lba(sd_lba), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .durable_req(durable_req), .durable_ack(durable_ack), .durable_error(durable_error)
);

endmodule
