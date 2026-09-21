`default_nettype none
`timescale 1ns / 1ps

// Connect the hardened UART loader to cocotb test signals.
module tb;
  reg clk;
  reg ena;
  reg rst_n;
  reg [7:0] ui_in;
  reg [7:0] uio_in;

  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
  wire spi_cs_n = uio_out[0];
  wire spi_mosi = uio_out[1];
  wire spi_sck = uio_out[3];

  tt_um_romd_uart_loader user_project (
      .ui_in(ui_in),
      .uo_out(uo_out),
      .uio_in(uio_in),
      .uio_out(uio_out),
      .uio_oe(uio_oe),
      .ena(ena),
      .clk(clk),
      .rst_n(rst_n)
  );
endmodule

`default_nettype wire
