package ap68040_lc040_pkg;

localparam logic [9:0] LC_ENTRY = 10'd900, LC_EA = 10'd901, LC_FMT4 = 10'd904;
typedef struct packed {
    logic valid, ea, dynamic_list;
    logic [6:0] bytes;
} lc040_dec_t;

function automatic logic lc040_opmode(input logic [6:0] op);
    case (op)
        7'h05, 7'h07, 7'h0B, 7'h13, 7'h17, 7'h1B,
        7'h29, 7'h2A, 7'h2B, 7'h2C, 7'h2D, 7'h2E, 7'h2F,
        7'h39, 7'h3B, 7'h3C, 7'h3D, 7'h3E, 7'h3F,
        7'h42, 7'h43, 7'h46, 7'h47,
        7'h48, 7'h49, 7'h4A, 7'h4B, 7'h4C, 7'h4D, 7'h4E, 7'h4F,
        7'h50, 7'h51, 7'h52, 7'h53, 7'h54, 7'h55, 7'h56, 7'h57,
        7'h59, 7'h5B, 7'h5D, 7'h5F,
        7'h61, 7'h65, 7'h69, 7'h6A, 7'h6B, 7'h6D, 7'h6E, 7'h6F,
        7'h70, 7'h71, 7'h72, 7'h73, 7'h74, 7'h75, 7'h76, 7'h77,
        7'h78, 7'h79, 7'h7A, 7'h7B, 7'h7C, 7'h7D, 7'h7E, 7'h7F:
            lc040_opmode = 0;
        default: lc040_opmode = 1;
    endcase
endfunction

function automatic logic [6:0] lc040_list_bytes(input logic [7:0] mask);
    logic [3:0] count;
    count = 0;
    for (int i = 0; i < 8; i++) count = count + {3'd0, mask[i]};
    return {3'd0, count} * 7'd12;
endfunction

// Decode without an operand transfer or an address-register update.
function automatic lc040_dec_t lc040_decode(input logic [15:0] ow, ew);
    lc040_dec_t d;
    logic [2:0] mode, rn, sel;
    mode = ow[5:3]; rn = ow[2:0];
    sel = ew[12:10] == 0 ? 3'b001 : ew[12:10];
    d = '0;
    d.valid = (ow[15:9] == 7'b1111001);
    case (ew[12:10])
        0, 1: d.bytes = 4;
        4: d.bytes = 2;
        6: d.bytes = 1;
        5: d.bytes = 8;
        default: d.bytes = 12;
    endcase
    case (ow[8:6])
        0: begin
            d.ea = 1;
            if (mode == 7 && rn > 4) d.valid = 0;
            case (ew[15:13])
                0: begin d.valid &= lc040_opmode(ew[6:0]); d.bytes = 0; d.ea = 0; end
                1: d.valid = 0;
                2: begin
                    if (ew[12:10] == 7) begin
                        d.valid &= ew[6:0] == 0 || (ew[6:0] >= 'h0B && ew[6:0] <= 'h0F) ||
                                   (ew[6:0] >= 'h30 && ew[6:0] <= 'h3F);
                        d.bytes = 0;
                        d.ea = 0;
                    end
                    else d.valid &= lc040_opmode(ew[6:0]) && mode != 1 &&
                                    !(mode == 0 && d.bytes > 4);
                end
                3: d.valid &= mode != 1 && !(mode == 0 && d.bytes > 4) &&
                              !(mode == 7 && rn >= 2);
                4, 5: begin
                    d.bytes = ({5'd0, sel[0]} + {5'd0, sel[1]} + {5'd0, sel[2]}) * 7'd4;
                    d.valid &= !(mode == 0 && d.bytes != 4) && !(mode == 1 && sel != 1) &&
                               !(ew[13] && mode == 7 && rn >= 2);
                end
                default: begin
                    d.dynamic_list = ew[11];
                    d.bytes = lc040_list_bytes(ew[7:0]);
                    d.valid &= mode >= 2 && !(mode == 7 && rn == 4) &&
                               !(ew[13] && (mode == 3 || (mode == 7 && rn >= 2))) &&
                               !(!ew[13] && mode == 4);
                end
            endcase
        end
        1: begin
            d.valid &= !(mode == 7 && rn > 4);
            d.bytes = 1;
            d.ea = mode != 1 && !(mode == 7 && rn >= 2);
        end
        2, 3: begin d.bytes = 0; d.ea = 0; end
        4: begin
            d.valid &= mode >= 2 && mode != 3 && !(mode == 7 && rn > 1);
            d.bytes = 4; d.ea = 1;
        end
        5: begin
            d.valid &= mode >= 2 && mode != 4 && !(mode == 7 && rn >= 4);
            d.bytes = 4; d.ea = 1;
        end
        default: d.valid = 0;
    endcase
    d.ea &= mode >= 2 && !(mode == 7 && rn == 4);
    if (d.bytes == 1 && rn == 7) d.bytes = 2;
    return d;
endfunction

endpackage
