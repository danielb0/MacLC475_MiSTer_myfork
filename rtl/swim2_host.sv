// Core-specific durable results over stock hps_io EXT_BUS.
module swim2_host (
    input        clk,
    input        nreset,
    inout [35:0] EXT_BUS,
    input        mount_owned,
    input [31:0] sd_lba,
    input        sd_wr,
    input        sd_ack,
    input        durable_req,
    output reg   durable_ack,
    output reg   durable_error
);

wire io_strobe = EXT_BUS[33];
wire io_enable = EXT_BUS[34];
wire [15:0] io_din = EXT_BUS[31:16];
reg [15:0] command, io_dout;
reg [3:0] word_count;
reg sd_wr_d, pending, result_valid, result_error;
reg [31:0] token = 0; // Survives global abort; exhaustion fails closed.
reg [31:0] lba, reply_token;

assign EXT_BUS[32] = io_enable && (command == 16'h08 || command == 16'h09);
assign EXT_BUS[15:0] = io_dout;

always @(posedge clk) begin
    if (!nreset) begin
        command <= 0;
        io_dout <= 0;
        word_count <= 0;
        sd_wr_d <= 0;
        pending <= 0;
        result_valid <= 0;
        result_error <= 0;
        durable_ack <= 0;
        durable_error <= 0;
        lba <= 0;
        reply_token <= 0;
    end else begin
        sd_wr_d <= sd_wr;
        if (sd_wr && !sd_wr_d) begin
            if (token != 32'hffffffff) begin
                token <= token + 1'b1;
                pending <= 1;
            end else pending <= 0;
            lba <= sd_lba;
            result_valid <= 0;
            durable_ack <= 0;
            durable_error <= 0;
        end

        if (pending && result_valid && durable_req && !durable_ack) begin
            durable_ack <= 1;
            durable_error <= result_error;
        end
        if (durable_ack && !durable_req) begin
            durable_ack <= 0;
            durable_error <= 0;
            result_valid <= 0;
            pending <= 0;
        end

        if (!io_enable) begin
            command <= 0;
            word_count <= 0;
            io_dout <= 0;
        end else if (io_strobe) begin
            if (word_count != 15) word_count <= word_count + 1'b1;
            if (word_count == 0) begin
                command <= io_din;
                io_dout <= io_din == 16'h08 ? 16'h5357 : 16'd0;
            end else if (command == 16'h08) begin
                case (word_count)
                    1: io_dout <= {8'h01, 4'd0, mount_owned, sd_ack, sd_wr, pending};
                    2: io_dout <= token[15:0];
                    3: io_dout <= token[31:16];
                    4: io_dout <= lba[15:0];
                    5: io_dout <= lba[31:16];
                    6: io_dout <= 16'd6;
                    default: io_dout <= 0;
                endcase
            end else if (command == 16'h09) begin
                case (word_count)
                    1: reply_token[15:0] <= io_din;
                    2: reply_token[31:16] <= io_din;
                    3: if (pending && !sd_wr && !sd_ack && !result_valid &&
                           !durable_ack && reply_token == token) begin
                        result_valid <= 1;
                        result_error <= io_din != 0;
                    end
                    default: ;
                endcase
            end
        end
    end
end

endmodule
