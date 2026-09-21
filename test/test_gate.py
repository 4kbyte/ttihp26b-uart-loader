# Copyright (c) 2026 Rom DuPlain (@4kbyte)
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import (
    ClockCycles,
    FallingEdge,
    RisingEdge,
    Timer,
    with_timeout,
)

CLOCK_PERIOD_NS = 20
SPI_MISO = 2


async def spi_transaction(dut, response):
    await FallingEdge(dut.spi_cs_n)
    transmitted = 0
    for bit_index in range(16):
        response_bit = (response >> (15 - bit_index)) & 1
        dut.uio_in.value = response_bit << SPI_MISO
        await RisingEdge(dut.spi_sck)
        transmitted = (transmitted << 1) | int(dut.spi_mosi.value)
    await RisingEdge(dut.spi_cs_n)
    return transmitted


@cocotb.test()
async def test_hardened_wrapper_and_sram_initialization(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1 << 3
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 8)
    await Timer(1, unit="ns")
    assert int(dut.uo_out.value) == 0x10
    assert int(dut.uio_out.value) == 0x01
    assert int(dut.uio_oe.value) == 0x0B

    dut.rst_n.value = 1
    mode_write = await with_timeout(spi_transaction(dut, 0), 100, "us")
    mode_read = await with_timeout(spi_transaction(dut, 0x0040), 100, "us")

    assert mode_write == 0x0140
    assert mode_read >> 8 == 0x05

    await ClockCycles(dut.clk, 4)
    await Timer(1, unit="ns")
    assert int(dut.uo_out.value) == 0x19
    assert int(dut.uio_out.value) == 0x01
    assert int(dut.uio_oe.value) == 0x0B
