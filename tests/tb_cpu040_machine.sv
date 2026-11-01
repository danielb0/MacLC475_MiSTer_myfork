`timescale 1ns/1ps
module tb_cpu040_machine;
reg clk = 0, nreset = 0;
always #20 clk = ~clk;
reg [2:0] irq = 3'b111;
wire mem_req, mem_write, mem_wp_valid, halted, fault, overlay;
wire mem_vram_wp;
wire [31:2] mem_addr, mem_wp_addr;
wire [3:0] mem_be, mem_wp_be;
wire [31:0] mem_wdata, mem_wp_data;
wire [1:0] mem_memsel;
reg ram_ack = 0;
reg [31:0] ram_rdata = 0;
reg vram_phase = 0;
reg [31:0] vram_q = 0;
reg [7:0] vram [0:65535];
wire vram_req = mem_req && mem_memsel == 2;
wire mem_ack = ram_ack || (vram_req && vram_phase);
wire [31:0] mem_rdata = mem_memsel == 2 ? vram_q : ram_rdata;
reg line_valid = 0, rom_line_valid = 0;
reg [26:4] line_tag = 0;
reg [19:4] rom_line_tag = 0;
reg [127:0] line_data = 0, rom_line_data = 0;
reg retain = 0, room = 1;
reg [7:0] rom [0:65535];
reg [7:0] ram [0:4194303];
reg [31:0] expected [0:31];
integer pc, signatures = 0, expected_count = 0, signature_slot = 0;
integer delay_cycles = 0, delay_left = 0, transfers = 0, posts = 0;
integer vector_reads = 0, irq_reads = 0, fill_beats = 0, cache_reads = 0;
integer runs = 0, plain_transfers = 0;
reg [31:0] wait_pc, done_pc;

quadra605 #(.CDROM(0), .SONIC(0)) dut (
    .clk(clk), .nreset(nreset), .cuda_power_reset_n(nreset), .cuda_host_reset_n(nreset),
    .ce(1'b1), .clk_vid(clk), .nreset_vid(nreset), .ram_cfg(3'd0), .mon_12in(1'b0),
    .dbg_sw(3'd0), .eth_ena(1'b0), .adb_diagnostic(1'b0), .video_diagnostic(1'b0),
    .video_platform_status(16'd0), .mem_req(mem_req), .mem_write(mem_write),
    .mem_addr(mem_addr), .mem_be(mem_be), .mem_wdata(mem_wdata), .mem_memsel(mem_memsel),
    .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_wq_room(room),
    .mem_wp_valid(mem_wp_valid), .mem_wp_addr(mem_wp_addr),
    .mem_wp_be(mem_wp_be), .mem_wp_data(mem_wp_data),
    .mem_vram_wp(mem_vram_wp),
    .mem_line_valid(line_valid), .mem_line_tag(line_tag), .mem_line_data(line_data),
    .mem_line_pending(1'b0), .mem_line_pending_tag(23'd0),
    .mem_rom_line_valid(rom_line_valid), .mem_rom_line_tag(rom_line_tag),
    .mem_rom_line_data(rom_line_data), .vid_rdata(32'd0),
    .img_mounted(3'd0), .img_size(64'd0), .io_ack(3'd0),
    .sd_buff_addr(13'd0), .sd_buff_dout(16'd0), .sd_buff_wr(1'b0),
    .ps2_key(11'd0), .ps2_mouse(25'd0), .timestamp(33'd0),
    .pram_h_we(1'b0), .pram_h_addr(7'd0), .pram_h_wdata(16'd0),
    .scc_rxd_a(1'b1), .scc_cts_a(1'b1), .scc_rxd_b(1'b1),
    .eth_mem_accept(1'b0), .eth_mem_rvalid(1'b0), .eth_mem_rdata(64'd0),
    .debug_halted(halted), .debug_fault(fault), .dbg_overlay(overlay)
);

// Exercise CPU interrupt entry at the IOSB output boundary.
always @* force dut.ipl_n = irq;

// Match production BRAM capture/deliver timing; storage omits stride compaction.
always @(posedge clk) begin
    if (!nreset) vram_phase <= 0;
    else if (vram_req) vram_phase <= !vram_phase;
    vram_q <= {vram[{mem_addr[15:2],2'b00}], vram[{mem_addr[15:2],2'b01}],
               vram[{mem_addr[15:2],2'b10}], vram[{mem_addr[15:2],2'b11}]};
    if ((vram_req && mem_write && !vram_phase) || mem_vram_wp)
        for (integer i = 0; i < 4; i++)
            if (mem_be[3-i]) vram[{mem_addr[15:2],2'b00}+i] <= mem_wdata[31-i*8 -: 8];
end

function automatic [31:0] read32(input bit is_rom, input integer a);
    if (is_rom) return {rom[a & 65535], rom[(a+1) & 65535],
                        rom[(a+2) & 65535], rom[(a+3) & 65535]};
    if (a < 0 || a > 4194300) $fatal(1, "Unexpected physical RAM address %h", a);
    return {ram[a], ram[a+1], ram[a+2], ram[a+3]};
endfunction

task automatic write_ram(input integer a, input [3:0] be, input [31:0] data);
    if (a < 0 || a > 4194300) $fatal(1, "Unexpected physical write %h", a);
    for (integer i = 0; i < 4; i++)
        if (be[3-i]) ram[a+i] = data[31-i*8 -: 8];
    line_valid <= 0;
    if (a >= 'h100 && a < 'h180) begin
        if (signatures >= expected_count || a != 'h100 + signatures*4 || be != 15 || data !== expected[signatures])
            $fatal(1, "Signature %0d: addr=%h be=%h data=%h expected=%h",
                   signatures, a, be, data, expected[signatures]);
        signatures++;
    end
endtask

always @(posedge clk) begin
    ram_ack <= 0;
    if (!nreset) begin
        delay_left <= 0;
        line_valid <= 0; rom_line_valid <= 0;
    end
    else begin
        if (halted || fault || dut.cpu_stall_flt || dut.cpu_berr)
            $fatal(1, "Machine fault at PC %h", dut.cpu_instruction_pc);
        if (mem_wp_valid) begin
            if (!room) $fatal(1, "Posted write ignored FIFO backpressure");
            write_ram({mem_wp_addr, 2'b00}, mem_wp_be, mem_wp_data);
            posts++;
        end
        if (dut.bus_req && dut.bus_ack && !dut.bus_write) begin
            if (!dut.bus_instr && dut.bus_addr < 8) vector_reads++;
            if (!dut.bus_instr && dut.bus_addr == 'h68) irq_reads++;
            if (!dut.bus_instr && dut.bus_addr >= 'h2000 && dut.bus_addr < 'h2010)
                cache_reads++;
            if (dut.cpu.c_siz == 3) fill_beats++;
        end
        if (mem_req && mem_memsel != 2 && !mem_ack) begin
            if (delay_left < delay_cycles) delay_left <= delay_left + 1;
            else begin
                delay_left <= 0;
                ram_ack <= 1;
                transfers++;
                if (mem_memsel > 1) $fatal(1, "Unexpected memory select %d", mem_memsel);
                if (mem_write) begin
                    if (mem_memsel == 0) write_ram({mem_addr, 2'b00}, mem_be, mem_wdata);
                end
                else begin
                    ram_rdata <= read32(mem_memsel == 1, {mem_addr, 2'b00});
                    if (mem_memsel == 1) begin
                        rom_line_valid <= retain;
                        rom_line_tag <= mem_addr[19:4];
                        for (integer i = 0; i < 4; i++)
                            rom_line_data[127-i*32 -: 32] <= read32(1, {mem_addr[31:4],4'd0} + i*4);
                    end
                    else begin
                        line_valid <= retain;
                        line_tag <= mem_addr[26:4];
                        for (integer i = 0; i < 4; i++)
                            line_data[127-i*32 -: 32] <= read32(0, {mem_addr[31:4],4'd0} + i*4);
                    end
                end
            end
        end
    end
end

task automatic emit16(input [15:0] v);
    rom[pc] = v[15:8]; rom[pc+1] = v[7:0]; pc += 2;
endtask
task automatic emit32(input [31:0] v);
    emit16(v[31:16]); emit16(v[15:0]);
endtask
task automatic store(input [31:0] a, input [31:0] v);
    emit16('h23FC); emit32(v); emit32(a); // MOVE.L #v,(a).L
endtask
task automatic check_read(input [31:0] a, input [31:0] v);
    emit16('h2039); emit32(a); // MOVE.L (a).L,D0
    emit16('h23C0); emit32('h100 + signature_slot*4);
    expected[signature_slot] = v;
    signature_slot++;
endtask

`include "tests/support/cpu040_profile.svh"

