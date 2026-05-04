// ============================================================================
// mac_lane.sv
// Single INT8×INT8 multiply-accumulate lane with INT32 accumulator
//
// PURPOSE
//   One processing element of the systolic MAC array.  On each enabled clock
//   cycle it computes  acc ← acc + weight × actv  and holds the result in a
//   registered INT32 accumulator.  A clear pulse resets the accumulator to
//   zero, which the FSM issues at the start of each new output-channel group.
//
//   In the RAVE encoder each lane is responsible for one output channel within
//   the current MAC group.  Over a full Conv1d evaluation the FSM streams all
//   (input_channel, kernel_tap) pairs through the lane; when all pairs have
//   been presented the accumulator holds the complete integer dot product for
//   that output channel.
//
// ARITHMETIC
//   Operands are signed INT8.  The multiply produces a signed INT16 intermediate
//   that is sign-extended to AW bits before accumulation into the INT32 register.
//   This avoids overflow: max sum over 12,288 INT8×INT8 products = 198,246,912,
//   which fits comfortably within INT32 (max 2,147,483,647).  See precision.md.
//
// TIMING
//   clear and en are synchronous.  clear takes priority over en so that
//   zeroing the accumulator and loading the first product can occur in
//   consecutive cycles without a gap cycle.
//
// CLOCK / RESET
//   Single clock domain (clk).  Synchronous active-low reset (rst_n) zeroes
//   the accumulator; equivalent to a permanent clear.
//
// PORT LIST
//   Name      Dir   Width   Purpose
//   --------------------------------------------------------------------------
//   clk       in    1       System clock
//   rst_n     in    1       Synchronous active-low reset; zeroes accumulator
//   clear     in    1       Synchronous accumulator clear (priority over en)
//   en        in    1       Accumulate: acc ← acc + weight × actv this cycle
//   weight    in    DW      INT8 weight operand (from weight_sram slice)
//   actv      in    DW      INT8 activation operand (broadcast from actv_buf)
//   acc       out   AW      Current INT32 accumulator value (registered)
// ============================================================================

module mac_lane #(
    parameter int DW = 8,    // data width (INT8)
    parameter int AW = 32    // accumulator width (INT32)
) (
    input  logic          clk,
    input  logic          rst_n,  // synchronous active-low
    input  logic          clear,  // priority: zeroes acc; overrides en
    input  logic          en,     // accumulate this cycle
    input  logic [DW-1:0] weight,
    input  logic [DW-1:0] actv,
    output logic [AW-1:0] acc
);

    // =========================================================================
    // Accumulator register
    // =========================================================================
    logic signed [AW-1:0]     acc_r;
    logic signed [2*DW-1:0]   product;

    // INT8 × INT8 → INT16 signed product; sign-extended to AW for accumulation
    assign product = $signed(weight) * $signed(actv);

    always_ff @(posedge clk) begin
        if (~rst_n || clear)
            acc_r <= '0;
        else if (en)
            acc_r <= acc_r + AW'(signed'(product));
    end

    assign acc = acc_r;

endmodule
