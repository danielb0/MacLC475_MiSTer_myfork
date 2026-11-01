// LC040 F-line handling at EX. D1 has consumed the instruction extensions.
module ap68040_lc040
    import ap68040_lc040_pkg::*;
(
    input logic clk, nreset, ex_v, safe, adv, kill,
    input logic [3:0] sub,
    input logic [15:0] ow, ew,
    input logic [31:0] ea, pc,
    input logic [7:0] list_mask,
    output logic hold,
    output logic [7:0] xvec,
    output logic [3:0] xfmt,
    output logic xnext,
    output logic [31:0] xaddr
);

logic [15:0] opword, extension;
lc040_dec_t current_dec, saved_dec;
logic [6:0] bytes;
assign current_dec = lc040_decode(ow, ew);
assign saved_dec = lc040_decode(opword, extension);
assign bytes = saved_dec.dynamic_list ? lc040_list_bytes(list_mask) : saved_dec.bytes;
assign hold = ex_v && !safe;

always_comb begin
    xvec = 0; xfmt = 0; xnext = 0; xaddr = pc;
    if (ex_v && safe) begin
        if (sub == 0) begin
            if (!current_dec.valid) xvec = 11;
        end
        else begin
            xvec = 11; xfmt = 4; xnext = 1; xaddr = 0;
            if (saved_dec.ea)
                xaddr = ea - (opword[5:3] == 4 ? {25'd0, bytes} : 32'd0);
        end
    end
end

always_ff @(posedge clk) begin
    if (!nreset || kill) begin
        opword <= 0;
        extension <= 0;
    end
    else if (adv && ex_v && safe && sub == 0) begin
        opword <= ow;
        extension <= ew;
    end
end

endmodule
