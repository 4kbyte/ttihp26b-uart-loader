`default_nettype none
`timescale 1ns / 1ps

// Verify loader commands, errors, memory operations, and framing.
module uart_loader_tb #(
    parameter integer MAX_TRANSFER_BYTES = 16
);
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n;
  reg rx_valid;
  wire rx_ready;
  reg [7:0] rx_data;
  wire tx_valid;
  reg tx_ready;
  wire [7:0] tx_data;
  wire mem_req_valid;
  reg mem_req_ready;
  wire mem_req_write;
  wire [15:0] mem_req_addr;
  wire [7:0] mem_req_data;
  reg mem_rsp_valid;
  wire mem_rsp_ready;
  reg [7:0] mem_rsp_data;
  reg mem_rsp_fault;
  reg memory_ready;
  reg [2:0] memory_fault_class;
  wire protocol_error;
  reg [7:0] memory [0:65535];
  reg response_pending;
  integer checks;
  integer errors;
  integer i;
  integer response_length;
  reg [7:0] received [0:MAX_TRANSFER_BYTES+15];
  reg [7:0] frame_payload [0:MAX_TRANSFER_BYTES+2];

  uart_loader #(
      .MAX_TRANSFER_BYTES(MAX_TRANSFER_BYTES)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .rx_valid(rx_valid),
      .rx_ready(rx_ready),
      .rx_data(rx_data),
      .tx_valid(tx_valid),
      .tx_ready(tx_ready),
      .tx_data(tx_data),
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

  task tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask
  task check;
    input condition;
    input [8*96-1:0] message;
    begin
      checks = checks + 1;
      if (!condition) begin
        errors = errors + 1;
        $display("FAIL: %0s", message);
      end
    end
  endtask
  task send_byte;
    input [7:0] value;
    begin
      while (!rx_ready) tick();
      rx_data = value;
      rx_valid = 1;
      tick();
      rx_valid = 0;
    end
  endtask
  task receive_response;
    integer index;
    begin
      for (index = 0; index < 7; index = index + 1) begin
        while (!tx_valid) tick();
        received[index] = tx_data;
        tx_ready = 1;
        tick();
        tx_ready = 0;
      end
      response_length = {received[6], received[5]};
      for (index = 7; index < 9 + response_length; index = index + 1) begin
        while (!tx_valid) tick();
        received[index] = tx_data;
        tx_ready = 1;
        tick();
        tx_ready = 0;
      end
    end
  endtask
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
  task check_response_crc;
    integer index;
    reg [15:0] crc;
    begin
      crc = 16'hffff;
      for (index = 2; index < 7 + response_length; index = index + 1)
        crc = crc_byte(crc, received[index]);
      check(
          received[7 + response_length] == crc[7:0] &&
          received[8 + response_length] == crc[15:8],
          "response CRC covers every transmitted response byte");
    end
  endtask
  task send_frame;
    input [7:0] opcode;
    input [7:0] seq_value;
    input [15:0] length;
    input corrupt_crc;
    integer index;
    reg [15:0] crc;
    begin
      crc = 16'hffff;
      send_byte(8'ha5);
      send_byte(8'h5a);
      send_byte(8'h01);
      crc = crc_byte(crc, 8'h01);
      send_byte(opcode);
      crc = crc_byte(crc, opcode);
      send_byte(seq_value);
      crc = crc_byte(crc, seq_value);
      send_byte(length[7:0]);
      crc = crc_byte(crc, length[7:0]);
      send_byte(length[15:8]);
      crc = crc_byte(crc, length[15:8]);
      for (index = 0; index < length; index = index + 1) begin
        send_byte(frame_payload[index]);
        crc = crc_byte(crc, frame_payload[index]);
      end
      send_byte(crc[7:0] ^ corrupt_crc);
      send_byte(crc[15:8]);
      receive_response();
      check_response_crc();
    end
  endtask
  task send_frame_version;
    input [7:0] version;
    input [7:0] opcode;
    input [7:0] seq_value;
    input [15:0] length;
    integer index;
    reg [15:0] crc;
    begin
      crc = 16'hffff;
      send_byte(8'ha5);
      send_byte(8'h5a);
      send_byte(version);
      crc = crc_byte(crc, version);
      send_byte(opcode);
      crc = crc_byte(crc, opcode);
      send_byte(seq_value);
      crc = crc_byte(crc, seq_value);
      send_byte(length[7:0]);
      crc = crc_byte(crc, length[7:0]);
      send_byte(length[15:8]);
      crc = crc_byte(crc, length[15:8]);
      for (index = 0; index < length; index = index + 1) begin
        send_byte(frame_payload[index]);
        crc = crc_byte(crc, frame_payload[index]);
      end
      send_byte(crc[7:0]);
      send_byte(crc[15:8]);
      receive_response();
      check_response_crc();
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      mem_rsp_valid <= 0;
      response_pending <= 0;
    end
    else begin
      if (mem_rsp_valid && mem_rsp_ready)
        mem_rsp_valid <= 0;
      if (response_pending) begin
        mem_rsp_valid <= 1;
        response_pending <= 0;
      end
      if (mem_req_valid && mem_req_ready) begin
        if (mem_req_write)
          memory[mem_req_addr] <= mem_req_data;
        mem_rsp_data <= mem_req_write ? 8'd0 : memory[mem_req_addr];
        mem_rsp_fault <= (mem_req_addr == 16'h2001);
        response_pending <= 1;
      end
    end
  end

  initial begin
    checks = 0;
    errors = 0;
    rst_n = 0;
    rx_valid = 0;
    rx_data = 0;
    tx_ready = 0;
    mem_req_ready = 1;
    mem_rsp_valid = 0;
    mem_rsp_data = 0;
    mem_rsp_fault = 0;
    response_pending = 0;
    memory_ready = 1;
    memory_fault_class = 0;
    for (i = 0; i < 65536; i = i + 1) begin
      memory[i] = 0;
    end
    repeat (4) tick();
    rst_n = 1;
    tick();

    send_frame(8'h00, 8'h2a, 0, 0);
    check(
        response_length == 5 && received[7] == 0 &&
          received[8] == "U" && received[9] == "L" &&
          received[10] == "R" && received[11] == "1",
        "exact ULR1 PING identity");
    check(
        received[0] == 8'h5a && received[1] == 8'ha5 &&
          received[2] == 8'h01 && received[3] == 8'h80 &&
          received[4] == 8'h2a && received[5] == 8'h05 &&
          received[6] == 0 && received[12] == 8'h60 &&
          received[13] == 8'h4d,
        "exact ULR1 PING response vector");

    send_frame(8'h01, 8'h2b, 0, 0);
    check(
        received[7] == 0 && received[8] == 1 &&
          received[9] == 8 && received[10] == 0 &&
          received[11] == 0 && received[12] == 1 &&
          received[13] == 0 && received[14] == MAX_TRANSFER_BYTES &&
          received[15] == 8'h18 && received[16] == 0,
        "CAPABILITIES describes 64 KiB and command mask");

    memory_ready = 0;
    memory_fault_class = 3'd2;
    send_frame(8'h14, 8'h2c, 0, 0);
    check(received[7] == 0 && received[8] == 0 && received[9] == 2 && received[10] == 0,
          "STATUS reports memory state");
    memory_ready = 1;
    memory_fault_class = 0;

    frame_payload[0] = 8'h34;
    frame_payload[1] = 8'h12;
    frame_payload[2] = 2;
    frame_payload[3] = 8'hef;
    frame_payload[4] = 8'hbe;
    send_frame(8'h11, 8'h20, 5, 0);
    check(received[7] == 0, "minimal WRITE succeeds");
    check(memory[16'h1234] == 8'hef && memory[16'h1235] == 8'hbe,
          "minimal WRITE commits bounded bytes");

    frame_payload[0] = 8'h34;
    frame_payload[1] = 8'h12;
    frame_payload[2] = 2;
    send_frame(8'h12, 8'h21, 3, 0);
    check(received[7] == 0 && received[8] == 2, "minimal READ succeeds");
    check(received[9] == 8'hef && received[10] == 8'hbe && response_length == 4,
          "minimal READ returns bytes");

    frame_payload[0] = 8'h00;
    frame_payload[1] = 8'h01;
    frame_payload[2] = MAX_TRANSFER_BYTES;
    for (i = 0; i < MAX_TRANSFER_BYTES; i = i + 1) begin
      frame_payload[3 + i] = i;
    end
    send_frame(8'h11, 8'h22, 3 + MAX_TRANSFER_BYTES, 0);
    check(
        received[7] == 0 && memory[16'h0100] == 0 &&
          memory[16'h0100 + MAX_TRANSFER_BYTES - 1] ==
              MAX_TRANSFER_BYTES - 1,
        "maximum configured transfer succeeds");

    if (MAX_TRANSFER_BYTES < 255) begin
      frame_payload[0] = 8'h00;
      frame_payload[1] = 8'h01;
      frame_payload[2] = MAX_TRANSFER_BYTES + 1;
      send_frame(8'h12, 8'h22, 3, 0);
      check(received[7] == 8'h03, "configured transfer bound is enforced");
    end

    frame_payload[0] = 8'hff;
    frame_payload[1] = 8'hff;
    frame_payload[2] = 1;
    frame_payload[3] = 8'h34;
    send_frame(8'h11, 8'h23, 4, 0);
    check(received[7] == 0 && memory[65535] == 8'h34, "last byte is writable");
    frame_payload[0] = 8'hff;
    frame_payload[1] = 8'hff;
    frame_payload[2] = 1;
    send_frame(8'h12, 8'h24, 3, 0);
    check(received[7] == 0 && received[8] == 1 && received[9] == 8'h34,
          "last byte is readable");

    frame_payload[0] = 8'hff;
    frame_payload[1] = 8'hff;
    frame_payload[2] = 2;
    send_frame(8'h12, 8'h25, 3, 0);
    check(received[7] == 8'h06, "minimal loader rejects range overflow");

    send_frame(8'h00, 8'h26, 0, 1);
    check(received[7] == 8'h04, "minimal loader reports bad CRC");
    send_frame_version(8'h02, 8'h00, 8'h27, 0);
    check(received[7] == 8'h01, "loader reports bad version");
    send_frame(8'h7f, 8'h28, 0, 0);
    check(received[7] == 8'h02, "loader reports bad opcode");
    frame_payload[0] = 0;
    send_frame(8'h00, 8'h29, 1, 0);
    check(received[7] == 8'h03, "loader reports bad command length");

    send_byte(8'h00);
    send_byte(8'hff);
    send_byte(8'ha5);
    send_byte(8'ha5);
    send_frame(8'h00, 8'h2a, 0, 0);
    check(received[7] == 0 && received[8] == "U", "malformed stream resynchronizes");

    frame_payload[0] = 8'h00;
    frame_payload[1] = 8'h20;
    frame_payload[2] = 3;
    frame_payload[3] = 1;
    frame_payload[4] = 2;
    frame_payload[5] = 3;
    send_frame(8'h11, 8'h2b, 6, 0);
    check(received[7] == 8'h07 && received[8] == 1 && received[9] == 0,
          "memory fault reports partial byte progress");
    check(memory[16'h2000] == 1 && memory[16'h2002] == 0,
          "memory fault stops later bytes");

    check(protocol_error, "protocol error flag is sticky");
    send_frame(8'h14, 8'h2c, 0, 0);
    check(received[7] == 0 && received[10] == 1,
          "STATUS reports sticky protocol error");

    if (errors == 0)
      $display("PASS minimal loader contract: %0d checks", checks);
    else
      $fatal(1, "minimal loader failures: %0d", errors);
    $finish;
  end
endmodule

`default_nettype wire
