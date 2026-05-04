"""
Cocotb testbench for mac_array.sv

mac_array is a structural wrapper that instantiates LANES mac_lane modules.
Tests focus on the array-level properties not covered by test_mac_lane:

  - All LANES psum outputs are zeroed by reset
  - actv is broadcast identically to every lane
  - Each lane accumulates its own weight[i] slice independently
  - clear clears all LANES simultaneously
  - clear has priority over en for all lanes
  - All lanes hold when en=0
  - Correct per-lane accumulation with distinct weights for all 64 lanes

Timing note: see test_mac_lane.py.  The tick / ticks helpers add a 1 ps
Timer after every rising edge to let always_ff NBA updates commit before
outputs are read.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
import random

LANES = 64
DW    = 8    # INT8
AW    = 32   # INT32


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def u8(v: int) -> int:
    return int(v) & 0xFF


def s32(v) -> int:
    raw = int(v) & 0xFFFF_FFFF
    return raw - 0x1_0000_0000 if raw >= 0x8000_0000 else raw


def pack_weights(weights: list[int]) -> int:
    """Pack LANES signed INT8 values into the flat weight bus (lane 0 at LSB)."""
    mask   = (1 << DW) - 1
    result = 0
    for i, w in enumerate(weights):
        result |= (int(w) & mask) << (i * DW)
    return result


def unpack_psum(flat_val, lane: int) -> int:
    """Extract the signed INT32 psum for a single lane."""
    mask = (1 << AW) - 1
    v    = (int(flat_val) >> (lane * AW)) & mask
    return v - (1 << AW) if v >= (1 << (AW - 1)) else v


async def tick(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def ticks(dut, n: int):
    await ClockCycles(dut.clk, n)
    await Timer(1, unit="ps")


async def init(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value  = 0
    dut.clear.value  = 0
    dut.en.value     = 0
    dut.weight.value = 0
    dut.actv.value   = 0
    await ticks(dut, 2)
    dut.rst_n.value  = 1
    await ticks(dut, 1)


def check_all_lanes(dut, expected_fn, label: str):
    """Assert expected_fn(lane) == psum[lane] for every lane."""
    flat    = dut.psum.value
    errors  = []
    for lane in range(LANES):
        got = unpack_psum(flat, lane)
        exp = expected_fn(lane)
        if got != exp:
            errors.append(f"  lane {lane:2d}: expected {exp}, got {got}")
    assert not errors, f"{label} — lane mismatches:\n" + "\n".join(errors)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_zeroes_all_lanes(dut):
    """Synchronous reset drives every psum to 0, regardless of prior value."""
    await init(dut)

    # Accumulate non-zero values across all lanes
    weights = [i + 1 for i in range(LANES)]   # 1 … 64
    dut.weight.value = pack_weights(weights)
    dut.actv.value   = u8(3)
    dut.en.value     = 1
    await ticks(dut, 4)   # psum[i] = (i+1)*3*4

    # Apply reset
    dut.en.value    = 0
    dut.rst_n.value = 0
    await ticks(dut, 1)
    check_all_lanes(dut, lambda _: 0, "After reset")

    dut.rst_n.value = 1
    await ticks(dut, 1)
    check_all_lanes(dut, lambda _: 0, "After reset release")

    dut._log.info("test_reset_zeroes_all_lanes: PASSED")


@cocotb.test()
async def test_broadcast_actv(dut):
    """actv is broadcast to every lane; with uniform weights all psums are equal."""
    await init(dut)

    w, a = 5, 7
    dut.weight.value = pack_weights([w] * LANES)
    dut.actv.value   = u8(a)
    dut.en.value     = 1

    for n in range(1, 6):
        await tick(dut)
        expected = w * a * n
        check_all_lanes(dut, lambda _: expected, f"Cycle {n}")

    dut._log.info("test_broadcast_actv: PASSED")


@cocotb.test()
async def test_distinct_weights_per_lane(dut):
    """Each lane accumulates its own weight[i] slice independently of other lanes."""
    await init(dut)

    # weights[i] = i - 32  →  range -32 … +31, a mix of signs
    weights = [i - 32 for i in range(LANES)]
    actv    = 4
    dut.weight.value = pack_weights(weights)
    dut.actv.value   = u8(actv)
    dut.en.value     = 1

    for n in range(1, 5):
        await tick(dut)
        check_all_lanes(
            dut,
            lambda lane, _n=n: weights[lane] * actv * _n,
            f"Cycle {n}",
        )

    dut._log.info("test_distinct_weights_per_lane: PASSED")


@cocotb.test()
async def test_clear_all_lanes_simultaneously(dut):
    """clear=1 drives every psum to 0 in a single cycle."""
    await init(dut)

    dut.weight.value = pack_weights([10] * LANES)
    dut.actv.value   = u8(2)
    dut.en.value     = 1
    await ticks(dut, 5)   # psum[i] = 100 for all i
    check_all_lanes(dut, lambda _: 100, "Pre-clear")

    dut.en.value    = 0
    dut.clear.value = 1
    await ticks(dut, 1)
    check_all_lanes(dut, lambda _: 0, "After clear")

    # Accumulation resumes from 0
    dut.clear.value = 0
    dut.en.value    = 1
    await ticks(dut, 3)   # psum[i] = 60
    check_all_lanes(dut, lambda _: 60, "After resume")

    dut._log.info("test_clear_all_lanes_simultaneously: PASSED")


@cocotb.test()
async def test_clear_priority_over_en(dut):
    """When clear=1 and en=1 simultaneously, clear wins for every lane."""
    await init(dut)

    dut.weight.value = pack_weights([3] * LANES)
    dut.actv.value   = u8(3)
    dut.en.value     = 1
    await ticks(dut, 4)   # psum[i] = 36
    check_all_lanes(dut, lambda _: 36, "Pre-clear+en")

    dut.clear.value  = 1   # assert clear and en simultaneously
    dut.en.value     = 1
    await ticks(dut, 1)
    check_all_lanes(dut, lambda _: 0, "After simultaneous clear+en (clear wins)")

    dut.clear.value = 0
    dut._log.info("test_clear_priority_over_en: PASSED")


@cocotb.test()
async def test_hold_when_disabled(dut):
    """When en=0 all psums hold their values for multiple cycles."""
    await init(dut)

    weights = [i + 1 for i in range(LANES)]
    actv    = 2
    dut.weight.value = pack_weights(weights)
    dut.actv.value   = u8(actv)
    dut.en.value     = 1
    await ticks(dut, 3)   # psum[i] = (i+1)*2*3 = (i+1)*6

    # Snapshot expected values
    snapshot = {lane: unpack_psum(dut.psum.value, lane) for lane in range(LANES)}

    dut.en.value = 0
    for cycle in range(1, 5):
        await ticks(dut, 1)
        errors = []
        for lane in range(LANES):
            got = unpack_psum(dut.psum.value, lane)
            if got != snapshot[lane]:
                errors.append(f"  lane {lane}: held {snapshot[lane]}, got {got}")
        assert not errors, f"Cycle {cycle}: lanes changed while disabled:\n" + "\n".join(errors)

    dut._log.info("test_hold_when_disabled: PASSED")


@cocotb.test()
async def test_random_weights_all_lanes(dut):
    """Random distinct weights for all 64 lanes; verify independent accumulation."""
    await init(dut)

    rng     = random.Random(0xDEAD_C0DE)
    weights = [rng.randint(-128, 127) for _ in range(LANES)]
    actv    = rng.randint(-128, 127)
    N       = 8

    dut.weight.value = pack_weights(weights)
    dut.actv.value   = u8(actv)
    dut.en.value     = 1
    await ticks(dut, N)

    check_all_lanes(
        dut,
        lambda lane: weights[lane] * actv * N,
        f"After {N} cycles (actv={actv})",
    )

    dut._log.info(f"test_random_weights_all_lanes: {LANES} lanes × {N} cycles  PASSED")
