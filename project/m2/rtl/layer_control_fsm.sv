// ============================================================================
// layer_control_fsm.sv
// Encoder layer sequencing FSM — control plane for compute_core
//
// PURPOSE
//   Sequences the full RAVE v2 EncoderV2 layer stack (stem → 4 stages →
//   head), generating all SRAM read addresses, activation buffer addresses,
//   MAC array controls, and output handshake signals.  This module is the
//   sole source of control logic; it does not touch data paths.
//
// LAYER TABLE (v2.gin, indexed by layer_idx)
//   idx  description          C_in   C_out  K  S  D (per dilated sub-unit)
//   ---  -------------------  -----  -----  -  -  ---
//    0   stem Conv1d           16     96    7  1  1
//    1   stage-0 DilatedUnit   96     96    3  1  1/3/9 (3 sub-layers)
//    2   stage-0 downsample    96    192    8  4  1
//    3   stage-1 DilatedUnit  192    192    3  1  1/3/9
//    4   stage-1 downsample   192    384    8  4  1
//    5   stage-2 DilatedUnit  384    384    3  1  1/3/9
//    6   stage-2 downsample   384    768    8  4  1
//    7   stage-3 DilatedUnit  768    768    3  1  1/3
//    8   stage-3 downsample   768   1536    4  2  1
//    9   head Conv1d         1536    256    3  1  1
//   (DilatedUnit internally contains two Conv1d ops + a residual add.)
//
// FSM STATES
//   ST_RESET     — hold all outputs inactive; transition unconditionally to
//                  ST_LOAD_WAIT on the cycle after rst_n de-assertion.
//   ST_LOAD_WAIT — wait for w_load_done; hold s_ready low to block input.
//   ST_IDLE      — assert s_ready; wait for s_valid to start a time step.
//   ST_INPUT     — accept one encoder input time step (C_IN = 16 channels);
//                  write each channel word into actv_buf (actv_wr_sel = 0);
//                  advance s_ch_idx from 0 to C_IN-1, then go to ST_COMPUTE.
//   ST_COMPUTE   — iterate (layer_idx, mac_grp, k_tap, cin_idx):
//                    - assert sram_rd_en and actv_rd_en one cycle before data needed;
//                    - assert mac_en on the cycle data is valid;
//                    - when all (cin × K) pairs done for current mac_grp:
//                        assert mac_clear; capture psum; advance mac_grp.
//                    - when all mac_grps done for current layer:
//                        go to ST_ACTIVATE.
//   ST_ACTIVATE  — apply LeakyReLU (combinational, no clock); write relu_out
//                  back to actv_buf (actv_wr_sel = 1) one lane per cycle;
//                  advance layer_idx; return to ST_COMPUTE or go to ST_OUTPUT
//                  if layer_idx has reached the head layer.
//   ST_OUTPUT    — assert m_valid; hold until m_ready; then go to ST_IDLE
//                  (or ST_FRAME_END if s_last was latched).
//   ST_FRAME_END — flush counters and head pointers; return to ST_IDLE.
//
// SRAM ADDRESS GENERATION
//   Weight layout in weight_sram: weights are stored contiguously per layer in
//   the order [layer][output_channel_group][input_channel][kernel_tap], so the
//   FSM read address is:
//     rd_addr = layer_base[layer_idx]
//               + mac_grp_idx * (C_in * K)
//               + cin_idx * K
//               + tap_idx
//   where layer_base[] is a ROM of precomputed layer start addresses.
//
// ACTIVATION BUFFER ADDRESS GENERATION
//   Write (input phase):  chan * BUF_HIST + head_ptr[chan]
//   Read  (compute):      chan * BUF_HIST + (head_ptr[chan] - tap * D + BUF_HIST) % BUF_HIST
//   head_ptr[] is an array of C_MAX head pointers maintained in this module.
//
// CLOCK / RESET
//   Single clock domain (clk).  Synchronous active-low reset (rst_n) returns
//   the FSM to ST_RESET and clears all counters and head pointers.
//
// PORT LIST
//   Name              Dir   Width         Purpose
//   --------------------------------------------------------------------------
//   clk               in    1             System clock
//   rst_n             in    1             Synchronous active-low reset
//
//   -- Weight init (from compute_core top-level port) --
//   w_load_done       in    1             Pulse: all weights written by interface.sv
//
//   -- Input stream handshake (to/from compute_core ports) --
//   s_valid           in    1             Input time step available
//   s_last            in    1             Final time step of the frame
//   s_ready           out   1             Core can accept input (ST_IDLE only)
//
//   -- Output stream handshake (to/from compute_core ports) --
//   m_valid           out   1             Latent output time step ready
//   m_ready           in    1             Downstream ready to accept
//   m_last            out   1             Final latent time step of frame
//
//   -- weight_sram read port control --
//   sram_rd_en        out   1             Assert one cycle before data needed
//   sram_rd_addr      out   WADDR_W       Wide-word read address into weight_sram
//
//   -- actv_buf control --
//   actv_wr_en        out   1             Activation buffer write enable
//   actv_wr_addr      out   AADDR_W       Activation buffer write address
//   actv_wr_sel       out   1             Write source: 0=s_data channel, 1=relu lane
//   actv_rd_en        out   1             Assert one cycle before data needed
//   actv_rd_addr      out   AADDR_W       Activation buffer read address
//   s_ch_idx          out   CMAX_W        Which s_data channel slice to write (wr_sel=0)
//   rl_lane_idx       out   LANE_W        Which relu_out lane to write back (wr_sel=1)
//
//   -- mac_array control --
//   mac_clear         out   1             Synchronous clear all accumulators
//   mac_en            out   1             Enable MAC accumulation this cycle
//
//   -- output register control (in compute_core) --
//   out_wr_en         out   1             Write current relu_out group to out_reg
//   out_wr_slot       out   SLOT_W        Which MAC_LANES slot of out_reg to write
//   rq_shift          out   6             INT32→INT8 requant right-shift for this layer
// ============================================================================

