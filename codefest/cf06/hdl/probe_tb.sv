`timescale 1ns/1ps
module probe_tb;
  logic clk, rst_n;
  logic signed [7:0] in_data [3:0];
  logic weight_wr_en;
  logic [1:0] weight_row, weight_col;
  logic weight_val;
  logic signed [9:0] out [3:0];

  crossbar_mac_4x4 dut(.*);

  initial clk=0; always #5 clk=~clk;

  initial begin
    rst_n=0; weight_wr_en=0; weight_row=0; weight_col=0; weight_val=0;
    in_data[0]=0; in_data[1]=0; in_data[2]=0; in_data[3]=0;
    @(negedge clk); // apply reset on negedge so FF sees it
    rst_n = 0;
    @(posedge clk); #1;
    $display("t=%0t  rst_n=%b  weight=%b  sx0=%0d  wc00=%0d  sum0=%0d  out0=%0d",
              $time, rst_n, dut.weight, dut.sx[0], dut.wc[0][0], dut.sum[0], out[0]);
    @(negedge clk); rst_n = 1;
    in_data[0]=8'sd1; in_data[1]=8'sd1; in_data[2]=8'sd1; in_data[3]=8'sd1;
    @(posedge clk); #1;
    $display("t=%0t  rst_n=%b  weight=%b  sx0=%0d  wc00=%0d  sum0=%0d  out0=%0d",
              $time, rst_n, dut.weight, dut.sx[0], dut.wc[0][0], dut.sum[0], out[0]);
    $finish;
  end
endmodule
