`default_nettype none
`timescale 1ns / 1ps

// Verify SPI SRAM initialization, transfers, faults, and reset behavior.
module spi_sram_tb;
  reg clk = 0;
  always #10 clk = ~clk;
  reg rst_n;
  reg req_valid;
  wire req_ready;
  reg req_write;
  reg [15:0] req_addr;
  reg [7:0] req_data;
  wire rsp_valid;
  reg rsp_ready;
  wire [7:0] rsp_data;
  wire rsp_fault;
  wire memory_ready;
  wire [2:0] fault_class;
  wire spi_cs_n;
  wire spi_mosi;
  reg spi_miso;
  wire spi_sck;
  integer checks;
  integer errors;
  integer cs_windows;
  integer rising_edges;
  integer bit_count;
  integer clock_count;
  integer last_sck_edge;
  integer i;
  reg [31:0] captured;
  reg [31:0] last_frame;
  reg [7:0] command;
  reg [15:0] byte_address;
  reg [7:0] read_stream;
  reg [7:0] mode_register;
  reg force_bad_mode;
  reg [7:0] sram [0:65535];

  spi_sram dut (
      .clk(clk),
      .rst_n(rst_n),
      .req_valid(req_valid),
      .req_ready(req_ready),
      .req_write(req_write),
      .req_addr(req_addr),
      .req_data(req_data),
      .rsp_valid(rsp_valid),
      .rsp_ready(rsp_ready),
      .rsp_data(rsp_data),
      .rsp_fault(rsp_fault),
      .memory_ready(memory_ready),
      .fault_class(fault_class),
      .spi_cs_n(spi_cs_n),
      .spi_mosi(spi_mosi),
      .spi_miso(spi_miso),
      .spi_sck(spi_sck)
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
  task reset_adapter;
    begin
      rst_n = 0;
      req_valid = 0;
      rsp_ready = 0;
      repeat (3) tick();
      rst_n = 1;
      while (!memory_ready && fault_class == 0) tick();
    end
  endtask
  task request;
    input write_value;
    input [15:0] address;
    input [7:0] data;
    begin
      req_write = write_value;
      req_addr = address;
      req_data = data;
      req_valid = 1;
      while (!req_ready) tick();
      tick();
      req_valid = 0;
      while (!rsp_valid) tick();
    end
  endtask

  always @(negedge spi_cs_n) begin
    check(spi_sck == 0, "mode-0 clock low at CS assertion");
    bit_count = 0;
    last_sck_edge = -1;
    captured = 0;
    command = 0;
    byte_address = 0;
    read_stream = 0;
    spi_miso = 0;
    cs_windows = cs_windows + 1;
  end

  always @(posedge clk) clock_count = clock_count + 1;

  always @(spi_sck) begin
    if (!spi_cs_n && rst_n) begin
      if (last_sck_edge >= 0)
        check(clock_count - last_sck_edge >= 2, "SPI clock does not exceed 12.5 MHz");
      last_sck_edge = clock_count;
    end
  end

  always @(posedge spi_sck) begin
    if (!spi_cs_n) begin
      captured = {captured[30:0], spi_mosi};
      bit_count = bit_count + 1;
      rising_edges = rising_edges + 1;
      if (bit_count == 8)
        command = captured[7:0];
      if (bit_count == 24) begin
        byte_address = captured[15:0];
        read_stream = sram[captured[15:0]];
      end
    end
  end

  always @(negedge spi_sck) begin
    if (!spi_cs_n) begin
      if (command == 8'h05 && bit_count >= 8 && bit_count < 16)
        spi_miso = force_bad_mode ? 1'b0 : mode_register[15 - bit_count];
      else if (command == 8'h03 && bit_count >= 24 && bit_count < 32)
        spi_miso = read_stream[31 - bit_count];
      else
        spi_miso = 0;
    end
  end

  always @(posedge spi_cs_n) begin
    if (bit_count != 0) begin
      last_frame = captured;
      if (command == 8'h01 && bit_count == 16)
        mode_register = captured[7:0];
      if (command == 8'h02 && bit_count == 32)
        sram[captured[23:8]] = captured[7:0];
    end
  end

  initial begin
    checks = 0;
    errors = 0;
    cs_windows = 0;
    rising_edges = 0;
    clock_count = 0;
    last_sck_edge = -1;
    mode_register = 0;
    force_bad_mode = 0;
    spi_miso = 0;
    rst_n = 0;
    req_valid = 0;
    req_write = 0;
    req_addr = 0;
    req_data = 0;
    rsp_ready = 0;
    for (i = 0; i < 65536; i = i + 1) begin
      sram[i] = 0;
    end
    reset_adapter();
    check(memory_ready && fault_class == 0, "WRMR/RDMR initialization");
    check(mode_register == 8'h40, "sequential mode programmed");
    check(cs_windows == 2, "one CS window per initialization command");
    check(rising_edges == 32, "exact initialization bit count");

    request(1, 16'h1234, 8'hab);
    check(last_frame == {8'h02, 16'h1234, 8'hab},
          "WRITE command preserves byte address and data");
    check(sram[16'h1234] == 8'hab, "WRITE committed at CS release");
    check(!rsp_fault, "WRITE abstract response");
    rsp_ready = 1;
    tick();
    rsp_ready = 0;

    sram[16'h2345] = 8'h5a;
    request(0, 16'h2345, 0);
    check(last_frame[31:8] == {8'h03, 16'h2345}, "READ command preserves byte address");
    check(rsp_data == 8'h5a && !rsp_fault, "READ returns one byte");
    repeat (5) begin
      check(rsp_valid && rsp_data == 8'h5a && !rsp_fault, "stalled response stability");
      tick();
    end
    rsp_ready = 1;
    tick();
    rsp_ready = 0;

    request(1, 16'hffff, 8'ha5);
    check(sram[16'hffff] == 8'ha5, "last byte is writable");
    rsp_ready = 1;
    tick();
    rsp_ready = 0;
    request(0, 16'hffff, 0);
    check(rsp_data == 8'ha5, "last byte is readable");
    rsp_ready = 1;
    tick();
    rsp_ready = 0;

    rst_n = 0;
    repeat (2) tick();
    rst_n = 1;
    while (!memory_ready && fault_class == 0) tick();
    check(memory_ready && fault_class == 0,
          "electrical reset reinitializes controller without SRAM loss");
    check(sram[16'h1234] == 8'hab, "electrical reset preserves SRAM contents");

    for (i = 0; i <= 8; i = i + 1) begin
      reset_adapter();
      sram[16'h0100] = 8'h12;
      req_write = 1;
      req_addr = 16'h0100;
      req_data = 8'h55;
      req_valid = 1;
      while (!req_ready) tick();
      tick();
      req_valid = 0;
      while (bit_count < 24 + i) tick();
      #3 rst_n = 0;
      #1;
      check(spi_cs_n && !spi_sck && !spi_mosi && !memory_ready,
            "electrical reset aborts at every data bit");
      if (i < 8) begin
        check(sram[16'h0100] == 8'h12,
              "pre-complete reset does not physically commit write");
      end
      else begin
        check(sram[16'h0100] == 8'h55 && !rsp_valid,
              "final-bit reset may commit physically without abstract response");
      end
      repeat (2) tick();
      rst_n = 1;
      while (!memory_ready && fault_class == 0) tick();
    end

    force_bad_mode = 1;
    rst_n = 0;
    repeat (3) tick();
    rst_n = 1;
    while (fault_class == 0) tick();
    check(!memory_ready && fault_class == 2, "mode verification failure");
    request(0, 0, 0);
    check(rsp_fault, "failed adapter returns abstract fault");
    rsp_ready = 1;
    tick();

    if (errors == 0)
      $display("PASS SPI SRAM: %0d checks", checks);
    else
      $fatal(1, "SPI SRAM failures: %0d", errors);
    $finish;
  end
endmodule

`default_nettype wire
