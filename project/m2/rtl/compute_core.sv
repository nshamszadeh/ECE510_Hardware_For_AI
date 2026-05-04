// ============================================================================
// compute_core.sv
// RAVE v2 Variational Encoder — Systolic Conv1d Accelerator, Compute Core
//
// ECE 510 Project Milestone 2
//
// ============================================================================
// PURPOSE
//   Top-level compute module for the RAVE v2 EncoderV2 accelerator.  Wires
//   together the sub-modules that implement the full encoder layer stack:
//
//     weight_sram      — on-chip SRAM holding all encoder weights (~16 MB INT8)
//     actv_buf         — activation history scratchpad for dilated Conv1d
//     mac_array        — LANES-wide systolic INT8×INT8 MAC array (INT32 acc.)
//     leaky_relu       — combinational LeakyReLU applied between layers
//     layer_control_fsm — control plane: SRAM addresses, enables, counters
//
//   All AXI4-Stream framing is handled by interface.sv; this module presents
//   plain valid/ready handshakes and a dedicated SRAM write port for the
//   one-time weight initialisation.
//
// ============================================================================
// ALGORITHM
//   1D discrete convolution  y[c_o, t] = Σ_{c_i,k} w[c_o,c_i,k] · x[c_i, t·S+k·D]
//   where K=kernel size, S=stride (downsampling), D=dilation (residual units).
//   Activation: LeakyReLU(α=0.2) applied between encoder layers.
//   Corresponds to PyTorch: blocks.EncoderV2.forward() → cc.Conv1d → aten::mkldnn_convolution.
//
// ============================================================================
// NUMERIC PRECISION
//   Weights and activations: signed INT8 (quantized from FP32 on the host).
//   MAC accumulators: signed INT32.  Requantization (INT32→INT8, saturation
//   clamp to [-128,127]) is applied after each LeakyReLU using a per-layer
//   right-shift (rq_shift) from layer_control_fsm.  See precision.md.
//
// ============================================================================
// ENCODER ARCHITECTURE (v2.gin)
//   Stem:    Conv1d( 16→  96, K=7, S=1)
//   Stage 0: 3×DilatedUnit( 96, K=3, D∈{1,3,9}) + Conv1d( 96→192, K=8, S=4)
//   Stage 1: 3×DilatedUnit(192, K=3, D∈{1,3,9}) + Conv1d(192→384, K=8, S=4)
//   Stage 2: 3×DilatedUnit(384, K=3, D∈{1,3,9}) + Conv1d(384→768, K=8, S=4)
//   Stage 3: 2×DilatedUnit(768, K=3, D∈{1,3  }) + Conv1d(768→1536,K=4, S=2)
//   Head:    Conv1d(1536→256, K=3, S=1)   (256 = 2×LATENT_SIZE: µ ‖ log σ²)
//   Total compression: 128× (3000 input steps → 24 latent steps per frame)
//
// ============================================================================
// INTERFACE TO interface.sv
//   Compute core presents plain valid/ready handshakes; interface.sv handles
//   AXI4-Stream protocol.  Weight initialisation is via the w_* port group:
//   interface.sv packs MAC_LANES consecutive INT8 words from the AXI4-Stream
//   into one wide word and writes it through w_wr_en/addr/data.
//
// ============================================================================
// CLOCK / RESET
//   Single clock domain: clk (posedge).
//   Reset: synchronous, active-low (rst_n).  All sub-module registers clear
//   to 0 on the first posedge after rst_n is de-asserted.
//
// ============================================================================
// PORT LIST
//   Name          Dir   Width             Purpose
//   --------------------------------------------------------------------------
//   clk           in    1                 System clock
//   rst_n         in    1                 Synchronous active-low reset
//
//   w_wr_en       in    1                 Weight SRAM write enable (init only)
//   w_wr_addr     in    WADDR_W           Wide-word address into weight_sram
//   w_wr_data     in    MAC_LANES*DW      Wide word: MAC_LANES packed INT8 weights
//   w_load_done   in    1                 Pulsed by interface.sv after last weight word;
//                                         core holds s_ready low until seen
//
//   s_valid       in    1                 Input time step ready (from interface.sv)
//   s_ready       out   1                 Core can accept input this cycle
//   s_data        in    C_IN*DW           Packed 16-channel INT8 input
//   s_last        in    1                 Final time step of the input frame
//
//   m_valid       out   1                 Latent output time step valid
//   m_ready       in    1                 Downstream (interface.sv) ready
//   m_data        out   C_OUT*DW          Packed 256-channel INT8 latent output
//   m_last        out   1                 Final latent time step of the frame
// ============================================================================

