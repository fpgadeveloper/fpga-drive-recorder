// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_ingest -- clock-domain crossing FIFO with drop counting
//
//   * s_axis (src_clk) -> xpm_fifo_async -> fifo_* (dp_clk, first-word-fall-through)
//   * s_axis_tready is always 1: the source is never stalled. A beat offered
//     while the FIFO is full is dropped and counted (drop_count).
//   * beats_in counts every beat offered by the source (accepted + dropped).
//   * src_srst (src_clk domain, level) resets the FIFO and holds both counters
//     at 0. While src_srst is high, or while the FIFO is still coming out of
//     reset (wr_rst_busy), beats are neither written nor counted, so
//     beats_in == accepted + dropped always holds outside the reset window.
//
// The FIFO is built from block RAM (xpm_fifo_async does not support UltraRAM).

`timescale 1ns / 1ps

module fdrec_ingest #(
  parameter integer FIFO_DEPTH = 4096,   // beats; power of 2, 16..131072
  parameter integer CDC_STAGES = 3
) (
  // Source side (src_clk)
  input  wire          src_clk,
  input  wire          src_srst,          // active-high reset, src_clk domain
  input  wire [127:0]  s_axis_tdata,
  input  wire          s_axis_tvalid,
  output wire          s_axis_tready,
  output reg  [63:0]   beats_in,
  output reg  [63:0]   drop_count,

  // Datapath side (dp_clk), first-word-fall-through read port
  input  wire          dp_clk,
  output wire [127:0]  fifo_tdata,
  output wire          fifo_tvalid,
  input  wire          fifo_tready,
  output wire [$clog2(FIFO_DEPTH):0] fifo_count,  // occupancy seen from dp_clk
  output wire          fifo_rst_busy              // dp_clk domain
);

  localparam integer CNT_W = $clog2(FIFO_DEPTH) + 1;

  wire full;
  wire empty;
  wire wr_rst_busy;
  wire rd_rst_busy;

  // The source can never be stalled
  assign s_axis_tready = 1'b1;

  wire src_live = ~src_srst & ~wr_rst_busy;
  wire wr_en    = s_axis_tvalid & src_live & ~full;
  wire drop     = s_axis_tvalid & src_live &  full;

  always @(posedge src_clk) begin
    if (src_srst) begin
      beats_in   <= 64'd0;
      drop_count <= 64'd0;
    end else begin
      if (s_axis_tvalid & src_live) beats_in   <= beats_in + 64'd1;
      if (drop)                     drop_count <= drop_count + 64'd1;
    end
  end

  wire rd_en = fifo_tready & ~empty & ~rd_rst_busy;
  assign fifo_tvalid   = ~empty & ~rd_rst_busy;
  assign fifo_rst_busy = rd_rst_busy;

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("block"),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (128),
    .READ_DATA_WIDTH     (128),
    .READ_MODE           ("fwft"),
    .FIFO_READ_LATENCY   (0),
    .CDC_SYNC_STAGES     (CDC_STAGES),
    .RELATED_CLOCKS      (0),
    .ECC_MODE            ("no_ecc"),
    .FULL_RESET_VALUE    (1),
    .USE_ADV_FEATURES    ("0400"),      // rd_data_count only
    .RD_DATA_COUNT_WIDTH (CNT_W),
    .WR_DATA_COUNT_WIDTH (CNT_W),
    .PROG_FULL_THRESH    (10),
    .PROG_EMPTY_THRESH   (10),
    .DOUT_RESET_VALUE    ("0"),
    .WAKEUP_TIME         (0),
    .SIM_ASSERT_CHK      (0)
  ) u_fifo (
    .rst           (src_srst),
    .wr_clk        (src_clk),
    .wr_en         (wr_en),
    .din           (s_axis_tdata),
    .full          (full),
    .wr_rst_busy   (wr_rst_busy),
    .rd_clk        (dp_clk),
    .rd_en         (rd_en),
    .dout          (fifo_tdata),
    .empty         (empty),
    .rd_rst_busy   (rd_rst_busy),
    .rd_data_count (fifo_count),
    .sleep         (1'b0),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    // unused outputs
    .overflow      (),
    .prog_full     (),
    .wr_data_count (),
    .almost_full   (),
    .wr_ack        (),
    .underflow     (),
    .prog_empty    (),
    .almost_empty  (),
    .data_valid    (),
    .sbiterr       (),
    .dbiterr       ()
  );

endmodule
