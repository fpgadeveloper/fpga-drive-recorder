// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_egress -- playback clock-domain crossing FIFO (dp_clk -> src_clk)
//
//   * s_axis (dp_clk, from the AXI DMA MM2S) -> xpm_fifo_async ->
//     m_axis (src_clk, first-word-fall-through, to the user_data_sink).
//   * Lossless: s_axis_tready is deasserted while the FIFO is full, so the DMA
//     is stalled (backpressure) instead of data being dropped.
//   * TDATA and TLAST are carried through the FIFO; TKEEP is ignored (the
//     playback path always moves whole 16-byte beats).
//   * flush (dp_clk, level): beats from the DMA are accepted and DISCARDED
//     (tready = 1, nothing is written), so the DMA can always drain, e.g. to
//     stop a playback while the sink is disabled. Discarded beats are counted
//     (discard_count). The same accept-and-discard behaviour applies while srst
//     is high (soft reset in progress); those beats are not counted.
//   * fifo_rst (dp_clk, level) resets the FIFO; it must be a short window
//     (fdrec_core drives it for 32 dp_clk cycles), wr_rst_busy reports when the
//     write side is out of reset again.
//   * beats_in counts beats written into the FIFO; srst clears both counters.

`timescale 1ns / 1ps

module fdrec_egress #(
  parameter integer FIFO_DEPTH = 4096,   // beats; power of 2, 16..131072
  parameter integer CDC_STAGES = 3
) (
  // DMA side (dp_clk)
  input  wire          dp_clk,
  input  wire          fifo_rst,          // FIFO reset window, dp_clk domain
  input  wire          srst,              // soft reset in progress (level)
  input  wire          flush,
  input  wire [127:0]  s_axis_tdata,
  input  wire [15:0]   s_axis_tkeep,
  input  wire          s_axis_tlast,
  input  wire          s_axis_tvalid,
  output wire          s_axis_tready,
  output reg  [63:0]   beats_in,
  output reg  [63:0]   discard_count,
  output wire [$clog2(FIFO_DEPTH):0] fifo_level, // occupancy seen from dp_clk
  output wire          wr_rst_busy,

  // Sink side (src_clk), first-word-fall-through
  input  wire          src_clk,
  output wire [127:0]  m_axis_tdata,
  output wire          m_axis_tlast,
  output wire          m_axis_tvalid,
  input  wire          m_axis_tready
);

  localparam integer CNT_W = $clog2(FIFO_DEPTH) + 1;

  wire full, empty, rd_rst_busy;

  wire drain  = srst | flush;
  wire can_wr = ~full & ~wr_rst_busy;
  wire wr_en  = s_axis_tvalid & can_wr & ~drain;

  assign s_axis_tready = drain | can_wr;

  always @(posedge dp_clk) begin
    if (srst) begin
      beats_in      <= 64'd0;
      discard_count <= 64'd0;
    end else begin
      if (wr_en)                 beats_in      <= beats_in + 64'd1;
      if (s_axis_tvalid & flush) discard_count <= discard_count + 64'd1;
    end
  end

  assign m_axis_tvalid = ~empty & ~rd_rst_busy;
  wire rd_en = m_axis_tready & m_axis_tvalid;

  xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("block"),
    .FIFO_WRITE_DEPTH    (FIFO_DEPTH),
    .WRITE_DATA_WIDTH    (129),
    .READ_DATA_WIDTH     (129),
    .READ_MODE           ("fwft"),
    .FIFO_READ_LATENCY   (0),
    .CDC_SYNC_STAGES     (CDC_STAGES),
    .RELATED_CLOCKS      (0),
    .ECC_MODE            ("no_ecc"),
    .FULL_RESET_VALUE    (1),
    .USE_ADV_FEATURES    ("0004"),      // wr_data_count only
    .RD_DATA_COUNT_WIDTH (CNT_W),
    .WR_DATA_COUNT_WIDTH (CNT_W),
    .PROG_FULL_THRESH    (10),
    .PROG_EMPTY_THRESH   (10),
    .DOUT_RESET_VALUE    ("0"),
    .WAKEUP_TIME         (0),
    .SIM_ASSERT_CHK      (0)
  ) u_fifo (
    .rst           (fifo_rst),
    .wr_clk        (dp_clk),
    .wr_en         (wr_en),
    .din           ({s_axis_tlast, s_axis_tdata}),
    .full          (full),
    .wr_rst_busy   (wr_rst_busy),
    .rd_clk        (src_clk),
    .rd_en         (rd_en),
    .dout          ({m_axis_tlast, m_axis_tdata}),
    .empty         (empty),
    .rd_rst_busy   (rd_rst_busy),
    .wr_data_count (fifo_level),
    .sleep         (1'b0),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    // unused outputs
    .overflow      (),
    .prog_full     (),
    .rd_data_count (),
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