module compute_core #(
    parameter int DATA_WIDTH  = 8,              // bits per sample/weight (INT8)
    parameter int ACCUM_WIDTH = 32,             // MAC accumulator bits (INT32)
    parameter int C_IN        = 16,             // PQMF sub-bands entering encoder
    parameter int C_LATENT    = 128,            // LATENT_SIZE in v2.gin
    parameter int C_OUT       = C_LATENT * 2,   // µ ‖ log σ² concatenated (= 256)
    parameter int MAC_LANES   = 64,             // parallel MAC units; must divide C_OUT
    parameter int SRAM_DEPTH  = 16 * 1024 * 1024  // total INT8 weight words (16 MB)
) (
    input  logic                           clk,
    input  logic                           rst_n,

    // -------------------------------------------------------------------------
    // Weight initialisation — driven by interface.sv once at startup
    // -------------------------------------------------------------------------
    input  logic                           w_wr_en,
    input  logic [$clog2(SRAM_DEPTH/MAC_LANES)-1:0] w_wr_addr,
    input  logic [MAC_LANES*DATA_WIDTH-1:0] w_wr_data,  // wide word
    input  logic                           w_load_done,

    // -------------------------------------------------------------------------
    // Activation input — one encoder input time step per transaction
    // -------------------------------------------------------------------------
    input  logic                           s_valid,
    output logic                           s_ready,
    input  logic [C_IN*DATA_WIDTH-1:0]     s_data,   // 16 ch × 8 b = 128 b
    input  logic                           s_last,

    // -------------------------------------------------------------------------
    // Latent output — one encoder output time step per transaction
    // -------------------------------------------------------------------------
    output logic                           m_valid,
    input  logic                           m_ready,
    output logic [C_OUT*DATA_WIDTH-1:0]    m_data,   // 256 ch × 8 b = 2 048 b
    output logic                           m_last
);

    // =========================================================================
    // Derived local parameters
    // =========================================================================
    localparam int DW            = DATA_WIDTH;
    localparam int AW            = ACCUM_WIDTH;
    localparam int OUT_BUS_W     = C_OUT * DW;                // = 2 048
    localparam int WADDR_W       = $clog2(SRAM_DEPTH / MAC_LANES); // = 18
    localparam int WGT_SRAM_W    = MAC_LANES * DW;            // wide word = 512 b

    localparam int C_MAX         = 1536;   // deepest layer channel count
    localparam int BUF_HIST      = 64;     // activation history depth per channel
    localparam int ACTV_BUF_SIZE = C_MAX * BUF_HIST;          // = 98 304 words
    localparam int AADDR_W       = $clog2(ACTV_BUF_SIZE);     // = 17 bits

    localparam int MAC_GROUPS    = C_OUT / MAC_LANES;          // = 4
    localparam int SLOT_W        = $clog2(MAC_GROUPS);         // = 2 bits
    localparam int LANE_W        = $clog2(MAC_LANES);          // = 6 bits
    localparam int CMAX_W        = $clog2(C_MAX);              // = 11 bits

    // =========================================================================
    // Internal interconnect signals
    // =========================================================================

    // --- weight_sram read port (driven by layer_control_fsm) ----------------
    logic                    sram_rd_en;
    logic [WADDR_W-1:0]      sram_rd_addr;
    logic [WGT_SRAM_W-1:0]   sram_rd_data;   // valid 1 cycle after rd_en

    // --- actv_buf ports (driven by layer_control_fsm) -----------------------
    logic                    actv_wr_en;
    logic [AADDR_W-1:0]      actv_wr_addr;
    logic [DW-1:0]           actv_wr_data;    // muxed below
    logic                    actv_wr_sel;     // 0 = s_data channel, 1 = relu writeback
    logic                    actv_rd_en;
    logic [AADDR_W-1:0]      actv_rd_addr;
    logic [DW-1:0]           actv_rd_data;   // valid 1 cycle after rd_en

    // FSM-provided indices for muxes
    logic [CMAX_W-1:0]       fsm_s_ch_idx;   // which s_data channel to write (wr_sel=0)
    logic [LANE_W-1:0]       fsm_rl_lane_idx; // which relu_rq lane to writeback (wr_sel=1)

    // --- MAC array signals ---------------------------------------------------
    logic [MAC_LANES-1:0][DW-1:0] mac_weight;   // sliced from sram_rd_data
    logic [DW-1:0]                 mac_actv;     // from actv_rd_data (broadcast)
    logic [MAC_LANES-1:0][AW-1:0] mac_psum;     // INT32 partial sums
    logic                          mac_clear;
    logic                          mac_en;

    // --- LeakyReLU output (INT32) -------------------------------------------
    logic [MAC_LANES-1:0][AW-1:0] relu_out;

    // --- Requantized INT8 outputs --------------------------------------------
    logic [MAC_LANES-1:0][DW-1:0] relu_rq;     // saturated INT8 after rq_shift
    logic [5:0]                    rq_shift;    // from layer_control_fsm

    // --- Output register control (driven by layer_control_fsm) -------------
    logic            out_wr_en;
    logic [SLOT_W-1:0] out_wr_slot;

    // --- Output register ----------------------------------------------------
    logic [OUT_BUS_W-1:0] out_reg;

    // =========================================================================
    // Data path: constant assignments
    // =========================================================================

    // Reinterpret wide SRAM word as packed array of MAC_LANES INT8 weights
    assign mac_weight = sram_rd_data;

    // Activation broadcast: actv_buf read data (INT8) goes to all MAC lanes
    assign mac_actv = actv_rd_data;

    // actv_buf write data mux:
    //   wr_sel=0 → one INT8 channel word sliced from s_data
    //   wr_sel=1 → one requantized INT8 relu lane written back as inter-layer activation
    assign actv_wr_data = actv_wr_sel
        ? relu_rq[fsm_rl_lane_idx]
        : s_data[fsm_s_ch_idx * DW +: DW];

    // =========================================================================
    // Requantization: INT32 relu_out → INT8 relu_rq
    // =========================================================================
    // For each lane: rq = saturate(relu_out >>> rq_shift, -128, 127)
    genvar g;
    generate
        for (g = 0; g < MAC_LANES; g++) begin : gen_rq
            logic signed [AW-1:0] shifted;
            assign shifted = $signed(relu_out[g]) >>> rq_shift;
            assign relu_rq[g] = ($signed(shifted) > 32'sd127)  ? 8'h7F :
                                ($signed(shifted) < -32'sd128) ? 8'h80 :
                                shifted[DW-1:0];
        end
    endgenerate

    // =========================================================================
    // Output register — assembles one complete output time step (INT8)
    // =========================================================================
    // The FSM writes MAC_LANES requantized INT8 outputs per cycle into the
    // appropriate slice; m_data is driven from this register.
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            out_reg <= '0;
        end else if (out_wr_en) begin
            out_reg[out_wr_slot * (MAC_LANES * DW) +: (MAC_LANES * DW)] <=
                relu_rq;  // pack [MAC_LANES-1:0][DW-1:0] into flat slice
        end
    end

    assign m_data = out_reg;

    // =========================================================================
    // Sub-module instantiations
    // =========================================================================

    // --- weight_sram ---------------------------------------------------------
    weight_sram #(
        .DEPTH    (SRAM_DEPTH / MAC_LANES),   // wide-word count
        .WR_WIDTH (DW),                        // narrow write (INT8)
        .RD_WIDTH (WGT_SRAM_W)                // wide read: MAC_LANES INT8 per word
    ) u_weight_sram (
        .clk      (clk),
        .wr_en    (w_wr_en),
        .wr_addr  (w_wr_addr),
        .wr_data  (w_wr_data),
        .rd_en    (sram_rd_en),
        .rd_addr  (sram_rd_addr),
        .rd_data  (sram_rd_data)
    );

    // --- actv_buf ------------------------------------------------------------
    actv_buf #(
        .DEPTH (ACTV_BUF_SIZE),
        .WIDTH (DW)
    ) u_actv_buf (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (actv_wr_en),
        .wr_addr  (actv_wr_addr),
        .wr_data  (actv_wr_data),
        .rd_en    (actv_rd_en),
        .rd_addr  (actv_rd_addr),
        .rd_data  (actv_rd_data)
    );

    // --- mac_array -----------------------------------------------------------
    mac_array #(
        .LANES (MAC_LANES),
        .DW    (DW),
        .AW    (AW)
    ) u_mac_array (
        .clk    (clk),
        .rst_n  (rst_n),
        .clear  (mac_clear),
        .en     (mac_en),
        .weight (mac_weight),
        .actv   (mac_actv),
        .psum   (mac_psum)
    );

    // --- leaky_relu ----------------------------------------------------------
    leaky_relu #(
        .LANES (MAC_LANES),
        .AW    (AW)
    ) u_leaky_relu (
        .in_data  (mac_psum),
        .out_data (relu_out)
    );

    // --- layer_control_fsm ---------------------------------------------------
    layer_control_fsm #(
        .DATA_WIDTH (DW),
        .C_IN       (C_IN),
        .C_OUT      (C_OUT),
        .MAC_LANES  (MAC_LANES),
        .SRAM_DEPTH (SRAM_DEPTH),
        .C_MAX      (C_MAX),
        .BUF_HIST   (BUF_HIST)
    ) u_fsm (
        .clk           (clk),
        .rst_n         (rst_n),

        .w_load_done   (w_load_done),

        .s_valid       (s_valid),
        .s_last        (s_last),
        .s_ready       (s_ready),

        .m_valid       (m_valid),
        .m_ready       (m_ready),
        .m_last        (m_last),

        .sram_rd_en    (sram_rd_en),
        .sram_rd_addr  (sram_rd_addr),

        .actv_wr_en    (actv_wr_en),
        .actv_wr_addr  (actv_wr_addr),
        .actv_wr_sel   (actv_wr_sel),
        .actv_rd_en    (actv_rd_en),
        .actv_rd_addr  (actv_rd_addr),
        .s_ch_idx      (fsm_s_ch_idx),
        .rl_lane_idx   (fsm_rl_lane_idx),

        .mac_clear     (mac_clear),
        .mac_en        (mac_en),

        .out_wr_en     (out_wr_en),
        .out_wr_slot   (out_wr_slot),

        .rq_shift      (rq_shift)
    );

endmodule
