`default_nettype none
`timescale 1ns / 1ps

// Verify wrapper reset, pins, initialization, and memory activity.
module project_tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n;
  reg [7:0] ui_in;
  wire [7:0] uo_out;
  reg [7:0] uio_in;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  reg spi_miso;
  reg [15:0] spi_bits;
  reg [7:0] spi_command;
  integer spi_count;
  integer checks;
  integer errors;
  integer i;
  reg activity_dropped;

  tt_um_romd_uart_loader #(
      .UART_CLOCK_HZ(100),
      .UART_BAUD(10)
  ) dut (
      .ui_in(ui_in),
      .uo_out(uo_out),
      .uio_in(uio_in),
      .uio_out(uio_out),
      .uio_oe(uio_oe),
      .ena(1'b1),
      .clk(clk),
      .rst_n(rst_n)
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
  always @* begin
    uio_in = 0;
    uio_in[2] = spi_miso;
  end
  always @(negedge uio_out[0]) begin
    spi_count = 0;
    spi_bits = 0;
    spi_command = 0;
    spi_miso = 0;
  end
  always @(posedge uio_out[3]) begin
    if (!uio_out[0]) begin
      spi_bits = {spi_bits[14:0], uio_out[1]};
      spi_count = spi_count + 1;
      if (spi_count == 8)
        spi_command = spi_bits[7:0];
    end
  end
  always @(negedge uio_out[3]) begin
    if (!uio_out[0] && spi_command == 8'h05 && spi_count >= 8 && spi_count < 16)
      spi_miso = (8'h40 >> (15 - spi_count)) & 1'b1;
  end

  initial begin
    checks = 0;
    errors = 0;
    rst_n = 0;
    ui_in = 8'h08;
    spi_miso = 0;
    spi_bits = 0;
    spi_command = 0;
    spi_count = 0;
    #1;
    check(uo_out == 8'h10, "reset output is deterministic");
    check(uio_out == 8'h01 && uio_oe == 8'h0b, "reset SPI pins and output enables");
    repeat (4) tick();
    rst_n = 1;
    while (!uo_out[0]) tick();
    check(uio_out[0] && !uio_out[1] && !uio_out[3],
          "SPI is mode-0 idle after initialization");

    check(uio_oe == 8'h0b && uo_out[4],
          "wrapper pin directions and UART idle remain stable");

    force dut.mem_req_valid = 1'b1;
    force dut.mem_req_write = 1'b0;
    force dut.mem_req_addr = 16'h0010;
    tick();
    release dut.mem_req_valid;
    release dut.mem_req_write;
    release dut.mem_req_addr;
    check(uo_out[1], "memory activity starts when a request is accepted");
    activity_dropped = 0;
    while (!dut.mem_rsp_valid) begin
      if (!uo_out[1])
        activity_dropped = 1;
      tick();
    end
    check(!activity_dropped, "memory activity remains high during SPI transfer");
    check(uo_out[1], "memory activity remains high with a pending response");
    force dut.mem_rsp_ready = 1'b1;
    tick();
    release dut.mem_rsp_ready;
    check(!uo_out[1], "memory activity ends when the response is accepted");

    rst_n = 0;
    #1;
    check(uio_out == 8'h01 && uo_out == 8'h10,
          "electrical reset restores output boundaries");
    if (errors == 0)
      $display("PASS wrapper: %0d checks", checks);
    else
      $fatal(1, "wrapper failures: %0d", errors);
    $finish;
  end
endmodule

`default_nettype wire
