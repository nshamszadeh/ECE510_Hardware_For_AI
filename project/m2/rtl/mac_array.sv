// ============================================================================
// mac_array.sv
// Systolic MAC array — LANES parallel INT8×INT8 multiply-accumulate units
//
// PURPOSE
//   Instantiates LANES mac_lane modules to evaluate LANES output channels of
//   a Conv1d layer in parallel.  The RAVE v2 encoder has up to C_OUT = 256
//   output channels; with LANES = 64 the array completes one output time step
//   in C_OUT / LANES = 4 passes over the output-channel dimension.
//
// DATA FLOW
//   For each (input_channel, kernel_tap) pair the FSM presents:
//     - weight[LANES-1:0][DW-1:0]: one INT8 weight per lane, read from the wide
//       word returned by weight_sram (all LANES weights at this kernel position
//       for LANES consecutive output channels are packed into one SRAM word).
//     - actv[DW-1:0]: a single INT8 activation sample, broadcast identically to
//       every lane.
//   Each lane accumulates:  acc_i ← acc_i + weight[i] × actv  (INT32)
//
//   When the FSM has streamed all (c_in × K) pairs for the current group, the
//   accumulators hold the complete INT32 partial sums psum[LANES-1:0][AW-1:0].
//   The FSM then asserts clear before the next output-channel group so all
//   accumulators reset simultaneously.
//
// CLEAR / ENABLE PROTOCOL
//   clear has priority over en (delegated to mac_lane).  The FSM may assert
//   clear and en on the same cycle to atomically reset and begin accumulating
//   the first product of the new group.
//
// CLOCK / RESET
//   Single clock domain (clk).  Synchronous active-low reset (rst_n) is
//   broadcast to all mac_lane instances, zeroing every accumulator.
//
// PORT LIST
//   Name       Dir   Width              Purpose
//   --------------------------------------------------------------------------
//   clk        in    1                  System clock
//   rst_n      in    1                  Synchronous active-low reset (broadcast)
//   clear      in    1                  Broadcast clear to all lanes (priority)
//   en         in    1                  Broadcast enable to all lanes
//   weight     in    LANES × DW         Per-lane INT8 weight operands (packed 2-D)
//   actv       in    DW                 Single INT8 activation word, broadcast
//   psum       out   LANES × AW         Per-lane INT32 accumulated partial sums
// ============================================================================

module mac_array #(
    parameter int LANES = 64,    // parallel MAC units; must evenly divide C_OUT
    parameter int DW    = 8,     // data width (INT8)
    parameter int AW    = 32     // accumulator width (INT32)
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        clear,
    input  logic                        en,
    input  logic [LANES-1:0][DW-1:0]   weight,  // one INT8 weight per lane
    input  logic [DW-1:0]              actv,    // broadcast INT8 activation
    output logic [LANES-1:0][AW-1:0]   psum     // per-lane INT32 partial sums
);

    // =========================================================================
    // Lane instantiation
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < LANES; i++) begin : gen_lanes
            mac_lane #(
                .DW (DW),
                .AW (AW)
            ) u_lane (
                .clk    (clk),
                .rst_n  (rst_n),
                .clear  (clear),
                .en     (en),
                .weight (weight[i]),
                .actv   (actv),
                .acc    (psum[i])
            );
        end
    endgenerate

endmodule
