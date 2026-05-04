// ============================================================================
// leaky_relu.sv
// Combinational LeakyReLU activation — LANES-wide, fixed-point INT32
//
// PURPOSE
//   Applies LeakyReLU element-wise to all LANES INT32 partial-sum outputs of
//   mac_array before they are requantized and written back to actv_buf
//   (inter-layer) or to the output register (head layer).
//
//   LeakyReLU:  y = x         if x ≥ 0
//               y = α · x     if x < 0
//   where α = 0.2 (matching blocks.py: nn.LeakyReLU(.2) throughout EncoderV2).
//
// FIXED-POINT APPROXIMATION
//   α = 0.2 is approximated as ALPHA_MULT / 2^ALPHA_SHIFT = 205 / 1024.
//   Error: |0.2 − 205/1024| = 0.000195, relative error < 0.1%.
//
//   For the negative branch:
//     out = (in × 205) >>> 10   (arithmetic right shift)
//
//   The intermediate product requires 64-bit signed arithmetic:
//   max|in| after 12,288 INT8×INT8 accumulations ≈ 2×10^8;
//   2×10^8 × 205 ≈ 4.1×10^10, which exceeds INT32 (2.1×10^9).
//   A 64-bit intermediate prevents overflow.
//
// CLOCK / RESET
//   None — purely combinational.
//
// PORT LIST
//   Name       Dir   Width         Purpose
//   --------------------------------------------------------------------------
//   in_data    in    LANES × AW    INT32 partial sums from mac_array
//   out_data   out   LANES × AW    Activated INT32 outputs
// ============================================================================

module leaky_relu #(
    parameter int LANES       = 64,
    parameter int AW          = 32,   // accumulator width (INT32)
    parameter int ALPHA_MULT  = 205,  // α numerator:   α ≈ ALPHA_MULT / 2^ALPHA_SHIFT
    parameter int ALPHA_SHIFT = 10    // α denominator: 2^10 = 1024
) (
    input  logic [LANES-1:0][AW-1:0] in_data,
    output logic [LANES-1:0][AW-1:0] out_data
);

    // Declare ALPHA_MULT as a 64-bit signed localparam so the multiply below
    // stays signed regardless of how different tools interpret parameter casts.
    localparam logic signed [63:0] ALPHA64 = ALPHA_MULT;

    genvar i;
    generate
        for (i = 0; i < LANES; i++) begin : gen_lane
            logic signed [63:0] in64;
            logic signed [63:0] prod;

            // Sign-extend AW-bit accumulator to 64 bits (explicit concatenation
            // avoids relying on implicit sign-extension in width casts).
            assign in64 = {{(64-AW){in_data[i][AW-1]}}, in_data[i]};

            // Both operands are signed [63:0], so * is a signed 64-bit multiply.
            // Max |in64| ≈ 2e8; 2e8 × 205 ≈ 4.1e10 < 2^63 — no overflow.
            assign prod = in64 * ALPHA64;

            // Negative branch (MSB=1): divide by 2^ALPHA_SHIFT via arithmetic
            // right shift, then truncate to AW bits.  Result fits in AW bits
            // because |prod >>> ALPHA_SHIFT| ≤ |in_data[i]|.
            // Positive branch (MSB=0): pass through unchanged.
            assign out_data[i] = in_data[i][AW-1]
                ? AW'(prod >>> ALPHA_SHIFT)
                : in_data[i];
        end
    endgenerate

endmodule
