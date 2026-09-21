/*
 * Copyright (c) 2026 Rom DuPlain (@4kbyte)
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

// Connect the UART loader to TinyTapeout pins and external SPI SRAM.
module tt_um_romd_uart_loader #(
    parameter integer UART_CLOCK_HZ = 50000000,
    parameter integer UART_BAUD = 115200,
    parameter integer MAX_TRANSFER_BYTES = 16
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
  wire uart_rx_valid;
  wire uart_rx_ready;
  wire [7:0] uart_rx_data;
  wire [2:0] uart_rx_level;
  wire uart_framing_error;
  wire uart_overrun;
  wire uart_tx_valid;
  wire uart_tx_ready;
  wire [7:0] uart_tx_data;
  wire uart_tx;
  wire mem_req_valid;
  wire mem_req_ready;
  wire mem_req_write;
  wire [15:0] mem_req_addr;
  wire [7:0] mem_req_data;
  wire mem_rsp_valid;
  wire mem_rsp_ready;
  wire [7:0] mem_rsp_data;
  wire mem_rsp_fault;
  wire memory_ready;
  wire [2:0] memory_fault_class;
  wire spi_cs_n;
  wire spi_mosi;
  wire spi_sck;
  wire protocol_error;
  reg memory_transaction_active;

  uart_rx #(
      .CLOCK_HZ(UART_CLOCK_HZ),
      .BAUD(UART_BAUD)
  ) uart_rx (
      .clk(clk),
      .rst_n(rst_n),
      .rx(ui_in[3]),
      .out_valid(uart_rx_valid),
      .out_ready(uart_rx_ready),
      .out_data(uart_rx_data),
      .level(uart_rx_level),
      .framing_error(uart_framing_error),
      .overrun(uart_overrun)
  );

  uart_tx #(
      .CLOCK_HZ(UART_CLOCK_HZ),
      .BAUD(UART_BAUD)
  ) uart_tx_block (
      .clk(clk),
      .rst_n(rst_n),
      .in_valid(uart_tx_valid),
      .in_ready(uart_tx_ready),
      .in_data(uart_tx_data),
      .tx(uart_tx)
  );

  uart_loader #(
      .MAX_TRANSFER_BYTES(MAX_TRANSFER_BYTES)
  ) loader (
      .clk(clk),
      .rst_n(rst_n),
      .rx_valid(uart_rx_valid),
      .rx_ready(uart_rx_ready),
      .rx_data(uart_rx_data),
      .tx_valid(uart_tx_valid),
      .tx_ready(uart_tx_ready),
      .tx_data(uart_tx_data),
      .mem_req_valid(mem_req_valid),
      .mem_req_ready(mem_req_ready),
      .mem_req_write(mem_req_write),
      .mem_req_addr(mem_req_addr),
      .mem_req_data(mem_req_data),
      .mem_rsp_valid(mem_rsp_valid),
      .mem_rsp_ready(mem_rsp_ready),
      .mem_rsp_data(mem_rsp_data),
      .mem_rsp_fault(mem_rsp_fault),
      .memory_ready(memory_ready),
      .memory_fault_class(memory_fault_class),
      .protocol_error(protocol_error)
  );

  spi_sram spi_memory (
      .clk(clk),
      .rst_n(rst_n),
      .req_valid(mem_req_valid),
      .req_ready(mem_req_ready),
      .req_write(mem_req_write),
      .req_addr(mem_req_addr),
      .req_data(mem_req_data),
      .rsp_valid(mem_rsp_valid),
      .rsp_ready(mem_rsp_ready),
      .rsp_data(mem_rsp_data),
      .rsp_fault(mem_rsp_fault),
      .memory_ready(memory_ready),
      .fault_class(memory_fault_class),
      .spi_cs_n(spi_cs_n),
      .spi_mosi(spi_mosi),
      .spi_miso(uio_in[2]),
      .spi_sck(spi_sck)
  );

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      memory_transaction_active <= 1'b0;
    else if (mem_req_valid && mem_req_ready)
      memory_transaction_active <= 1'b1;
    else if (mem_rsp_valid && mem_rsp_ready)
      memory_transaction_active <= 1'b0;
  end

  assign uo_out = rst_n ?
      {memory_fault_class != 0, protocol_error, uart_overrun,
       uart_rx_level < 4, uart_tx, uart_framing_error,
       memory_transaction_active, memory_ready} :
      8'b0001_0000;
  assign uio_out = {4'b0000, spi_sck, 1'b0, spi_mosi, spi_cs_n};
  assign uio_oe = 8'b0000_1011;

  wire _unused = &{ena, ui_in[7:4], ui_in[2:0], uio_in[7:4],
                   uio_in[3], uio_in[1:0], 1'b0};
endmodule

`default_nettype wire
