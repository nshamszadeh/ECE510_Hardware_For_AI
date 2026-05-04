"""
Cocotb testbench for weight_sram.sv

weight_sram is a synchronous SRAM with no reset:
  - Write port: wr_en=1 → mem[wr_addr] ← wr_data  (committed on next posedge)
  - Read port:  rd_en=1 → rd_data ← mem[rd_addr]   (output valid one cycle later)

Tests:
  1. Basic write-then-read (1-cycle write latency, 1-cycle read latency)
  2. Multiple independent addresses
  3. Registered read latency: switching rd_addr takes exactly 1 cycle to update rd_data
  4. wr_en gating: wr_en=0 does not overwrite existing contents
  5. rd_en gating: rd_data holds its value when rd_en=0
  6. Simultaneous read and write to different addresses
  7. Read-before-write: simultaneous same-address read/write returns old data
  8. Packed weight word: full 512-bit word of 64 INT8 weights survives write/read intact
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
import random

RD_WIDTH = 512    # default DUT parameter
DEPTH    = 262144
BYTES    = RD_WIDTH // 8   # 64 bytes per wide word


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_word(pattern_byte: int) -> int:
    """Fill a 512-bit word with a repeated byte pattern."""
    return int.from_bytes([pattern_byte & 0xFF] * BYTES, "little")


def pack_int8s(values: list[int]) -> int:
    """Pack a list of signed INT8 values into a wide word (index 0 at LSB)."""
    word = 0
    for i, v in enumerate(values):
        word |= (int(v) & 0xFF) << (i * 8)
    return word


def unpack_int8s(word: int, count: int) -> list[int]:
    """Unpack count signed INT8 values from a wide word (index 0 at LSB)."""
    out = []
    for i in range(count):
        raw = (word >> (i * 8)) & 0xFF
        out.append(raw - 256 if raw >= 128 else raw)
    return out


async def tick(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")   # let NBA region commit before reading


async def ticks(dut, n: int):
    await ClockCycles(dut.clk, n)
    await Timer(1, unit="ps")


async def init(dut):
    """Start clock and let the design settle (weight_sram has no reset)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.wr_en.value   = 0
    dut.wr_addr.value = 0
    dut.wr_data.value = 0
    dut.rd_en.value   = 0
    dut.rd_addr.value = 0
    await ticks(dut, 2)


async def do_write(dut, addr: int, data: int):
    """Drive a single-cycle write."""
    dut.wr_en.value   = 1
    dut.wr_addr.value = addr
    dut.wr_data.value = data
    await tick(dut)
    dut.wr_en.value   = 0


async def do_read(dut, addr: int) -> int:
    """Issue a read and return rd_data after its one-cycle latency."""
    dut.rd_en.value   = 1
    dut.rd_addr.value = addr
    await tick(dut)
    return int(dut.rd_data.value)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_write_then_read(dut):
    """Written data is returned after exactly one read-enable cycle."""
    await init(dut)

    DATA = make_word(0xAB)
    await do_write(dut, 0, DATA)
    got = await do_read(dut, 0)

    assert got == DATA, f"Expected {DATA:#x}, got {got:#x}"
    dut._log.info("test_write_then_read: PASSED")


@cocotb.test()
async def test_multiple_addresses(dut):
    """Each address stores its own data independently; read-back order doesn't matter."""
    await init(dut)

    NUM  = 8
    data = [make_word(0x10 + i) for i in range(NUM)]

    for addr, d in enumerate(data):
        await do_write(dut, addr, d)

    # Forward readback
    for addr, expected in enumerate(data):
        got = await do_read(dut, addr)
        assert got == expected, f"Fwd addr {addr}: expected {expected:#x}, got {got:#x}"

    # Reverse readback
    for addr, expected in reversed(list(enumerate(data))):
        got = await do_read(dut, addr)
        assert got == expected, f"Rev addr {addr}: expected {expected:#x}, got {got:#x}"

    dut._log.info("test_multiple_addresses: PASSED")


@cocotb.test()
async def test_registered_read_latency(dut):
    """Switching rd_addr takes exactly 1 cycle to update rd_data (registered output)."""
    await init(dut)

    DATA_0 = make_word(0xAA)
    DATA_1 = make_word(0xBB)
    await do_write(dut, 0, DATA_0)
    await do_write(dut, 1, DATA_1)

    # First read — latch addr 0
    dut.rd_en.value   = 1
    dut.rd_addr.value = 0
    await tick(dut)
    assert int(dut.rd_data.value) == DATA_0, "Read addr 0: expected DATA_0"

    # Switch address combinationally — rd_data must NOT change yet
    dut.rd_addr.value = 1
    assert int(dut.rd_data.value) == DATA_0, \
        "Before clock edge: rd_data should still hold DATA_0"

    # One cycle later — rd_data updates to DATA_1
    await tick(dut)
    assert int(dut.rd_data.value) == DATA_1, \
        "After addr switch: rd_data should now be DATA_1"

    dut.rd_en.value = 0
    dut._log.info("test_registered_read_latency: PASSED")