module layer_control_fsm #(
    parameter int DATA_WIDTH  = 8,           // INT8 data width
    parameter int C_IN        = 16,          // PQMF bands (encoder input channels)
    parameter int C_OUT       = 256,         // latent channels (encoder output)
    parameter int MAC_LANES   = 64,
    parameter int SRAM_DEPTH  = 16 * 1024 * 1024,
    parameter int C_MAX       = 1536,        // max channels in any encoder layer
    parameter int BUF_HIST    = 64           // activation history depth per channel
) (
    input  logic clk,
    input  logic rst_n,

    // Weight init
    input  logic w_load_done,

    // Input stream
    input  logic s_valid,
    input  logic s_last,
    output logic s_ready,

    // Output stream
    output logic m_valid,
    input  logic m_ready,
    output logic m_last,

    // weight_sram read control
    output logic                              sram_rd_en,
    output logic [$clog2(SRAM_DEPTH/MAC_LANES)-1:0] sram_rd_addr,

    // actv_buf control
    output logic                              actv_wr_en,
    output logic [$clog2(C_MAX*BUF_HIST)-1:0] actv_wr_addr,
    output logic                              actv_wr_sel,    // 0=s_data, 1=relu
    output logic                              actv_rd_en,
    output logic [$clog2(C_MAX*BUF_HIST)-1:0] actv_rd_addr,
    output logic [$clog2(C_MAX)-1:0]          s_ch_idx,       // input channel being written
    output logic [$clog2(MAC_LANES)-1:0]      rl_lane_idx,    // relu lane being written back

    // mac_array control
    output logic mac_clear,
    output logic mac_en,

    // output register control
    output logic                              out_wr_en,
    output logic [$clog2(C_OUT/MAC_LANES)-1:0] out_wr_slot,

    // requantization shift — INT32 accumulator → INT8 output
    // rq_out = saturate(relu_out >>> rq_shift, -128, 127)
    // value is per-layer, sourced from the layer ROM at layer_idx_r
    output logic [5:0]                        rq_shift
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam int NUM_LAYERS  = 10;          // stem + 4 stages (DU + DS each) + head
    localparam int WADDR_W     = $clog2(SRAM_DEPTH / MAC_LANES);
    localparam int AADDR_W     = $clog2(C_MAX * BUF_HIST);
    localparam int MAC_GROUPS  = C_OUT / MAC_LANES;   // = 4
    localparam int LAYER_IDX_W = $clog2(NUM_LAYERS);

    // =========================================================================
    // FSM state encoding
    // =========================================================================
    typedef enum logic [3:0] {
        ST_RESET,
        ST_LOAD_WAIT,
        ST_IDLE,
        ST_INPUT,
        ST_COMPUTE,
        ST_ACTIVATE,
        ST_OUTPUT,
        ST_FRAME_END
    } state_t;

    state_t state_r, state_next;

    // =========================================================================
    // Internal registers
    // =========================================================================

    // Weights-loaded flag — set on w_load_done, cleared by rst_n
    logic weights_loaded_r;

    // Frame-last latch — set when s_last is seen, held until ST_FRAME_END
    logic frame_last_r;

    // Current encoder layer
    logic [LAYER_IDX_W-1:0] layer_idx_r;

    // Counters for the nested loop inside ST_COMPUTE:
    //   for mac_grp in [0, MAC_GROUPS):
    //     for tap in [0, K):
    //       for cin in [0, C_in):
    //         present (weight, actv) to MAC array
    logic [$clog2(C_MAX/MAC_LANES)-1:0] mac_grp_r;
    logic [3:0]                      tap_r;      // kernel tap k, max K=8
    logic [10:0]                     cin_r;      // input channel index, max C_in=1536

    // Per-channel activation buffer head pointers (circular, mod BUF_HIST)
    // One pointer per possible input channel — sized for C_MAX channels.
    // In synthesis this becomes a small register file.
    logic [$clog2(BUF_HIST)-1:0] head_ptr_r [0:C_MAX-1];

    // =========================================================================
    // Layer parameter ROM
    // =========================================================================
    // Encodes {C_in, C_out, K, S, D} for each of NUM_LAYERS layers.
    // Indexed by layer_idx_r; read combinationally to produce cur_* signals.
    // (Detailed ROM contents to be filled in during implementation.)

    logic [10:0] rom_c_in    [0:NUM_LAYERS-1]; // ∈ {16,96,192,384,768,1536}
    logic [10:0] rom_c_out   [0:NUM_LAYERS-1]; // ∈ {96,192,384,768,1536,256}
    logic [3:0]  rom_kernel  [0:NUM_LAYERS-1]; // ∈ {3,4,7,8}
    logic [2:0]  rom_stride  [0:NUM_LAYERS-1]; // ∈ {1,2,4}
    logic [3:0]  rom_dilation[0:NUM_LAYERS-1]; // ∈ {1,3,9}
    logic [5:0]  rom_rq_shift[0:NUM_LAYERS-1]; // INT32→INT8 right-shift per layer

    // Precomputed base addresses into weight_sram for each layer start
    logic [WADDR_W-1:0] layer_base [0:NUM_LAYERS-1];

    // Current-layer decoded parameters (combinational mux from ROM)
    logic [10:0] cur_c_in;
    logic [10:0] cur_c_out;
    logic [3:0]  cur_kernel;
    logic [2:0]  cur_stride;
    logic [3:0]  cur_dilation;

    // =========================================================================
    // FSM — state register
    // =========================================================================
    always_ff @(posedge clk) begin
        if (~rst_n) state_r <= ST_RESET;
        else        state_r <= state_next;
    end

    // =========================================================================
    // weights_loaded register
    // =========================================================================
    always_ff @(posedge clk) begin
        if (~rst_n)       weights_loaded_r <= 1'b0;
        else if (w_load_done) weights_loaded_r <= 1'b1;
    end

    // =========================================================================
    // Layer parameter ROM initialisation
    // =========================================================================
    // layer_base[i] = cumulative wide-word offset in weight_sram for layer i.
    // Wide words per layer = ceil(C_out/MAC_LANES) * C_in * K  (one wide word
    // holds MAC_LANES INT8 weights, i.e. one full row of the systolic array).
    //
    // DilatedUnit rows (idx 1,3,5,7) store base D=1; the FSM is responsible
    // for cycling through the full dilation set {1,3,9} or {1,3} when
    // scheduling sub-unit passes for those layers.
    //
    // rq_shift is a per-layer INT32→INT8 right-shift calibrated from the
    // quantized model; placeholder value 8 (÷256) is used here.
    initial begin
        // idx 0 — stem Conv1d:          16 → 96,  K=7, S=1, D=1
        rom_c_in[0]    = 11'd16;    rom_c_out[0]    = 11'd96;
        rom_kernel[0]  = 4'd7;      rom_stride[0]   = 3'd1;
        rom_dilation[0]= 4'd1;      rom_rq_shift[0] = 6'd8;

        // idx 1 — stage-0 DilatedUnit:  96 → 96,  K=3, S=1, base D=1
        rom_c_in[1]    = 11'd96;    rom_c_out[1]    = 11'd96;
        rom_kernel[1]  = 4'd3;      rom_stride[1]   = 2'd1;
        rom_dilation[1]= 4'd1;      rom_rq_shift[1] = 6'd8;

        // idx 2 — stage-0 downsample:   96 → 192, K=8, S=4, D=1
        rom_c_in[2]    = 11'd96;    rom_c_out[2]    = 11'd192;
        rom_kernel[2]  = 4'd8;      rom_stride[2]   = 3'd4;
        rom_dilation[2]= 4'd1;      rom_rq_shift[2] = 6'd8;

        // idx 3 — stage-1 DilatedUnit: 192 → 192, K=3, S=1, base D=1
        rom_c_in[3]    = 11'd192;   rom_c_out[3]    = 11'd192;
        rom_kernel[3]  = 4'd3;      rom_stride[3]   = 2'd1;
        rom_dilation[3]= 4'd1;      rom_rq_shift[3] = 6'd8;

        // idx 4 — stage-1 downsample:  192 → 384, K=8, S=4, D=1
        rom_c_in[4]    = 11'd192;   rom_c_out[4]    = 11'd384;
        rom_kernel[4]  = 4'd8;      rom_stride[4]   = 3'd4;
        rom_dilation[4]= 4'd1;      rom_rq_shift[4] = 6'd8;

        // idx 5 — stage-2 DilatedUnit: 384 → 384, K=3, S=1, base D=1
        rom_c_in[5]    = 11'd384;   rom_c_out[5]    = 11'd384;
        rom_kernel[5]  = 4'd3;      rom_stride[5]   = 2'd1;
        rom_dilation[5]= 4'd1;      rom_rq_shift[5] = 6'd8;

        // idx 6 — stage-2 downsample:  384 → 768, K=8, S=4, D=1
        rom_c_in[6]    = 11'd384;   rom_c_out[6]    = 11'd768;
        rom_kernel[6]  = 4'd8;      rom_stride[6]   = 3'd4;
        rom_dilation[6]= 4'd1;      rom_rq_shift[6] = 6'd8;

        // idx 7 — stage-3 DilatedUnit: 768 → 768, K=3, S=1, base D=1
        rom_c_in[7]    = 11'd768;   rom_c_out[7]    = 11'd768;
        rom_kernel[7]  = 4'd3;      rom_stride[7]   = 2'd1;
        rom_dilation[7]= 4'd1;      rom_rq_shift[7] = 6'd8;

        // idx 8 — stage-3 downsample:  768 → 1536, K=4, S=2, D=1
        rom_c_in[8]    = 11'd768;   rom_c_out[8]    = 11'd1536;
        rom_kernel[8]  = 4'd4;      rom_stride[8]   = 3'd2;
        rom_dilation[8]= 4'd1;      rom_rq_shift[8] = 6'd8;

        // idx 9 — head Conv1d:        1536 → 256, K=3, S=1, D=1
        rom_c_in[9]    = 11'd1536;  rom_c_out[9]    = 11'd256;
        rom_kernel[9]  = 4'd3;      rom_stride[9]   = 2'd1;
        rom_dilation[9]= 4'd1;      rom_rq_shift[9] = 6'd8;

        // Cumulative wide-word base addresses (ceil(C_out/64) * C_in * K each):
        //   [0]  2*16*7     =     224  → base       0
        //   [1]  2*96*3     =     576  → base     224
        //   [2]  3*96*8     =   2,304  → base     800
        //   [3]  3*192*3    =   1,728  → base   3,104
        //   [4]  6*192*8    =   9,216  → base   4,832
        //   [5]  6*384*3    =   6,912  → base  14,048
        //   [6] 12*384*8    =  36,864  → base  20,960
        //   [7] 12*768*3    =  27,648  → base  57,824
        //   [8] 24*768*4    =  73,728  → base  85,472
        //   [9]  4*1536*3   =  18,432  → base 159,200
        //   total                        177,632  (< 262,144 SRAM wide-word depth)
        layer_base[0] = 18'd0;
        layer_base[1] = 18'd224;
        layer_base[2] = 18'd800;
        layer_base[3] = 18'd3104;
        layer_base[4] = 18'd4832;
        layer_base[5] = 18'd14048;
        layer_base[6] = 18'd20960;
        layer_base[7] = 18'd57824;
        layer_base[8] = 18'd85472;
        layer_base[9] = 18'd159200;
    end

    // =========================================================================
    // Combinational layer parameter mux
    // =========================================================================
    always_comb begin
        cur_c_in    = rom_c_in    [layer_idx_r];
        cur_c_out   = rom_c_out   [layer_idx_r];
        cur_kernel  = rom_kernel  [layer_idx_r];
        cur_stride  = rom_stride  [layer_idx_r];
        cur_dilation= rom_dilation[layer_idx_r];
    end

    // =========================================================================
    // FSM — next-state logic
    // =========================================================================
    // Per-layer MAC group count: ceil(cur_c_out / MAC_LANES).
    // MAC_LANES=64 is a power of 2, so this is a right-shift + OR-reduce.
    logic [4:0] cur_num_grps;
    assign cur_num_grps = cur_c_out[10:6] + (|cur_c_out[5:0]);

    logic cin_done, tap_done, lane_done, grp_done, layer_done;
    assign cin_done   = (cin_r       == cur_c_in   - 11'd1);
    assign tap_done   = (tap_r       == cur_kernel -  4'd1);
    assign lane_done  = &rl_lane_idx;                         // rl_lane_idx == MAC_LANES-1
    assign grp_done   = (mac_grp_r   == cur_num_grps - 5'd1);
    assign layer_done = (layer_idx_r == NUM_LAYERS - 1);

    always_comb begin
        state_next = state_r;   // hold by default

        case (state_r)
            ST_RESET:
                state_next = ST_LOAD_WAIT;

            ST_LOAD_WAIT:
                if (weights_loaded_r) state_next = ST_IDLE;

            ST_IDLE:
                if (s_valid) state_next = ST_INPUT;

            ST_INPUT:
                // Transition once the last input channel word has been latched
                if (s_ch_idx == C_IN - 1) state_next = ST_COMPUTE;

            ST_COMPUTE:
                // One MAC cycle per (tap, cin) pair for the current mac_grp;
                // move to writeback state when the full group is accumulated
                if (tap_done && cin_done) state_next = ST_ACTIVATE;

            ST_ACTIVATE: begin
                // Write relu_rq lanes 0..MAC_LANES-1 back to actv_buf, one per cycle.
                // On the last lane decide whether to start the next group, the next
                // layer, or produce output.
                if (lane_done) begin
                    if (grp_done && layer_done)
                        state_next = ST_OUTPUT;
                    else
                        state_next = ST_COMPUTE;  // next mac_grp or next layer
                end
            end

            ST_OUTPUT:
                if (m_ready) begin
                    if (frame_last_r) state_next = ST_FRAME_END;
                    else              state_next = ST_IDLE;
                end

            ST_FRAME_END:
                state_next = ST_IDLE;

            default:
                state_next = ST_RESET;
        endcase
    end

    // =========================================================================
    // Requantization shift: purely combinational, sourced from layer ROM
    // =========================================================================
    assign rq_shift = rom_rq_shift[layer_idx_r];

    // =========================================================================
    // FSM — output and counter update logic
    // =========================================================================
    // Pipeline offset:
    //   sram_rd_en / actv_rd_en  — registered, set when state_next==ST_COMPUTE
    //                              so data arrives on the FIRST cycle of ST_COMPUTE
    //   mac_en                   — registered, set when state_r==ST_COMPUTE
    //                              so it accumulates the PREVIOUS cycle's fetch
    //   ST_ACTIVATE first cycle  — mac_en is still 1 (last accumulation draining);
    //                              actv_buf writeback is gated by !mac_en so it
    //                              starts on cycle 2, after psum is fully settled
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            s_ready      <= 1'b0;
            m_valid      <= 1'b0;
            m_last       <= 1'b0;
            sram_rd_en   <= 1'b0;
            actv_rd_en   <= 1'b0;
            actv_wr_en   <= 1'b0;
            actv_wr_sel  <= 1'b0;
            mac_en       <= 1'b0;
            mac_clear    <= 1'b0;
            out_wr_en    <= 1'b0;
            out_wr_slot  <= '0;
            s_ch_idx     <= '0;
            rl_lane_idx  <= '0;
            mac_grp_r    <= '0;
            tap_r        <= '0;
            cin_r        <= '0;
            layer_idx_r  <= '0;
            frame_last_r <= 1'b0;
            for (int i = 0; i < C_MAX; i++) head_ptr_r[i] <= '0;
        end else begin
            // ---- Default: clear single-cycle strobes -------------------------
            mac_clear  <= 1'b0;
            out_wr_en  <= 1'b0;
            actv_wr_en <= 1'b0;

            // ---- Pipeline pre-fetch and accumulate enables ------------------
            sram_rd_en <= (state_next == ST_COMPUTE);
            actv_rd_en <= (state_next == ST_COMPUTE);
            mac_en     <= (state_r    == ST_COMPUTE);

            // ---- Per-state logic -------------------------------------------
            case (state_r)

                ST_RESET: begin
                    s_ready <= 1'b0;
                    m_valid <= 1'b0;
                end

                ST_LOAD_WAIT: begin
                    s_ready <= 1'b0;
                end

                ST_IDLE: begin
                    s_ready <= 1'b1;
                    m_valid <= 1'b0;
                    if (s_valid) begin
                        s_ready     <= 1'b0;
                        s_ch_idx    <= '0;
                        // Pre-arm write enable so channel 0 is written on cycle 1 of ST_INPUT
                        actv_wr_en  <= 1'b1;
                        actv_wr_sel <= 1'b0;
                        // Reset compute counters for the upcoming frame
                        mac_grp_r   <= '0;
                        tap_r       <= '0;
                        cin_r       <= '0;
                        layer_idx_r <= '0;
                        // Latch frame-last here: s_last accompanies the s_valid beat
                        // and is de-asserted before the FSM reaches ST_INPUT.
                        if (s_last) frame_last_r <= 1'b1;
                    end
                end

                ST_INPUT: begin
                    // Write s_data channel s_ch_idx to actv_buf each cycle.
                    // actv_wr_addr is computed combinationally in the address block.
                    // Suppress re-arm on the last channel so wr_en clears before ST_COMPUTE.
                    actv_wr_en  <= (s_ch_idx != C_IN - 1);
                    actv_wr_sel <= 1'b0;
                    if (s_last) frame_last_r <= 1'b1;
                    // Advance head pointer for the channel just written
                    head_ptr_r[s_ch_idx] <= head_ptr_r[s_ch_idx] + 1;
                    if (s_ch_idx == C_IN - 1)
                        s_ch_idx <= '0;
                    else
                        s_ch_idx <= s_ch_idx + 1;
                end

                ST_COMPUTE: begin
                    // Advance inner loop: tap is innermost, cin is next.
                    // mac_en fires the cycle AFTER we arrive here (registered),
                    // so the first cycle is effectively a pipeline fill.
                    if (tap_done) begin
                        tap_r <= '0;
                        cin_r <= cin_done ? '0 : cin_r + 1;
                    end else begin
                        tap_r <= tap_r + 1;
                    end
                end

                ST_ACTIVATE: begin
                    // Cycle 0: mac_en==1 — MAC pipeline draining; pre-arm write enable
                    //          so it fires on cycle 1 (lane 0) when mac_en goes low.
                    // Cycles 1..64: mac_en==0 — write relu_rq lanes 0..63.
                    //   Suppress re-arm on lane_done so wr_en clears before next state.
                    actv_wr_sel <= 1'b1;
                    if (mac_en) begin
                        actv_wr_en <= 1'b1;  // pre-arm for lane 0
                    end else begin
                        if (!lane_done) actv_wr_en <= 1'b1;
                        // actv_wr_addr driven combinationally below
                        // Advance head pointer for the output channel just written
                        head_ptr_r[{mac_grp_r, rl_lane_idx}] <=
                            head_ptr_r[{mac_grp_r, rl_lane_idx}] + 1;

                        if (lane_done) begin
                            // All 64 lanes written — finalize this mac_grp
                            out_wr_en   <= layer_done;  // latch full output word for head layer
                            out_wr_slot <= mac_grp_r;
                            mac_clear   <= 1'b1;        // clear accumulators for next group
                            rl_lane_idx <= '0;
                            tap_r       <= '0;
                            cin_r       <= '0;
                            if (grp_done) begin
                                mac_grp_r <= '0;
                                if (!layer_done)
                                    layer_idx_r <= layer_idx_r + 1;
                            end else begin
                                mac_grp_r <= mac_grp_r + 1;
                            end
                        end else begin
                            rl_lane_idx <= rl_lane_idx + 1;
                        end
                    end
                end

                ST_OUTPUT: begin
                    m_valid <= 1'b1;
                    m_last  <= frame_last_r;
                    if (m_ready) begin
                        m_valid <= 1'b0;
                        m_last  <= 1'b0;
                    end
                end

                ST_FRAME_END: begin
                    frame_last_r <= 1'b0;
                    layer_idx_r  <= '0;
                    mac_grp_r    <= '0;
                    tap_r        <= '0;
                    cin_r        <= '0;
                end

                default: begin
                    s_ready <= 1'b0;
                    m_valid <= 1'b0;
                end

            endcase
        end
    end

    // =========================================================================
    // SRAM address computation
    // =========================================================================
    // Operands widened to WADDR_W bits before multiplication to prevent silent
    // truncation: cur_c_in*cur_kernel reaches 1536*8=12288 (>11-bit max 2047).
    logic [WADDR_W-1:0] cin_x_k;
    logic [WADDR_W-1:0] mac_grp_offset;
    logic [WADDR_W-1:0] cin_offset;

    assign cin_x_k        = {{(WADDR_W-11){1'b0}}, cur_c_in}  * {{(WADDR_W-4){1'b0}}, cur_kernel};
    assign mac_grp_offset = {{(WADDR_W-5){1'b0}},  mac_grp_r} * cin_x_k;
    assign cin_offset     = {{(WADDR_W-11){1'b0}}, cin_r}      * {{(WADDR_W-4){1'b0}}, cur_kernel};
    assign sram_rd_addr   = layer_base[layer_idx_r] + mac_grp_offset
                            + cin_offset + {{(WADDR_W-4){1'b0}}, tap_r};

    // =========================================================================
    // Activation buffer address computation
    // =========================================================================
    // BUF_HIST=64 and MAC_LANES=64 are both powers of 2, so all *BUF_HIST
    // multiplies are bit-concatenations and %BUF_HIST is a 6-bit truncation.

    // Read: dilated circular buffer tap lookup
    logic [6:0] tap_dil;    // tap_r * cur_dilation, max 7*9=63
    logic [6:0] rd_sum;    // head_ptr[cin] + 64 - tap_dil, range 1..127
    logic [5:0] rd_offset; // rd_sum mod 64 (lower 6 bits)

    assign tap_dil    = {3'b0, tap_r} * {3'b0, cur_dilation};
    assign rd_sum     = {1'b0, head_ptr_r[cin_r]} + 7'd64 - tap_dil;
    assign rd_offset  = rd_sum[5:0];
    assign actv_rd_addr = {cin_r, rd_offset};

    // Write: output channel index for writeback (mac_grp*64 + lane = bit-concat)
    logic [10:0] wr_ch_idx;
    assign wr_ch_idx = {mac_grp_r, rl_lane_idx};

    assign actv_wr_addr = actv_wr_sel
        ? {wr_ch_idx, head_ptr_r[wr_ch_idx]}
        : {s_ch_idx,  head_ptr_r[s_ch_idx]};

endmodule
