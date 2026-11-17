`timescale 1ns/1ps
module tb_cpu040;
reg clk = 0, nreset = 0;
always #20 clk = ~clk;
wire req, wr, instr, halted, stall;
wire [1:0] size;
wire [31:0] addr, wdata, instruction_pc;
reg ack = 0;
reg [31:0] rdata = 0;
integer stores = 0, vectors = 0, pending = 0, delay_left = 0;
reg [31:0] saved_addr;
reg [1:0] saved_size;
reg saved_write;

cpu040 #(.AP040_HAS_FPU(0)) dut (
    .clk(clk), .nreset(nreset), .ce(1'b1), .ipl(3'b111),
    .ipl_autovector(1'b1), .berr(1'b0), .stall_hold(1'b0), .dbg_stall_flt(stall),
    .cache_line_valid(1'b0), .cache_line_tag(28'd0), .cache_line_data(128'd0),
    .store_buffer_ok(1'b0), .bus_req(req), .bus_write(wr), .bus_instr(instr),
    .bus_size(size), .bus_addr(addr), .bus_wdata(wdata), .bus_fc(),
    .bus_ack(ack), .bus_rdata(rdata), .walker_req(), .walker_we(),
    .walker_addr(), .walker_wdat(), .walker_ack(1'b0), .walker_data(32'd0),
    .walker_berr(1'b0), .snoop_stb(1'b0), .snoop_addr(32'd0),
    .nresetout(), .nmi_ack_toggle(), .cacr_out(), .vbr_out(),
    .debug_busy(), .debug_fault(), .debug_halted(halted),
    .debug_status(), .debug_status2(), .debug_test_status(),
    .debug_instruction_pc(instruction_pc)
);

function [31:0] read_long(input [31:0] address);
    case (address[31:2])
        0: read_long = 32'h00007000;
        1: read_long = 32'h00000400;
        'h100: read_long = 32'h702A23C0; // MOVEQ #42,D0; MOVE.L D0,$600
        'h101: read_long = 32'h00000600;
        'h102: read_long = 32'h4E722700; // STOP #$2700
        default: read_long = 0;
    endcase
endfunction

always @(posedge clk) begin
    ack <= 0;
    if (!nreset) begin
        pending <= 0;
        delay_left <= 0;
    end
    else begin
        if (halted || stall) $fatal(1, "Integer smoke test halted or timed out");
        if (!pending && req && !ack) begin
            pending <= 1;
            delay_left <= (stores == 0) ? 0 : 3;
            saved_addr <= addr; saved_size <= size; saved_write <= wr;
        end
        else if (pending) begin
            if (!req || addr != saved_addr || size != saved_size || wr != saved_write)
                $fatal(1, "CPU changed an outstanding transaction");
            if (delay_left != 0) delay_left <= delay_left - 1;
            else begin
                ack <= 1; pending <= 0;
                if (wr) begin
                    if (addr != 'h600 || size != 2 || wdata != 42)
                        $fatal(1, "Bad integer store: %h size %d data %h", addr, size, wdata);
                    stores <= stores + 1;
                end
                else begin
                    if (!instr && addr < 8) vectors <= vectors + 1;
                    case (size)
                        0: rdata <= (read_long(addr) >> (8*(3-addr[1:0]))) & 32'hFF;
                        1: rdata <= (read_long(addr) >> (16*(1-addr[1]))) & 32'hFFFF;
                        default: rdata <= read_long(addr);
                    endcase
                end
            end
        end
    end
end

initial begin
    repeat (2) @(negedge clk);
    nreset = 1;
    wait (stores == 1);
    repeat (50) @(negedge clk);
    if (instruction_pc != 'h408) $fatal(1, "Retirement PC did not reach STOP");
    nreset = 0;
    repeat (4) @(negedge clk);
    nreset = 1;
    wait (stores == 2);
    repeat (50) @(negedge clk);
    if (vectors != 4 || instruction_pc != 'h408)
        $fatal(1, "Repeated reset/retirement failed");
    $display("PASS: pipelined CPU integer smoke, two resets and delayed bus replies");
    $finish;
end

initial begin
    #1000000;
    $fatal(1, "CPU smoke timeout: stores=%0d vectors=%0d PC=%h req=%b addr=%h",
           stores, vectors, instruction_pc, req, addr);
end
endmodule
