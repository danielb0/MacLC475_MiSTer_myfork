`timescale 1ns/1ps
module tb_swim2_host_control;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
wire io_selected;
wire [15:0] io_dout;
reg host_owned = 0, media_live = 0, loader_fault = 0, writer_fault = 0;
wire cancel, release_request, loader_retry, save_retry;
integer checks = 0, load_retries = 0, save_retries = 0;
reg [15:0] response, status, lo, hi;
reg [31:0] first_token, second_token;
swim2_host_control dut (.*);
always @(posedge clk) begin
    if (loader_retry) load_retries <= load_retries + 1;
    if (save_retry) save_retries <= save_retries + 1;
end
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
task check(input [63:0] actual, input [63:0] wanted);
    begin
        checks = checks + 1;
        if (actual !== wanted) $fatal(1, "check %0d: got %h expected %h", checks, actual, wanted);
    end
endtask
task word_io(input [15:0] value);
    begin
        io_enable = 1; io_strobe = 1; io_din = value; cycle;
        io_strobe = 0; cycle; response = io_dout;
    end
endtask
task close_io;
    begin io_enable = 0; cycle; check(io_selected, 0); end
endtask
task metadata;
    begin
        word_io(16'h0c); check(response, 16'h5343); check(io_selected, 1);
        word_io(0); status = response;
        word_io(0); lo = response; word_io(0); hi = response;
        word_io(0); check(response, 0); word_io(0); check(response, 0);
        word_io(0); check(response, 6); close_io;
    end
endtask
task action(input [31:0] token, input [15:0] value);
    begin
        word_io(16'h0d); check(io_selected, 1);
        word_io(token[15:0]); word_io(token[31:16]); word_io(value); close_io;
    end
endtask
initial begin
    repeat (3) cycle; nreset = 1; cycle;
    metadata; check(status, 16'h0100);
    action(0, 1); check(cancel, 0);
    host_owned = 1; repeat (3) cycle;
    metadata; first_token = {hi, lo}; check(first_token, 1); check(status, 16'h0101);
    // Truncation, unknown actions and overlong transactions cannot eject.
    word_io(16'h0d); word_io(lo); word_io(hi); close_io; check(cancel, 0);
    action(first_token, 4); check(cancel, 0);
    word_io(16'h0d); word_io(lo); word_io(hi); word_io(0);
    repeat (24) word_io(1);
    close_io; check(cancel, 0);
    action(first_token + 1, 1); check(cancel, 0);
    loader_fault = 1; action(first_token, 2); check(load_retries, 1);
    action(first_token, 3); check(save_retries, 0);
    action(first_token, 1); check(cancel, 1); check(release_request, 0);
    action(first_token, 2); check(load_retries, 1);
    repeat (12) begin cycle; check(cancel, 1); end
    // A publication collision must turn cancellation into a live release.
    media_live = 1; cycle; check(cancel, 0); check(release_request, 1);
    writer_fault = 1; action(first_token, 3); check(save_retries, 1);
    repeat (12) begin cycle; check(release_request, 1); end
    host_owned = 0; media_live = 0; cycle;
    check(cancel, 0); check(release_request, 0);
    host_owned = 1; repeat (3) cycle;
    metadata; second_token = {hi, lo}; check(second_token, 2);
    action(first_token, 1); check(cancel, 0);
    // Global abort preserves token uniqueness.
    nreset = 0; cycle; nreset = 1; repeat (3) cycle;
    metadata; check({hi, lo}, 3);
    action(second_token, 1); check(cancel, 0);
    // A command spanning acquisition cannot use the old mount's token.
    word_io(16'h0d); word_io(3); word_io(0);
    host_owned = 0; cycle; host_owned = 1; cycle;
    word_io(1); close_io; check(cancel, 0);
    metadata; check({hi, lo}, 4);
    // Status and generation describe one mount even across a slow SPI read.
    word_io(16'h0c);
    host_owned = 0; cycle; host_owned = 1; repeat (3) cycle;
    word_io(0); check(response, 16'h0119);
    word_io(0); check(response, 4); word_io(0); check(response, 0); close_io;
    action(4, 1); check(cancel, 0);
    // Exhaustion cannot wrap to a previously used generation.
    dut.token = 32'hfffffffe;
    host_owned = 0; cycle; host_owned = 1; repeat (3) cycle;
    metadata; check({hi, lo}, 32'hffffffff); check(status[5], 1);
    action(32'hffffffff, 1); check(cancel, 0);
    host_owned = 0; cycle; host_owned = 1; repeat (3) cycle;
    metadata; check({hi, lo}, 32'hffffffff);
    $display("PASS: SWIM II host eject/retry controls, %0d checks", checks);
    $finish;
end
initial begin #1000000; $fatal(1, "timeout"); end
endmodule
