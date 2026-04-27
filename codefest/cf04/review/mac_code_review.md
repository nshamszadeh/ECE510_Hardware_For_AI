mac_llm_A.v was produced by chatgpt (free version).
mac_llm_B.v was produced by claude pro (sonnet 4.6).

Both modules are virtually identical other than minor formatting differences.
Both modules were synthesized with no errors or warnings using AMD Vivado 2025.1. Modules were also compiled with verilator with no issues.
When compiling with verilator, if the -Wall flag is used there is a warning regarding the module name "mac" not matching the file name.

## Testbench output when simulating mac_llm_A:
Time resolution is 1 ps
$finish called at time : 66 ns : File "C:/Users/Navid/Documents/ece/ece510/ECE510_Hardware_For_AI/codefest/cf04/hdl/mac_tb.v" Line 91
=== MAC Testbench Log ===
=------------------------------------------------------------
Time=6000 | rst=1 | a=0 | b=0 | a*b=0 | out=0 [RESET INIT]
--- Phase 1: a=3, b=4 for 3 cycles ---
Time=16000 | rst=0 | a=3 | b=4 | a*b=12 | out=12
Time=26000 | rst=0 | a=3 | b=4 | a*b=12 | out=24
Time=36000 | rst=0 | a=3 | b=4 | a*b=12 | out=36
--- Phase 2: RESET asserted ---
Time=46000 | rst=1 | a=3 | b=4 | a*b=12 | out=0
--- Phase 3: a=-5, b=2 for 2 cycles ---
Time=56000 | rst=0 | a=-5 | b=2 | a*b=-10 | out=-10
Time=66000 | rst=0 | a=-5 | b=2 | a*b=-10 | out=-20
=== Simulation complete ===

## Testbench output when simulating mac_llm_B:
Time resolution is 1 ps
$finish called at time : 66 ns : File "C:/Users/Navid/Documents/ece/ece510/ECE510_Hardware_For_AI/codefest/cf04/hdl/mac_tb.v" Line 91
=== MAC Testbench Log ===
                Time    rst      a      b      a*b          out
=------------------------------------------------------------
Time=6000 | rst=1 | a=0 | b=0 | a*b=0 | out=0 [RESET INIT]
--- Phase 1: a=3, b=4 for 3 cycles ---
Time=16000 | rst=0 | a=3 | b=4 | a*b=12 | out=12
Time=26000 | rst=0 | a=3 | b=4 | a*b=12 | out=24
Time=36000 | rst=0 | a=3 | b=4 | a*b=12 | out=36
--- Phase 2: RESET asserted ---
Time=46000 | rst=1 | a=3 | b=4 | a*b=12 | out=0
--- Phase 3: a=-5, b=2 for 2 cycles ---
Time=56000 | rst=0 | a=-5 | b=2 | a*b=-10 | out=-10
Time=66000 | rst=0 | a=-5 | b=2 | a*b=-10 | out=-20
=== Simulation complete ===

## Testbench output when simulating mac_correct:
Since the original modules have no errors, mac_llm_A was simply copied and pasted into mac_correct.v, so the testbench output is identical to mac_llm_A.

## Code Review
As stated before, the modules both are virtually identical and successfully compile (although with a warning regarding different module name from file name).
mac_llm_A's mac module included a comment after the rst port declaration indicating it is an active high synchronous reset, which may or may not be desirable in the context of a larger project. I.e., if the project specs indicate active high reset for all modules, then it may be assumed without adding comments by port declarations; however for projects that have multiple varying reset functionalities, including the comment would be preferable.

## Running yosys
Runnign yosys initially failed with error message:
-- Parsing `mac_correct.v' using frontend `verilog' --

1. Executing Verilog-2005 frontend: mac_correct.v
Parsing Verilog input from `mac_correct.v' to AST representation.
Lexer warning: The SystemVerilog keyword `logic' (at mac_correct.v:2) is not recognized unless read_verilog is called with -sv!
mac_correct.v:2: ERROR: syntax error, unexpected TOK_ID, expecting ',' or '=' or ')'

As suggested by the error message, yosys needs to be told to parse for systemverilog instead of verilog:

yosys -p "read_verilog -sv mac_correct.v; synth -top mac"

