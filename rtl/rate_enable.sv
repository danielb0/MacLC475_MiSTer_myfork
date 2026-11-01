module rate_enable #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer RATE_HZ = 1_000
) (
    input  clk,
    input  nreset,
    input  ce,
    output tick
);

function automatic integer gcd(input integer a, input integer b);
    integer remainder;
    begin
        while (b != 0) begin
            remainder = a % b;
            a = b;
            b = remainder;
        end
        gcd = a;
    end
endfunction

// Phase starts at zero, so common units preserve every tick cycle.
localparam integer DIVISOR = (RATE_HZ > 0 && RATE_HZ <= CLK_HZ) ? gcd(CLK_HZ, RATE_HZ) : 1;
localparam integer CLOCK_UNITS = CLK_HZ / DIVISOR;
localparam integer RATE_UNITS = RATE_HZ / DIVISOR;
localparam integer ACCW = (CLOCK_UNITS > 1) ? $clog2(CLOCK_UNITS) : 1;
localparam [ACCW-1:0] STEP = ACCW'(RATE_UNITS);
localparam [ACCW-1:0] LIMIT = ACCW'(CLOCK_UNITS - RATE_UNITS);
reg [ACCW-1:0] phase = 0;

assign tick = nreset && ce && (phase >= LIMIT);

always @(posedge clk) begin
    if (!nreset) phase <= 0;
    else if (ce) phase <= tick ? phase - LIMIT : phase + STEP;
end

endmodule
