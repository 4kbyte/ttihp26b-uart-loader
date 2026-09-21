`default_nettype none
`timescale 1ns / 1ps

// Verify UART timing, framing, buffering, and reset behavior.
module uart_tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n;
  reg rx;
  reg rx_ready;
  wire rx_valid;
  wire [7:0] rx_data;
  wire [2:0] rx_level;
  wire framing_error;
  wire overrun;
  reg tx_valid;
  wire tx_ready;
  reg [7:0] tx_data;
  wire tx;
  integer errors;
  integer checks;
  integer i;

  uart_rx #(
      .CLOCK_HZ(100),
      .BAUD(10)
  ) rx_dut (
      .clk(clk),
      .rst_n(rst_n),
      .rx(rx),
      .out_valid(rx_valid),
      .out_ready(rx_ready),
      .out_data(rx_data),
      .level(rx_level),
      .framing_error(framing_error),
      .overrun(overrun)
  );
  uart_tx #(
      .CLOCK_HZ(100),
      .BAUD(10)
  ) tx_dut (
      .clk(clk),
      .rst_n(rst_n),
      .in_valid(tx_valid),
      .in_ready(tx_ready),
      .in_data(tx_data),
      .tx(tx)
  );

  task tick;
    begin
      @(posedge clk);
      #1;
    end
  endtask
  task check;
    input condition;
    input [8*80-1:0] message;
    begin
      checks = checks + 1;
      if (!condition) begin
        errors = errors + 1;
        $display("FAIL: %0s", message);
      end
    end
  endtask
  task bit_time;
    input value;
    begin
      rx = value;
      repeat (10) tick();
    end
  endtask
  task send_uart;
    input [7:0] value;
    input stop_high;
    begin
      bit_time(0);
      for (i = 0; i < 8; i = i + 1) begin
        bit_time(value[i]);
      end
      bit_time(stop_high);
      if (stop_high)
        bit_time(1);
    end
  endtask
  task reset_uart;
    begin
      rst_n = 0;
      repeat (2) tick();
      rst_n = 1;
      repeat (2) tick();
    end
  endtask

  initial begin
    errors = 0;
    checks = 0;
    rst_n = 0;
    rx = 1;
    rx_ready = 0;
    tx_valid = 0;
    tx_data = 0;
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();

    rx = 0;
    repeat (3) tick();
    rx = 1;
    repeat (12) tick();
    check(!rx_valid && rx_level == 0 && !framing_error,
          "UART RX rejects a short false start");

    send_uart(8'h41, 1);
    check(rx_valid && rx_data == 8'h41, "UART RX 8N1 byte");
    rx_ready = 1;
    tick();
    rx_ready = 0;

    send_uart(8'h42, 1);
    send_uart(8'h43, 1);
    send_uart(8'h44, 1);
    send_uart(8'h45, 1);
    send_uart(8'h46, 1);
    check(overrun && rx_level == 4, "UART FIFO overflow and pacing");
    reset_uart();
    check(!overrun && rx_level == 0, "reset clears RX overflow and FIFO");

    send_uart(8'hff, 0);
    bit_time(1);
    check(framing_error, "UART RX rejects a low stop bit");
    reset_uart();

    send_uart(8'h51, 1);
    send_uart(8'h52, 1);
    send_uart(8'h53, 1);
    send_uart(8'h54, 1);
    check(rx_level == 4 && !overrun, "RX FIFO holds four bytes");
    for (i = 0; i < 4; i = i + 1) begin
      check(rx_valid && rx_data == 8'h51 + i, "RX FIFO preserves byte order");
      rx_ready = 1;
      tick();
      rx_ready = 0;
      tick();
    end
    check(!rx_valid, "RX FIFO empties after four reads");

    send_uart(8'h61, 1);
    send_uart(8'h62, 1);
    reset_uart();
    check(!rx_valid && rx_level == 0, "reset discards RX FIFO contents");

    while (!tx_ready) tick();
    tx_data = 8'ha5;
    tx_valid = 1;
    tick();
    tx_valid = 0;
    while (tx) tick();
    repeat (5) tick();
    check(tx == 0, "UART TX start bit");
    for (i = 0; i < 8; i = i + 1) begin
      repeat (10) tick();
      check(tx == ((8'ha5 >> i) & 1'b1), "UART TX LSB-first data");
    end
    repeat (10) tick();
    check(tx == 1, "UART TX stop bit");
    check(!tx_ready, "UART TX backpressures while active");
    reset_uart();
    check(tx_ready && tx, "reset stops an active transmission");

    if (errors == 0)
      $display("PASS UART: %0d checks", checks);
    else
      $fatal(1, "UART failures: %0d", errors);
    $finish;
  end
endmodule

`default_nettype wire