# Yosys output:
 /----------------------------------------------------------------------------\
 |                                                                            |
 |  yosys -- Yosys Open SYnthesis Suite                                       |
 |                                                                            |
 |  Copyright (C) 2012 - 2019  Clifford Wolf <clifford@clifford.at>           |
 |                                                                            |
 |  Permission to use, copy, modify, and/or distribute this software for any  |
 |  purpose with or without fee is hereby granted, provided that the above    |
 |  copyright notice and this permission notice appear in all copies.         |
 |                                                                            |
 |  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES  |
 |  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF          |
 |  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR   |
 |  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES    |
 |  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN     |
 |  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF   |
 |  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.            |
 |                                                                            |
 \----------------------------------------------------------------------------/

 Yosys 0.9 (git sha1 1979e0b)


-- Running command `read_verilog -sv mac_correct.v; synth -top mac' --

1. Executing Verilog-2005 frontend: mac_correct.v
Parsing SystemVerilog input from `mac_correct.v' to AST representation.
Generating RTLIL representation for module `\mac'.
Successfully finished Verilog frontend.

2. Executing SYNTH pass.

2.1. Executing HIERARCHY pass (managing design hierarchy).

2.1.1. Analyzing design hierarchy..
Top module:  \mac

2.1.2. Analyzing design hierarchy..
Top module:  \mac
Removed 0 unused modules.

2.2. Executing PROC pass (convert processes to netlists).

2.2.1. Executing PROC_CLEAN pass (remove empty switches from decision trees).
Cleaned up 0 empty switches.

2.2.2. Executing PROC_RMDEAD pass (remove dead branches from decision trees).
Marked 1 switch rules as full_case in process $proc$mac_correct.v:9$1 in module mac.
Removed a total of 0 dead cases.

2.2.3. Executing PROC_INIT pass (extract init attributes).

2.2.4. Executing PROC_ARST pass (detect async resets in processes).

2.2.5. Executing PROC_MUX pass (convert decision trees to multiplexers).
Creating decoders for process `\mac.$proc$mac_correct.v:9$1'.
     1/1: $0\out[31:0]

2.2.6. Executing PROC_DLATCH pass (convert process syncs to latches).

