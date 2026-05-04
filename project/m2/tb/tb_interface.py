"""
Cocotb testbench for interface.sv (module: encoder_axi)

AXI4-Stream ↔ RAVE v2 Encoder bridge integration test.

Design notes:
  Weight SRAM is not zeroed.  Only MAC_LANES=64 weight bytes are streamed to
  exit the weight phase; the remaining 177,631 SRAM words are uninitialized.
  The layer_control_fsm advances on cycle counters alone, so m_axis_tvalid
  asserts cleanly despite x values in the data path.  m_axis_tdata is not
  numerically checked in any test.

  m_axis_tready is held LOW until m_axis_tvalid is detected.  Although the
  NBA "last assignment wins" issue does not apply to encoder_axi's combinational
  m_axis_tvalid (it stays high for all C_OUT beats, not just one), keeping
  tready low during the inference wait mirrors the compute_core testbench
  discipline and avoids any ambiguity about when the output phase begins.

Tests:
  1. test_weight_phase_ready  — s_axis_tready=1 throughout ST_WEIGHT_LOAD;
                                still 1 immediately after TLAST transitions
                                the FSM to ST_INPUT
  2. test_input_phase_ready   — s_axis_tready=1 for C_IN-1 bytes; drops to 0
                                on the cycle that in_full_r is set (buffer full)
  3. test_full_pipeline       — 64 weight bytes → 16 input bytes (s_axis_tlast=1)
                                → m_axis_tvalid asserts within PIPELINE_TIMEOUT;
                                → C_OUT=256 bytes received; m_axis_tlast=1 on
                                  the 256th byte; m_axis_tvalid drops after
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer, First

C_IN             = 16
C_OUT            = 256
MAC_LANES        = 64

# Upper bound on cycles from input-phase handshake to first M_AXIS byte:
#   ST_WAIT_OUTPUT (~182,458 compute cycles) + ST_ACCEPT_OUTPUT (1) + margin
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
    dut.rst_n.value         = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tlast.value  = 0
    dut.m_axis_tready.value = 0   # held LOW so m_axis_tvalid is observable
    await ticks(dut, 2)
    dut.rst_n.value = 1
    await ticks(dut, 1)


async def init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await do_reset(dut)


async def send_byte(dut, data: int = 0, last: bool = False):
    """Send one byte on S_AXIS; spins on s_axis_tready before asserting valid."""
    while not int(dut.s_axis_tready.value):
        await tick(dut)
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value  = data
    dut.s_axis_tlast.value  = 1 if last else 0
    await tick(dut)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0


async def send_weight_word(dut, last_word: bool = False):
    """Send one MAC_LANES-byte (64-byte) weight word of zeros.
    TLAST is asserted on the final byte iff last_word=True."""
    for i in range(MAC_LANES):
        last = last_word and (i == MAC_LANES - 1)
        await send_byte(dut, 0, last=last)


# ── Tests ─────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_weight_phase_ready(dut):
    """s_axis_tready=1 throughout ST_WEIGHT_LOAD.

    Verifies that tready stays high for all MAC_LANES-1 bytes before the TLAST
    byte and remains high on the first ST_INPUT cycle (buffer empty)."""
    await init(dut)

    await tick(dut)   # advance one cycle so NBAs from reset settle
    assert int(dut.s_axis_tready.value) == 1, \
        "s_axis_tready should be 1 in ST_WEIGHT_LOAD"

    # Send MAC_LANES-1 bytes without TLAST; tready must stay high throughout.
    for i in range(MAC_LANES - 1):
        assert int(dut.s_axis_tready.value) == 1, \
            f"s_axis_tready dropped at weight byte {i} (expected 1)"
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tdata.value  = 0
        dut.s_axis_tlast.value  = 0
        await tick(dut)
        dut.s_axis_tvalid.value = 0

    # 64th byte with TLAST completes weight phase → FSM enters ST_INPUT.
    assert int(dut.s_axis_tready.value) == 1
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tlast.value  = 1
    await tick(dut)   # posedge: state_r → ST_INPUT
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value  = 0

    # ST_INPUT with empty buffer: tready = (ST_INPUT) && !in_full_r = 1.
    await tick(dut)
    assert int(dut.s_axis_tready.value) == 1, \
        "s_axis_tready should be 1 in ST_INPUT (buffer not yet full)"

    dut._log.info("test_weight_phase_ready: PASSED")


@cocotb.test()
async def test_input_phase_ready(dut):
    """After weight phase, s_axis_tready=1 while accumulating C_IN bytes.
    Drops to 0 on the cycle that in_full_r is set (16th byte accepted)."""
    await init(dut)
    await send_weight_word(dut, last_word=True)
    # State is now ST_INPUT, in_full_r=0, tready=1.

    # Bytes 0..C_IN-2: tready must be 1 before each send.
    for i in range(C_IN - 1):
        assert int(dut.s_axis_tready.value) == 1, \
            f"s_axis_tready should be 1 at input byte {i}"
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tdata.value  = 0
        dut.s_axis_tlast.value  = 0
        await tick(dut)
        dut.s_axis_tvalid.value = 0

    # C_IN-th byte (byte 15): accepted → in_full_r ← 1 (NBA).
    assert int(dut.s_axis_tready.value) == 1
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value  = 0
    dut.s_axis_tlast.value  = 0
    await tick(dut)   # posedge: in_full_r=1, state_r stays ST_INPUT this cycle
    dut.s_axis_tvalid.value = 0

    # tready = (ST_INPUT) && !in_full_r = 1 && !1 = 0.
    assert int(dut.s_axis_tready.value) == 0, \
        "s_axis_tready should be 0 when input buffer is full (in_full_r=1)"

    dut._log.info("test_input_phase_ready: PASSED")


@cocotb.test(timeout_time=120, timeout_unit="sec")
async def test_full_pipeline(dut):
    """Weight phase → input phase → 10-layer inference → C_OUT bytes on M_AXIS.

    Sends 64 zero weight bytes (TLAST) to exit ST_WEIGHT_LOAD, then 16 input
    bytes (TLAST on byte 16) to launch one inference step.  Holds
    m_axis_tready=0 during inference and waits for m_axis_tvalid via
    RisingEdge trigger.  Receives all C_OUT=256 output bytes, asserting
    m_axis_tlast on byte 255 and m_axis_tvalid=0 after.

    m_axis_tdata is not checked: uninitialized weight SRAM produces x values.
    """
    await init(dut)

    # ── Weight phase: one 64-byte word with TLAST ─────────────────────────────
    dut._log.info("Weight phase: sending %d bytes…", MAC_LANES)
    await send_weight_word(dut, last_word=True)
    dut._log.info("Weight phase complete. FSM now in ST_INPUT.")

    # ── Input phase: C_IN bytes, TLAST on last ────────────────────────────────
    dut._log.info("Input phase: sending %d bytes (TLAST on last)…", C_IN)
    for i in range(C_IN):
        await send_byte(dut, 0, last=(i == C_IN - 1))
    dut._log.info("Input phase complete. Waiting for m_axis_tvalid…")

    # ── Wait for M_AXIS output (m_axis_tready held LOW) ───────────────────────
    result = await First(
        RisingEdge(dut.m_axis_tvalid),
        ClockCycles(dut.clk, PIPELINE_TIMEOUT)
    )
    await Timer(1, unit="ps")

    assert int(dut.m_axis_tvalid.value) == 1, \
        f"m_axis_tvalid never asserted within {PIPELINE_TIMEOUT} cycles"
    dut._log.info("m_axis_tvalid asserted. Receiving %d output bytes…", C_OUT)

    # ── Receive all C_OUT output bytes ────────────────────────────────────────
    dut.m_axis_tready.value = 1
    tlast_seen = False

    for i in range(C_OUT):
        # m_axis_tvalid stays 1 for the entire ST_OUTPUT_SEND state; no spin.
        if int(dut.m_axis_tlast.value):
            tlast_seen = True
            assert i == C_OUT - 1, \
                f"m_axis_tlast asserted at byte {i} (expected byte {C_OUT - 1})"
        await tick(dut)

    dut.m_axis_tready.value = 0

    assert tlast_seen, "m_axis_tlast was never asserted during output"
    assert int(dut.m_axis_tvalid.value) == 0, \
        "m_axis_tvalid should deassert after final output byte"

    dut._log.info("test_full_pipeline: PASSED")
