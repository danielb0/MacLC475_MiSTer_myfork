`timescale 1ns/1ps
module tb_swim2_host;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, mount_owned = 1;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
assign EXT_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign EXT_BUS[31:16] = io_din;
reg [12:0] image_blocks = 2880, sd_buff_addr = 0;
reg [7:0] sd_buf_addr = 0;
reg [15:0] sd_buf_data = 0;
reg sd_buf_wr = 0, save_valid = 0, flush_req = 0, sd_ack = 0, retry = 0;
reg [21:0] save_addr = 0;
wire save_ready, flush_ack, sd_wr, fault, busy;
wire [31:0] sd_lba;
wire [15:0] sd_buff_din;
integer checks = 0, i, saves = 0;
reg [31:0] first_token, second_token, reset_token;
reg [15:0] response, status;

swim2_host_persistence dut (.*);

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
        io_enable = 1; io_din = data; io_strobe = 1; cycle;
        io_strobe = 0; cycle;
        value = EXT_BUS[15:0];
    end
endtask

task close_io;
    begin io_enable = 0; cycle; check(EXT_BUS[32], 0); end
endtask

task metadata(output [31:0] value, input [15:0] wanted_status);
    reg [15:0] lo, hi;
    begin
        word_io(16'h08, response); check(response, 16'h5357); check(EXT_BUS[32], 1);
        word_io(0, status); check(status, wanted_status);
        word_io(0, lo); word_io(0, hi); value = {hi, lo};
        word_io(0, response); check(response, sd_lba[15:0]);
        word_io(0, response); check(response, sd_lba[31:16]);
        word_io(0, response); check(response, 6);
        close_io;
    end
endtask

task result(input [31:0] value, input [15:0] error);
    begin
        word_io(16'h09, response); check(EXT_BUS[32], 1);
        word_io(value[15:0], response);
        word_io(value[31:16], response);
        word_io(error, response);
        close_io;
    end
endtask

task capture(input [7:0] seed);
    begin
        for (i = 0; i < 256; i = i + 1) begin
            sd_buf_addr = i; sd_buf_data = {i[7:0] ^ seed, i[7:0] ^ seed ^ 8'ha7};
            sd_buf_wr = 1; cycle;
        end
        sd_buf_wr = 0; cycle;
    end
endtask

task start_save(input [21:0] address);
    begin
        save_addr = address; save_valid = 1;
        repeat (5) cycle;
        check(sd_wr, 1); check(save_ready, 0);
    end
endtask

task transfer(input [7:0] seed);
    begin
        sd_ack = 1; cycle; check(sd_wr, 0);
        for (i = 0; i < 256; i = i + 1) begin
            sd_buff_addr = i; cycle;
            check(sd_buff_din, {i[7:0] ^ seed ^ 8'ha7, i[7:0] ^ seed});
            check(save_ready, 0);
        end
        sd_ack = 0; repeat (5) cycle;
        check(dut.durable_req, 1); check(save_ready, 0);
    end
endtask

initial begin
    cycle; nreset = 1; cycle;
    metadata(first_token, 16'h0108); check(first_token, 0);
    word_io(16'h0016, response); check(EXT_BUS[32], 0); close_io;

    capture(8'h51); start_save(22'd1024); flush_req = 1;
    metadata(first_token, 16'h010b); check(first_token, 1);
    // Results before the buffer transfer and while transfer ACK is high are rejected.
    result(first_token, 0); check(dut.host.result_valid, 0);
    sd_ack = 1; repeat (3) cycle;
    result(first_token, 0); check(dut.host.result_valid, 0);
    sd_ack = 0; repeat (6) cycle;
    check(dut.durable_req, 1); check(save_ready, 0); check(flush_ack, 0);
    result(first_token + 1, 0);
    repeat (20) begin cycle; check(save_ready, 0); check(flush_ack, 0); end
    // A truncated command cannot publish a result.
    word_io(16'h09, response); word_io(first_token[15:0], response); close_io;
    check(dut.host.result_valid, 0);
    result(first_token, 1);
    repeat (4) cycle; check(fault, 1); check(save_ready, 0); check(flush_ack, 0);
    result(first_token, 0); check(fault, 1);

    retry = 1; cycle; retry = 0; repeat (5) cycle;
    metadata(second_token, 16'h010b); check(second_token, first_token + 1);
    transfer(8'h51);
    result(first_token, 0); check(dut.durable_req, 1); check(save_ready, 0);
    result(second_token, 0);
    repeat (5) cycle;
    check(saves, 1); check(fault, 0);
    check(flush_ack, 1); flush_req = 0; repeat (3) cycle;
    metadata(reset_token, 16'h0108); check(reset_token, second_token);

    // Global abort invalidates a result without reusing its attempt token.
    capture(8'hb2); start_save(22'd1536);
    metadata(first_token, 16'h010b);
    transfer(8'hb2);
    nreset = 0; cycle; save_valid = 0; nreset = 1; cycle;
    capture(8'hc3); start_save(22'd2048);
    metadata(second_token, 16'h010b); check(second_token, first_token + 1);
    transfer(8'hc3);
    result(first_token, 0); check(dut.durable_req, 1);
    result(second_token, 2); repeat (3) cycle; check(fault, 1);
    retry = 1; cycle; retry = 0; repeat (5) cycle;
    metadata(reset_token, 16'h010b);
    transfer(8'hc3); result(reset_token, 0); repeat (5) cycle; check(saves, 2);

    // No token wrap can make an old response valid.
    dut.host.token = 32'hffffffff;
    capture(8'hd4); start_save(22'd2560);
    metadata(reset_token, 16'h010a); check(reset_token, 32'hffffffff);
    transfer(8'hd4); result(reset_token, 0);
    repeat (10) begin cycle; check(save_ready, 0); check(flush_ack, 0); end
    nreset = 0; cycle; check(dut.durable_ack, 0);
    save_valid = 0; mount_owned = 0; nreset = 1; cycle;
    metadata(reset_token, 16'h0100);
    $display("PASS: SWIM II host transport, %0d checks", checks);
    $finish;
end

initial begin #2000000; $fatal(1, "timeout"); end
endmodule

module tb_swim2_host_mailbox;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, mount_owned = 1, sd_wr = 0, sd_ack = 0, durable_req = 0;
reg [31:0] sd_lba = 3;
wire durable_ack, durable_error;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
integer checks = 0;
assign EXT_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign EXT_BUS[31:16] = io_din;
swim2_host dut (.*);

task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask

task check(input [31:0] actual, input [31:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted)
            $fatal(1, "mailbox check %0d: got %08h expected %08h", checks, actual, wanted);
    end
endtask

task word_io(input [15:0] data);
    begin
        io_enable = 1; io_strobe = 1; io_din = data; cycle;
        io_strobe = 0; cycle;
    end
endtask

task result(input [15:0] error);
    begin
        word_io(16'h09); word_io(1); word_io(0); word_io(error);
        io_enable = 0; cycle;
    end
endtask

initial begin
    cycle; nreset = 1; cycle;
    sd_wr = 1; cycle; sd_ack = 1; sd_wr = 0; cycle;
    sd_ack = 0; cycle;
    // The file result can precede the backend's durable request.
    result(1); check(dut.result_valid, 1); check(durable_ack, 0);
    result(0); check(dut.result_error, 1); check(durable_ack, 0);
    repeat (8) begin cycle; check(durable_ack, 0); end
    durable_req = 1; cycle; check(durable_ack, 1); check(durable_error, 1);
    result(0); check(durable_ack, 1); check(durable_error, 1);
    repeat (8) begin cycle; check(durable_ack, 1); check(durable_error, 1); end
    durable_req = 0; cycle;
    check(durable_ack, 0); check(dut.pending, 0); check(dut.result_valid, 0);
    result(0); check(dut.result_valid, 0);
    $display("PASS: SWIM II early/duplicate host results, %0d checks", checks);
    $finish;
end
initial begin #100000; $fatal(1, "timeout"); end
endmodule
