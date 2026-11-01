`timescale 1ns/1ps
module tb_swim2_host_read;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, mount_owned = 1;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
wire io_selected;
wire [15:0] io_dout;
reg [31:0] sd_lba = 0;
reg sd_rd = 0, sd_ack = 0, result_req = 0;
wire result_ack, result_error;
integer checks = 0;
reg [15:0] lo, hi;
reg [31:0] first_token, second_token;
swim2_host_read dut (.*);

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

task word_io(input [15:0] data);
    begin
        io_enable = 1; io_strobe = 1; io_din = data; cycle;
        io_strobe = 0; cycle;
    end
endtask

task close_io;
    begin io_enable = 0; cycle; check(io_selected, 0); end
endtask

task metadata(input [15:0] status, input [31:0] token, input [31:0] lba);
    begin
        word_io(16'h0a); check(io_selected, 1); check(io_dout, 16'h5352);
        word_io(0); check(io_dout, status);
        word_io(0); lo = io_dout; word_io(0); hi = io_dout;
        check({hi, lo}, token);
        word_io(0); check(io_dout, lba[15:0]);
        word_io(0); check(io_dout, lba[31:16]);
        word_io(0); check(io_dout, 6); close_io;
    end
endtask

task reply(input [31:0] token, input [15:0] error);
    begin
        word_io(16'h0b); check(io_selected, 1);
        word_io(token[15:0]); word_io(token[31:16]); word_io(error); close_io;
    end
endtask

task attempt(input [31:0] lba);
    begin sd_lba = lba; sd_rd = 1; cycle; end
endtask

task transfer;
    begin sd_ack = 1; sd_rd = 0; repeat (3) cycle; sd_ack = 0; cycle; end
endtask

task finish_result;
    begin
        result_req = 0; cycle;
        check(result_ack, 0); check(result_error, 0); check(dut.pending, 0);
    end
endtask

initial begin
    cycle; nreset = 1; cycle;
    metadata(16'h0108, 0, 0);
    word_io(16'h08); check(io_selected, 0); check(io_dout, 0); close_io;
    word_io(16'h16); check(io_selected, 0); check(io_dout, 0); close_io;
    result_req = 1;
    reply(0, 0); check(result_ack, 0); result_req = 0;

    attempt(32'h12345678); first_token = 1;
    sd_lba = 32'h87654321;
    metadata(16'h010b, first_token, 32'h12345678);
    reply(first_token, 0); check(dut.result_valid, 0); check(result_ack, 0);
    sd_ack = 1; sd_rd = 0; cycle;
    reply(first_token, 0); check(dut.result_valid, 0);
    sd_ack = 0; cycle;
    reply(first_token + 1, 0); check(dut.result_valid, 0);
    word_io(16'h0b); word_io(first_token[15:0]); close_io;
    check(dut.result_valid, 0);
    // Mailbox delivery may precede the loader's result request.
    reply(first_token, 1); check(dut.result_valid, 1); check(result_ack, 0);
    reply(first_token, 0); check(dut.mailbox_error, 1);
    repeat (12) begin cycle; check(result_ack, 0); end
    result_req = 1; cycle; check(result_ack, 1); check(result_error, 1);
    reply(first_token, 0); check(result_ack, 1); check(result_error, 1);
    repeat (12) begin cycle; check(result_ack, 1); check(result_error, 1); end
    finish_result;
    reply(first_token, 0); check(dut.result_valid, 0);

    // Retry uses a new attempt token even at the same LBA.
    attempt(32'h12345678); second_token = first_token + 1;
    metadata(16'h010b, second_token, 32'h12345678); transfer;
    result_req = 1;
    repeat (12) begin cycle; check(result_ack, 0); end
    reply(first_token, 0); check(result_ack, 0);
    reply(second_token, 0); check(result_ack, 1); check(result_error, 0);
    finish_result;

    // A global abort discards mailbox state without reusing its token.
    attempt(32'd11); first_token = second_token + 1; transfer;
    reply(first_token, 0); check(dut.result_valid, 1);
    nreset = 0; cycle; check(result_ack, 0); check(dut.pending, 0);
    nreset = 1; cycle;
    attempt(32'd12); second_token = first_token + 1; transfer;
    result_req = 1;
    reply(first_token, 0); check(result_ack, 0);
    reply(second_token, 2); check(result_ack, 1); check(result_error, 1);
    finish_result;

    dut.token = 32'hffffffff;
    attempt(32'd13); metadata(16'h010a, 32'hffffffff, 13); transfer;
    result_req = 1; reply(32'hffffffff, 0);
    repeat (12) begin cycle; check(result_ack, 0); end
    nreset = 0; cycle; result_req = 0; mount_owned = 0; nreset = 1; cycle;
    metadata(16'h0100, 32'hffffffff, 0);
    $display("PASS: SWIM II checked-read host transport, %0d checks", checks);
    $finish;
end

initial begin #100000; $fatal(1, "timeout"); end
endmodule
