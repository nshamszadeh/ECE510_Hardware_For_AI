"""
Cocotb testbench for layer_control_fsm.sv

Uses layer 0 (stem Conv1d: 16→96, K=7, D=1) as the primary test vehicle —
smallest channel counts, so simulations stay fast while hitting every state.

Tests:
  1. reset_and_load      — s_ready stays low until w_load_done, then rises
  2. input_phase_addr    — actv_wr_en/sel/addr correct for channels 0–15; no
                           bleed into ST_COMPUTE
  3. sram_addr_compute   — sram_rd_addr matches layer_base+mac_grp*C_in*K+cin*K+tap
                           for first 3 cin groups (21 cycles)
  4. mac_en_timing       — sram_rd_en fires one cycle ahead of mac_en (pipeline fill)
  5. activate_phase_addr — actv_wr_en/sel/addr correct for lanes 0–63;
                           drain cycle (mac_en=1) has wr_en=0; no bleed after lane 63
  6. mac_grp_advance     — after group 0 ST_ACTIVATE, ST_COMPUTE resumes with the
                           mac_grp=1 SRAM base offset
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

# ── Layer-0 constants (must match ROM in layer_control_fsm.sv) ───────────────
C_IN         = 16
K0           = 7
C_OUT0       = 96
NUM_GRPS0    = 2        # ceil(96/64)
MAC_LANES    = 64
BUF_HIST     = 64       # also == MAC_LANES
LAYER_BASE_0 = 0        # layer_base[0] from ROM


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

async def tick(dut):
    """One rising edge + 1 ps so NBA updates commit before we read outputs."""
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def ticks(dut, n: int):
    await ClockCycles(dut.clk, n)
    await Timer(1, unit="ps")


async def do_reset(dut):
    """Synchronous active-low reset for 2 cycles, then release."""
    dut.rst_n.value       = 0
    dut.w_load_done.value = 0
    dut.s_valid.value     = 0
    dut.s_last.value      = 0
    dut.m_ready.value     = 1
    await ticks(dut, 2)
    dut.rst_n.value = 1
    await ticks(dut, 1)


async def init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await do_reset(dut)


async def load_weights(dut):
    """Pulse w_load_done → FSM moves from ST_LOAD_WAIT to ST_IDLE.

    Needs 3 ticks total: tick 1 sets weights_loaded_r; tick 2 transitions
    state_r to ST_IDLE (output case still fires with old state, s_ready=0);
    tick 3 runs the ST_IDLE output case and raises s_ready.
    """
    dut.w_load_done.value = 1
    await tick(dut)
    dut.w_load_done.value = 0
    await tick(dut)   # state_r → ST_IDLE
    await tick(dut)   # ST_IDLE output case fires → s_ready=1


async def start_time_step(dut, last: bool = False):
    """Assert s_valid for one cycle; FSM latches it and moves to ST_INPUT."""
    dut.s_valid.value = 1
    dut.s_last.value  = 1 if last else 0
    await tick(dut)
    dut.s_valid.value = 0
    dut.s_last.value  = 0


def sram_addr(mac_grp: int, cin: int, tap: int) -> int:
    """Expected SRAM read address for layer 0."""
    return LAYER_BASE_0 + mac_grp * (C_IN * K0) + cin * K0 + tap


def actv_input_addr(ch: int) -> int:
    """Expected actv_wr_addr during ST_INPUT.  head_ptr is 0 on first time step."""
    return ch * BUF_HIST   # {ch, 6'b0}


def actv_activate_addr(lane: int) -> int:
    """Expected actv_wr_addr during ST_ACTIVATE for mac_grp=0.

    After one ST_INPUT pass, head_ptr_r[ch] == 1 for ch in 0..C_IN-1, else 0.
    The address is presented before the head-pointer update for this lane fires,
    so it still reflects the post-ST_INPUT value.
    """
    ch        = lane   # mac_grp=0 → wr_ch_idx = {5'b0, lane}
    head_ptr  = 1 if ch < C_IN else 0
    return ch * BUF_HIST + head_ptr


# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_reset_and_load(dut):
    """s_ready=0 through reset and ST_LOAD_WAIT; all active outputs idle.
    s_ready rises exactly one cycle after w_load_done is de-asserted."""
    await init(dut)

    assert int(dut.s_ready.value)    == 0, "s_ready should be 0 before weights loaded"
    assert int(dut.sram_rd_en.value) == 0, "sram_rd_en should be 0 at reset"
    assert int(dut.actv_wr_en.value) == 0, "actv_wr_en should be 0 at reset"
    assert int(dut.actv_rd_en.value) == 0, "actv_rd_en should be 0 at reset"
    assert int(dut.mac_en.value)     == 0, "mac_en should be 0 at reset"
    assert int(dut.mac_clear.value)  == 0, "mac_clear should be 0 at reset"

    await load_weights(dut)

    assert int(dut.s_ready.value) == 1, "s_ready should rise after w_load_done"
    assert int(dut.mac_en.value)  == 0, "mac_en should stay 0 in ST_IDLE"

    dut._log.info("test_reset_and_load: PASSED")


@cocotb.test()
async def test_input_phase_addresses(dut):
    """actv_wr_en=1, sel=0, and correct address for every channel 0..15.
    On the cycle after channel 15 the enable must have cleared (no bleed
    into the first cycle of ST_COMPUTE)."""
    await init(dut)
    await load_weights(dut)
    await start_time_step(dut)
    # FSM is now in ST_INPUT, s_ch_idx=0, actv_wr_en pre-armed from ST_IDLE

    for ch in range(C_IN):
        wr_en   = int(dut.actv_wr_en.value)
        wr_sel  = int(dut.actv_wr_sel.value)
        wr_addr = int(dut.actv_wr_addr.value)
        exp     = actv_input_addr(ch)

        assert wr_en   == 1,   f"ch {ch:2d}: actv_wr_en=0 (expected 1)"
        assert wr_sel  == 0,   f"ch {ch:2d}: actv_wr_sel={wr_sel} (expected 0)"
        assert wr_addr == exp, f"ch {ch:2d}: actv_wr_addr={wr_addr} (expected {exp})"

        await tick(dut)

    # First cycle of ST_COMPUTE — write enable must have cleared
    assert int(dut.actv_wr_en.value) == 0, (
        f"actv_wr_en leaked into ST_COMPUTE: got {int(dut.actv_wr_en.value)}"
    )

    dut._log.info("test_input_phase_addresses: PASSED")


@cocotb.test()
async def test_sram_addresses_compute_phase(dut):
    """sram_rd_en=1 and sram_rd_addr matches formula for first 3 cin groups."""
    await init(dut)
    await load_weights(dut)
    await start_time_step(dut)
    await ticks(dut, C_IN)   # advance through all 16 ST_INPUT cycles → ST_COMPUTE cycle 1

    for cin in range(3):
        for tap in range(K0):
            rd_en   = int(dut.sram_rd_en.value)
            rd_addr = int(dut.sram_rd_addr.value)
            exp     = sram_addr(mac_grp=0, cin=cin, tap=tap)

            assert rd_en   == 1,   f"cin={cin} tap={tap}: sram_rd_en=0"
            assert rd_addr == exp, (
                f"cin={cin} tap={tap}: sram_rd_addr={rd_addr} (expected {exp})"
            )
            await tick(dut)

    dut._log.info("test_sram_addresses_compute_phase: PASSED")


@cocotb.test()
async def test_mac_en_timing(dut):
    """sram_rd_en pre-fetches one cycle ahead of mac_en (pipeline fill on cycle 1)."""
    await init(dut)
    await load_weights(dut)
    await start_time_step(dut)
    await ticks(dut, C_IN)   # → ST_COMPUTE cycle 1

    # Cycle 1: sram_rd_en=1 (pre-armed from last ST_INPUT cycle), mac_en=0
    assert int(dut.sram_rd_en.value) == 1, "sram_rd_en should be 1 on cycle 1 of ST_COMPUTE"
    assert int(dut.mac_en.value)     == 0, "mac_en should be 0 on cycle 1 (pipeline fill)"
    await tick(dut)

    # Cycles 2..6: both active
    for cyc in range(2, 7):
        assert int(dut.sram_rd_en.value) == 1, f"cycle {cyc}: sram_rd_en=0"
        assert int(dut.mac_en.value)     == 1, f"cycle {cyc}: mac_en=0"
        await tick(dut)

    dut._log.info("test_mac_en_timing: PASSED")


@cocotb.test()
async def test_activate_phase_addresses(dut):
    """ST_ACTIVATE:
      - Cycle 1 (drain): mac_en=1, actv_wr_en=0
      - Cycles 2..65: mac_en=0, actv_wr_en=1, sel=1, correct address per lane
      - After lane 63: actv_wr_en must clear (no bleed into next state)
    """
    await init(dut)
    await load_weights(dut)
    await start_time_step(dut)
    await ticks(dut, C_IN)           # 16 cycles → ST_COMPUTE cycle 1
    await ticks(dut, C_IN * K0)      # 112 cycles → ST_ACTIVATE cycle 1

    # Drain cycle: mac_en still 1 from last ST_COMPUTE cycle
    assert int(dut.mac_en.value)     == 1, "ST_ACTIVATE drain: expected mac_en=1"
    assert int(dut.actv_wr_en.value) == 0, (
        f"ST_ACTIVATE drain: actv_wr_en={int(dut.actv_wr_en.value)} (expected 0)"
    )
    await tick(dut)   # → cycle 2 (mac_en=0, rl_lane_idx=0, wr_en pre-armed)

    for lane in range(MAC_LANES):
        wr_en   = int(dut.actv_wr_en.value)
        wr_sel  = int(dut.actv_wr_sel.value)
        wr_addr = int(dut.actv_wr_addr.value)
        exp     = actv_activate_addr(lane)

        assert wr_en   == 1,   f"lane {lane:2d}: actv_wr_en=0 (expected 1)"
        assert wr_sel  == 1,   f"lane {lane:2d}: actv_wr_sel={wr_sel} (expected 1)"
        assert wr_addr == exp, (
            f"lane {lane:2d}: actv_wr_addr={wr_addr} (expected {exp})"
        )
        await tick(dut)

    # After lane 63 the enable must have cleared
    assert int(dut.actv_wr_en.value) == 0, (
        f"actv_wr_en leaked after lane 63: got {int(dut.actv_wr_en.value)}"
    )

    dut._log.info("test_activate_phase_addresses: PASSED")


@cocotb.test()
async def test_mac_grp_advance(dut):
    """After group-0 ST_ACTIVATE, ST_COMPUTE resumes with the mac_grp=1 SRAM offset."""
    await init(dut)
    await load_weights(dut)
    await start_time_step(dut)
    await ticks(dut, C_IN)                   # ST_INPUT  (16 cycles)
    await ticks(dut, C_IN * K0)              # ST_COMPUTE group 0 (112 cycles)
    await ticks(dut, 1 + MAC_LANES)          # ST_ACTIVATE: 1 drain + 64 write cycles

    # Should now be at ST_COMPUTE cycle 1 for mac_grp=1
    assert int(dut.sram_rd_en.value) == 1, "sram_rd_en should be 1 in ST_COMPUTE (group 1)"

    exp     = sram_addr(mac_grp=1, cin=0, tap=0)   # = 1 * (16*7) = 112
    rd_addr = int(dut.sram_rd_addr.value)
    assert rd_addr == exp, (
        f"mac_grp=1 SRAM base: expected {exp}, got {rd_addr}"
    )

    dut._log.info("test_mac_grp_advance: PASSED")
