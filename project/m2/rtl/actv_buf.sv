// ============================================================================
// actv_buf.sv
// Activation history buffer — dual-port scratchpad RAM
//
// PURPOSE
//   Holds the inter-layer activation tensors and the temporal history required
//   to evaluate dilated Conv1d.  Two types of data share this buffer:
//
//   (a) Input history for dilated access:
//       DilatedUnit layers use dilation D ∈ {1, 3, 9} with kernel size K = 3,
//       so the deepest tap reaches back (K-1)·D = 2·9 = 18 time steps.
//       layer_control_fsm tracks a per-channel head pointer and accesses
//       address  chan_idx · BUF_HIST + (head − k·D) mod BUF_HIST
//       where BUF_HIST = 64 (ACTV_BUF_DEPTH in compute_core).
//
//   (b) Inter-layer activations:
//       After each non-head Conv1d layer, requantized INT8 outputs are written
//       back here so the next layer reads them as its input activations.
//
// CAPACITY
//   DEPTH = C_MAX × BUF_HIST = 1536 × 64 = 98 304 words (96 KB at INT8).
//   The largest layer has C_MAX = 1536 channels (before the head Conv1d).
//   Shallower layers use a contiguous sub-range of the address space.
//
// ADDRESSING
//   layer_control_fsm computes all addresses externally; this module is a
//   plain dual-port RAM.  Separate read and write addresses allow the FSM to
//   read one activation tap while simultaneously writing back another channel.
//
// CLOCK / RESET
//   Single clock domain (clk).  Synchronous reset (rst_n) zeroes all storage
//   on the first active clock edge — needed to avoid spurious values on the
//   first inference frame.  rd_data is registered (one-cycle read latency).
//
// PORT LIST
//   Name       Dir   Width      Purpose
//   --------------------------------------------------------------------------
//   clk        in    1          System clock
//   rst_n      in    1          Synchronous active-low reset; zeroes all entries
//
//   wr_en      in    1          Write enable
//   wr_addr    in    AADDR_W    Write address: chan_idx * BUF_HIST + time_offset
//   wr_data    in    WIDTH      One INT8 activation word
//
//   rd_en      in    1          Read enable; rd_data valid one cycle later
//   rd_addr    in    AADDR_W    Read address: chan_idx * BUF_HIST + dilated_offset
//   rd_data    out   WIDTH      Registered read data
// ============================================================================

module actv_buf #(
    parameter int DEPTH = 98304,   // C_MAX * BUF_HIST_DEPTH  (1536 * 64)
    parameter int WIDTH = 8        // DATA_WIDTH (INT8)
) (
    input  logic                     clk,
    input  logic                     rst_n,    // synchronous active-low

    // Write port
    input  logic                     wr_en,
    input  logic [$clog2(DEPTH)-1:0] wr_addr,
    input  logic [WIDTH-1:0]         wr_data,

    // Read port (one-cycle registered latency)
    input  logic                     rd_en,
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic [WIDTH-1:0]         rd_data
);

    // =========================================================================
    // Storage array
    // =========================================================================
    // At 98 304 × 8 b = 96 KB; synthesis maps this to embedded SRAM or BRAM.
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    // =========================================================================
    // Write path (synchronous)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // =========================================================================
    // Read path (registered, one-cycle latency)
    // =========================================================================
    // Reset clears rd_data only; the array itself is not reset cycle-by-cycle
    // to avoid a 98K-cycle reset storm.  The FSM ensures all channels are
    // initialised via wr_en before first use on any inference frame.
    always_ff @(posedge clk) begin
        if (~rst_n)
            rd_data <= '0;
        else if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
