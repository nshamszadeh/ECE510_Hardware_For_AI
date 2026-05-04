SIM           ?= icarus
TOPLEVEL_LANG ?= verilog

# Select module under test on the command line, e.g.:
#   make TOPLEVEL=mac_lane
#   make TOPLEVEL=weight_sram
# Defaults to leaky_relu.
TOPLEVEL            ?= leaky_relu
COCOTB_TEST_MODULES ?= tb_$(TOPLEVEL)

# encoder_axi module lives in tb_interface.py, not tb_encoder_axi.py
ifeq ($(TOPLEVEL),encoder_axi)
COCOTB_TEST_MODULES = tb_interface
endif

# Explicit per-module source lists so sub-module dependencies are included.
# leaky_relu and mac_lane are self-contained; mac_array needs mac_lane too.
ifeq ($(TOPLEVEL),mac_array)
VERILOG_SOURCES = $(abspath ../rtl/mac_lane.sv) \
                  $(abspath ../rtl/mac_array.sv)
else ifeq ($(TOPLEVEL),compute_core)
VERILOG_SOURCES = $(abspath ../rtl/mac_lane.sv) \
                  $(abspath ../rtl/mac_array.sv) \
                  $(abspath ../rtl/leaky_relu.sv) \
                  $(abspath ../rtl/weight_sram.sv) \
                  $(abspath ../rtl/actv_buf.sv) \
                  $(abspath ../rtl/layer_control_fsm.sv) \
                  $(abspath ../rtl/compute_core.sv)
else ifeq ($(TOPLEVEL),encoder_axi)
VERILOG_SOURCES = $(abspath ../rtl/mac_lane.sv) \
                  $(abspath ../rtl/mac_array.sv) \
                  $(abspath ../rtl/leaky_relu.sv) \
                  $(abspath ../rtl/weight_sram.sv) \
                  $(abspath ../rtl/actv_buf.sv) \
                  $(abspath ../rtl/layer_control_fsm.sv) \
                  $(abspath ../rtl/compute_core.sv) \
                  $(abspath ../rtl/interface.sv)
else
VERILOG_SOURCES = $(abspath ../rtl/$(TOPLEVEL).sv)
endif

COMPILE_ARGS += -g2012

# Separate build directory per module so switching TOPLEVEL never reuses a
# stale binary compiled for a different design.
SIM_BUILD = sim_build/$(TOPLEVEL)

include $(shell cocotb-config --makefiles)/Makefile.sim
