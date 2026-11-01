`timescale 1ns/1ps
module tb_swim2_loader_hps;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = 819200;
wire host_owned, mount_valid, mount_hd, mount_readonly, mount_gcr, mount_sides;
wire [12:0] image_blocks;
wire [31:0] sd_lba;
wire sd_rd, sd_ack, sd_buff_wr, mem_req, fault, busy;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout, mem_data;
wire [21:0] mem_addr;
reg mem_ack = 0, retry = 0;
wire host_req;
wire host_ack, host_error;
reg read_failure = 0, send_result = 1;
reg [15:0] token_lo, token_hi;
reg [31:0] old_token;
wire cancel_done;
wire cancel, release_request, host_retry, save_retry, read_selected, control_selected;
wire [15:0] read_dout, control_dout;
reg [31:0] mount_token;
wire [45:0] HPS_BUS;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0, response;
assign HPS_BUS[45:38] = {2'b00, clk, clk, 4'b0000};
assign HPS_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign HPS_BUS[31:16] = io_din;
wire [6:0] slot_ack;
assign sd_ack = slot_ack[6];
wire [31:0] host_lba [7];
wire [5:0] host_count [7];
wire [15:0] host_data [7];
genvar g;
generate for (g = 0; g < 7; g = g + 1) begin : slots
    assign host_lba[g] = g == 6 ? sd_lba : 32'd0;
    assign host_count[g] = 0;
    assign host_data[g] = 0;
end endgenerate
hps_io #(.CONF_STR("Q605;"), .WIDE(1), .VDNUM(7), .BLKSZ(2), .PS2DIV(0)) hps (
    .clk_sys(clk), .HPS_BUS(HPS_BUS), .EXT_BUS(EXT_BUS),
    .sd_lba(host_lba), .sd_blk_cnt(host_count), .sd_rd({sd_rd, 6'd0}), .sd_wr(7'd0),
    .sd_ack(slot_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
    .sd_buff_wr(sd_buff_wr), .sd_buff_din(host_data),
    .status_in(128'd0), .status_set(1'b0), .status_menumask(16'd0),
    .info_req(1'b0), .info(8'd0), .new_vmode(1'b0), .video_rotated(1'b0),
    .ioctl_wait(1'b0), .ioctl_upload_req(1'b0), .ioctl_upload_index(8'd0), .ioctl_din(16'd0),
    .ps2_kbd_clk_in(1'b1), .ps2_kbd_data_in(1'b1),
    .ps2_mouse_clk_in(1'b1), .ps2_mouse_data_in(1'b1),
    .ps2_kbd_led_status(3'd0), .ps2_kbd_led_use(3'd0),
    .joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0), .joystick_2_rumble(16'd0),
    .joystick_3_rumble(16'd0), .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0),
    .joystick_0(), .joystick_1(), .joystick_2(), .joystick_3(), .joystick_4(), .joystick_5(),
    .joystick_l_analog_0(), .joystick_l_analog_1(), .joystick_l_analog_2(),
    .joystick_l_analog_3(), .joystick_l_analog_4(), .joystick_l_analog_5(),
    .joystick_r_analog_0(), .joystick_r_analog_1(), .joystick_r_analog_2(),
    .joystick_r_analog_3(), .joystick_r_analog_4(), .joystick_r_analog_5(),
    .paddle_0(), .paddle_1(), .paddle_2(), .paddle_3(), .paddle_4(), .paddle_5(),
    .spinner_0(), .spinner_1(), .spinner_2(), .spinner_3(), .spinner_4(), .spinner_5(),
    .ps2_kbd_clk_out(), .ps2_kbd_data_out(), .ps2_mouse_clk_out(), .ps2_mouse_data_out(),
    .ps2_key(), .ps2_mouse(), .ps2_mouse_ext(), .buttons(), .forced_scandoubler(), .direct_video(),
    .gamma_bus(), .status(), .img_mounted(), .img_readonly(), .img_size(),
    .ioctl_download(), .ioctl_index(), .ioctl_wr(), .ioctl_addr(), .ioctl_dout(),
    .ioctl_upload(), .ioctl_rd(), .ioctl_file_ext(), .sdram_sz(), .RTC(), .TIMESTAMP(),
    .uart_mode(), .uart_speed()
);
swim2_loader dut (
    .clk(clk), .nreset(nreset), .img_mounted(img_mounted), .img_size(img_size),
    .img_readonly(img_readonly), .host_owned(host_owned), .mount_valid(mount_valid),
    .mount_ready(1'b0), .mount_hd(mount_hd), .mount_readonly(mount_readonly),
    .mount_gcr(mount_gcr), .mount_sides(mount_sides), .image_blocks(image_blocks),
    .release_done(1'b0), .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .mem_req(mem_req), .mem_addr(mem_addr), .mem_data(mem_data), .mem_ack(mem_ack),
    .mem_busy(1'b0), .retry(retry || host_retry), .fault(fault), .busy(busy),
    .host_req(host_req), .host_ack(host_ack), .host_error(host_error),
    .cancel(cancel), .cancel_done(cancel_done)
);
swim2_host_read read_host (
    .clk(clk), .nreset(nreset), .io_strobe(io_strobe), .io_enable(io_enable), .io_din(io_din),
    .io_selected(read_selected), .io_dout(read_dout), .mount_owned(host_owned),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack),
    .result_req(host_req), .result_ack(host_ack), .result_error(host_error)
);
swim2_host_control control_host (
    .clk(clk), .nreset(nreset), .io_strobe(io_strobe), .io_enable(io_enable), .io_din(io_din),
    .io_selected(control_selected), .io_dout(control_dout), .host_owned(host_owned),
    .media_live(1'b0), .loader_fault(fault), .writer_fault(1'b0), .cancel(cancel),
    .release_request(release_request), .loader_retry(host_retry), .save_retry(save_retry)
);
assign EXT_BUS[32] = control_selected || read_selected;
assign EXT_BUS[15:0] = control_selected ? control_dout : read_dout;
integer checks = 0, writes = 0, delay_count = 0, i;
reg [21:0] expected_addr = 0;
reg [15:0] last_word = 0;

function [15:0] pattern(input [21:0] address);
    pattern = {address[8:1] ^ address[16:9] ^ 8'h59,
               address[8:1] ^ address[21:14] ^ 8'ha7};
endfunction
task check(input [31:0] actual, input [31:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "check %0d at %0t: got %08h expected %08h", checks, $time, actual, wanted);
    end
endtask
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
task word_io(input [15:0] value);
    begin
        io_enable = 1; io_din = value; cycle;
        io_strobe = 1; cycle; io_strobe = 0; repeat (4) cycle;
        response = HPS_BUS[15:0];
    end
endtask
task close_io;
    begin io_enable = 0; repeat (4) cycle; check(sd_ack, 0); end
endtask
task block_transfer(input integer words);
    reg [15:0] data;
    integer w;
    begin
        while (!sd_rd) cycle;
        word_io(16'h0a); check(response, 16'h5352); check(EXT_BUS[32], 1);
        word_io(0); check(response, 16'h010b);
        word_io(0); token_lo = response;
        word_io(0); token_hi = response;
        word_io(0); check(response, sd_lba[15:0]);
        word_io(0); check(response, sd_lba[31:16]);
        word_io(0); check(response, 6); close_io;
        word_io(16'h0617); check(sd_ack, 1); check(slot_ack, 7'h40);
        for (w = 0; w < words; w = w + 1) begin
            data = pattern({sd_lba[12:0], w[7:0], 1'b0});
            word_io({data[7:0], data[15:8]});
            check(mem_req, 0); check(mount_valid, 0);
        end
        close_io;
        if (send_result) read_result({token_hi, token_lo}, read_failure);
    end
endtask

task read_result(input [31:0] token, input error);
    begin
        word_io(16'h0b); check(EXT_BUS[32], 1);
        word_io(token[15:0]); word_io(token[31:16]); word_io({15'd0, error}); close_io;
    end
endtask
task finish_block(input integer total);
    begin
        while (writes < total || mem_ack) cycle;
        while (!sd_rd) cycle;
        check(writes, total); check(last_word, pattern(expected_addr - 2));
        check(fault, 0); check(host_owned, 1); check(mount_valid, 0);
    end
endtask

task control_metadata;
    begin
        word_io(16'h0c); check(response, 16'h5343); check(EXT_BUS[32], 1);
        word_io(0); check(response[0], host_owned);
        word_io(0); mount_token[15:0] = response;
        word_io(0); mount_token[31:16] = response;
        word_io(0); check(response, 0); word_io(0); check(response, 0);
        word_io(0); check(response, 6); close_io;
    end
endtask
task control_action(input [31:0] token, input [15:0] action);
    begin
        word_io(16'h0d); check(EXT_BUS[32], 1);
        word_io(token[15:0]); word_io(token[31:16]); word_io(action); close_io;
    end
endtask

always @(posedge clk) begin
    if (!nreset) begin mem_ack <= 0; delay_count <= 0; end
    else if (!mem_req) begin mem_ack <= 0; delay_count <= 0; end
    else if (!mem_ack) begin
        if (delay_count == 2) begin
            check(mem_addr, expected_addr); check(mem_data, pattern(expected_addr));
            last_word <= mem_data;
            mem_ack <= 1; writes <= writes + 1; expected_addr <= expected_addr + 22'd2;
        end else delay_count <= delay_count + 1;
    end
end

initial begin
    repeat (5) cycle; nreset = 1; cycle;
    // A physical stale transfer cannot satisfy a newly acquired image.
    word_io(16'h0617); check(sd_ack, 1);
    img_mounted = 1; cycle; img_mounted = 0;
    word_io(16'hdead); check(sd_rd, 0); check(mem_req, 0); check(writes, 0);
    close_io;
    block_transfer(256); finish_block(256); check(sd_lba, 1);
    word_io(16'h43); check(response, 0); close_io;
    block_transfer(256); finish_block(512); check(sd_lba, 2);
    read_failure = 1;
    block_transfer(256); old_token = {token_hi, token_lo}; repeat (16) cycle;
    check(fault, 1); check(writes, 512); check(host_owned, 1); check(mem_req, 0);
    control_metadata; control_action(mount_token, 2);
    read_failure = 0; send_result = 0;
    block_transfer(256); check({token_hi, token_lo} != old_token, 1);
    read_result(old_token, 0); repeat (16) cycle;
    check(writes, 512); check(mem_req, 0); check(host_req, 1);
    read_result({token_hi, token_lo}, 0); finish_block(768); check(sd_lba, 3);
    send_result = 1;
    block_transfer(255); repeat (16) cycle;
    check(fault, 1); check(writes, 768); check(mem_req, 0); check(host_owned, 1);
    retry = 1; cycle; retry = 0;
    block_transfer(257); repeat (16) cycle;
    check(fault, 1); check(writes, 768); check(mem_req, 0); check(host_owned, 1);
    retry = 1; cycle; retry = 0;
    block_transfer(256); finish_block(1024); check(sd_lba, 4);
    control_metadata;
    control_action(mount_token + 1, 1); check(cancel, 0);
    control_action(mount_token, 1); check(cancel, 1);
    repeat (8) begin cycle; check(host_owned, 1); check(mount_valid, 0); end
    send_result = 0; block_transfer(256);
    repeat (8) begin cycle; check(host_owned, 1); check(writes, 1024); end
    read_result({token_hi, token_lo}, 1);
    while (host_owned) cycle;
    check(writes, 1024); check(mount_valid, 0); check(cancel, 0);
    img_mounted = 1; cycle; img_mounted = 0;
    while (!sd_rd) cycle;
    control_action(mount_token, 1); check(cancel, 0); check(host_owned, 1);
    $display("PASS: SWIM II loader stock hps_io capture pipeline, %0d checks, %0d memory words", checks, writes);
    $finish;
end
initial begin #2000000; $fatal(1, "timeout"); end
endmodule
