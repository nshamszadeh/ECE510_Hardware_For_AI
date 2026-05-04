"""
Cocotb testbench for leaky_relu.sv

Verifies:
  - Positive inputs pass through unchanged
  - Negative inputs are scaled by floor(x * 205 / 1024) ≈ 0.2·x
  - All 64 lanes operate independently
  - Output magnitude never exceeds input magnitude for negative inputs
"""

import cocotb
from cocotb.triggers import Timer
import random

# Match default DUT parameters
LANES = 64
AW    = 32
ALPHA_MULT  = 205
ALPHA_SHIFT = 10


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def pack_lanes(values: list[int]) -> int:
    """Pack a list of signed AW-bit integers into one flat unsigned int.

    Lane 0 occupies bits [AW-1:0], lane 1 bits [2·AW-1:AW], etc.
    """
    mask   = (1 << AW) - 1
    result = 0
    for i, v in enumerate(values):
        result |= (int(v) & mask) << (i * AW)
    return result


def unpack_lane(flat_val: int, lane: int) -> int:
    """Extract signed AW-bit integer from lane of flat packed value."""
    mask = (1 << AW) - 1
    v    = (int(flat_val) >> (lane * AW)) & mask
    if v >= (1 << (AW - 1)):
        v -= (1 << AW)
    return v


def expected_relu(x: int) -> int:
    """Reference LeakyReLU using exact integer arithmetic.

    Positive: pass through.
    Negative: floor(x * ALPHA_MULT / 2**ALPHA_SHIFT).
    Python's >> on negative integers is arithmetic (floor division), so
    (x * ALPHA_MULT) >> ALPHA_SHIFT matches the hardware behaviour exactly.
    """
    return x if x >= 0 else (x * ALPHA_MULT) >> ALPHA_SHIFT


# Sanity-check the reference against known values before any DUT interaction
_KNOWN = [
    (0,            0),
    (100,        100),
    (-1,          -1),     # -205 >> 10 = floor(-0.2002) = -1
    (-5,          -2),     # -1025 >> 10 = floor(-1.001) = -2
    (-100,       -21),     # -20500 >> 10 = floor(-20.020) = -21
    (-128,       -26),     # -26240 >> 10 = floor(-25.625) = -26
    (-1000,     -201),     # -205000 >> 10 = floor(-200.195) = -201
    (-198246912, -39688103),
]
for _x, _exp in _KNOWN:
    _got = expected_relu(_x)
    assert _got == _exp, f"Reference self-check failed: in={_x}, got={_got}, want={_exp}"


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_positive_passthrough(dut):
    """Positive inputs (including zero) must pass through unchanged."""
    test_values = [0, 1, 100, 127, 1000, 10_000_000, 2_147_483_647]

    for v in test_values:
        vals = [v] + [0] * (LANES - 1)
        dut.in_data.value = pack_lanes(vals)
        await Timer(1, unit="ns")

        got = unpack_lane(dut.out_data.value, 0)
        assert got == v, f"Positive passthrough: in={v}, expected={v}, got={got}"

    dut._log.info(f"test_positive_passthrough: {len(test_values)} values — PASSED")


@cocotb.test()
async def test_negative_scaling(dut):
    """Negative inputs must be scaled by ~0.2 (205/1024) via arithmetic right-shift."""
    test_cases = [
        (-1,           expected_relu(-1)),
        (-5,           expected_relu(-5)),
        (-100,         expected_relu(-100)),
        (-128,         expected_relu(-128)),
        (-1000,        expected_relu(-1000)),
        (-100_000,     expected_relu(-100_000)),
        (-198_246_912, expected_relu(-198_246_912)),  # max encoder accumulator
        (-2_147_483_648, expected_relu(-2_147_483_648)),  # INT32_MIN
    ]

    for inp, expected in test_cases:
        vals = [inp] + [0] * (LANES - 1)
        dut.in_data.value = pack_lanes(vals)
        await Timer(1, unit="ns")

        got = unpack_lane(dut.out_data.value, 0)
        assert got == expected, (
            f"Negative scaling: in={inp}, expected={expected}, got={got}"
        )
        dut._log.info(f"  in={inp:>14d}  →  {got:>14d}  (ref {expected:>14d})")

    dut._log.info("test_negative_scaling: PASSED")


@cocotb.test()
async def test_all_lanes_independent(dut):
    """All 64 lanes must produce the correct output simultaneously with no cross-talk."""
    rng = random.Random(0xCAFE_BABE)
    inputs = [rng.randint(-(2**31), 2**31 - 1) for _ in range(LANES)]

    dut.in_data.value = pack_lanes(inputs)
    await Timer(1, unit="ns")

    mismatches = []
    for lane in range(LANES):
        got = unpack_lane(dut.out_data.value, lane)
        exp = expected_relu(inputs[lane])
        if got != exp:
            mismatches.append(f"  Lane {lane:2d}: in={inputs[lane]}, expected={exp}, got={got}")

    assert not mismatches, "Lane independence failures:\n" + "\n".join(mismatches)
    dut._log.info(f"test_all_lanes_independent: all {LANES} lanes — PASSED")


@cocotb.test()
async def test_output_magnitude_bounded(dut):
    """For any negative input, |out| must be strictly less than |in|
    (since α < 1, scaling always shrinks the magnitude)."""
    rng = random.Random(0xDEAD_BEEF)
    failures = []

    for _ in range(500):
        v    = rng.randint(-(2**31), -1)
        vals = [v] + [0] * (LANES - 1)
        dut.in_data.value = pack_lanes(vals)
        await Timer(1, unit="ns")

        got = unpack_lane(dut.out_data.value, 0)
        if abs(got) > abs(v):
            failures.append(f"  in={v}, out={got}: |out| > |in|")

    assert not failures, "Magnitude bound violated:\n" + "\n".join(failures)
    dut._log.info("test_output_magnitude_bounded: 500 random negatives — PASSED")