@cocotb.test()
async def test_write_enable_gating(dut):
    """wr_en=0 does not overwrite existing contents."""
    await init(dut)

    ORIG = make_word(0xCC)
    BAD  = make_word(0xDD)

    await do_write(dut, 5, ORIG)

    # Present bad data with wr_en=0 — must be a no-op
    dut.wr_en.value   = 0
    dut.wr_addr.value = 5
    dut.wr_data.value = BAD
    await tick(dut)

    got = await do_read(dut, 5)
    assert got == ORIG, f"wr_en=0 wrote! Expected {ORIG:#x}, got {got:#x}"
    dut._log.info("test_write_enable_gating: PASSED")


@cocotb.test()
async def test_read_enable_gating(dut):
    """rd_data holds its last valid value when rd_en=0."""
    await init(dut)

    DATA = make_word(0xEE)
    await do_write(dut, 3, DATA)

    # Latch a known value into rd_data
    held = await do_read(dut, 3)
    assert held == DATA

    # Deassert rd_en — rd_data must freeze
    dut.rd_en.value = 0
    for cycle in range(1, 5):
        await tick(dut)
        got = int(dut.rd_data.value)
        assert got == held, \
            f"Cycle {cycle}: rd_data changed to {got:#x} while rd_en=0 (held={held:#x})"

    dut._log.info("test_read_enable_gating: PASSED")


@cocotb.test()
async def test_simultaneous_read_write_different_addr(dut):
    """Write to address A while reading address B — both complete correctly."""
    await init(dut)

    DATA_B = make_word(0x11)
    DATA_A = make_word(0x22)

    # Pre-load addr 10
    await do_write(dut, 10, DATA_B)

    # Simultaneously write addr 20, read addr 10
    dut.wr_en.value   = 1
    dut.wr_addr.value = 20
    dut.wr_data.value = DATA_A
    dut.rd_en.value   = 1
    dut.rd_addr.value = 10
    await tick(dut)
    dut.wr_en.value   = 0

    # Read result for addr 10 is already latched
    assert int(dut.rd_data.value) == DATA_B, \
        f"Addr 10: expected {DATA_B:#x}, got {int(dut.rd_data.value):#x}"

    # Now read addr 20 to confirm the write landed
    got_a = await do_read(dut, 20)
    assert got_a == DATA_A, \
        f"Addr 20: expected {DATA_A:#x}, got {got_a:#x}"

    dut._log.info("test_simultaneous_read_write_different_addr: PASSED")


@cocotb.test()
async def test_read_before_write_same_addr(dut):
    """Simultaneous read and write to the same address returns the old (pre-write) data.

    Both always_ff blocks evaluate mem[addr] in the active region before any
    non-blocking assignment updates take effect, so rd_data captures the old value.
    """
    await init(dut)

    OLD = make_word(0x33)
    NEW = make_word(0x44)

    await do_write(dut, 7, OLD)

    # Simultaneously read and write addr 7
    dut.wr_en.value   = 1
    dut.wr_addr.value = 7
    dut.wr_data.value = NEW
    dut.rd_en.value   = 1
    dut.rd_addr.value = 7
    await tick(dut)
    dut.wr_en.value   = 0

    assert int(dut.rd_data.value) == OLD, (
        f"Read-before-write: expected old data {OLD:#x}, "
        f"got {int(dut.rd_data.value):#x}"
    )

    # Subsequent read must return the newly written value
    got_new = await do_read(dut, 7)
    assert got_new == NEW, f"Post-write: expected {NEW:#x}, got {got_new:#x}"

    dut._log.info("test_read_before_write_same_addr: PASSED")


@cocotb.test()
async def test_packed_weight_word(dut):
    """Full 512-bit word of 64 INT8 weights survives a write/read cycle intact,
    and each weight can be unpacked from the correct bit position."""
    await init(dut)

    rng     = random.Random(0x0ECE_0510)
    weights = [rng.randint(-128, 127) for _ in range(64)]
    word    = pack_int8s(weights)

    await do_write(dut, 42, word)
    got_word = await do_read(dut, 42)

    assert got_word == word, f"Wide-word mismatch:\n  wrote {word:#x}\n  read  {got_word:#x}"

    got_weights = unpack_int8s(got_word, 64)
    mismatches  = [
        f"  weight[{i}]: expected {weights[i]}, got {got_weights[i]}"
        for i in range(64) if got_weights[i] != weights[i]
    ]
    assert not mismatches, "Per-weight mismatches:\n" + "\n".join(mismatches)

    dut._log.info("test_packed_weight_word: 64 INT8 weights packed/unpacked correctly  PASSED")
