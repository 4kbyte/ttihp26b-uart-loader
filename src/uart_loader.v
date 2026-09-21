/*
 * Copyright (c) 2026 Rom DuPlain (@4kbyte)
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none
`timescale 1ns / 1ps

// Translate framed UART commands into bounded memory transactions.
module uart_loader #(
    parameter integer MAX_TRANSFER_BYTES = 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx_valid,
    output wire        rx_ready,
    input  wire [7:0]  rx_data,
    output wire        tx_valid,
    input  wire        tx_ready,
    output wire [7:0]  tx_data,
    output reg         mem_req_valid,
    input  wire        mem_req_ready,
    output reg         mem_req_write,
    output reg  [15:0] mem_req_addr,
    output reg  [7:0]  mem_req_data,
    input  wire        mem_rsp_valid,
    output reg         mem_rsp_ready,
    input  wire [7:0]  mem_rsp_data,
    input  wire        mem_rsp_fault,
    input  wire        memory_ready,
    input  wire [2:0]  memory_fault_class,
    output reg         protocol_error
);
  localparam [7:0] PROTOCOL_VERSION = 8'd1;
  localparam [16:0] MEMORY_BYTES = 17'd65536;
  localparam integer MAX_PAYLOAD_BYTES = 3 + MAX_TRANSFER_BYTES;
  localparam integer MAX_RESPONSE_BYTES =
      MAX_TRANSFER_BYTES < 6 ? 17 : 11 + MAX_TRANSFER_BYTES;

  localparam [7:0] PING = 8'h00;
  localparam [7:0] CAPABILITIES = 8'h01;
  localparam [7:0] WRITE = 8'h11;
  localparam [7:0] READ = 8'h12;
  localparam [7:0] STATUS = 8'h14;

  localparam [7:0] OK = 8'h00;
  localparam [7:0] BAD_VERSION = 8'h01;
  localparam [7:0] BAD_OPCODE = 8'h02;
  localparam [7:0] BAD_LENGTH = 8'h03;
  localparam [7:0] BAD_CRC = 8'h04;
  localparam [7:0] BAD_ADDRESS = 8'h06;
  localparam [7:0] MEMORY_FAULT = 8'h07;

  localparam [3:0] PS_SYNC0 = 4'd0;
  localparam [3:0] PS_SYNC1 = 4'd1;
  localparam [3:0] PS_VERSION = 4'd2;
  localparam [3:0] PS_OPCODE = 4'd3;
  localparam [3:0] PS_SEQUENCE = 4'd4;
  localparam [3:0] PS_LEN_LO = 4'd5;
  localparam [3:0] PS_LEN_HI = 4'd6;
  localparam [3:0] PS_PAYLOAD = 4'd7;
  localparam [3:0] PS_CRC_LO = 4'd8;
  localparam [3:0] PS_CRC_HI = 4'd9;

  localparam [1:0] CMD_IDLE = 2'd0;
  localparam [1:0] CMD_MEM_REQUEST = 2'd1;
  localparam [1:0] CMD_MEM_RESPONSE = 2'd2;

  localparam [1:0] RESPONSE_IDLE = 2'd0;
  localparam [1:0] RESPONSE_CRC = 2'd1;
  localparam [1:0] RESPONSE_TX = 2'd2;

  reg [3:0] parser_state;
  reg [1:0] command_state;
  reg [1:0] response_state;
  reg [7:0] request_version;
  reg [7:0] request_opcode;
  reg [7:0] request_sequence;
  reg [15:0] request_length;
  reg [8:0] payload_index;
  reg [7:0] payload [0:MAX_PAYLOAD_BYTES-1];
  reg [15:0] request_crc;
  reg [7:0] request_crc_low;
  reg [8:0] response_length;
  reg [8:0] response_index;
  reg [8:0] response_data_length;
  reg [8:0] response_crc_index;
  reg [15:0] response_crc_value;
  reg [7:0] response [0:MAX_RESPONSE_BYTES-1];
  reg [15:0] operation_start;
  reg [7:0] operation_data;
  reg [7:0] operation_count;
  reg [7:0] operation_progress;

  assign rx_ready = command_state == CMD_IDLE && response_state == RESPONSE_IDLE;
  assign tx_valid = response_state == RESPONSE_TX;
  assign tx_data = response[response_index];
  wire [15:0] response_crc_next = crc_byte(
      response_crc_value, response[response_crc_index]
  );

  // Update CRC-16/CCITT-FALSE with one byte.
  function automatic [15:0] crc_byte;
    input [15:0] crc;
    input [7:0] data;
    integer bit_number;
    reg [15:0] value;
    begin
      value = crc ^ {data, 8'h00};
      for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
        value = value[15] ? (value << 1) ^ 16'h1021 : value << 1;
      end
      crc_byte = value;
    end
  endfunction

  // Validate the active WRITE request.
  function automatic [7:0] write_validation_status;
    reg [16:0] range_end;
    begin
      range_end = {1'b0, payload[1], payload[0]} + {9'd0, payload[2]};
      if (request_length < 3 || payload[2] > MAX_TRANSFER_BYTES ||
          request_length != 16'd3 + {8'd0, payload[2]}) begin
        write_validation_status = BAD_LENGTH;
      end
      else if (range_end > MEMORY_BYTES)
        write_validation_status = BAD_ADDRESS;
      else
        write_validation_status = OK;
    end
  endfunction

  // Validate the active READ request.
  function automatic [7:0] read_validation_status;
    reg [16:0] range_end;
    begin
      range_end = {1'b0, payload[1], payload[0]} + {9'd0, payload[2]};
      if (request_length != 3 || payload[2] > MAX_TRANSFER_BYTES)
        read_validation_status = BAD_LENGTH;
      else if (range_end > MEMORY_BYTES)
        read_validation_status = BAD_ADDRESS;
      else
        read_validation_status = OK;
    end
  endfunction

  // Build a response header and begin CRC serialization.
  task automatic make_response;
    input [7:0] status;
    input [8:0] data_length;
    reg [15:0] wire_payload_length;
    begin
      wire_payload_length = {11'd0, data_length} + 16'd1;
      response[0] <= 8'h5a;
      response[1] <= 8'ha5;
      response[2] <= PROTOCOL_VERSION;
      response[3] <= request_opcode | 8'h80;
      response[4] <= request_sequence;
      response[5] <= wire_payload_length[7:0];
      response[6] <= wire_payload_length[15:8];
      response[7] <= status;
      response_data_length <= data_length;
      response_crc_index <= 2;
      response_crc_value <= 16'hffff;
      response_state <= RESPONSE_CRC;
    end
  endtask

  // Mark a protocol error and build its response.
  task automatic fail_response;
    input [7:0] status;
    begin
      protocol_error <= 1'b1;
      make_response(status, 0);
    end
  endtask

  // Validate and execute PING.
  task automatic execute_ping;
    begin
      if (request_length != 0)
        fail_response(BAD_LENGTH);
      else begin
        response[8] <= "U";
        response[9] <= "L";
        response[10] <= "R";
        response[11] <= "1";
        make_response(OK, 4);
      end
    end
  endtask

  // Validate and execute CAPABILITIES.
  task automatic execute_capabilities;
    begin
      if (request_length != 0)
        fail_response(BAD_LENGTH);
      else begin
        response[8] <= PROTOCOL_VERSION;
        response[9] <= 8'd8;
        response[10] <= 8'h00;
        response[11] <= 8'h00;
        response[12] <= 8'h01;
        response[13] <= 8'h00;
        response[14] <= 8'(MAX_TRANSFER_BYTES);
        response[15] <= 8'h18;
        response[16] <= 8'h00;
        make_response(OK, 9);
      end
    end
  endtask

  // Start a validated WRITE request.
  task automatic start_write;
    begin
      if (payload[2] == 0)
        make_response(OK, 0);
      else begin
        operation_start <= {payload[1], payload[0]};
        operation_data <= payload[3];
        operation_count <= payload[2];
        operation_progress <= 0;
        command_state <= CMD_MEM_REQUEST;
      end
    end
  endtask

  // Validate WRITE and start its first memory request.
  task automatic execute_write;
    begin
      case (write_validation_status())
        BAD_LENGTH: fail_response(BAD_LENGTH);
        BAD_ADDRESS: fail_response(BAD_ADDRESS);
        default: start_write();
      endcase
    end
  endtask

  // Start a validated READ request.
  task automatic start_read;
    begin
      response[8] <= payload[2];
      if (payload[2] == 0)
        make_response(OK, 1);
      else begin
        operation_start <= {payload[1], payload[0]};
        operation_count <= payload[2];
        operation_progress <= 0;
        command_state <= CMD_MEM_REQUEST;
      end
    end
  endtask

  // Validate READ and start its first memory request.
  task automatic execute_read;
    begin
      case (read_validation_status())
        BAD_LENGTH: fail_response(BAD_LENGTH);
        BAD_ADDRESS: fail_response(BAD_ADDRESS);
        default: start_read();
      endcase
    end
  endtask

  // Validate and execute STATUS.
  task automatic execute_status;
    begin
      if (request_length != 0)
        fail_response(BAD_LENGTH);
      else begin
        response[8] <= {7'd0, memory_ready};
        response[9] <= {5'd0, memory_fault_class};
        response[10] <= {7'd0, protocol_error};
        make_response(OK, 3);
      end
    end
  endtask

  // Dispatch one version-valid request.
  task automatic dispatch_request;
    begin
      case (request_opcode)
        PING: execute_ping();
        CAPABILITIES: execute_capabilities();
        WRITE: execute_write();
        READ: execute_read();
        STATUS: execute_status();
        default: fail_response(BAD_OPCODE);
      endcase
    end
  endtask

  // Dispatch one CRC-valid request.
  task automatic execute_request;
    begin
      if (request_version != PROTOCOL_VERSION)
        fail_response(BAD_VERSION);
      else
        dispatch_request();
    end
  endtask

  // Report a failed memory operation.
  task automatic handle_memory_fault;
    begin
      response[8] <= operation_progress;
      response[9] <= 0;
      make_response(MEMORY_FAULT, 2);
      command_state <= CMD_IDLE;
    end
  endtask

  // Consume one successful READ response.
  task automatic handle_read_response;
    begin
      response[9 + operation_progress] <= mem_rsp_data;
      if (operation_progress + 1'b1 == operation_count) begin
        make_response(OK, 9'd1 + operation_count);
        command_state <= CMD_IDLE;
      end
      else begin
        operation_progress <= operation_progress + 1'b1;
        command_state <= CMD_MEM_REQUEST;
      end
    end
  endtask

  // Consume one successful WRITE response.
  task automatic handle_write_response;
    begin
      if (operation_progress + 1'b1 == operation_count) begin
        make_response(OK, 0);
        command_state <= CMD_IDLE;
      end
      else begin
        operation_data <= payload[4 + operation_progress];
        operation_progress <= operation_progress + 1'b1;
        command_state <= CMD_MEM_REQUEST;
      end
    end
  endtask

  // Dispatch one successful memory response.
  task automatic dispatch_memory_response;
    begin
      case (request_opcode)
        READ: handle_read_response();
        default: handle_write_response();
      endcase
    end
  endtask

  // Consume one memory response and advance the active command.
  task automatic handle_memory_response;
    begin
      if (mem_rsp_fault)
        handle_memory_fault();
      else
        dispatch_memory_response();
    end
  endtask

  always @* begin
    mem_req_valid = command_state == CMD_MEM_REQUEST;
    mem_req_write = command_state == CMD_MEM_REQUEST &&
                    request_opcode == WRITE;
    mem_req_addr = operation_start + operation_progress;
    mem_req_data = operation_data;
    mem_rsp_ready = command_state == CMD_MEM_RESPONSE;
  end

  // Recover parser synchronization.
  task automatic restart_parser;
    begin
      parser_state <= PS_SYNC0;
    end
  endtask

  // Detect the first request synchronization byte.
  task automatic parse_sync0;
    begin
      if (rx_data == 8'ha5)
        parser_state <= PS_SYNC1;
    end
  endtask

  // Detect the second request synchronization byte.
  task automatic parse_sync1;
    begin
      if (rx_data == 8'h5a) begin
        parser_state <= PS_VERSION;
        request_crc <= 16'hffff;
      end
      else if (rx_data != 8'ha5)
        restart_parser();
    end
  endtask

  // Capture the request protocol version.
  task automatic parse_version;
    begin
      request_version <= rx_data;
      request_crc <= crc_byte(request_crc, rx_data);
      parser_state <= PS_OPCODE;
    end
  endtask

  // Capture the request opcode.
  task automatic parse_opcode;
    begin
      request_opcode <= rx_data;
      request_crc <= crc_byte(request_crc, rx_data);
      parser_state <= PS_SEQUENCE;
    end
  endtask

  // Capture the request sequence.
  task automatic parse_sequence;
    begin
      request_sequence <= rx_data;
      request_crc <= crc_byte(request_crc, rx_data);
      parser_state <= PS_LEN_LO;
    end
  endtask

  // Capture the low request-length byte.
  task automatic parse_length_low;
    begin
      request_length[7:0] <= rx_data;
      request_crc <= crc_byte(request_crc, rx_data);
      parser_state <= PS_LEN_HI;
    end
  endtask

  // Capture and validate the complete request length.
  task automatic parse_length_high;
    begin
      request_length[15:8] <= rx_data;
      if ({rx_data, request_length[7:0]} > MAX_PAYLOAD_BYTES) begin
        fail_response(BAD_LENGTH);
        restart_parser();
      end
      else begin
        request_crc <= crc_byte(request_crc, rx_data);
        payload_index <= 0;
        parser_state <= ({rx_data, request_length[7:0]} == 0) ?
                        PS_CRC_LO : PS_PAYLOAD;
      end
    end
  endtask

  // Capture one request payload byte.
  task automatic parse_payload;
    begin
      payload[payload_index] <= rx_data;
      request_crc <= crc_byte(request_crc, rx_data);
      if ({7'd0, payload_index} + 16'd1 == request_length)
        parser_state <= PS_CRC_LO;
      else
        payload_index <= payload_index + 1'b1;
    end
  endtask

  // Capture the low request-CRC byte.
  task automatic parse_crc_low;
    begin
      request_crc_low <= rx_data;
      parser_state <= PS_CRC_HI;
    end
  endtask

  // Validate the complete request CRC.
  task automatic parse_crc_high;
    begin
      restart_parser();
      if ({rx_data, request_crc_low} != request_crc)
        fail_response(BAD_CRC);
      else
        execute_request();
    end
  endtask

  // Dispatch one accepted request byte.
  task automatic parse_request_byte;
    begin
      case (parser_state)
        PS_SYNC0: parse_sync0();
        PS_SYNC1: parse_sync1();
        PS_VERSION: parse_version();
        PS_OPCODE: parse_opcode();
        PS_SEQUENCE: parse_sequence();
        PS_LEN_LO: parse_length_low();
        PS_LEN_HI: parse_length_high();
        PS_PAYLOAD: parse_payload();
        PS_CRC_LO: parse_crc_low();
        PS_CRC_HI: parse_crc_high();
        default: restart_parser();
      endcase
    end
  endtask

  // Accept one request byte while idle.
  task automatic accept_request_byte;
    begin
      if (rx_valid && rx_ready)
        parse_request_byte();
    end
  endtask

  // Accept one memory request.
  task automatic accept_memory_request;
    begin
      if (mem_req_valid && mem_req_ready)
        command_state <= CMD_MEM_RESPONSE;
    end
  endtask

  // Accept one memory response.
  task automatic accept_memory_response;
    begin
      if (mem_rsp_valid)
        handle_memory_response();
    end
  endtask

  // Recover from an invalid command state.
  task automatic restart_command;
    begin
      command_state <= CMD_IDLE;
    end
  endtask

  // Advance the active command state.
  task automatic advance_command;
    begin
      case (command_state)
        CMD_IDLE: accept_request_byte();
        CMD_MEM_REQUEST: accept_memory_request();
        CMD_MEM_RESPONSE: accept_memory_response();
        default: restart_command();
      endcase
    end
  endtask

  // Serialize the next response CRC byte.
  task automatic advance_response_crc;
    begin
      if (response_crc_index == 7 + response_data_length) begin
        response[8 + response_data_length] <= response_crc_next[7:0];
        response[9 + response_data_length] <= response_crc_next[15:8];
        response_length <= 9'd10 + response_data_length;
        response_index <= 0;
        response_state <= RESPONSE_TX;
      end
      else begin
        response_crc_value <= response_crc_next;
        response_crc_index <= response_crc_index + 1'b1;
      end
    end
  endtask

  // Advance after one transmitted response byte.
  task automatic accept_response_byte;
    begin
      if (response_index + 1'b1 == response_length) begin
        response_state <= RESPONSE_IDLE;
        response_index <= 0;
      end
      else
        response_index <= response_index + 1'b1;
    end
  endtask

  // Accept the current response byte.
  task automatic advance_response_tx;
    begin
      if (tx_ready)
        accept_response_byte();
    end
  endtask

  // Advance response construction or transmission.
  task automatic advance_response;
    begin
      if (response_state == RESPONSE_CRC)
        advance_response_crc();
      else if (response_state == RESPONSE_TX)
        advance_response_tx();
    end
  endtask

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      parser_state <= PS_SYNC0;
      command_state <= CMD_IDLE;
      response_state <= RESPONSE_IDLE;
      request_version <= 0;
      request_opcode <= 0;
      request_sequence <= 0;
      request_length <= 0;
      payload_index <= 0;
      request_crc <= 16'hffff;
      request_crc_low <= 0;
      response_length <= 0;
      response_index <= 0;
      response_data_length <= 0;
      response_crc_index <= 0;
      response_crc_value <= 16'hffff;
      operation_start <= 0;
      operation_data <= 0;
      operation_count <= 0;
      operation_progress <= 0;
      protocol_error <= 1'b0;
    end
    else begin
      advance_response();
      advance_command();
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (MAX_TRANSFER_BYTES < 1 || MAX_TRANSFER_BYTES > 255)
      $fatal(1, "MAX_TRANSFER_BYTES must be 1..255");
  end
`endif
endmodule

`default_nettype wire
