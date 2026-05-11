`timescale 1ns/1ps

module crossbar_tb;

    logic               clk, rst_n;
    logic signed [7:0]  in_data [3:0];
    logic               weight_wr_en;
    logic [1:0]         weight_row, weight_col;
    logic               weight_val;
    logic [3:0][9:0]    out;         // packed to match DUT port

    crossbar_mac_4x4 dut (.*);

    initial clk = 0;
    always #5 clk = ~clk;

    // Write one weight entry and deassert enable
    task write_weight;
        input [1:0] row, col;
        input       val;
        begin
            @(negedge clk);
            weight_wr_en = 1;
            weight_row   = row;
            weight_col   = col;
            weight_val   = val;
            @(posedge clk); #1;
            weight_wr_en = 0;
        end
    endtask

    integer pass_count, fail_count;

    task check;
        input integer j;
        input signed [9:0] expected;
        begin
            if ($signed(out[j]) === expected) begin
                $display("PASS  out[%0d] = %0d", j, $signed(out[j]));
                $fdisplay(log_fd, "PASS  out[%0d] = %0d", j, $signed(out[j]));
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL  out[%0d] = %0d  (expected %0d)", j, $signed(out[j]), expected);
                $fdisplay(log_fd, "FAIL  out[%0d] = %0d  (expected %0d)", j, $signed(out[j]), expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    integer log_fd;

    initial begin
        log_fd = $fopen("../sim_log.log", "w");
        pass_count   = 0;
        fail_count   = 0;
        rst_n        = 1;   // start high so the negedge pulse is a real transition
        weight_wr_en = 0;
        weight_row   = 0;
        weight_col   = 0;
        weight_val   = 0;
        in_data[0] = 0; in_data[1] = 0; in_data[2] = 0; in_data[3] = 0;

        @(negedge clk); rst_n = 0;   // assert reset (1→0 negedge seen by FFs)
        @(negedge clk); rst_n = 1;   // release reset

        // ── Load weight matrix ───────────────────────────────────────────────
        // Row 0: [+1, −1, +1, −1]  → [1, 0, 1, 0]
        write_weight(0, 0, 1);
        write_weight(0, 1, 0);
        write_weight(0, 2, 1);
        write_weight(0, 3, 0);
        // Row 1: [+1, +1, −1, −1]  → [1, 1, 0, 0]
        write_weight(1, 0, 1);
        write_weight(1, 1, 1);
        write_weight(1, 2, 0);
        write_weight(1, 3, 0);
        // Row 2: [−1, +1, +1, −1]  → [0, 1, 1, 0]
        write_weight(2, 0, 0);
        write_weight(2, 1, 1);
        write_weight(2, 2, 1);
        write_weight(2, 3, 0);
        // Row 3: [−1, −1, −1, +1]  → [0, 0, 0, 1]
        write_weight(3, 0, 0);
        write_weight(3, 1, 0);
        write_weight(3, 2, 0);
        write_weight(3, 3, 1);

        // ── Apply inputs [10, 20, 30, 40] ───────────────────────────────────
        @(negedge clk);
        in_data[0] = 8'sd10;
        in_data[1] = 8'sd20;
        in_data[2] = 8'sd30;
        in_data[3] = 8'sd40;

        // Wait one cycle for registered output
        @(posedge clk); #1;

        // ── Check against hand-computed expected outputs ─────────────────────
        // out[0] = (+1)(10)+(+1)(20)+(−1)(30)+(−1)(40) = −40
        // out[1] = (−1)(10)+(+1)(20)+(+1)(30)+(−1)(40) =   0
        // out[2] = (+1)(10)+(−1)(20)+(+1)(30)+(−1)(40) = −20
        // out[3] = (−1)(10)+(−1)(20)+(−1)(30)+(+1)(40) = −20
        $display("─── Results ───────────────────────────");
        $fdisplay(log_fd, "─── Results ───────────────────────────");
        check(0, -10'sd40);
        check(1,  10'sd0);
        check(2, -10'sd20);
        check(3, -10'sd20);
        $display("─── %0d passed, %0d failed ────────────", pass_count, fail_count);
        $fdisplay(log_fd, "─── %0d passed, %0d failed ────────────", pass_count, fail_count);
        $fclose(log_fd);

        $finish;
    end

    initial begin
        #10000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
