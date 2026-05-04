// ============================================================================
// interface.sv
// AXI4-Stream ↔ RAVE v2 Encoder Compute-Core Bridge
//
// ECE 510 Project Milestone 2
//
// ============================================================================
// PURPOSE
//   Top-level AXI4-Stream wrapper around compute_core.  Translates between
//   the narrow byte-serial AXI4-Stream protocol presented to the host and the
//   wide parallel data buses used internally by the systolic array.
//
//   Two sequential phases are managed by an internal state machine:
//
//   Phase 1 — Weight Initialisation (one-time at startup)
//     The host streams all encoder INT8 weights over S_AXIS.  The interface
//     accumulates MAC_LANES=64 consecutive bytes into a 512-bit word and
//     issues a single w_wr_en write to the weight SRAM.  When S_AXIS asserts
//     TLAST on the final weight byte the interface pulses w_load_done, which
//     allows the compute core to begin accepting inference inputs.
//
//   Phase 2 — Inference (one AXI4-Stream frame per encoder frame)
//     a) Input acceptance: the host sends C_IN bytes per time step over
//        S_AXIS.  The interface packs them into a C_IN*DW-bit word and
//        presents it to the compute core via the plain valid/ready handshake.
//        S_AXIS TLAST on the last byte of a time step sets s_last, telling
//        the encoder this is the final step of the frame.
//
//     b) Output transmission: when the compute core asserts m_valid the
//        interface latches the C_OUT-byte output vector and streams each byte
//        in order over M_AXIS, asserting TLAST on the final byte.
//
// ============================================================================
// AXI4-STREAM PROTOCOL
//   Minimum required signals used: TVALID, TREADY, TDATA (DATA_WIDTH bits),
//   TLAST.  A beat transfers when TVALID=1 AND TREADY=1 on a rising edge.
//   TLAST meanings:
//     S_AXIS weight phase: marks the last byte of the entire weight blob
//     S_AXIS input phase:  marks the last byte of the frame's last time step
//     M_AXIS output phase: marks the last byte of the output frame
//
// ============================================================================
// m_valid / m_ready HANDSHAKE NOTE
//   compute_core's ST_OUTPUT always_ff contains the pattern:
//       m_valid <= 1'b1;
//       if (m_ready) m_valid <= 1'b0;   // last NBA wins
//   If m_ready is already asserted when m_valid first becomes 1, both NBAs
//   evaluate on the same posedge and the second (zero) wins, so m_valid is
//   never observable as 1.  This interface therefore holds core_m_ready=0
//   while waiting in ST_WAIT_OUTPUT, lets the core hold m_valid=1, and then
//   pulses core_m_ready=1 for exactly one cycle (ST_ACCEPT_OUTPUT) to
//   complete the handshake and latch m_data.
//
// ============================================================================
// PORT LIST
//   Name              Dir   Width     Purpose
//   --------------------------------------------------------------------------
//   clk               in    1         System clock
//   rst_n             in    1         Synchronous active-low reset
//
//   s_axis_tvalid     in    1         Host→core: data valid
//   s_axis_tready     out   1         Interface ready to accept
//   s_axis_tdata      in    DW        One INT8 byte per beat
//   s_axis_tlast      in    1         Last byte of current S_AXIS frame
//
//   m_axis_tvalid     out   1         Core→host: output byte valid
//   m_axis_tready     in    1         Host ready to accept
//   m_axis_tdata      out   DW        One INT8 output byte per beat
//   m_axis_tlast      out   1         Last byte of current M_AXIS frame
// ============================================================================

