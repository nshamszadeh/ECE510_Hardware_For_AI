// ============================================================================
// weight_sram.sv
// On-chip weight SRAM — dual-port, write-narrow / read-wide
//
// PURPOSE
//   Stores all RAVE v2 encoder weights on-chip so that inference frames incur
//   zero DRAM traffic for weights.  The write port is narrow (one DATA_WIDTH
//   word per cycle) to accept the serial stream from interface.sv during the
//   one-time initialisation phase.  The read port is wide (MAC_LANES words per
//   cycle) so that layer_control_fsm can supply all MAC_LANES parallel weight
//   operands to mac_array in a single clock.
//
//   In synthesis this module maps to an embedded SRAM macro with a column-mux
//   ratio of MAC_LANES between the write and read ports.  In simulation the
//   behavioural model uses a flat logic array of depth DEPTH and width RD_WIDTH.
//
// CAPACITY
//   RAVE v2 encoder weights: ~16 M INT8 words = 16 MB (quantized from FP32).
//   Default: DEPTH = SRAM_DEPTH / MAC_LANES = 16 M / 64 = 262 144 wide words.
//            RD_WIDTH = MAC_LANES × DATA_WIDTH = 64 × 8 = 512 bits per word.
//            WR_WIDTH = DATA_WIDTH = 8 bits (one INT8 word per write).
//   interface.sv accumulates MAC_LANES consecutive narrow write beats before
//   asserting wr_en, so each wr_en pulse writes one full wide word.
//
// CLOCK / RESET
//   Single clock domain (clk).  No reset — contents are undefined until the
//   initialisation write sequence completes.  rd_data is registered (one-cycle
//   read latency); the FSM issues rd_addr one cycle before consuming rd_data.
//
// PORT LIST
//   Name        Dir   Width      Purpose
//   --------------------------------------------------------------------------
//   clk         in    1          System clock
//
//   wr_en       in    1          Write enable; one wide word written per pulse
//   wr_addr     in    WADDR_W    Word address for the write (wide-word granularity)
//   wr_data     in    RD_WIDTH   Data word to write (MAC_LANES INT8 weights packed)
//
//   rd_en       in    1          Read enable; rd_data valid on the next posedge
//   rd_addr     in    WADDR_W    Word address to read
//   rd_data     out   RD_WIDTH   Registered read data: MAC_LANES INT8 weights
// ============================================================================

module weight_sram #(
    parameter int DEPTH    = 262144,         // wide-word count (SRAM_DEPTH / MAC_LANES)
    parameter int WR_WIDTH = 8,              // narrow write width (DATA_WIDTH = INT8)
    parameter int RD_WIDTH = 512             // wide read width (MAC_LANES * DATA_WIDTH)
) (
    input  logic                       clk,

    // Write port — narrow, one INT8 word per beat; interface.sv packs beats
    input  logic                       wr_en,
    input  logic [$clog2(DEPTH)-1:0]   wr_addr,
    input  logic [RD_WIDTH-1:0]        wr_data,  // full wide word delivered by interface.sv

    // Read port — wide, one cycle registered latency
    input  logic                       rd_en,
    input  logic [$clog2(DEPTH)-1:0]   rd_addr,
    output logic [RD_WIDTH-1:0]        rd_data
);

    // =========================================================================
    // Storage array
    // =========================================================================
    // At 262 144 × 512 b = 16 MB this must map to embedded SRAM macros in
    // synthesis.  For simulation, this elaborates as a large logic array.
    logic [RD_WIDTH-1:0] mem [0:DEPTH-1];

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
    always_ff @(posedge clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
