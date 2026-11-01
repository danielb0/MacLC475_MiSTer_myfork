`timescale 1ns/1ps
module tb_swim2_hps;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, mount_owned = 1;
wire [45:0] HPS_BUS;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
assign HPS_BUS[45:38] = {2'b00, clk, clk, 4'b0000};
assign HPS_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign HPS_BUS[31:16] = io_din;
reg [12:0] image_blocks = 2880;
wire [12:0] sd_buff_addr;
reg [7:0] sd_buf_addr = 0;
reg [15:0] sd_buf_data = 0;
reg sd_buf_wr = 0, save_valid = 0, flush_req = 0, retry = 0;
reg [21:0] save_addr = 0;
wire save_ready, flush_ack, sd_wr, fault, busy;
wire [31:0] sd_lba;
wire [15:0] sd_buff_din;
wire [6:0] host_ack;
wire sd_ack = host_ack[6];
wire [31:0] host_lba [7];
wire [5:0] host_count [7];
wire [15:0] host_data [7];
wire [6:0] host_write = {sd_wr, 6'd0};
genvar g;
generate for (g = 0; g < 7; g = g + 1) begin : slots
    assign host_lba[g] = g == 6 ? sd_lba : 32'd0;
    assign host_count[g] = 0;
    assign host_data[g] = g == 6 ? sd_buff_din : 16'd0;
end endgenerate

hps_io #(.CONF_STR("Q605;"), .WIDE(1), .VDNUM(7), .BLKSZ(2), .PS2DIV(0)) hps (
    .clk_sys(clk), .HPS_BUS(HPS_BUS), .EXT_BUS(EXT_BUS),
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
    .sd_buff_dout(), .sd_buff_wr(), .ioctl_download(), .ioctl_index(), .ioctl_wr(),
    .ioctl_addr(), .ioctl_dout(), .ioctl_upload(), .ioctl_rd(), .ioctl_file_ext(),
    .sdram_sz(), .RTC(), .TIMESTAMP(), .uart_mode(), .uart_speed(),
    .sd_lba(host_lba), .sd_blk_cnt(host_count), .sd_rd(7'd0), .sd_wr(host_write),
    .sd_ack(host_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_din(host_data),
    .status_in(128'd0), .status_set(1'b0), .status_menumask(16'd0),
    .info_req(1'b0), .info(8'd0), .new_vmode(1'b0), .video_rotated(1'b0),
    .ioctl_wait(1'b0), .ioctl_upload_req(1'b0), .ioctl_upload_index(8'd0), .ioctl_din(16'd0),
    .ps2_kbd_clk_in(1'b1), .ps2_kbd_data_in(1'b1),
    .ps2_mouse_clk_in(1'b1), .ps2_mouse_data_in(1'b1),
    .ps2_kbd_led_status(3'd0), .ps2_kbd_led_use(3'd0),
    .joystick_0_rumble(16'd0), .joystick_1_rumble(16'd0), .joystick_2_rumble(16'd0),
    .joystick_3_rumble(16'd0), .joystick_4_rumble(16'd0), .joystick_5_rumble(16'd0)
);
swim2_host_persistence dut (.*);
integer checks = 0, i, saves = 0;
reg [15:0] response, lo, hi;
reg [31:0] token, old_token;

always @(posedge clk) if (nreset && save_ready) begin
    save_valid <= 0;
    saves <= saves + 1;
end

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
task check(input [31:0] actual, input [31:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "check %0d at %0t: got %08h expected %08h", checks, $time, actual, wanted);
    end
endtask
task word_io(input [15:0] data, output [15:0] value);
    begin
        io_enable = 1; io_din = data; cycle;
        io_strobe = 1; cycle;
        io_strobe = 0; repeat (4) cycle;
        value = HPS_BUS[15:0];
    end
endtask
task close_io;
    begin io_enable = 0; repeat (4) cycle; check(EXT_BUS[32], 0); end
endtask
task metadata;
    begin
        word_io(16'h08, response); check(response, 16'h5357); check(EXT_BUS[32], 1);
        word_io(0, response); check(response, 16'h010b);
        word_io(0, lo); word_io(0, hi); token = {hi, lo};
        word_io(0, response); check(response, sd_lba[15:0]);
        word_io(0, response); check(response, sd_lba[31:16]);
        word_io(0, response); check(response, 6); close_io;
    end
endtask
task result(input [31:0] value, input [15:0] error);
    begin
        word_io(16'h09, response); check(EXT_BUS[32], 1);
        word_io(value[15:0], response); word_io(value[31:16], response);
        word_io(error, response); close_io;
    end
endtask
task capture(input [7:0] seed, input [21:0] address);
    begin
        for (i = 0; i < 256; i = i + 1) begin
            sd_buf_addr = i; sd_buf_data = {i[7:0] ^ seed, i[7:0] ^ seed ^ 8'ha7};
            sd_buf_wr = 1; cycle;
        end
        sd_buf_wr = 0; cycle; save_addr = address; save_valid = 1;
        repeat (6) cycle; check(sd_wr, 1);
    end
endtask
task transfer(input [7:0] seed);
    begin
        word_io(16'h16, response); check(response, 16'h809a); check(EXT_BUS[32], 0);
        word_io(0, response);
        word_io(0, response); check(response, sd_lba[15:0]);
        word_io(0, response); check(response, sd_lba[31:16]); close_io;
        metadata;
        word_io(16'h0618, response); check(sd_ack, 1); check(EXT_BUS[32], 0);
        check(HPS_BUS[32], 1);
        for (i = 0; i < 256; i = i + 1) begin
            word_io(0, response);
            check(response, {i[7:0] ^ seed ^ 8'ha7, i[7:0] ^ seed});
            check(save_ready, 0); check(host_ack, 7'h40);
        end
        close_io; check(sd_ack, 0); check(sd_wr, 0);
        repeat (8) cycle; check(dut.durable_req, 1); check(save_ready, 0);
    end
endtask

initial begin
    repeat (5) cycle; nreset = 1; cycle;
    // The ordinary command response must pass through the extension mux.
    word_io(16'h43, response); check(response, 0); check(EXT_BUS[32], 0); close_io;
    capture(8'h51, 22'd1024); transfer(8'h51); old_token = token;
    flush_req = 1;
    repeat (20) begin cycle; check(saves, 0); check(flush_ack, 0); end
    result(token, 1); repeat (5) cycle;
    check(fault, 1); check(saves, 0); check(flush_ack, 0);
    retry = 1; cycle; retry = 0; repeat (6) cycle;
    transfer(8'h51); check(token, old_token + 1);
    result(old_token, 0); check(saves, 0); check(dut.durable_req, 1);
    result(token, 0); repeat (5) cycle;
    check(saves, 1); check(fault, 0); check(flush_ack, 1);
    flush_req = 0; repeat (5) cycle;
    capture(8'hc3, 22'd1536); transfer(8'hc3);
    result(token, 0); repeat (5) cycle; check(saves, 2);
    word_io(16'h43, response); check(response, 0); check(EXT_BUS[32], 0); close_io;
    $display("PASS: SWIM II stock hps_io WIDE transfer/result integration, %0d checks", checks);
    $finish;
end
initial begin #2000000; $fatal(1, "timeout"); end
endmodule
