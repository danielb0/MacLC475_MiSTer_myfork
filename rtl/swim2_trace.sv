// Passive 115200-baud trace. W + 48 hex digits + LF, 8N1.
module swim2_trace #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer BAUD_DIV = CLK_HZ / 115200
) (
    input clk,
    input nreset,
    input [15:0] events,
    input [31:0] context_data,
    input [7:0] error,
    input [21:0] decode_addr, commit_addr,
    input [31:0] host_lba,
    input [7:0] status,
    output tx
);

reg [31:0] clocks, heartbeat;
reg [15:0] dropped;
reg [191:0] queue [0:127];
reg [7:0] wp, rp;
reg [191:0] current;
reg have;
reg [5:0] character;
reg [9:0] shift;
reg [3:0] bits_left;
reg [31:0] baud_count;
wire empty = wp == rp;
wire full = wp == {~rp[7], rp[6:0]};
wire pop = !have && bits_left == 0 && !empty;
wire sample = events != 0 || heartbeat == 0;
assign tx = shift[0];

function [7:0] hex_digit(input [3:0] value);
    hex_digit = value < 10 ? 8'h30 + {4'd0, value} : 8'h37 + {4'd0, value};
endfunction

always @(posedge clk) begin
    if (!nreset) begin
        clocks <= 0; heartbeat <= 0; dropped <= 0; wp <= 0; rp <= 0;
    end else begin
        clocks <= clocks + 32'd1;
        heartbeat <= heartbeat == 0 ? CLK_HZ - 1 : heartbeat - 32'd1;
        if (sample && !full) begin
            queue[wp[6:0]] <= {events, clocks, context_data, decode_addr, commit_addr,
                               host_lba, dropped, error, status, 4'd1};
            wp <= wp + 8'd1;
        end else if (events != 0 && dropped != 16'hffff) dropped <= dropped + 16'd1;
        if (pop) rp <= rp + 8'd1;
    end
end

always @(posedge clk) begin
    if (!nreset) begin
        current <= 0; have <= 0; character <= 0;
        shift <= 10'h3ff; bits_left <= 0; baud_count <= 0;
    end else if (bits_left != 0) begin
        if (baud_count == 0) begin
            shift <= {1'b1, shift[9:1]};
            bits_left <= bits_left - 4'd1;
            baud_count <= BAUD_DIV - 1;
        end else baud_count <= baud_count - 32'd1;
    end else if (pop) begin
        current <= queue[rp[6:0]]; have <= 1; character <= 0;
    end else if (have) begin
        if (character == 0) shift <= {1'b1, 8'h57, 1'b0};
        else if (character == 49) begin
            shift <= {1'b1, 8'h0a, 1'b0}; have <= 0;
        end else begin
            shift <= {1'b1, hex_digit(current[191:188]), 1'b0};
            current <= {current[187:0], 4'd0};
        end
        character <= character + 6'd1;
        bits_left <= 10; baud_count <= BAUD_DIV - 1;
    end
end
endmodule
