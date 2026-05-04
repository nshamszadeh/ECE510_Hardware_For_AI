"""
Cocotb testbench for actv_buf.sv

actv_buf is an 8-bit dual-port synchronous RAM with a synchronous active-low
reset.  Reset zeroes rd_data but does NOT clear the memory array (the FSM is
responsible for writing every channel before first use).

Tests:
  1.  Basic write-then-read (1-cycle read latency)
  2.  Reset zeroes rd_data, not the memory array
  3.  Reset during an active read: rd_data becomes 0 even with rd_en=1
  4.  Write succeeds during reset (wr path has no rst_n gate)
  5.  Multiple independent addresses
  6.  wr_en gating: wr_en=0 does not overwrite
  7.  rd_en gating: rd_data holds when rd_en=0
  8.  Simultaneous read/write to different addresses
  9.  Read-before-write: same-address collision returns old data
  10. Dilated circular-buffer access (simulates layer_control_fsm addressing)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

WIDTH    = 8
DEPTH    = 98304
BUF_HIST = 64     # history slots per channel (matches compute_core localparam)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def u8(v: int) -> int:
    """Signed Python int → unsigned 8-bit two's complement."""
    return int(v) & 0xFF


def s8(v) -> int:
    """Raw cocotb value → signed 8-bit Python int."""
    raw = int(v) & 0xFF
    return raw - 256 if raw >= 128 else raw


async def tick(dut):
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


async def ticks(dut, n: int):
    await ClockCycles(dut.clk, n)
    await Timer(1, unit="ps")