initial begin
    for (integer i = 0; i < 65536; i++) rom[i] = 0;
    if ($test$plusargs("PROFILE")) begin
        run_profile();
        $finish;
    end
    pc = 0; emit32('h7000); emit32('h40800400);
    pc = 'h400;
    emit16('hF4D8); // CINVA BC: reset preserves cache contents.
    store('h1000, 'h11223344);
    check_read('h00101000, 'h11223344);
    check_read('h00201000, 'h11223344);
    emit16('h13FC); emit16('h00A5); emit32('h1001); // MOVE.B #$A5,$1001
    emit16('h33FC); emit16('hB6C7); emit32('h1002); // MOVE.W #$B6C7,$1002
    check_read('h1000, 'h11A5B6C7);
    store('h100F, 'h89ABCDEF);
    check_read('h100F, 'h89ABCDEF);
    check_read('h0C000000, 0);
    // Set bank 0 mode 1: all four soldered megabytes are addressable.
    store('h5000E07C, 'h10);
    store('h5000E004, 0);
    check_read('h5000E07C, 'h10);
    store('h00101000, 'h55667788);
    check_read('h00101000, 'h55667788);
    check_read('h1000, 'h11A5B6C7);
    store('h2000, 'hCAFEBABE);
    store('h68, 'h40800800); // level 2 autovector
    emit16('h203C); emit32('h80008000);
    emit16('h4E7B); emit16('h0002); // MOVEC D0,CACR
    check_read('h2000, 'hCAFEBABE);
    check_read('h2000, 'hCAFEBABE);
    store('h2000, 'hDEADBEEF);
    check_read('h2000, 'hDEADBEEF);
    wait_pc = 'h40800000 + pc;
    emit16('h4E72); emit16('h2000); // STOP, allow interrupts
    check_read('h2100, 'h12345678);
    done_pc = 'h40800000 + pc;
    emit16('h4E72); emit16('h2700);
    expected_count = signature_slot;
    pc = 'h800;
    store('h2100, 'h12345678);
    emit16('h4E73); // RTE

    // Repeat with platform retained lines, delayed memory and FIFO backpressure.
    for (integer run = 0; run < 2; run++) begin
        nreset = 0; irq = 7;
        repeat (8) @(negedge clk);
        for (integer i = 0; i < 4194304; i++) ram[i] = 0;
        signatures = 0; transfers = 0; posts = 0;
        vector_reads = 0; irq_reads = 0; fill_beats = 0; cache_reads = 0;
        retain = (run != 0); delay_cycles = run*3;
        nreset = 1;
        wait (dut.cpu_instruction_pc == wait_pc);
        repeat (40) @(negedge clk);
        if (overlay || signatures != expected_count-1 || vector_reads != 2)
            $fatal(1, "Overlay/reset execution incomplete");
        if (dut.cpu.cpu.cacr != 'h80008000 || fill_beats == 0 || cache_reads != 4)
            $fatal(1, "Cache fill/hit checks failed: beats=%0d reads=%0d", fill_beats, cache_reads);
        // Block posted stores while the interrupt handler writes RAM.
        room = 0; irq = 3'b101;
        wait (irq_reads == 1);
        @(negedge clk); irq = 7;
        wait (dut.bus_req && dut.bus_write && dut.bus_addr == 'h2100 && dut.bus_ack);
        @(negedge clk); room = 1;
        wait (dut.cpu_instruction_pc == done_pc);
        repeat (40) @(negedge clk);
        if (signatures != expected_count || irq_reads != 1)
            $fatal(1, "Interrupt/RTE execution incomplete");
        if (run == 0) plain_transfers = transfers;
        else if (transfers >= plain_transfers)
            $fatal(1, "Retained lines did not reduce platform reads");
        $display("PASS: CPU040 machine run %0d: %0d signatures, %0d memory beats, %0d posted writes",
                 run, signatures, transfers, posts);
        runs++;
    end
    $display("PASS: CPU040 MEMCjr execution, overlay, aliases, lanes, split access, caches, IRQ/RTE and reset (%0d runs)", runs);
    $finish;
end

initial begin
    if ($test$plusargs("PROFILE")) #20000000;
    else #4000000;
    $fatal(1, "Machine timeout: PC=%h bus=%h req=%b signatures=%0d irq_reads=%0d",
           dut.cpu_instruction_pc, dut.bus_addr, dut.bus_req, signatures, irq_reads);
end
endmodule
