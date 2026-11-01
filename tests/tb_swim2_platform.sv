`timescale 1ns/1ps
module tb_swim2_platform;
reg clk = 0;
always #20 clk = ~clk;
reg nreset = 0, guest_reset = 0, init = 0;
reg [15:0] sdram_sz = 16'h8003;
wire [35:0] EXT_BUS;
reg io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
assign EXT_BUS[35:33] = {1'b0, io_enable, io_strobe};
assign EXT_BUS[31:16] = io_din;
reg sel = 0, write = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata;
reg img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = 737280;
wire [31:0] sd_lba;
wire sd_rd, sd_wr, fault;
reg sd_ack = 0, sd_buff_wr = 0;
reg [12:0] sd_buff_addr = 0;
reg [15:0] sd_buff_dout = 0;
wire [15:0] sd_buff_din;
reg cpu_req = 0, cpu_we = 0;
reg [26:2] cpu_addr = 25'h100;
reg [3:0] cpu_be = 15;
reg [31:0] cpu_wdata = 0;
wire cpu_ack;
wire [31:0] cpu_rdata;
wire beat_req, beat_we;
wire [26:2] beat_addr;
wire [3:0] beat_be;
wire [31:0] beat_wdata;
reg beat_ack = 0;
reg [31:0] beat_rdata = 0;
wire beat_busy = beat_ack;
reg beat_line_pending = 0;
reg [31:0] ram [0:184319];
reg [15:0] saved [0:255];
localparam [26:2] IMAGE_BASE = 25'h0900000;
integer checks = 0, accepted = 0, b, w, i, lane, position, cycles = 0, last_byte_cycle;
integer last_write_cycle = 0, write_period = 0, write_bytes = 0;
reg [15:0] response, lo, hi, crc;
reg [7:0] got, handshake, expected;
reg persisted = 0;
`ifdef SWIM2_TRACE
wire trace_tx;
`endif

swim2_platform dut (.*);

task check(input [63:0] actual, input [63:0] expected_value);
    begin
        checks = checks + 1;
        if (actual !== expected_value)
            $fatal(1, "check %0d at %0t: got %016h expected %016h", checks, $time, actual, expected_value);
    end
endtask
task cycle;
    begin @(posedge clk); #1; @(negedge clk); end
endtask
function [7:0] original(input integer offset);
    original = offset[7:0] ^ offset[16:9] ^ 8'h9b;
endfunction
function [7:0] written(input integer offset);
    written = offset[7:0] ^ {7'd0, offset[8]} ^ 8'h35;
endfunction
function [15:0] crc_step(input [15:0] c, input [7:0] d);
    reg [15:0] v;
    integer k;
    begin
        v = c;
        for (k = 7; k >= 0; k = k - 1)
            v = (v[15] ^ d[k]) ? {v[14:0], 1'b0} ^ 16'h1021 : {v[14:0], 1'b0};
        crc_step = v;
    end
endfunction
always @(posedge clk) begin
    cycles = cycles + 1;
    if (write_period != 0 && dut.drive.written_strobe) begin
        if (last_write_cycle != 0) check(cycles - last_write_cycle, write_period);
        last_write_cycle = cycles;
        write_bytes = write_bytes + 1;
    end
    beat_ack <= 0;
    if (beat_req && !beat_ack) begin
        beat_ack <= 1;
        accepted = accepted + 1;
        if (beat_addr == cpu_addr) beat_rdata <= 32'h13579bdf;
        else begin
            check(beat_addr >= IMAGE_BASE && beat_addr < IMAGE_BASE + 184320, 1);
            position = beat_addr - IMAGE_BASE;
            if (beat_we) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (beat_be[3-lane]) ram[position][(3-lane)*8 +: 8] <= beat_wdata[(3-lane)*8 +: 8];
            end else beat_rdata <= ram[position];
        end
    end
end
task word_io(input [15:0] value, output [15:0] reply);
    begin
        io_enable = 1; io_strobe = 1; io_din = value; cycle;
        io_strobe = 0; cycle; reply = EXT_BUS[15:0];
    end
endtask
task close_io;
    begin io_enable = 0; cycle; check(EXT_BUS[32], 0); end
endtask
task metadata(input [15:0] command, input [15:0] magic);
    begin
        word_io(command, response); check(response, magic);
        word_io(0, response); check(response, 16'h010b);
        word_io(0, lo); word_io(0, hi);
        word_io(0, response); check(response, sd_lba[15:0]);
        word_io(0, response); check(response, 0);
        word_io(0, response); check(response, 6); close_io;
    end
endtask
task result(input [15:0] command, input error);
    begin
        word_io(command, response); word_io(lo, response); word_io(hi, response);
        word_io({15'd0, error}, response); close_io;
    end
endtask
task control(input [15:0] action);
    reg [15:0] token_lo, token_hi;
    begin
        word_io(16'h0c, response); check(response, 16'h5343);
        word_io(0, response); check(response[0], 1);
        word_io(0, token_lo); word_io(0, token_hi);
        word_io(0, response); word_io(0, response); word_io(0, response); close_io;
        word_io(16'h0d, response); word_io(token_lo, response); word_io(token_hi, response);
        word_io(action, response); close_io;
    end
endtask
task transfer_read;
    begin
        sd_ack = 1; cycle;
        for (w = 0; w < 256; w = w + 1) begin
            sd_buff_addr = w;
            sd_buff_dout = persisted && b == 0 ? saved[w] :
                           {original(b*512+w*2+1), original(b*512+w*2)};
            sd_buff_wr = 1; cycle;
        end
        sd_buff_wr = 0; repeat (3) cycle; sd_ack = 0; cycle;
    end
endtask
task wr(input [2:0] a, input [7:0] value);
    begin addr = a; wdata = value; write = 1; sel = 1; cycle; sel = 0; write = 0; cycle; end
endtask
task rd(input [2:0] a, output [7:0] value);
    begin addr = a; sel = 1; write = 0; #1; value = rdata; cycle; sel = 0; cycle; end
endtask
task next_read;
    begin
        handshake = 0;
        while (!handshake[7]) rd(7, handshake);
        rd(handshake[0] ? 1 : 0, got);
    end
endtask
task put(input [2:0] a, input [7:0] value);
    begin
        handshake = 0;
        while (!handshake[7]) rd(7, handshake);
        wr(a, value);
    end
endtask
task transfer_save(input error);
    begin
        while (!sd_wr) cycle;
        check(sd_lba, 0); metadata(16'h08, 16'h5357);
        sd_ack = 1; cycle;
        for (w = 0; w < 256; w = w + 1) begin
            sd_buff_addr = w; cycle;
            check(sd_buff_din, {written(w*2+1), written(w*2)});
            saved[w] = sd_buff_din;
        end
        sd_ack = 0; cycle;
        repeat (8) cycle; result(16'h09, error);
        if (!error) persisted = 1;
    end
endtask

initial begin
    repeat (4) cycle; nreset = 1; repeat (4) cycle;
    img_mounted = 1; cycle; img_mounted = 0;
    b = 0; while (!sd_rd) cycle;
    metadata(16'h0a, 16'h5352); transfer_read; result(16'h0b, 1);
    while (!fault) cycle;
    check(accepted, 0); control(2);
    // Load runs through a guest reset and publishes only after checked results.
    guest_reset = 1;
    for (b = 0; b < 1440; b = b + 1) begin
        while (!sd_rd) cycle;
        check(sd_lba, b); metadata(16'h0a, 16'h5352); transfer_read; result(16'h0b, 0);
    end
    while (!dut.drive.loaded) cycle;
    guest_reset = 0; repeat (4) cycle; check(fault, 0);
    for (i = 0; i < 184320; i = i + 1)
        check(ram[i], {original(i*4), original(i*4+1), original(i*4+2), original(i*4+3)});

    // Mode motor-on alone starts rotation, without a mechanical motor command.
    wr(7, 8'h82); wr(4, 8'hf4); wr(7, 8);
    last_byte_cycle = 0;
    for (b = 158; b < 720; b = b + 1) begin
        next_read;
        if (b > 158) check(cycles - last_byte_cycle, 800);
        last_byte_cycle = cycles;
        if (b < 80 || (b >= 96 && b < 146) || (b >= 168 && b < 190)) check(got, 8'h4e);
        if ((b >= 158 && b < 161) || (b >= 202 && b < 205)) check(got, 8'ha1);
        if (b == 161) check(got, 8'hfe);
        if (b == 164) check(got, 1);
        if (b == 205) check(got, 8'hfb);
        if (b >= 206 && b < 718) check(got, original(b - 206));
        if (b == 719) check(handshake[1], 0);
    end
    check(dut.drive.read_fault, 0);
    // Arbitration must route the machine's reply separately from image reads.
    cpu_req = 1; while (!cpu_ack) cycle; check(cpu_rdata, 32'h13579bdf);
    cpu_req = 0; repeat (4) cycle;

    // Normal clock drains at 16 us even on DD media; it must not follow rotation.
    wr(6, 8); wr(7, 16); wr(7, 1); wr(6, 1);
    wr(1, 8'ha1); wr(1, 8'ha1);
    write_period = 400; wr(7, 8);
    while (dut.drive.mode[3]) cycle;
    check(write_bytes, 2); check(dut.drive.buffer_owned, 0);
    write_period = 0; last_write_cycle = 0; write_bytes = 0;
    rd(2, got); check(got, 1);
    wr(5, 8); wr(7, 1); wr(6, 1);
    write_period = 800;
    wr(1, 8'ha1); wr(1, 8'ha1); wr(7, 8);
    put(1, 8'ha1); put(0, 8'hfb);
    for (b = 0; b < 512; b = b + 1) put(0, written(b));
    put(2, 0);
    while (!sd_wr) cycle;
    check(write_bytes, 518); write_period = 0;
    // Completed bytes survive guest reset and a host eject during failed save.
    guest_reset = 1; control(1); transfer_save(1);
    while (!fault) cycle;
    repeat (20) cycle; check(dut.storage.loader.host_owned, 1);
    control(3); transfer_save(0);
    while (dut.storage.loader.host_owned) cycle;
    check(persisted, 1); check(fault, 0);
    guest_reset = 0; repeat (8) cycle;
    check(dut.drive.loaded, 0);
    // Reload the modeled durable sector through the actual loader and byte fetcher.
    img_mounted = 1; cycle; img_mounted = 0;
    for (b = 0; b < 1440; b = b + 1) begin
        while (!sd_rd) cycle;
        metadata(16'h0a, 16'h5352); transfer_read; result(16'h0b, 0);
    end
    while (!dut.drive.loaded) cycle;
    wr(7, 8'h82); wr(4, 8'hf4); wr(7, 8);
    for (b = 158; b < 718; b = b + 1) begin
        next_read;
        if (b >= 206) check(got, written(b - 206));
    end
    check(dut.drive.read_fault, 0); check(fault, 0);
    $display("PASS: SWIM II production platform load/read/write/retry/eject/reload, %0d checks", checks);
    $finish;
end
initial begin #600000000; $fatal(1, "timeout"); end
endmodule
