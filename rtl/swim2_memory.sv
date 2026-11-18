// Image byte offsets share the existing SDRAM beat port with the machine.
module swim2_memory (
    input        clk,
    input        nreset, // Global client abort; an in-flight beat still drains.
    input        init,   // Shared SDRAM bridge power-up.
    input [15:0] sdram_sz,
    input [12:0] image_blocks,
    input        cpu_req,
    input        cpu_we,
    input [26:2] cpu_addr,
    input  [3:0] cpu_be,
    input [31:0] cpu_wdata,
    output       cpu_ack,
    output [31:0] cpu_rdata,
    input        load_req,
    input [21:0] load_addr,
    input [15:0] load_data,
    output       load_ack,
    input        wr_req,
    input [21:0] wr_addr,
    input [15:0] wr_data,
    output       wr_ack,
    input        rd_req,
    input [21:0] rd_addr,
    output       rd_ack,
    output [7:0] rd_data,
    output       beat_req,
    output reg   beat_we = 0,
    output reg [26:2] beat_addr = 0,
    output reg [3:0] beat_be = 0,
    output reg [31:0] beat_wdata = 0,
    input        beat_ack,
    input [31:0] beat_rdata,
    input        beat_busy,
    input        beat_line_pending,
    output       memory_ready,
    output       mem_busy,
    output reg   fault = 0
);

// All populated MEMCjr banks lie below byte 36 MiB, including aliases, except
// the 64 MB rank of the 68 MB and 100 MB options, which sits at 64-128 MiB.
localparam [26:0] IMAGE_BASE = 27'h2400000;
localparam IDLE = 2'd0, WAIT_ACK = 2'd1, TURN = 2'd2, DRAIN = 2'd3;
localparam CPU = 2'd0, LOAD = 2'd1, WRITE = 2'd2, READ = 2'd3;
reg [1:0] state = DRAIN, owner = CPU, next_owner = CPU;
reg [1:0] byte_lane = 0;
reg [7:0] held_byte = 0;
reg discard = 0;
reg [2:0] selected;
reg [3:0] eligible;
reg [21:0] offset;
reg [15:0] word_data;
integer i, candidate;
wire geometry_valid = image_blocks != 0 && image_blocks <= 2880;
wire load_valid = !load_addr[0] && load_addr[21:9] < image_blocks;
wire write_valid = !wr_addr[0] && wr_addr[21:9] < image_blocks;
wire read_valid = rd_addr[21:9] < image_blocks;
wire owner_req = owner == CPU ? cpu_req : owner == LOAD ? load_req :
                 owner == WRITE ? wr_req : rd_req;
wire reply = nreset && !init && !discard &&
             ((state == WAIT_ACK && beat_ack) || state == TURN);

assign memory_ready = nreset && !init && sdram_sz[15] &&
                      (sdram_sz[1:0] == 2 || sdram_sz[1:0] == 3) && geometry_valid;
assign beat_req = !init && state == WAIT_ACK && !beat_ack;
assign cpu_ack = reply && state == WAIT_ACK && owner == CPU;
assign cpu_rdata = beat_rdata;
assign load_ack = reply && owner == LOAD;
assign wr_ack = reply && owner == WRITE;
assign rd_ack = reply && owner == READ;
assign rd_data = state == WAIT_ACK ? (beat_rdata >> ((3 - byte_lane) * 8)) : held_byte;
assign mem_busy = state != IDLE || beat_busy || beat_line_pending || beat_ack;

always @* begin
    eligible = {rd_req && read_valid && memory_ready,
                wr_req && write_valid && memory_ready,
                load_req && load_valid && memory_ready, cpu_req};
    selected = 3'd4;
    candidate = 0;
    for (i = 0; i < 4; i = i + 1) begin
        candidate = (next_owner + i) & 3;
        if (selected == 4 && eligible[candidate]) selected = candidate;
    end
    offset = selected == LOAD ? load_addr : selected == WRITE ? wr_addr : rd_addr;
    word_data = selected == LOAD ? load_data : wr_data;
end

always @(posedge clk) begin
    if (init) begin
        state <= DRAIN;
        discard <= 1;
        fault <= 0;
    end else begin
        if (!nreset) begin
            discard <= 1;
            fault <= 0;
        end else if ((load_req && (!memory_ready || !load_valid)) ||
                     (wr_req && (!memory_ready || !write_valid)) ||
                     (rd_req && (!memory_ready || !read_valid))) fault <= 1;

        case (state)
            IDLE: if (!nreset) state <= DRAIN;
            else if (!beat_ack && selected != 4) begin
                owner <= selected[1:0];
                next_owner <= selected[1:0] + 2'd1;
                discard <= 0;
                if (selected == CPU) begin
                    beat_we <= cpu_we;
                    beat_addr <= cpu_addr;
                    beat_be <= cpu_be;
                    beat_wdata <= cpu_wdata;
                end else begin
                    beat_we <= selected != READ;
                    beat_addr <= IMAGE_BASE[26:2] + {5'd0, offset[21:2]};
                    beat_be <= selected == READ ? 4'b1111 : offset[1] ? 4'b0011 : 4'b1100;
                    beat_wdata <= {word_data, word_data};
                    byte_lane <= offset[1:0];
                end
                state <= WAIT_ACK;
            end
            WAIT_ACK: if (beat_ack) begin
                held_byte <= beat_rdata >> ((3 - byte_lane) * 8);
                state <= (!nreset || discard) ? DRAIN : TURN;
            end
            TURN: if (!nreset || discard) state <= DRAIN;
                  else if (!owner_req && !beat_ack) state <= IDLE;
            DRAIN: if (nreset && !beat_busy && !beat_line_pending && !beat_ack) begin
                discard <= 0;
                state <= IDLE;
            end
            default: state <= DRAIN;
        endcase
    end
end

endmodule
