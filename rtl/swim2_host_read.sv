// Checked host read results over core-specific user I/O commands.
module swim2_host_read (
    input        clk,
    input        nreset,
    input        io_strobe,
    input        io_enable,
    input [15:0] io_din,
    output       io_selected,
    output reg [15:0] io_dout,
    input        mount_owned,
    input [31:0] sd_lba,
    input        sd_rd,
    input        sd_ack,
    input        result_req,
    output reg   result_ack,
    output reg   result_error
);

reg [15:0] command;
reg [3:0] word_count;
reg sd_rd_d, pending, result_valid, mailbox_error;
reg [31:0] token = 0; // Survives global abort; exhaustion fails closed.
reg [31:0] lba, reply_token;

assign io_selected = io_enable && (command == 16'h0a || command == 16'h0b);

always @(posedge clk) begin
    if (!nreset) begin
        command <= 0;
        io_dout <= 0;
        word_count <= 0;
        sd_rd_d <= 0;
        pending <= 0;
        result_valid <= 0;
        mailbox_error <= 0;
        result_ack <= 0;
        result_error <= 0;
        lba <= 0;
        reply_token <= 0;
    end else begin
        sd_rd_d <= sd_rd;
        if (sd_rd && !sd_rd_d) begin
            if (token != 32'hffffffff) begin
                token <= token + 1'b1;
                pending <= 1;
            end else pending <= 0;
            lba <= sd_lba;
            result_valid <= 0;
            result_ack <= 0;
            result_error <= 0;
        end

        if (pending && result_valid && result_req && !result_ack) begin
            result_ack <= 1;
            result_error <= mailbox_error;
        end
        if (result_ack && !result_req) begin
            result_ack <= 0;
            result_error <= 0;
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
                io_dout <= io_din == 16'h0a ? 16'h5352 : 16'd0;
            end else if (command == 16'h0a) begin
                case (word_count)
                    1: io_dout <= {8'h01, 4'd0, mount_owned, sd_ack, sd_rd, pending};
                    2: io_dout <= token[15:0];
                    3: io_dout <= token[31:16];
                    4: io_dout <= lba[15:0];
                    5: io_dout <= lba[31:16];
                    6: io_dout <= 16'd6;
                    default: io_dout <= 0;
                endcase
            end else if (command == 16'h0b) begin
                case (word_count)
                    1: reply_token[15:0] <= io_din;
                    2: reply_token[31:16] <= io_din;
                    3: if (pending && !sd_rd && !sd_ack && !result_valid &&
                           !result_ack && reply_token == token) begin
                        result_valid <= 1;
                        mailbox_error <= io_din != 0;
                    end
                    default: ;
                endcase
            end
        end
    end
end

endmodule