module encoder_axi #(
    parameter int DATA_WIDTH = 8,               // INT8
    parameter int C_IN       = 16,              // encoder input channels
    parameter int C_OUT      = 256,             // encoder output channels (µ ‖ log σ²)
    parameter int C_LATENT   = 128,
    parameter int MAC_LANES  = 64,
    parameter int SRAM_DEPTH = 16 * 1024 * 1024
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // ── AXI4-Stream slave (host → core) ──────────────────────────────────────
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tlast,

    // ── AXI4-Stream master (core → host) ─────────────────────────────────────
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic [DATA_WIDTH-1:0] m_axis_tdata,
    output logic                  m_axis_tlast
);

    // =========================================================================
    // Derived local parameters
    // =========================================================================
    localparam int DW         = DATA_WIDTH;
    localparam int WGT_WORD_W = MAC_LANES * DW;               // 512 b per SRAM word
    localparam int IN_BUS_W   = C_IN  * DW;                   // 128 b
    localparam int OUT_BUS_W  = C_OUT * DW;                   // 2048 b
    localparam int WADDR_W    = $clog2(SRAM_DEPTH / MAC_LANES); // 18 b

    localparam int WGT_CNT_W  = $clog2(MAC_LANES);            // 6 b: 0..63
    localparam int IN_CNT_W   = $clog2(C_IN);                 // 4 b: 0..15
    localparam int OUT_CNT_W  = $clog2(C_OUT);                // 8 b: 0..255

    // =========================================================================
    // State encoding
    // =========================================================================
    typedef enum logic [2:0] {
        ST_WEIGHT_LOAD,    // accumulate MAC_LANES bytes then write one SRAM word
        ST_INPUT,          // accept C_IN bytes from S_AXIS; present to core
        ST_WAIT_OUTPUT,    // wait for compute core m_valid (m_ready held LOW)
        ST_ACCEPT_OUTPUT,  // pulse m_ready=1 for one cycle; latch m_data
        ST_OUTPUT_SEND     // stream C_OUT bytes over M_AXIS
    } state_t;

    state_t state_r, state_next;

    // =========================================================================
    // Compute-core interface signals
    // =========================================================================
    logic                    w_wr_en;
    logic [WADDR_W-1:0]      w_wr_addr;
    logic [WGT_WORD_W-1:0]   w_wr_data;
    logic                    w_load_done;

    logic                    core_s_valid;
    logic                    core_s_ready;
    logic [IN_BUS_W-1:0]     core_s_data;
    logic                    core_s_last;

    logic                    core_m_valid;
    logic                    core_m_ready;
    logic [OUT_BUS_W-1:0]    core_m_data;
    logic                    core_m_last;

    // =========================================================================
    // Internal data registers
    // =========================================================================

    // ── Weight packing ────────────────────────────────────────────────────────
    // Accumulates MAC_LANES bytes; counter-indexed so byte 0 → bits [7:0],
    // byte 63 → bits [511:504].
    logic [WGT_WORD_W-1:0]  wgt_shift_r;       // assembly buffer
    logic [WGT_CNT_W-1:0]   wgt_byte_cnt_r;    // 0..MAC_LANES-1
    logic [WADDR_W-1:0]      wgt_word_addr_r;   // next SRAM write address

    // Combinational assembled word including the incoming byte on this cycle.
    // Used to present the complete word to the write port the same cycle the
    // last byte arrives (avoids a one-cycle NBA lag for wgt_shift_r).
    logic [WGT_WORD_W-1:0]  wgt_full;
    always_comb begin
        wgt_full = wgt_shift_r;
        if (state_r == ST_WEIGHT_LOAD && s_axis_tvalid)
            wgt_full[wgt_byte_cnt_r * DW +: DW] = s_axis_tdata;
    end

    // ── Input packing ─────────────────────────────────────────────────────────
    logic [IN_BUS_W-1:0]     in_shift_r;        // packed input word
    logic [IN_CNT_W-1:0]     in_byte_cnt_r;     // 0..C_IN-1
    logic                    in_full_r;          // all C_IN bytes received
    logic                    in_last_r;          // captured S_AXIS TLAST

    // Accept bytes from S_AXIS only while the buffer is not yet full.
    logic in_accepting;
    assign in_accepting = (state_r == ST_INPUT) && !in_full_r;

    // ── Output unpacking ──────────────────────────────────────────────────────
    logic [OUT_BUS_W-1:0]    out_latch_r;       // latched m_data
    logic [OUT_CNT_W-1:0]    out_byte_cnt_r;    // 0..C_OUT-1
    logic                    out_last_r;         // latched m_last

    // =========================================================================
    // State register
    // =========================================================================
    always_ff @(posedge clk) begin
        if (~rst_n) state_r <= ST_WEIGHT_LOAD;
        else        state_r <= state_next;
    end

    // =========================================================================
    // Next-state logic
    // =========================================================================
    always_comb begin
        state_next = state_r;   // hold by default

        case (state_r)

            // Last byte of last MAC_LANES-byte weight group + TLAST → done
            ST_WEIGHT_LOAD:
                if (s_axis_tvalid && s_axis_tready &&
                    s_axis_tlast  && wgt_byte_cnt_r == WGT_CNT_W'(MAC_LANES - 1))
                    state_next = ST_INPUT;

            // Core handshake completes (valid && ready) → wait for output
            ST_INPUT:
                if (core_s_valid && core_s_ready)
                    state_next = ST_WAIT_OUTPUT;

            // Core asserts m_valid → grab it (m_ready is 0 here so core holds)
            ST_WAIT_OUTPUT:
                if (core_m_valid)
                    state_next = ST_ACCEPT_OUTPUT;

            // One-cycle: m_ready=1 latches data; immediately move to send
            ST_ACCEPT_OUTPUT:
                state_next = ST_OUTPUT_SEND;

            // Last byte sent → loop back for next time step
            ST_OUTPUT_SEND:
                if (m_axis_tvalid && m_axis_tready &&
                    out_byte_cnt_r == OUT_CNT_W'(C_OUT - 1))
                    state_next = ST_INPUT;

            default:
                state_next = ST_WEIGHT_LOAD;
        endcase
    end

    // =========================================================================
    // Weight loading — accumulation and SRAM write
    // =========================================================================
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            wgt_shift_r     <= '0;
            wgt_byte_cnt_r  <= '0;
            wgt_word_addr_r <= '0;
            w_wr_en         <= 1'b0;
            w_wr_addr       <= '0;
            w_wr_data       <= '0;
            w_load_done     <= 1'b0;
        end else begin
            w_wr_en     <= 1'b0;
            w_load_done <= 1'b0;

            if (state_r == ST_WEIGHT_LOAD && s_axis_tvalid) begin
                // Place incoming byte in the appropriate slot of the buffer.
                wgt_shift_r[wgt_byte_cnt_r * DW +: DW] <= s_axis_tdata;

                if (wgt_byte_cnt_r == WGT_CNT_W'(MAC_LANES - 1)) begin
                    // Full word ready — issue SRAM write using the combinational
                    // wgt_full which includes the current byte without a lag cycle.
                    w_wr_en         <= 1'b1;
                    w_wr_addr       <= wgt_word_addr_r;
                    w_wr_data       <= wgt_full;
                    wgt_word_addr_r <= wgt_word_addr_r + 1;
                    wgt_byte_cnt_r  <= '0;
                end else begin
                    wgt_byte_cnt_r <= wgt_byte_cnt_r + 1;
                end
            end

            // Pulse w_load_done on the cycle we transition out of ST_WEIGHT_LOAD.
            // state_next is already ST_INPUT at this point.
            if (state_r == ST_WEIGHT_LOAD && state_next == ST_INPUT)
                w_load_done <= 1'b1;
        end
    end

    // =========================================================================
    // Input packing — accumulate C_IN bytes for one time step
    // =========================================================================
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            in_shift_r    <= '0;
            in_byte_cnt_r <= '0;
            in_full_r     <= 1'b0;
            in_last_r     <= 1'b0;
        end else begin

            // Clear input state when the core handshake completes so the
            // buffer is ready for the next time step.
            if (core_s_valid && core_s_ready) begin
                in_full_r     <= 1'b0;
                in_byte_cnt_r <= '0;
                in_last_r     <= 1'b0;
            end

            if (in_accepting && s_axis_tvalid) begin
                // Byte 0 → bits [7:0], byte C_IN-1 → bits [IN_BUS_W-1:IN_BUS_W-DW].
                in_shift_r[in_byte_cnt_r * DW +: DW] <= s_axis_tdata;

                if (in_byte_cnt_r == IN_CNT_W'(C_IN - 1)) begin
                    in_full_r <= 1'b1;
                    // TLAST on the last byte of the last time step marks frame end.
                    in_last_r <= s_axis_tlast;
                end else begin
                    in_byte_cnt_r <= in_byte_cnt_r + 1;
                end
            end
        end
    end

    // =========================================================================
    // Compute-core input handshake
    // =========================================================================
    // s_valid is presented once all C_IN bytes are buffered and the state is
    // ST_INPUT.  The core holds s_ready=1 in ST_IDLE; the single-cycle
    // handshake sends all 16 packed channels simultaneously.
    assign core_s_valid = (state_r == ST_INPUT) && in_full_r;
    assign core_s_data  = in_shift_r;
    assign core_s_last  = in_last_r;

    // =========================================================================
    // Compute-core output handshake
    // =========================================================================
    // m_ready is kept LOW (backpressure) until ST_ACCEPT_OUTPUT fires.
    // This ensures m_valid is observable for a full clock period before
    // the handshake clears it (see design note in module header).
    assign core_m_ready = (state_r == ST_ACCEPT_OUTPUT);

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            out_latch_r    <= '0;
            out_byte_cnt_r <= '0;
            out_last_r     <= 1'b0;
        end else begin

            // Latch output when the one-cycle m_ready pulse fires.
            if (state_r == ST_ACCEPT_OUTPUT) begin
                out_latch_r    <= core_m_data;
                out_last_r     <= core_m_last;
                out_byte_cnt_r <= '0;
            end

            // Advance byte pointer each time M_AXIS accepts a beat.
            if (state_r == ST_OUTPUT_SEND && m_axis_tvalid && m_axis_tready)
                out_byte_cnt_r <= out_byte_cnt_r + 1;
        end
    end

    // =========================================================================
    // AXI4-Stream output
    // =========================================================================
    assign s_axis_tready = (state_r == ST_WEIGHT_LOAD) ||
                           (state_r == ST_INPUT && !in_full_r);

    assign m_axis_tvalid = (state_r == ST_OUTPUT_SEND);
    assign m_axis_tdata  = out_latch_r[out_byte_cnt_r * DW +: DW];
    assign m_axis_tlast  = out_last_r && (out_byte_cnt_r == OUT_CNT_W'(C_OUT - 1));

    // =========================================================================
    // Compute core instantiation
    // =========================================================================
    compute_core #(
        .DATA_WIDTH (DW),
        .C_IN       (C_IN),
        .C_OUT      (C_OUT),
        .C_LATENT   (C_LATENT),
        .MAC_LANES  (MAC_LANES),
        .SRAM_DEPTH (SRAM_DEPTH)
    ) u_core (
        .clk         (clk),
        .rst_n       (rst_n),

        .w_wr_en     (w_wr_en),
        .w_wr_addr   (w_wr_addr),
        .w_wr_data   (w_wr_data),
        .w_load_done (w_load_done),

        .s_valid     (core_s_valid),
        .s_ready     (core_s_ready),
        .s_data      (core_s_data),
        .s_last      (core_s_last),

        .m_valid     (core_m_valid),
        .m_ready     (core_m_ready),
        .m_data      (core_m_data),
        .m_last      (core_m_last)
    );

endmodule
