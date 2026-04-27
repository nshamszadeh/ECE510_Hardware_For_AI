`timescale 1ns/1ps

module mac_tb;

    // DUT signals
    logic        clk;
    logic        rst;
    logic signed [7:0]  a;
    logic signed [7:0]  b;
    logic signed [31:0] out;

    // Log file handle
    integer log_file;

    // Instantiate DUT
    mac dut (
        .clk(clk),
        .rst(rst),
        .a(a),
        .b(b),
        .out(out)
    );

    // Clock generation: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Task: apply inputs for N rising edges and log each result
    task apply_and_log(
        input logic signed [7:0] in_a,
        input logic signed [7:0] in_b,
        input integer            cycles
    );
        integer i;
        begin
            a = in_a;
            b = in_b;
            for (i = 0; i < cycles; i++) begin
                @(posedge clk);
                #1; // small settling delay after posedge to sample stable out
                $fdisplay(log_file,
                    "Time=%0t | rst=%0b | a=%0d | b=%0d | a*b=%0d | out=%0d",
                    $time, rst, a, b, (a*b), out);
            end
        end
    endtask

    // Stimulus
    initial begin
        // Open log file
        log_file = $fopen("mac_tb.log", "w");
        if (log_file == 0) begin
            $display("ERROR: Could not open log file.");
            $finish;
        end
        $fdisplay(log_file, "=== MAC Testbench Log ===");
        $fdisplay(log_file, "%-20s %-6s %-6s %-6s %-8s %-12s",
                  "Time", "rst", "a", "b", "a*b", "out");
        $fdisplay(log_file, "%s", {"=", {60{"-"}}});

        // Initialise
        rst = 1;
        a   = 8'sd0;
        b   = 8'sd0;

        // Hold reset for one cycle before starting
        @(posedge clk);
        #1;
        $fdisplay(log_file,
            "Time=%0t | rst=%0b | a=%0d | b=%0d | a*b=%0d | out=%0d [RESET INIT]",
            $time, rst, a, b, (a*b), out);

        // De-assert reset, apply a=3, b=4 for 3 cycles
        rst = 0;
        $fdisplay(log_file, "--- Phase 1: a=3, b=4 for 3 cycles ---");
        apply_and_log(8'sd3, 8'sd4, 3);

        // Assert reset for 1 cycle
        rst = 1;
        $fdisplay(log_file, "--- Phase 2: RESET asserted ---");
        apply_and_log(8'sd3, 8'sd4, 1);   // inputs held; reset clears out

        // De-assert reset, apply a=-5, b=2 for 2 cycles
        rst = 0;
        $fdisplay(log_file, "--- Phase 3: a=-5, b=2 for 2 cycles ---");
        apply_and_log(-8'sd5, 8'sd2, 2);

        $fdisplay(log_file, "=== Simulation complete ===");
        $fclose(log_file);
        $display("Simulation complete. Results written to mac_tb.log");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #10000;
        $fdisplay(log_file, "ERROR: Simulation timeout!");
        $fclose(log_file);
        $finish;
    end

endmodule