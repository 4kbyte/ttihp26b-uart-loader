/*
 * Copyright (c) 2026 Rom DuPlain (@4kbyte)
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

// Receive 8N1 UART bytes into a four-byte FIFO.
module uart_rx #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output wire       out_valid,
    input  wire       out_ready,
    output wire [7:0] out_data,
    output wire [2:0] level,
    output reg        framing_error,
    output reg        overrun
);
  localparam integer CLKS_PER_BIT = (CLOCK_HZ + BAUD / 2) / BAUD;
  localparam integer HALF_BIT = CLKS_PER_BIT / 2;
  localparam [15:0] CLKS_PER_BIT_COUNT = 16'(CLKS_PER_BIT);
  localparam [15:0] HALF_BIT_COUNT = 16'(HALF_BIT);
  localparam [2:0] FIFO_DEPTH = 3'd4;
  localparam [1:0] RX_IDLE = 2'd0;
  localparam [1:0] RX_START = 2'd1;
  localparam [1:0] RX_DATA = 2'd2;
  localparam [1:0] RX_STOP = 2'd3;

  reg [1:0] rx_state;
  reg [15:0] bit_timer;
  reg [2:0] bit_index;
  reg [7:0] rx_shift;
  reg rx_meta;
  reg rx_sync;

  reg [7:0] fifo_data [0:3];
  reg [2:0] count;
  reg [1:0] read_ptr;
  reg [1:0] write_ptr;

  wire pop = out_valid && out_ready;
  assign out_valid = (count != 0);
  assign out_data = fifo_data[read_ptr];
  assign level = count;

  // Queue one received byte or record an overrun.
  task automatic enqueue;
    input [7:0] byte_value;
    begin
      if ((count < FIFO_DEPTH) || pop) begin
        fifo_data[write_ptr] <= byte_value;
        write_ptr <= write_ptr + 1'b1;
        count <= pop ? count : count + 1'b1;
      end
      else
        overrun <= 1'b1;
    end
  endtask

  // Detect the start of a frame.
  task automatic receive_idle;
    begin
      if (!rx_sync) begin
        bit_timer <= HALF_BIT_COUNT;
        rx_state <= RX_START;
      end
    end
  endtask

  // Validate the start bit after half a bit period.
  task automatic receive_start;
    begin
      if (bit_timer != 0)
        bit_timer <= bit_timer - 1'b1;
      else if (rx_sync)
        rx_state <= RX_IDLE;
      else begin
        bit_timer <= CLKS_PER_BIT_COUNT - 16'd1;
        bit_index <= 0;
        rx_state <= RX_DATA;
      end
    end
  endtask

  // Sample the current data bit and select the next state.
  task automatic sample_data_bit;
    begin
      rx_shift[bit_index] <= rx_sync;
      bit_timer <= CLKS_PER_BIT_COUNT - 16'd1;
      if (bit_index == 7)
        rx_state <= RX_STOP;
      else
        bit_index <= bit_index + 1'b1;
    end
  endtask

  // Wait for and sample one data bit.
  task automatic receive_data;
    begin
      if (bit_timer != 0)
        bit_timer <= bit_timer - 1'b1;
      else
        sample_data_bit();
    end
  endtask

  // Accept a valid stop bit or record a framing error.
  task automatic sample_stop_bit;
    begin
      if (rx_sync)
        enqueue(rx_shift);
      else
        framing_error <= 1'b1;
      rx_state <= RX_IDLE;
    end
  endtask

  // Wait for and sample the stop bit.
  task automatic receive_stop;
    begin
      if (bit_timer != 0)
        bit_timer <= bit_timer - 1'b1;
      else
        sample_stop_bit();
    end
  endtask

  // Recover from an invalid receiver state.
  task automatic restart_receiver;
    begin
      rx_state <= RX_IDLE;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_meta <= 1'b1;
      rx_sync <= 1'b1;
    end
    else begin
      rx_meta <= rx;
      rx_sync <= rx_meta;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state      <= RX_IDLE;
      bit_timer     <= 0;
      bit_index     <= 0;
      rx_shift      <= 0;
      count         <= 0;
      read_ptr      <= 0;
      write_ptr     <= 0;
      framing_error <= 1'b0;
      overrun       <= 1'b0;
    end
    else begin
      if (pop) begin
        read_ptr <= read_ptr + 1'b1;
        count <= count - 1'b1;
      end

      case (rx_state)
        RX_IDLE: receive_idle();
        RX_START: receive_start();
        RX_DATA: receive_data();
        RX_STOP: receive_stop();
        default: restart_receiver();
      endcase
    end
  end

`ifndef SYNTHESIS
  reg held_output;
  reg [7:0] held_data;
  always @(posedge clk) begin
    if (!rst_n)
      held_output <= 1'b0;
    else begin
      if (held_output && (!out_valid || out_data != held_data))
        $fatal(1, "UART RX output changed while stalled");
      held_output <= out_valid && !out_ready;
      held_data <= out_data;
    end
  end
`endif
endmodule

// Transmit one 8N1 UART byte at a time.
module uart_tx #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       in_valid,
    output wire       in_ready,
    input  wire [7:0] in_data,
    output reg        tx
);
  localparam integer CLKS_PER_BIT = (CLOCK_HZ + BAUD / 2) / BAUD;
  localparam [15:0] CLKS_PER_BIT_COUNT = 16'(CLKS_PER_BIT);
  reg busy;
  reg [9:0] frame;
  reg [3:0] bit_index;
  reg [15:0] bit_timer;

  assign in_ready = !busy;

  // Start transmitting one framed byte.
  task automatic start_transmit;
    begin
      frame <= {1'b1, in_data, 1'b0};
      tx <= 1'b0;
      bit_index <= 0;
      bit_timer <= CLKS_PER_BIT_COUNT - 16'd1;
      busy <= 1'b1;
    end
  endtask

  // Advance the active frame by one clock.
  task automatic advance_transmit;
    begin
      if (bit_timer != 0)
        bit_timer <= bit_timer - 1'b1;
      else if (bit_index == 9) begin
        tx <= 1'b1;
        busy <= 1'b0;
      end
      else begin
        bit_index <= bit_index + 1'b1;
        tx <= frame[bit_index + 1'b1];
        bit_timer <= CLKS_PER_BIT_COUNT - 16'd1;
      end
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0;
      frame <= 10'h3ff;
      bit_index <= 0;
      bit_timer <= 0;
      tx <= 1'b1;
    end
    else begin
      if (in_valid && in_ready)
        start_transmit();
      else if (busy)
        advance_transmit();
    end
  end
endmodule

`default_nettype wire
