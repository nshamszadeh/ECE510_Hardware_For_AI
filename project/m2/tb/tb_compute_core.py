"""
Cocotb testbench for compute_core.sv

Full integration test: all 6 sub-modules wired together and exercised through
one complete encoder time step (10 layers, stem→head).

Design note — m_ready / m_valid handshake:
  layer_control_fsm's ST_OUTPUT always_ff contains:
      m_valid <= 1'b1;
      if (m_ready) m_valid <= 1'b0;   // last NBA wins
  When m_ready is pre-asserted the two NBAs collapse to 0, so m_valid is never
  visible as 1 between clock edges.  To make m_valid observable we hold
  m_ready=0 during the pipeline and only pulse it high once m_valid=1 is seen.

Weight SRAM zeroing:
  weight_sram has no reset; unwritten locations return 'x' in simulation.
  All 177,632 wide-word addresses used by the encoder are explicitly zeroed
  before each test to prevent 4-state x-propagation through the MAC array.

actv_buf initialisation:
  actv_buf's synchronous reset clears only the rd_data register, not the
  storage array.  On the very first inference frame, history taps other than
  the one written in ST_INPUT will read 'x'.  With non-zero weights this
  causes x-propagation into m_data, so m_data is not numerically asserted.

Tests:
  1. test_weight_load_ready  — s_ready=0 before w_load_done; rises after
  2. test_full_pipeline      — zero weights; one time step (s_last=1);
                               m_valid asserts within PIPELINE_TIMEOUT,
                               m_last=1, handshake completes, s_ready recovers
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, First

# ── Encoder constants ─────────────────────────────────────────────────────────
C_IN       = 16
C_OUT      = 256
MAC_LANES  = 64

# Total wide-word SRAM addresses used across all 10 encoder layers:
#   ceil(C_out/64) * C_in * K  summed over the full layer table in the FSM ROM.
#
#   L0:  2*16*7    =    224   base       0
#   L1:  2*96*3    =    576   base     224
#   L2:  3*96*8    =  2,304   base     800
#   L3:  3*192*3   =  1,728   base   3,104
#   L4:  6*192*8   =  9,216   base   4,832
#   L5:  6*384*3   =  6,912   base  14,048
#   L6: 12*384*8   = 36,864   base  20,960
#   L7: 12*768*3   = 27,648   base  57,824
#   L8: 24*768*4   = 73,728   base  85,472
#   L9:  4*1536*3  = 18,432   base 159,200
#   total = 177,632
TOTAL_WEIGHT_WORDS = 177_632

# Upper bound on cycles for one full 10-layer encoder pass:
#   ST_INPUT (16) + ST_COMPUTE (177,632) + ST_ACTIVATE (4,810) + margin
PIPELINE_TIMEOUT = 300_000


# ── Helpers ───────────────────────────────────────────────────────────────────

async def tick(dut):
    """One rising edge + 1 ps so NBA updates commit before reading outputs."""
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def ticks(dut, n: int):
    await ClockCycles(dut.clk, n)
    await Timer(1, unit="ps")


async def do_reset(dut):
    """m_ready starts low so ST_OUTPUT is not immediately consumed."""
    dut.rst_n.value       = 0
    dut.w_wr_en.value     = 0
    dut.w_wr_addr.value   = 0
    dut.w_wr_data.value   = 0
    dut.w_load_done.value = 0
    dut.s_valid.value     = 0
    dut.s_data.value      = 0
    dut.s_last.value      = 0
    dut.m_ready.value     = 0   # hold low so m_valid is observable
    await ticks(dut, 2)
    dut.rst_n.value = 1
    await ticks(dut, 1)


async def init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await do_reset(dut)


async def write_all_weights_zero(dut):
    """Zero all wide-word SRAM entries used by the encoder (177,632 words).
    Prevents x-propagation from uninitialized weight_sram storage.
    Runs in 177,632 clock cycles (~1.8 ms at 10 ns).
    """
    dut.w_wr_en.value   = 1
    dut.w_wr_data.value = 0
    for addr in range(TOTAL_WEIGHT_WORDS):
        dut.w_wr_addr.value = addr
        await RisingEdge(dut.clk)
    dut.w_wr_en.value = 0
    await Timer(1, unit="ps")


async def load_done(dut):
    """Pulse w_load_done and wait for s_ready (3 clock cycles).
    Tick 1: weights_loaded_r set.
    Tick 2: state_r → ST_IDLE.
    Tick 3: ST_IDLE output case fires → s_ready=1.
    """
    dut.w_load_done.value = 1
    await tick(dut)
    dut.w_load_done.value = 0
    await tick(dut)
    await tick(dut)


async def start_time_step(dut, last: bool = False):
    """Assert s_valid for one cycle to launch a time step."""
    dut.s_valid.value = 1
    dut.s_last.value  = 1 if last else 0
    await tick(dut)
    dut.s_valid.value = 0
    dut.s_last.value  = 0


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_weight_load_ready(dut):
    """s_ready stays low until w_load_done; m_valid stays low in ST_IDLE."""
    await init(dut)

    assert int(dut.s_ready.value) == 0, "s_ready should be 0 at reset"
    assert int(dut.m_valid.value) == 0, "m_valid should be 0 at reset"

    await load_done(dut)

    assert int(dut.s_ready.value) == 1, "s_ready should rise after w_load_done"
    assert int(dut.m_valid.value) == 0, "m_valid should be 0 in ST_IDLE"

    dut._log.info("test_weight_load_ready: PASSED")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def test_full_pipeline(dut):
    """Full 10-layer pipeline smoke test with all-zero weights.

    Drives one input time step (s_last=1) and verifies:
      - m_valid asserts within PIPELINE_TIMEOUT cycles (via RisingEdge trigger)
      - m_last=1 (because s_last=1 was the only time step)
      - m_valid drops one cycle after the m_ready handshake
      - s_ready recovers within a few cycles (FSM returns to ST_IDLE)

    m_valid is only observable when m_ready is low: the ST_OUTPUT always_ff
    assigns m_valid=1 then m_valid=0 in the same block when m_ready is already
    high (last NBA wins), so the testbench holds m_ready=0 during the pipeline
    and asserts it only after detecting m_valid.
    """
    await init(dut)
    dut._log.info("Zeroing weight SRAM (%d words)…", TOTAL_WEIGHT_WORDS)
    await write_all_weights_zero(dut)
    dut._log.info("Weight SRAM zeroed.")

    await load_done(dut)
    assert int(dut.s_ready.value) == 1, "s_ready should be 1 before time step"

    await start_time_step(dut, last=True)

    # ── Wait for m_valid using an edge trigger (efficient, no busy-poll) ──────
    result = await First(
        RisingEdge(dut.m_valid),
        ClockCycles(dut.clk, PIPELINE_TIMEOUT)
    )
    await Timer(1, unit="ps")  # let any pending NBA settle

    assert int(dut.m_valid.value) == 1, \
        f"m_valid never asserted within {PIPELINE_TIMEOUT} cycles"
    assert int(dut.m_last.value)  == 1, \
        "m_last should be 1 (s_last=1 was the only time step)"

    dut._log.info("m_valid asserted; asserting m_ready to complete handshake")

    # ── Complete handshake ────────────────────────────────────────────────────
    dut.m_ready.value = 1
    await tick(dut)
    dut.m_ready.value = 0

    assert int(dut.m_valid.value) == 0, \
        "m_valid should drop one cycle after m_ready handshake"

    # ── s_ready recovery: ST_OUTPUT → ST_FRAME_END → ST_IDLE ─────────────────
    recovered = False
    for _ in range(10):
        await tick(dut)
        if int(dut.s_ready.value) == 1:
            recovered = True
            break
    assert recovered, "s_ready did not recover after pipeline completion"

    dut._log.info("test_full_pipeline: PASSED")
