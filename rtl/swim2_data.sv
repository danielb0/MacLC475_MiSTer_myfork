// SWIM2 ERS Rev. 3.2, pp. 4-5, 9. Byte interface to the drive codecs.
module swim2_data (
    input        clk,
    input        nreset,
    input        ce,
    input        sel,          // one completed access to registers 0-2
    input        write,
    input  [1:0] addr,
    input  [7:0] wdata,
    output reg [7:0] rdata,
    input  [7:0] mode,
    input        context_changed,
    input        gcr,          // setup bit 2
    input        rddata,
    input        sense,
    input        rx_valid,     // one decoded medium byte per CE
    input  [7:0] rx_data,
    input        rx_mark,
    input        rx_crc_zero,  // CRC including this byte is zero
    input  [4:0] rx_sector,    // media provenance travels with the byte
    input        rx_short,
    input        rx_long,
    input        tx_take,      // medium byte deadline, including when empty
    input        tx_fault,     // outbound byte could not reach the media path
    output [7:0] tx_data,
    output       tx_mark,
    output       tx_crc,       // codec emits two CRC bytes for this token
    output       tx_valid,
    output [7:0] handshake,
    output       write_error,
    output reg [4:0] write_sector,
    output reg   write_sector_valid
);

// Entry: sector, CRC-zero, CRC token, mark, data. Oldest byte is entry 0.
reg [15:0] fifo [0:1];
reg [1:0] fifo_tag_valid;
reg [1:0] count;
reg [7:0] error;
reg synced;
reg read_active_d;
wire read_active = mode[3] && !mode[4];
wire read_start = read_active && !read_active_d;
wire clear_fifo = mode[0];
wire cpu_read = sel && !write;
wire cpu_write = sel && write;
wire error_read = cpu_read && addr == 2;
wire cpu_pop = cpu_read && !mode[4] &&
               (addr == 1 || (addr == 0 && mode[3]));
wire cpu_push = cpu_write && mode[4] && addr <= 2;
wire medium_pop = mode[3] && mode[4] && tx_take && error == 0;
wire medium_push = read_active && rx_valid &&
                   (gcr || rx_mark || (synced && !read_start));
wire pop_req = cpu_pop || medium_pop;
wire pop = pop_req && count != 0;
wire push_req = cpu_push || medium_push;
wire push = push_req && (count != 2 || pop);
wire [15:0] push_data = mode[4] ?
                       {6'd0, addr == 2, addr == 1, wdata} :
                       {rx_sector, rx_crc_zero, 1'b0, rx_mark, rx_data};
wire read_errors = read_active && !gcr &&
                   ((synced && !read_start) || (rx_valid && rx_mark));
reg [7:0] new_error;

always @* begin
    new_error = 0;
    if (!clear_fifo) begin
        if ((mode[4] && tx_fault) || (medium_pop && count == 0) ||
            (read_errors && medium_push && !push)) new_error = 8'h01;
        else if (read_errors && cpu_pop && pop && addr == 0 && fifo[0][8])
            new_error = 8'h02;
        else if ((cpu_push && !push) || (read_errors && cpu_pop && !pop))
            new_error = 8'h04;
        else if (read_errors && rx_short) new_error = 8'h10;
        else if (read_errors && rx_long) new_error = 8'h20;
    end
end

assign write_error = mode[4] && (error != 0 || new_error != 0);
assign tx_data = count != 0 ? fifo[0][7:0] : 8'd0;
assign tx_mark = count != 0 && fifo[0][8];
assign tx_crc = count != 0 && fifo[0][9];
assign tx_valid = mode[3] && mode[4] && !clear_fifo && count != 0 && error == 0;
assign handshake = {
    mode[4] ? (count != 2 || error != 0) : (count != 0),
    mode[4] ? (count == 0) : (count == 2),
    error != 0, 1'b0, sense, rddata,
    count != 0 && !fifo[0][10], count != 0 && fifo[0][8]
};

always @* begin
    rdata = 0;
    case (addr)
        2'd0: if (mode[3] && count != 0) rdata = fifo[0][7:0];
        2'd1: if (count != 0) rdata = fifo[0][7:0];
        2'd2: rdata = error;
        default: rdata = 0;
    endcase
end

always @(posedge clk) begin
    if (!nreset) begin
        count <= 0;
        error <= 0;
        synced <= 0;
        read_active_d <= 0;
        write_sector <= 0;
        write_sector_valid <= 0;
        fifo_tag_valid <= 0;
        fifo[0] <= 0;
        fifo[1] <= 0;
    end else if (ce) begin
        read_active_d <= read_active;
        // A new read invalidates the previous positional anchor. FIFO clear
        // preserves it: software clears the FIFO when switching to a write.
        if (read_start || context_changed) write_sector_valid <= 0;
        else if (!clear_fifo && cpu_pop && pop) begin
            write_sector <= fifo[0][15:11];
            write_sector_valid <= fifo_tag_valid[0];
        end
        if (!read_active || read_start || clear_fifo || context_changed) synced <= 0;
        if (read_active && !clear_fifo && !context_changed && rx_valid && rx_mark) synced <= 1;

        if (error_read) error <= 0;
        // Retain the first error; a new event survives a coincident read.
        if ((error == 0 || error_read) && new_error != 0) error <= new_error;

        if (clear_fifo) count <= 0;
        else begin
            case ({push, pop})
                2'b10: begin
                    fifo[count[0]] <= push_data;
                    fifo_tag_valid[count[0]] <= medium_push && !gcr && rx_sector != 0;
                    count <= count + 2'd1;
                end
                2'b01: begin
                    fifo[0] <= fifo[1];
                    fifo_tag_valid[0] <= fifo_tag_valid[1];
                    count <= count - 2'd1;
                end
                2'b11: begin
                    if (count == 2) begin
                        fifo[0] <= fifo[1];
                        fifo_tag_valid[0] <= fifo_tag_valid[1];
                    end
                    fifo[count == 2 ? 1 : 0] <= push_data;
                    fifo_tag_valid[count == 2 ? 1 : 0] <= medium_push && !gcr && rx_sector != 0;
                end
                default: ;
            endcase
        end
        // Retain guest-visible FIFO bytes, but revoke stale positional metadata.
        if (clear_fifo || context_changed) fifo_tag_valid <= 0;
    end
end

endmodule
