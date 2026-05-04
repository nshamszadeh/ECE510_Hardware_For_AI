"""
Cocotb testbench for mac_lane.sv

Verifies:
  - Synchronous active-low reset drives acc to 0
  - Positive × positive accumulation
  - Signed accumulation (neg×pos, pos×neg, neg×neg)
  - Boundary operands (INT8_MIN × INT8_MAX)
  - clear resets acc mid-accumulation; accumulation can resume from 0
  - clear has priority over en when both asserted simultaneously
  - acc holds when en=0
  - No INT32 overflow under maximum encoder load (12 288 terms of 127×127)

Timing note
-----------
cocotb's RisingEdge / ClockCycles trigger fires in VPI's active region, before
the simulator runs the non-blocking assignment (NBA) region where always_ff <=
updates are committed.  Reading a registered output immediately after one of
these triggers therefore gives the *pre-edge* value.  Every read in this file
is preceded by `await Timer(1, unit="ps")` (tick / ticks helpers) to advance
past the NBA region and obtain the post-edge registered value.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

DW = 8   # INT8
AW = 32  # INT32


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def u8(v: int) -> int:
    """Signed Python int → unsigned 8-bit two's complement."""
    return int(v) & 0xFF


def s32(v) -> int:
    """Raw cocotb LogicArray value → signed 32-bit Python int."""
    raw = int(v) & 0xFFFF_FFFF
    return raw - 0x1_0000_0000 if raw >= 0x8000_0000 else raw


async def tick(dut):
    """Advance one clock cycle and let the NBA region settle."""
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def ticks(dut, n: int):
    """Advance n clock cycles and let the NBA region settle."""
    await ClockCycles(dut.clk, n)
    await Timer(1, unit="ps")


