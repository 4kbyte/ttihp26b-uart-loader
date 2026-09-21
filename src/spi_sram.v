/*
 * Copyright (c) 2026 Rom DuPlain (@4kbyte)
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

// Adapt byte memory requests to a 23LC512-compatible SPI SRAM.
module spi_sram #(
    parameter integer SPI_HALF_PERIOD_CLKS = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [15:0] req_addr,
    input  wire [7:0]  req_data,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [7:0]  rsp_data,
    output reg         rsp_fault,
    output reg         memory_ready,
    output reg  [2:0]  fault_class,
    output reg         spi_cs_n,
    output reg         spi_mosi,
    input  wire        spi_miso,
    output reg         spi_sck
);
  localparam [2:0] FAULT_NONE = 3'd0;
  localparam [2:0] FAULT_MODE = 3'd2;
  localparam [2:0] FAULT_INTERNAL = 3'd3;

  localparam [7:0] SPI_WRITE_MODE = 8'h01;
  localparam [7:0] SPI_WRITE = 8'h02;
  localparam [7:0] SPI_READ = 8'h03;
  localparam [7:0] SPI_READ_MODE = 8'h05;
  localparam [7:0] SPI_SEQUENTIAL_MODE = 8'h40;
  localparam [7:0] SPI_MODE_MASK = 8'hc0;

  localparam [2:0] INIT_WRMR = 3'd0;
  localparam [2:0] INIT_RDMR = 3'd1;
  localparam [2:0] IDLE = 3'd2;
  localparam [2:0] TRANSFER = 3'd3;
  localparam [2:0] RESPOND = 3'd4;
  localparam [2:0] FAILED = 3'd5;
  localparam [2:0] COMPLETE = 3'd6;
  localparam [2:0] RECOVER = 3'd7;

  localparam [1:0] TRANSFER_INIT_WRITE = 2'd0;
  localparam [1:0] TRANSFER_INIT_READ = 2'd1;
  localparam [1:0] TRANSFER_WRITE = 2'd2;
  localparam [1:0] TRANSFER_READ = 2'd3;
  localparam integer SPI_DIVIDER_WIDTH =
      SPI_HALF_PERIOD_CLKS <= 1 ? 1 : $clog2(SPI_HALF_PERIOD_CLKS);

  reg [2:0] state;
  reg [2:0] resume_state;
  reg [31:0] tx_shift;
  reg [31:0] rx_shift;
  reg [5:0] total_bits;
  reg [5:0] sampled_bits;
  reg [SPI_DIVIDER_WIDTH-1:0] divider;
  reg [1:0] transfer_kind;

  assign req_ready = ((state == IDLE) || (state == FAILED)) && !rsp_valid;

  // Begin one SPI transfer with chip select asserted.
  task automatic start_transfer;
    input [31:0] bits;
    input [5:0] count;
    input [1:0] kind;
    begin
      tx_shift <= bits;
      rx_shift <= 32'd0;
      total_bits <= count;
      sampled_bits <= 0;
      divider <= 0;
      transfer_kind <= kind;
      spi_cs_n <= 1'b0;
      spi_sck <= 1'b0;
      spi_mosi <= bits[count - 1'b1];
      state <= TRANSFER;
    end
  endtask

  // Advance from mode-register write to readback.
  task automatic finish_mode_write;
    begin
      resume_state <= INIT_RDMR;
      state <= RECOVER;
    end
  endtask

  // Accept or reject the mode-register readback.
  task automatic finish_mode_read;
    begin
      if ((rx_shift[7:0] & SPI_MODE_MASK) == SPI_SEQUENTIAL_MODE) begin
        fault_class <= FAULT_NONE;
        resume_state <= IDLE;
      end
      else begin
        memory_ready <= 1'b0;
        fault_class <= FAULT_MODE;
        resume_state <= FAILED;
      end
      state <= RECOVER;
    end
  endtask

  // Complete one memory transfer.
  task automatic finish_memory_transfer;
    begin
      rsp_fault <= 1'b0;
      rsp_data <= transfer_kind == TRANSFER_READ ? rx_shift[7:0] : 8'h00;
      resume_state <= RESPOND;
      state <= RECOVER;
    end
  endtask

  // Enter the persistent internal-failure state.
  task automatic fail_internal;
    begin
      memory_ready <= 1'b0;
      fault_class <= FAULT_INTERNAL;
      spi_cs_n <= 1'b1;
      spi_sck <= 1'b0;
      spi_mosi <= 1'b0;
      state <= FAILED;
    end
  endtask

  // Complete the current initialization or memory transfer.
  task automatic finish_transfer;
    begin
      spi_cs_n <= 1'b1;
      spi_mosi <= 1'b0;
      case (transfer_kind)
        TRANSFER_INIT_WRITE: finish_mode_write();
        TRANSFER_INIT_READ: finish_mode_read();
        TRANSFER_WRITE: finish_memory_transfer();
        TRANSFER_READ: finish_memory_transfer();
        default: fail_internal();
      endcase
    end
  endtask

  // Start mode-register initialization.
  task automatic start_mode_write;
    begin
      start_transfer({16'd0, SPI_WRITE_MODE, SPI_SEQUENTIAL_MODE}, 6'd16,
                     TRANSFER_INIT_WRITE);
    end
  endtask

  // Start mode-register verification.
  task automatic start_mode_read;
    begin
      start_transfer({16'd0, SPI_READ_MODE, 8'h00}, 6'd16, TRANSFER_INIT_READ);
    end
  endtask

  // Accept one memory request.
  task automatic accept_request;
    begin
      if (req_valid && req_ready) begin
        start_transfer(
            {req_write ? SPI_WRITE : SPI_READ, req_addr, req_write ? req_data : 8'h00},
            6'd32, req_write ? TRANSFER_WRITE : TRANSFER_READ);
      end
    end
  endtask

  // Drive the falling edge or complete the transfer.
  task automatic lower_spi_clock;
    begin
      spi_sck <= 1'b0;
      if (sampled_bits == total_bits) begin
        spi_mosi <= 1'b0;
        state <= COMPLETE;
      end
      else
        spi_mosi <= tx_shift[total_bits - sampled_bits - 1'b1];
    end
  endtask

  // Drive the next active SPI edge.
  task automatic toggle_spi_clock;
    begin
      divider <= 0;
      if (!spi_sck) begin
        spi_sck <= 1'b1;
        rx_shift <= {rx_shift[30:0], spi_miso};
        sampled_bits <= sampled_bits + 1'b1;
      end
      else
        lower_spi_clock();
    end
  endtask

  // Advance one SPI transfer clock.
  task automatic advance_transfer;
    begin
      if (divider != SPI_HALF_PERIOD_CLKS - 1)
        divider <= divider + 1'b1;
      else
        toggle_spi_clock();
    end
  endtask

  // Preserve the minimum chip-select deselect interval before another transfer.
  task automatic recover_transfer;
    begin
      if (resume_state == IDLE)
        memory_ready <= 1'b1;
      if (resume_state == RESPOND)
        rsp_valid <= 1'b1;
      state <= resume_state;
    end
  endtask

  // Release an accepted memory response.
  task automatic accept_response;
    begin
      if (rsp_valid && rsp_ready) begin
        rsp_valid <= 1'b0;
        state <= IDLE;
      end
    end
  endtask

  // Hold the interface failed and reject memory requests.
  task automatic hold_failed;
    begin
      spi_cs_n <= 1'b1;
      spi_sck <= 1'b0;
      spi_mosi <= 1'b0;
      if (req_valid && req_ready) begin
        rsp_valid <= 1'b1;
        rsp_fault <= 1'b1;
        rsp_data <= 8'h00;
      end
      if (rsp_valid && rsp_ready)
        rsp_valid <= 1'b0;
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state                 <= INIT_WRMR;
      resume_state          <= INIT_WRMR;
      tx_shift              <= 0;
      rx_shift              <= 0;
      total_bits            <= 0;
      sampled_bits          <= 0;
      divider               <= 0;
      transfer_kind         <= TRANSFER_INIT_WRITE;
      rsp_valid             <= 1'b0;
      rsp_data              <= 0;
      rsp_fault             <= 1'b0;
      memory_ready          <= 1'b0;
      fault_class           <= FAULT_NONE;
      spi_cs_n              <= 1'b1;
      spi_mosi              <= 1'b0;
      spi_sck               <= 1'b0;
    end
    else begin
      case (state)
        INIT_WRMR: start_mode_write();
        INIT_RDMR: start_mode_read();
        IDLE: accept_request();
        TRANSFER: advance_transfer();
        COMPLETE: finish_transfer();
        RECOVER: recover_transfer();
        RESPOND: accept_response();
        FAILED: hold_failed();
        default: fail_internal();
      endcase
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (SPI_HALF_PERIOD_CLKS < 2)
      $fatal(1, "SPI clock exceeds the 23LC512 20 MHz limit");
  end

  reg held_rsp;
  reg [7:0] held_data;
  reg held_fault;
  always @(posedge clk) begin
    if (!rst_n)
      held_rsp <= 1'b0;
    else begin
      if (held_rsp &&
          (!rsp_valid || rsp_data != held_data || rsp_fault != held_fault)) begin
        $fatal(1, "SPI response changed while stalled");
      end
      held_rsp <= rsp_valid && !rsp_ready;
      held_data <= rsp_data;
      held_fault <= rsp_fault;
      if (spi_cs_n && spi_sck)
        $fatal(1, "SPI clock high while chip select inactive");
    end
  end
`endif
endmodule

`default_nettype wire
