`timescale 1ps/1ps
module tb_swim2_memory;
localparam integer TR = 6667, TS = 3*TR;
localparam [26:0] IMAGE_BASE = 27'h2400000;
reg clk_ram = 0, clk = 0;
always #TR clk_ram = ~clk_ram;
always #TS clk = ~clk;
reg nreset = 0, init = 1;
reg [15:0] sdram_sz = 16'h8003;
reg [12:0] image_blocks = 2880;
reg cpu_req = 0, cpu_we = 0;
reg [26:2] cpu_addr = 0;
reg [3:0] cpu_be = 0;
reg [31:0] cpu_wdata = 0;
wire cpu_ack;
wire [31:0] cpu_rdata;
reg load_req = 0, wr_req = 0, rd_req = 0;
reg [21:0] load_addr = 0, wr_addr = 0, rd_addr = 0;
reg [15:0] load_data = 0, wr_data = 0;
wire load_ack, wr_ack, rd_ack;
wire [7:0] rd_data;
wire beat_req, beat_we, beat_ack, beat_busy, beat_line_pending;
wire [26:2] beat_addr;
wire [3:0] beat_be;
wire [31:0] beat_wdata, beat_rdata;
wire memory_ready, mem_busy, fault;
reg wp_valid = 0;
reg [26:2] wp_addr = 0;
reg [3:0] wp_be = 0;
reg [31:0] wp_data = 0;
wire wq_room;
wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire [1:0] SDRAM_BA;
wire SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;
integer checks = 0, beats = 0, cpu_completions = 0, i, b0, cpu0;
reg [31:0] got;
reg [7:0] byte_value;
reg [3:0] old_acks = 0;
reg saw_read_tail = 0;

swim2_memory dut (.*);
sdram_beat32 bridge (
    .init(init), .clk_sys(clk), .clk_ram(clk_ram),
    .req(beat_req), .we(beat_we), .addr(beat_addr), .be(beat_be), .wdata(beat_wdata),
    .ack(beat_ack), .rdata(beat_rdata), .busy(beat_busy),
    .line_pending_o(beat_line_pending), .line_valid_o(), .line_tag_o(), .line_data_o(), .line_pending_tag_o(),
    .wp_valid(wp_valid), .wp_addr(wp_addr), .wp_be(wp_be), .wp_data(wp_data), .wq_room(wq_room),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_nCS(SDRAM_nCS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK)
);
sdram_model chip (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .ba(SDRAM_BA),
    .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML), .dq(SDRAM_DQ)
);
sdram_model chip_hi (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(~SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .ba(SDRAM_BA),
    .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML), .dq(SDRAM_DQ)
);

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
task drain;
    begin
        repeat (2) cycle;
        while (mem_busy) cycle;
        check(beat_busy, 0); check(beat_line_pending, 0); check(beat_ack, 0);
    end
endtask
task cpu_beat(input bit we, input [26:2] addr, input [3:0] be, input [31:0] data);
    begin
        cpu_we = we; cpu_addr = addr; cpu_be = be; cpu_wdata = data; cpu_req = 1;
        do cycle; while (!cpu_ack);
        got = cpu_rdata;
        cpu_req = 0; repeat (2) cycle;
        while (cpu_ack) cycle;
    end
endtask
task load_word(input [21:0] addr, input [15:0] data);
    begin
        load_addr = addr; load_data = data; load_req = 1;
        do cycle; while (!load_ack);
        load_req = 0; cycle;
        while (load_ack) cycle;
    end
endtask
task write_word(input [21:0] addr, input [15:0] data);
    begin
        wr_addr = addr; wr_data = data; wr_req = 1;
        do cycle; while (!wr_ack);
        wr_req = 0; cycle;
        while (wr_ack) cycle;
    end
endtask
task read_byte(input [21:0] addr);
    begin
        rd_addr = addr; rd_req = 1;
        do cycle; while (!rd_ack);
        byte_value = rd_data;
        rd_req = 0; cycle;
        while (rd_ack) cycle;
    end
endtask
task clear_fault;
    begin
        nreset = 0; repeat (4) cycle; nreset = 1; repeat (4) cycle;
        check(fault, 0);
    end
endtask
function [15:0] pattern(input integer word_index);
    pattern = {word_index[7:0] ^ 8'h59, word_index[7:0] ^ 8'he2};
endfunction

always @(negedge clk) begin
    if (beat_ack) beats = beats + 1;
    if (cpu_ack) cpu_completions = cpu_completions + 1;
    if (!nreset && (cpu_ack || load_ack || wr_ack || rd_ack))
        $fatal(1, "client completion during global abort");
    if (beat_busy || beat_line_pending || beat_ack)
        if (!mem_busy) $fatal(1, "memory drain fence dropped while bridge active");
    if (beat_line_pending && !beat_busy) saw_read_tail = 1;
end

initial begin
    repeat (4) cycle; init = 0;
    repeat (13000) @(posedge clk_ram);
    @(negedge clk); nreset = 1; repeat (4) cycle;
    check(chip.mode_set, 1); check(chip_hi.mode_set, 1); check(memory_ready, 1);
    cpu_beat(1, (IMAGE_BASE-4) >> 2, 4'hf, 32'h13579bdf);
    cpu_beat(1, 25'h200, 4'hf, 32'h2468ace0);
    load_word(0, 16'h1122); load_word(2, 16'h3344);
    write_word(4, 16'h5566); write_word(6, 16'h7788);
    drain;
    check(chip.peek(IMAGE_BASE >> 2, 0), 16'h1122);
    check(chip.peek(IMAGE_BASE >> 2, 1), 16'h3344);
    for (i = 0; i < 8; i = i + 1) begin
        read_byte(i); check(byte_value, 8'h11 * (i+1));
    end
    cpu_beat(0, (IMAGE_BASE-4) >> 2, 4'hf, 0); check(got, 32'h13579bdf);
    cpu_beat(0, 25'h200, 4'hf, 0); check(got, 32'h2468ace0);

    // Held level requests issue one physical beat and retain their reply.
    drain; b0 = beats;
    wr_addr = 8; wr_data = 16'h9abc; wr_req = 1;
    do cycle; while (!wr_ack);
    repeat (12) begin cycle; check(wr_ack, 1); end
    check(beats, b0 + 1);
    wr_req = 0; repeat (4) cycle; check(wr_ack, 0);
    drain; b0 = beats; cpu0 = cpu_completions;
    cpu_req = 1; cpu_we = 0; cpu_addr = 25'h200; cpu_be = 4'hf;
    do cycle; while (!cpu_ack);
    check(cpu_rdata, 32'h2468ace0);
    repeat (12) begin cycle; check(cpu_ack, 0); end
    check(beats, b0 + 1); check(cpu_completions, cpu0 + 1);
    cpu_req = 0; repeat (3) cycle;

    // Every port eventually progresses under simultaneous requests.
    cpu_req = 1; cpu_we = 1; cpu_addr = 25'h201; cpu_be = 4'hf; cpu_wdata = 32'h11223344;
    load_req = 1; load_addr = 10; load_data = 16'hdef0;
    wr_req = 1; wr_addr = 12; wr_data = 16'h0123;
    rd_req = 1; rd_addr = 0;
    old_acks = 0;
    while (old_acks != 4'hf) begin
        cycle;
        if (cpu_ack) begin old_acks[0] = 1; cpu_req = 0; end
        if (load_ack) begin old_acks[1] = 1; load_req = 0; end
        if (wr_ack) begin old_acks[2] = 1; wr_req = 0; end
        if (rd_ack) begin old_acks[3] = 1; rd_req = 0; check(rd_data, 8'h11); end
    end
    drain;

    // A registered CPU push keeps its direct FIFO contract during floppy work.
    fork
        begin : load_stream
            integer word_index;
            for (word_index = 0; word_index < 256; word_index = word_index + 1)
                load_word(22'd512 + word_index*2, pattern(word_index));
        end
        begin : cpu_stream
            integer word_index;
            for (word_index = 0; word_index < 64; word_index = word_index + 1) begin
                while (!wq_room) cycle;
                wp_addr = 25'h400 + word_index; wp_be = 4'hf;
                wp_data = 32'ha5000000 + word_index; wp_valid = 1; cycle;
                wp_valid = 0; cycle;
            end
        end
    join
    drain;
    for (i = 0; i < 256; i = i + 1) begin
        read_byte(22'd512 + i*2); check(byte_value, pattern(i) >> 8);
        read_byte(22'd513 + i*2); check(byte_value, pattern(i) & 255);
    end
    for (i = 0; i < 64; i = i + 1) begin
        cpu_beat(0, 25'h400+i, 4'hf, 0); check(got, 32'ha5000000+i);
    end

    // The last valid halfword is usable; offsets never wrap into guest RAM.
    load_word(22'd1474558, 16'hface); read_byte(22'd1474558); check(byte_value, 8'hfa);
    read_byte(22'd1474559); check(byte_value, 8'hce); drain;
    b0 = beats; wr_req = 1; wr_addr = 1; wr_data = 16'hdead;
    repeat (8) cycle; check(fault, 1); check(wr_ack, 0); check(beats, b0);
    wr_req = 0; clear_fault;
    b0 = beats; rd_req = 1; rd_addr = 22'd1474560;
    repeat (8) cycle; check(fault, 1); check(rd_ack, 0); check(beats, b0);
    rd_req = 0; clear_fault;
    b0 = beats; load_req = 1; load_addr = 22'h3ffffe;
    repeat (8) cycle; check(fault, 1); check(load_ack, 0); check(beats, b0);
    load_req = 0; clear_fault;

    sdram_sz = 16'h8001; repeat (2) cycle; check(memory_ready, 0);
    b0 = beats; load_req = 1; load_addr = 0;
    repeat (8) cycle; check(load_ack, 0); check(beats, b0); check(fault, 1);
    load_req = 0; clear_fault;
    sdram_sz = 0; repeat (2) cycle; check(memory_ready, 0);
    cpu_beat(0, (IMAGE_BASE-4) >> 2, 4'hf, 0); check(got, 32'h13579bdf);
    sdram_sz = 16'h8002; repeat (2) cycle; check(memory_ready, 1);
    image_blocks = 0; repeat (2) cycle; check(memory_ready, 0);
    image_blocks = 2881; repeat (2) cycle; check(memory_ready, 0);
    image_blocks = 2880; repeat (2) cycle; check(memory_ready, 1);

    // Abort an outstanding read; its eventual ACK cannot complete the next owner.
    drain; cpu0 = cpu_completions;
    rd_req = 1; rd_addr = 22'd2048;
    do cycle; while (!beat_req);
    cycle; nreset = 0; rd_req = 0;
    wr_req = 1; wr_addr = 22'd2050; wr_data = 16'hbeef;
    repeat (24) begin cycle; check(wr_ack, 0); check(rd_ack, 0); end
    nreset = 1;
    do cycle; while (!wr_ack);
    wr_req = 0; repeat (4) cycle;
    read_byte(22'd2050); check(byte_value, 8'hbe);
    read_byte(22'd2051); check(byte_value, 8'hef);
    check(cpu_completions, cpu0);
    drain;
    cpu_beat(0, (IMAGE_BASE-4) >> 2, 4'hf, 0); check(got, 32'h13579bdf);
    check(chip.errors + chip_hi.errors, 0);
    check(saw_read_tail, 1);
    $display("PASS: SWIM II memory arbitration and real SDRAM, %0d checks, %0d beats, zero chip protocol errors", checks, beats);
    $finish;
end
initial begin
    #2000000000;
    $display("checks=%0d beats=%0d cpu=%0d req=%b%b%b%b ack=%b%b%b%b state=%0d owner=%0d beat=%b/%b busy=%b/%b fault=%b",
        checks, beats, cpu_completions, cpu_req, load_req, wr_req, rd_req,
        cpu_ack, load_ack, wr_ack, rd_ack, dut.state, dut.owner,
        beat_req, beat_ack, beat_busy, beat_line_pending, fault);
    $fatal(1, "timeout");
end
endmodule
