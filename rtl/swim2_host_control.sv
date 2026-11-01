// Mount-scoped host eject and retry commands over stock EXT_BUS.
module swim2_host_control (
    input        clk,
    input        nreset,
    input        io_strobe,
    input        io_enable,
    input [15:0] io_din,
    output       io_selected,
    output reg [15:0] io_dout,
    input        host_owned,
    input        media_live,
    input        loader_fault,
    input        writer_fault,
    output       cancel,
    output       release_request,
    output reg   loader_retry,
    output reg   save_retry
);

reg [15:0] command;
reg [3:0] word_count;
reg owned_d, eject_pending;
reg [31:0] token = 0; // Survives global abort; exhaustion fails closed.
reg [31:0] reply_token;
reg [31:0] status_token;
reg [15:0] status;
wire exhausted = token == 32'hffffffff;

assign io_selected = io_enable && (command == 16'h0c || command == 16'h0d);
assign cancel = nreset && eject_pending && host_owned && !media_live;
assign release_request = nreset && eject_pending && host_owned && media_live;

always @(posedge clk) begin
    loader_retry <= 0;
    save_retry <= 0;
    if (!nreset) begin
        command <= 0;
        word_count <= 0;
        io_dout <= 0;
        owned_d <= 0;
        eject_pending <= 0;
        reply_token <= 0;
        status_token <= 0;
        status <= 0;
    end else begin
        owned_d <= host_owned;
        if (host_owned && !owned_d && !exhausted) token <= token + 1'b1;
        if (!host_owned) eject_pending <= 0;

        if (!io_enable) begin
            command <= 0;
            word_count <= 0;
            io_dout <= 0;
        end else if (io_strobe) begin
            if (word_count != 15) word_count <= word_count + 1'b1;
            if (word_count == 0) begin
                command <= io_din;
                io_dout <= io_din == 16'h0c ? 16'h5343 : 16'd0;
                status_token <= token;
                status <= {8'h01, 2'd0, exhausted, writer_fault, loader_fault,
                           media_live, eject_pending, host_owned};
            end else if (command == 16'h0c) begin
                case (word_count)
                    1: io_dout <= status;
                    2: io_dout <= status_token[15:0];
                    3: io_dout <= status_token[31:16];
                    6: io_dout <= 16'd6;
                    default: io_dout <= 0;
                endcase
            end else if (command == 16'h0d) begin
                case (word_count)
                    1: reply_token[15:0] <= io_din;
                    2: reply_token[31:16] <= io_din;
                    3: if (host_owned && owned_d && !exhausted && reply_token == token) begin
                        case (io_din)
                            1: eject_pending <= 1;
                            2: loader_retry <= !media_live && loader_fault && !eject_pending;
                            3: save_retry <= media_live && writer_fault;
                            default: ;
                        endcase
                    end
                    default: ;
                endcase
            end
        end
    end
end

endmodule