async def init(dut):
    """Start the clock and apply a two-cycle synchronous reset."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value  = 0
    dut.clear.value  = 0
    dut.en.value     = 0
    dut.weight.value = 0
    dut.actv.value   = 0
    await ticks(dut, 2)          # hold reset for two cycles
    dut.rst_n.value  = 1
    await ticks(dut, 1)          # one clean cycle after reset release


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_zeroes_acc(dut):
    """Synchronous active-low reset drives acc to 0 regardless of prior value."""
    await init(dut)

    # Accumulate for 4 cycles so acc is non-zero
    dut.weight.value = u8(10)
    dut.actv.value   = u8(10)
    dut.en.value     = 1
    await ticks(dut, 4)          # acc = 400
    assert s32(dut.acc.value) == 400, f"Pre-reset: expected 400, got {s32(dut.acc.value)}"

    # Apply synchronous reset; acc must become 0 on the same rising edge
    dut.en.value    = 0
    dut.rst_n.value = 0
    await ticks(dut, 1)
    assert s32(dut.acc.value) == 0, f"During reset: expected 0, got {s32(dut.acc.value)}"

    # Stays 0 after reset is released with en still low
    dut.rst_n.value = 1
    await ticks(dut, 1)
    assert s32(dut.acc.value) == 0, f"After reset release: expected 0, got {s32(dut.acc.value)}"

    dut._log.info("test_reset_zeroes_acc: PASSED")


@cocotb.test()
async def test_accumulate_positive(dut):
    """acc increases by weight×actv every enabled cycle (positive operands)."""
    await init(dut)
    w, a = 3, 4     # product = 12 per cycle
    dut.weight.value = u8(w)
    dut.actv.value   = u8(a)
    dut.en.value     = 1

    for n in range(1, 9):
        await tick(dut)
        expected = w * a * n
        got = s32(dut.acc.value)
        assert got == expected, f"Cycle {n}: expected {expected}, got {got}"

    dut._log.info("test_accumulate_positive: PASSED")


@cocotb.test()
async def test_accumulate_neg_pos(dut):
    """Negative weight × positive actv produces a negative running total."""
    await init(dut)
    w, a = -5, 3    # product = -15 per cycle
    dut.weight.value = u8(w)
    dut.actv.value   = u8(a)
    dut.en.value     = 1

    for n in range(1, 7):
        await tick(dut)
        expected = w * a * n
        got = s32(dut.acc.value)
        assert got == expected, f"Cycle {n}: expected {expected}, got {got}"

    dut._log.info("test_accumulate_neg_pos: PASSED")


@cocotb.test()
async def test_accumulate_neg_neg(dut):
    """Negative × negative gives a positive product (sign rule)."""
    await init(dut)
    w, a = -7, -6   # product = +42 per cycle
    dut.weight.value = u8(w)
    dut.actv.value   = u8(a)
    dut.en.value     = 1

    for n in range(1, 6):
        await tick(dut)
        expected = w * a * n
        got = s32(dut.acc.value)
        assert got == expected, f"Cycle {n}: expected {expected}, got {got}"

    dut._log.info("test_accumulate_neg_neg: PASSED")


@cocotb.test()
async def test_accumulate_min_max(dut):
    """Boundary operands: INT8_MIN (-128) × INT8_MAX (127) = -16256 per cycle."""
    await init(dut)
    w, a = -128, 127
    dut.weight.value = u8(w)
    dut.actv.value   = u8(a)
    dut.en.value     = 1

    for n in range(1, 5):
        await tick(dut)
        expected = w * a * n
        got = s32(dut.acc.value)
        assert got == expected, f"Cycle {n}: expected {expected}, got {got}"

    dut._log.info("test_accumulate_min_max: PASSED")


@cocotb.test()
async def test_clear_resets_mid_run(dut):
    """Asserting clear=1 drives acc to 0; accumulation resumes correctly from 0."""
    await init(dut)
    dut.weight.value = u8(10)
    dut.actv.value   = u8(10)
    dut.en.value     = 1
    await ticks(dut, 5)                            # acc = 500
    assert s32(dut.acc.value) == 500

    dut.en.value    = 0
    dut.clear.value = 1
    await ticks(dut, 1)
    assert s32(dut.acc.value) == 0, f"After clear: expected 0, got {s32(dut.acc.value)}"

    # Resume from zero
    dut.clear.value = 0
    dut.en.value    = 1
    await ticks(dut, 3)                            # acc = 300
    assert s32(dut.acc.value) == 300, f"After resume: expected 300, got {s32(dut.acc.value)}"

    dut._log.info("test_clear_resets_mid_run: PASSED")


@cocotb.test()
async def test_clear_priority_over_en(dut):
    """When clear=1 and en=1 simultaneously, clear wins and acc becomes 0."""
    await init(dut)
    dut.weight.value = u8(7)
    dut.actv.value   = u8(7)
    dut.en.value     = 1
    await ticks(dut, 3)                            # acc = 147
    assert s32(dut.acc.value) == 147

    # Assert both clear and en with a non-zero product on the inputs
    dut.clear.value  = 1
    dut.en.value     = 1
    dut.weight.value = u8(3)
    dut.actv.value   = u8(3)
    await ticks(dut, 1)
    got = s32(dut.acc.value)
    assert got == 0, f"Expected 0 (clear priority over en), got {got}"

    dut.clear.value = 0
    dut._log.info("test_clear_priority_over_en: PASSED")


@cocotb.test()
async def test_hold_when_disabled(dut):
    """When en=0 (and clear=0, rst_n=1), acc holds its value indefinitely."""
    await init(dut)
    dut.weight.value = u8(5)
    dut.actv.value   = u8(4)
    dut.en.value     = 1
    await ticks(dut, 4)                            # acc = 80
    held = s32(dut.acc.value)
    assert held == 80

    dut.en.value = 0
    for cycle in range(1, 7):
        await ticks(dut, 1)
        got = s32(dut.acc.value)
        assert got == held, f"Cycle {cycle}: acc changed to {got} while disabled (held={held})"

    dut._log.info("test_hold_when_disabled: PASSED")


@cocotb.test()
async def test_large_accumulation_no_overflow(dut):
    """Accumulate 127×127=16129 for 12288 cycles (max RAVE encoder load).

    Maximum possible sum = 1536 channels × 8 taps × 127² = 198,246,912.
    Must fit in INT32 (max 2,147,483,647) with no overflow or wrap-around.
    """
    await init(dut)
    max_terms = 1536 * 8       # 12 288
    expected  = 127 * 127 * max_terms   # 198 246 912

    dut.weight.value = u8(127)
    dut.actv.value   = u8(127)
    dut.en.value     = 1
    await ticks(dut, max_terms)

    got = s32(dut.acc.value)
    assert got == expected, f"Expected {expected:,}, got {got:,}"
    assert got < 2**31,     f"Overflowed INT32! got {got:,}"

    dut._log.info(f"Max accumulation: {got:,}  (INT32_MAX = {2**31-1:,})  PASSED")
