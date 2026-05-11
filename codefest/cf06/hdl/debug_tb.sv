`timescale 1ns/1ps
module debug_tb;
  logic clk, rst_n;
  logic signed [7:0] in_data [3:0];
  logic weight_wr_en;
  logic [1:0] weight_row, weight_col;
  logic weight_val;
  logic signed [9:0] out [3:0];
  crossbar_mac_4x4 dut(.*);
  initial clk=0; always #5 clk=~clk;
  initial begin
    rst_n=0; weight_wr_en=0;
    in_data[0]=0; in_data[1]=0; in_data[2]=0; in_data[3]=0;
    #20; rst_n=1; #20;
    // check weight[0][0] after reset -- should be 1 (all+1 default)
    in_data[0]=8'sd1; in_data[1]=8'sd1; in_data[2]=8'sd1; in_data[3]=8'sd1;
    @(posedge clk); #1;
    $display("After reset, all +1 weights, all in=1: out[0]=%0d (expect 4)", out[0]);
    $finish;
  end
endmodule
