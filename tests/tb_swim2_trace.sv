`timescale 1ns/1ps
module tb_swim2_trace;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;
reg [15:0] events = 0;
reg [31:0] context_data = 32'h12345678, host_lba = 32'h89abcdef;
reg [7:0] error = 8'ha5, status = 8'h5a;
reg [21:0] decode_addr = 22'h123456, commit_addr = 22'h234567;
wire tx;
reg [191:0] record;
reg [7:0] ch;
integer i, frames = 0, received = 0;
integer losses = 0, old_losses = 0;
string hex_text;
integer capture;

swim2_trace #(.CLK_HZ(200000), .BAUD_DIV(2)) dut (.*);

task read_char(output [7:0] value);
    integer bit_index;
    begin
        @(negedge tx);
        repeat (3) @(posedge clk);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            value[bit_index] = tx; repeat (2) @(posedge clk);
        end
        if (tx !== 1'b1) $fatal(1, "UART stop bit");
    end
endtask

initial begin
    capture = $fopen("local/tests/swim2_trace_capture.txt", "w");
    if (!capture) $fatal(1, "capture open failed");
    forever begin
        read_char(ch); if (ch != "W") $fatal(1, "UART frame prefix");
        $fwrite(capture, "%c", ch);
        hex_text = "";
        for (i = 0; i < 48; i = i + 1) begin
            read_char(ch); hex_text = {hex_text, ch}; $fwrite(capture, "%c", ch);
        end
        read_char(ch); if (ch != 10) $fatal(1, "UART frame terminator");
        $fwrite(capture, "%c", ch);
        if ($sscanf(hex_text, "%h", record) != 1) $fatal(1, "UART hex data");
        if (record[143:112] != 32'h12345678 || record[111:90] != 22'h123456 ||
            record[89:68] != 22'h234567 || record[67:36] != 32'h89abcdef ||
            record[19:12] != 8'ha5 || record[11:4] != 8'h5a || record[3:0] != 1)
            $fatal(1, "torn UART snapshot: %s", hex_text);
        if (frames == 0 && record[191:176] != 0) $fatal(1, "missing initial heartbeat");
        if (record[191:176] != 0) begin
            if (record[191:176] != 16'h2159) $fatal(1, "simultaneous events lost");
            received = received + 1;
        end
        losses = record[35:20];
        if (losses < old_losses) $fatal(1, "loss counter went backwards");
        old_losses = losses; frames = frames + 1;
    end
end

initial begin
    repeat (4) @(negedge clk); nreset = 1;
    repeat (4) @(negedge clk);
    events = 16'h2159;
    repeat (140) @(negedge clk);
    events = 0;
    // No new events: the heartbeat must still report queue overflow.
    wait (losses != 0);
    if (received + losses != 140) $fatal(1, "capture/loss accounting: %0d + %0d", received, losses);
    // Global abort resets the queue, time base and loss count.
    nreset = 0; repeat (4) @(negedge clk);
    if (tx !== 1 || dut.wp != 0 || dut.rp != 0 || dut.dropped != 0 || dut.clocks != 0)
        $fatal(1, "trace global reset");
    $fclose(capture);
    $display("PASS: SWIM II trace UART, atomic/simultaneous events, queue overflow and reset, %0d frames", frames);
    $finish;
end
initial begin #10000000; $fatal(1, "timeout"); end
endmodule
