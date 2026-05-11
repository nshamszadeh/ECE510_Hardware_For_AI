// 4×4 Binary-Weight Crossbar MAC Unit
// Weights: +1 (stored as 1) or −1 (stored as 0)
// Each cycle: out[j] = Σ_i weight[i][j] × in_data[i]
//
// All internal arrays are packed so iverilog can drive them from always_ff.
// Port arrays (in_data, out) kept as unpacked for TB convenience; driven via
// continuous assigns from packed internal registers.

module crossbar_mac_4x4 (
    input  logic                clk,
    input  logic                rst_n,

    // 4 signed 8-bit input activations (unpacked — driven by TB)
    input  logic signed [7:0]   in_data [3:0],

    // Weight write port
    input  logic                weight_wr_en,
    input  logic [1:0]          weight_row,
    input  logic [1:0]          weight_col,
    input  logic                weight_val,     // 1 = +1, 0 = −1

    // 4 signed 10-bit registered outputs; packed so iverilog can drive from FF
    // out[j] selects the j-th 10-bit slice; use $signed(out[j]) to interpret signed
    // Range: 4 × [−128..127] = [−512..508] → 10 bits
    output logic [3:0][9:0]     out
);

    // ── Weight register file ─────────────────────────────────────────────────
    // Packed [row][col]; case decode avoids variable index in always_ff
    logic [3:0][3:0] weight;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight <= 16'hFFFF;          // all weights reset to +1
        end else if (weight_wr_en) begin
            case ({weight_row, weight_col})
                4'h0: weight[0][0] <= weight_val;
                4'h1: weight[0][1] <= weight_val;
                4'h2: weight[0][2] <= weight_val;
                4'h3: weight[0][3] <= weight_val;
                4'h4: weight[1][0] <= weight_val;
                4'h5: weight[1][1] <= weight_val;
                4'h6: weight[1][2] <= weight_val;
                4'h7: weight[1][3] <= weight_val;
                4'h8: weight[2][0] <= weight_val;
                4'h9: weight[2][1] <= weight_val;
                4'ha: weight[2][2] <= weight_val;
                4'hb: weight[2][3] <= weight_val;
                4'hc: weight[3][0] <= weight_val;
                4'hd: weight[3][1] <= weight_val;
                4'he: weight[3][2] <= weight_val;
                4'hf: weight[3][3] <= weight_val;
            endcase
        end
    end

    // ── Sign-extend inputs to 10 bits ────────────────────────────────────────
    // Packed [row][10-bit value]
    wire signed [3:0][9:0] sx;
    assign sx[0] = {{2{in_data[0][7]}}, in_data[0]};
    assign sx[1] = {{2{in_data[1][7]}}, in_data[1]};
    assign sx[2] = {{2{in_data[2][7]}}, in_data[2]};
    assign sx[3] = {{2{in_data[3][7]}}, in_data[3]};

    // ── Weighted contributions: +sx[i] or −sx[i] per weight bit ─────────────
    // Packed [row][col][10-bit value]
    wire signed [3:0][3:0][9:0] wc;
    genvar gi, gj;
    generate
        for (gi = 0; gi < 4; gi++) begin : row_gen
            for (gj = 0; gj < 4; gj++) begin : col_gen
                assign wc[gi][gj] = weight[gi][gj] ? sx[gi] : -sx[gi];
            end
        end
    endgenerate

    // ── Column sums ──────────────────────────────────────────────────────────
    wire signed [3:0][9:0] sum;
    assign sum[0] = wc[0][0] + wc[1][0] + wc[2][0] + wc[3][0];
    assign sum[1] = wc[0][1] + wc[1][1] + wc[2][1] + wc[3][1];
    assign sum[2] = wc[0][2] + wc[1][2] + wc[2][2] + wc[3][2];
    assign sum[3] = wc[0][3] + wc[1][3] + wc[2][3] + wc[3][3];

    // ── Output pipeline register ─────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= '0;
        else begin
            out[0] <= sum[0]; out[1] <= sum[1];
            out[2] <= sum[2]; out[3] <= sum[3];
        end
    end

endmodule