2.2.7. Executing PROC_DFF pass (convert process syncs to FFs).
Creating register for signal `\mac.\out' using process `\mac.$proc$mac_correct.v:9$1'.
  created $dff cell `$procdff$7' with positive edge clock.

2.2.8. Executing PROC_CLEAN pass (remove empty switches from decision trees).
Found and cleaned up 1 empty switch in `\mac.$proc$mac_correct.v:9$1'.
Removing empty process `mac.$proc$mac_correct.v:9$1'.
Cleaned up 1 empty switch.

2.3. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 0 unused cells and 2 unused wires.
<suppressed ~1 debug messages>

2.5. Executing CHECK pass (checking for obvious problems).
checking module mac..
found and reported 0 problems.

2.6. Executing OPT pass (performing simple optimizations).

2.6.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.6.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.6.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  Evaluating internal representation of mux trees.
  Analyzing evaluation results.
Removed 0 multiplexer ports.
<suppressed ~1 debug messages>

2.6.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.6.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.6.6. Executing OPT_RMDFF pass (remove dff with constant values).

2.6.7. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.6.8. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.6.9. Finished OPT passes. (There is nothing left to do.)

2.7. Executing WREDUCE pass (reducing word size of cells).
Removed top 16 bits (of 32) from port Y of cell mac.$mul$mac_correct.v:13$2 ($mul).

2.8. Executing PEEPOPT pass (run peephole optimizers).

2.9. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.10. Executing TECHMAP pass (map to technology primitives).

2.10.1. Executing Verilog-2005 frontend: /usr/bin/../share/yosys/cmp2lut.v
Parsing Verilog input from `/usr/bin/../share/yosys/cmp2lut.v' to AST representation.
Generating RTLIL representation for module `\_90_lut_cmp_'.
Successfully finished Verilog frontend.

2.10.2. Continuing TECHMAP pass.
No more expansions possible.

2.11. Executing ALUMACC pass (create $alu and $macc cells).
Extracting $alu and $macc cells in module mac:
  creating $macc model for $add$mac_correct.v:13$3 ($add).
  creating $macc model for $mul$mac_correct.v:13$2 ($mul).
  creating $alu model for $macc $add$mac_correct.v:13$3.
  creating $macc cell for $mul$mac_correct.v:13$2: $auto$alumacc.cc:354:replace_macc$8
  creating $alu cell for $add$mac_correct.v:13$3: $auto$alumacc.cc:474:replace_alu$9
  created 1 $alu and 1 $macc cells.

2.12. Executing SHARE pass (SAT-based resource sharing).

2.13. Executing OPT pass (performing simple optimizations).

2.13.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.13.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.13.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  Evaluating internal representation of mux trees.
  Analyzing evaluation results.
Removed 0 multiplexer ports.
<suppressed ~1 debug messages>

2.13.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.13.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.13.6. Executing OPT_RMDFF pass (remove dff with constant values).

2.13.7. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.13.8. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.13.9. Finished OPT passes. (There is nothing left to do.)

2.14. Executing FSM pass (extract and optimize FSM).

2.14.1. Executing FSM_DETECT pass (finding FSMs in design).

2.14.2. Executing FSM_EXTRACT pass (extracting FSM from design).

2.14.3. Executing FSM_OPT pass (simple optimizations of FSMs).

2.14.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.14.5. Executing FSM_OPT pass (simple optimizations of FSMs).

2.14.6. Executing FSM_RECODE pass (re-assigning FSM state encoding).

2.14.7. Executing FSM_INFO pass (dumping all available information on FSM cells).

2.14.8. Executing FSM_MAP pass (mapping FSMs to basic logic).

2.15. Executing OPT pass (performing simple optimizations).

2.15.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.15.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.15.3. Executing OPT_RMDFF pass (remove dff with constant values).

2.15.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.15.5. Finished fast OPT passes.

2.16. Executing MEMORY pass.

2.16.1. Executing MEMORY_DFF pass (merging $dff cells to $memrd and $memwr).

2.16.2. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.16.3. Executing MEMORY_SHARE pass (consolidating $memrd/$memwr cells).

2.16.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.16.5. Executing MEMORY_COLLECT pass (generating $mem cells).

2.17. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.18. Executing OPT pass (performing simple optimizations).

2.18.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.18.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.18.3. Executing OPT_RMDFF pass (remove dff with constant values).

2.18.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.18.5. Finished fast OPT passes.

2.19. Executing MEMORY_MAP pass (converting $mem cells to logic and flip-flops).

2.20. Executing OPT pass (performing simple optimizations).

2.20.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.20.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.20.3. Executing OPT_MUXTREE pass (detect dead branches in mux trees).
Running muxtree optimizer on module \mac..
  Creating internal representation of mux trees.
  Evaluating internal representation of mux trees.
  Analyzing evaluation results.
Removed 0 multiplexer ports.
<suppressed ~1 debug messages>

2.20.4. Executing OPT_REDUCE pass (consolidate $*mux and $reduce_* inputs).
  Optimizing cells in module \mac.
Performed a total of 0 changes.

2.20.5. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.20.6. Executing OPT_RMDFF pass (remove dff with constant values).

2.20.7. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..

2.20.8. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.20.9. Finished OPT passes. (There is nothing left to do.)

2.21. Executing TECHMAP pass (map to technology primitives).

2.21.1. Executing Verilog-2005 frontend: <techmap.v>
Parsing Verilog input from `<techmap.v>' to AST representation.
Generating RTLIL representation for module `\_90_simplemap_bool_ops'.
Generating RTLIL representation for module `\_90_simplemap_reduce_ops'.
Generating RTLIL representation for module `\_90_simplemap_logic_ops'.
Generating RTLIL representation for module `\_90_simplemap_compare_ops'.
Generating RTLIL representation for module `\_90_simplemap_various'.
Generating RTLIL representation for module `\_90_simplemap_registers'.
Generating RTLIL representation for module `\_90_shift_ops_shr_shl_sshl_sshr'.
Generating RTLIL representation for module `\_90_shift_shiftx'.
Generating RTLIL representation for module `\_90_fa'.
Generating RTLIL representation for module `\_90_lcu'.
Generating RTLIL representation for module `\_90_alu'.
Generating RTLIL representation for module `\_90_macc'.
Generating RTLIL representation for module `\_90_alumacc'.
Generating RTLIL representation for module `\$__div_mod_u'.
Generating RTLIL representation for module `\$__div_mod'.
Generating RTLIL representation for module `\_90_div'.
Generating RTLIL representation for module `\_90_mod'.
Generating RTLIL representation for module `\_90_pow'.
Generating RTLIL representation for module `\_90_pmux'.
Generating RTLIL representation for module `\_90_lut'.
Successfully finished Verilog frontend.

2.21.2. Continuing TECHMAP pass.
Using extmapper simplemap for cells of type $mux.
Using extmapper maccmap for cells of type $macc.
  add \a * \b (8x8 bits, signed)