async def init(dut):
    """Start clock and apply a two-cycle synchronous reset."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value   = 0
    dut.wr_en.value   = 0
    dut.wr_addr.value = 0
    dut.wr_data.value = 0
    dut.rd_en.value   = 0
    dut.rd_addr.value = 0
    await ticks(dut, 2)
    dut.rst_n.value   = 1
    await ticks(dut, 1)


async def do_write(dut, addr: int, data: int):
    dut.wr_en.value   = 1
    dut.wr_addr.value = addr
    dut.wr_data.value = u8(data)
    await tick(dut)
    dut.wr_en.value   = 0


async def do_read(dut, addr: int) -> int:
    dut.rd_en.value   = 1
    dut.rd_addr.value = addr
    await tick(dut)
    return s8(dut.rd_data.value)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_write_then_read(dut):
    """Written INT8 data is returned after exactly one read-enable cycle."""
    await init(dut)

    for value in [0, 1, -1, 127, -128, 42, -42]:
        await do_write(dut, 0, value)
        got = await do_read(dut, 0)
        assert got == value, f"Value {value}: expected {value}, got {got}"

    dut._log.info("test_write_then_read: PASSED")


@cocotb.test()
async def test_reset_zeroes_rd_data_not_mem(dut):
    """Reset clears rd_data to 0 but leaves the memory array intact.

    The write path is not gated by rst_n, so a post-reset read of a
    previously-written address returns the written value, not zero.
    """
    await init(dut)

    await do_write(dut, 10, 99)

    # Latch the value into rd_data
    got = await do_read(dut, 10)
    assert got == 99, f"Pre-reset read: expected 99, got {got}"

    # Apply reset — rd_data must go to 0
    dut.rst_n.value = 0
    await ticks(dut, 1)
    assert s8(dut.rd_data.value) == 0, \
        f"During reset: rd_data should be 0, got {s8(dut.rd_data.value)}"

    # Release reset and read addr 10 — mem[10] still holds 99
    dut.rst_n.value = 1
    got_after = await do_read(dut, 10)
    assert got_after == 99, \
        f"Post-reset: mem[10] should still be 99, got {got_after}"

    dut._log.info("test_reset_zeroes_rd_data_not_mem: PASSED")


@cocotb.test()
async def test_reset_during_active_read(dut):
    """Assert rst_n=0 while rd_en=1: reset takes priority, rd_data becomes 0."""
    await init(dut)

    await do_write(dut, 5, 77)

    # Latch 77 into rd_data
    await do_read(dut, 5)
    assert s8(dut.rd_data.value) == 77

    # Assert reset and rd_en simultaneously
    dut.rst_n.value   = 0
    dut.rd_en.value   = 1
    dut.rd_addr.value = 5
    await ticks(dut, 1)
    assert s8(dut.rd_data.value) == 0, \
        f"Reset + rd_en: expected 0, got {s8(dut.rd_data.value)}"

    dut.rst_n.value = 1
    dut.rd_en.value = 0
    dut._log.info("test_reset_during_active_read: PASSED")


@cocotb.test()
async def test_write_succeeds_during_reset(dut):
    """wr_en is not gated by rst_n; writes committed during reset survive."""
    await init(dut)

    # Write while reset is asserted
    dut.rst_n.value   = 0
    dut.wr_en.value   = 1
    dut.wr_addr.value = 20
    dut.wr_data.value = u8(55)
    await ticks(dut, 1)
    dut.wr_en.value   = 0
    dut.rst_n.value   = 1

    # Read back after reset is released
    got = await do_read(dut, 20)
    assert got == 55, f"Post-reset-write: expected 55, got {got}"

    dut._log.info("test_write_succeeds_during_reset: PASSED")


@cocotb.test()
async def test_multiple_addresses(dut):
    """Each address stores its own INT8 value independently."""
    await init(dut)

    pairs = [(i, i - 64) for i in range(16)]   # addresses 0..15, values -64..-49

    for addr, val in pairs:
        await do_write(dut, addr, val)

    for addr, expected in pairs:
        got = await do_read(dut, addr)
        assert got == expected, f"Addr {addr}: expected {expected}, got {got}"

    # Reverse order
    for addr, expected in reversed(pairs):
        got = await do_read(dut, addr)
        assert got == expected, f"Addr {addr} (rev): expected {expected}, got {got}"

    dut._log.info("test_multiple_addresses: PASSED")


@cocotb.test()
async def test_write_enable_gating(dut):
    """wr_en=0 does not overwrite existing data."""
    await init(dut)

    await do_write(dut, 7, 33)

    dut.wr_en.value   = 0
    dut.wr_addr.value = 7
    dut.wr_data.value = u8(-99)
    await tick(dut)

    got = await do_read(dut, 7)
    assert got == 33, f"wr_en=0 wrote! Expected 33, got {got}"

    dut._log.info("test_write_enable_gating: PASSED")


@cocotb.test()
async def test_read_enable_gating(dut):
    """rd_data holds its last valid value when rd_en=0."""
    await init(dut)

    await do_write(dut, 4, -17)
    held = await do_read(dut, 4)
    assert held == -17

    dut.rd_en.value = 0
    for cycle in range(1, 5):
        await tick(dut)
        got = s8(dut.rd_data.value)
        assert got == held, \
            f"Cycle {cycle}: rd_data changed to {got} while rd_en=0 (held={held})"

    dut._log.info("test_read_enable_gating: PASSED")


@cocotb.test()
async def test_simultaneous_read_write_different_addr(dut):
    """Write to address A while reading address B — both complete correctly."""
    await init(dut)

    await do_write(dut, 30, 88)    # pre-load addr 30

    dut.wr_en.value   = 1
    dut.wr_addr.value = 50
    dut.wr_data.value = u8(-44)
    dut.rd_en.value   = 1
    dut.rd_addr.value = 30
    await tick(dut)
    dut.wr_en.value   = 0

    assert s8(dut.rd_data.value) == 88, \
        f"Read addr 30: expected 88, got {s8(dut.rd_data.value)}"

    got_50 = await do_read(dut, 50)
    assert got_50 == -44, f"Read addr 50: expected -44, got {got_50}"

    dut._log.info("test_simultaneous_read_write_different_addr: PASSED")


@cocotb.test()
async def test_read_before_write_same_addr(dut):
    """Simultaneous read and write to the same address returns old (pre-write) data."""
    await init(dut)

    await do_write(dut, 15, 11)

    dut.wr_en.value   = 1
    dut.wr_addr.value = 15
    dut.wr_data.value = u8(22)
    dut.rd_en.value   = 1
    dut.rd_addr.value = 15
    await tick(dut)
    dut.wr_en.value   = 0

    assert s8(dut.rd_data.value) == 11, \
        f"Read-before-write: expected old value 11, got {s8(dut.rd_data.value)}"

    got_new = await do_read(dut, 15)
    assert got_new == 22, f"Post-write: expected 22, got {got_new}"

    dut._log.info("test_read_before_write_same_addr: PASSED")


@cocotb.test()
async def test_dilated_circular_buffer_access(dut):
    """Simulate the dilated Conv1d addressing that layer_control_fsm generates.

    For channel c, address = c * BUF_HIST + (head - k*D) % BUF_HIST.
    We test dilation D in {1, 3, 9} with K=3 for a single channel (c=0).
    """
    await init(dut)

    # Fill the circular buffer for channel 0 (addresses 0..BUF_HIST-1)
    # value[t] = t so we can verify the correct time step is read back
    for t in range(BUF_HIST):
        await do_write(dut, t, t)

    head = 40   # current write position

    for dilation in (1, 3, 9):
        taps_read = []
        for k in range(3):   # K=3 kernel
            tap_addr = (head - k * dilation) % BUF_HIST
            got = await do_read(dut, tap_addr)
            taps_read.append(got)
            expected = tap_addr    # value[addr] == addr because we wrote t→t
            assert got == expected, (
                f"D={dilation} k={k}: addr={tap_addr}, expected {expected}, got {got}"
            )
        dut._log.info(
            f"  D={dilation}: taps at head={head} → "
            f"addrs {[(head - k*dilation) % BUF_HIST for k in range(3)]} "
            f"→ values {taps_read}"
        )

    dut._log.info("test_dilated_circular_buffer_access: PASSED")
