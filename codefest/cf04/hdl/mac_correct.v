module mac (
    input  logic              clk,
    input  logic              rst,   // active-high synchronous reset
    input  logic signed [7:0] a,
    input  logic signed [7:0] b,
    output logic signed [31:0] out
);

    always_ff @(posedge clk) begin
        if (rst) begin
            out <= 32'sd0;
        end else begin
            out <= out + (a * b);
        end
    end

endmodule