Using template $paramod\_90_alu\A_SIGNED=1\B_SIGNED=1\A_WIDTH=32\B_WIDTH=32\Y_WIDTH=32 for cells of type $alu.
Using extmapper simplemap for cells of type $dff.
Using extmapper simplemap for cells of type $and.
Using extmapper simplemap for cells of type $not.
Using template $paramod\_90_fa\WIDTH=16 for cells of type $fa.
Using template $paramod\_90_alu\A_SIGNED=0\B_SIGNED=0\A_WIDTH=16\B_WIDTH=16\Y_WIDTH=16 for cells of type $alu.
Using extmapper simplemap for cells of type $xor.
Using template $paramod\_90_lcu\WIDTH=32 for cells of type $lcu.
Using extmapper simplemap for cells of type $pos.
Using extmapper simplemap for cells of type $or.
Using template $paramod\_90_lcu\WIDTH=16 for cells of type $lcu.
No more expansions possible.
<suppressed ~633 debug messages>

2.22. Executing OPT pass (performing simple optimizations).

2.22.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.
<suppressed ~309 debug messages>

2.22.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
<suppressed ~360 debug messages>
Removed a total of 120 cells.

2.22.3. Executing OPT_RMDFF pass (remove dff with constant values).

2.22.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 64 unused cells and 158 unused wires.
<suppressed ~65 debug messages>

2.22.5. Finished fast OPT passes.

2.23. Executing ABC pass (technology mapping using ABC).

2.23.1. Extracting gate netlist of module `\mac' to `<abc-temp-dir>/input.blif'..
Extracted 685 gates and 735 wires to a netlist network with 49 inputs and 32 outputs.

2.23.1.1. Executing ABC.
Running ABC command: berkeley-abc -s -f <abc-temp-dir>/abc.script 2>&1
ABC: ABC command line: "source <abc-temp-dir>/abc.script".
ABC: 
ABC: + read_blif <abc-temp-dir>/input.blif 
ABC: + read_library <abc-temp-dir>/stdcells.genlib 
ABC: Entered genlib library with 17 gates from file "<abc-temp-dir>/stdcells.genlib".
ABC: + strash 
ABC: + dretime 
ABC: + retime 
ABC: + map 
ABC: + write_blif <abc-temp-dir>/output.blif 

2.23.1.2. Re-integrating ABC results.
ABC RESULTS:               AND cells:       61
ABC RESULTS:            ANDNOT cells:      147
ABC RESULTS:              AOI3 cells:       63
ABC RESULTS:               MUX cells:        1
ABC RESULTS:              NAND cells:       23
ABC RESULTS:               NOR cells:       21
ABC RESULTS:               NOT cells:       36
ABC RESULTS:              OAI3 cells:       23
ABC RESULTS:                OR cells:       31
ABC RESULTS:             ORNOT cells:       13
ABC RESULTS:              XNOR cells:       60
ABC RESULTS:               XOR cells:      150
ABC RESULTS:        internal signals:      654
ABC RESULTS:           input signals:       49
ABC RESULTS:          output signals:       32
Removing temp directory.

2.24. Executing OPT pass (performing simple optimizations).

2.24.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module mac.

2.24.2. Executing OPT_MERGE pass (detect identical cells).
Finding identical cells in module `\mac'.
Removed a total of 0 cells.

2.24.3. Executing OPT_RMDFF pass (remove dff with constant values).

2.24.4. Executing OPT_CLEAN pass (remove unused cells and wires).
Finding unused cells or wires in module \mac..
Removed 0 unused cells and 253 unused wires.
<suppressed ~1 debug messages>

2.24.5. Finished fast OPT passes.

2.25. Executing HIERARCHY pass (managing design hierarchy).

2.25.1. Analyzing design hierarchy..
Top module:  \mac

2.25.2. Analyzing design hierarchy..
Top module:  \mac
Removed 0 unused modules.

2.26. Printing statistics.

=== mac ===

   Number of wires:                603
   Number of wire bits:            679
   Number of public wires:           5
   Number of public wire bits:      50
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:                661
     \$_ANDNOT_                     147
     \$_AND_                         61
     \$_AOI3_                        63
     \$_DFF_P_                       32
     \$_MUX_                          1
     \$_NAND_                        23
     \$_NOR_                         21
     \$_NOT_                         36
     \$_OAI3_                        23
     \$_ORNOT_                       13
     \$_OR_                          31
     \$_XNOR_                        60
     \$_XOR_                        150

2.27. Executing CHECK pass (checking for obvious problems).
checking module mac..
found and reported 0 problems.

End of script. Logfile hash: ad83da2112
CPU: user 0.29s system 0.02s, MEM: 20.17 MB total, 14.25 MB resident
Yosys 0.9 (git sha1 1979e0b)
Time spent: 22% 12x opt_merge (0 sec), 17% 15x opt_clean (0 sec), ...