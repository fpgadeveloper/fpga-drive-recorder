// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_core -- FPGA Drive Recorder datapath core (block-design module reference)
//
//   s_axis (src_clk) -> fdrec_ingest (async FIFO, drop + count)
//                    -> fdrec_packetizer (TLAST every PKT_LEN beats, ENABLE gate)
//                    -> m_axis (dp_clk) -> AXI DMA S2MM
//
//   s_axis_mm2s (dp_clk, AXI DMA MM2S) -> fdrec_egress (async FIFO, lossless,
//                    backpressure to the DMA) -> m_axis_snk (src_clk) -> data sink
//
//   s_axi (dp_clk): AXI4-Lite register block (fdrec_regs), see include/fdrec_regs.h
//
// The test pattern generator lives OUTSIDE this module (user_data_source
// hierarchy) so that it can be replaced. Its controls are provided here as
// src_clk-domain ports:
//
//   tpg_enable    level, synchronised with xpm_cdc_single
//   tpg_seq_rst   pulse (xpm_cdc_pulse) on TPG_CTRL.SEQ_RST; held high during
//                 the source-side soft-reset window
//   tpg_rate_inc  32-bit quasi-static value, transferred with xpm_cdc_handshake
//                 (always a coherent word; a new value arrives within ~20 cycles)
//   tpg_seq_next  64-bit readback (input); sampled together with the ingest
//                 counters into one coherent snapshot (xpm_cdc_handshake,
//                 continuously refreshed, at most a few hundred ns old)
//
// Clock-domain crossings use XPM CDC macros only, which carry their own timing
// constraints (no XDC needed).
//
// Soft reset (GLOBAL_CTRL.SOFT_RST): a pulse crosses to src_clk and opens a
// 64-cycle source-side window during which the ingest FIFO is reset, the
// source-side counters are held at 0, tpg_enable is forced low and tpg_seq_rst
// is held high (so SEQ_NEXT also returns to 0). The register block disables the
// TPG and the packetizer and clears HWM/OVERFLOW/BEATS_OUT.
//
// Playback (register map 1.1): the checker (fdrec_check) lives OUTSIDE this
// module too (user_data_sink hierarchy); its controls and counters cross the
// same way as the TPG's:
//
//   chk_enable    level, xpm_cdc_single (forced low in the soft-reset window)
//   chk_reset     pulse on CHK_CTRL.RESET, held high in the soft-reset window
//   chk_rate_inc  32-bit, xpm_cdc_handshake (continuously re-sent)
//   chk_*         six 64-bit counters (input), one coherent snapshot to dp_clk
//
// SOFT_RST also resets the egress FIFO (32 dp_clk cycles) and, while it is in
// progress, accepts and discards beats from the DMA so the MM2S never wedges.

`timescale 1ns / 1ps

module fdrec_core #(
  parameter integer SRC_CLK_HZ = 200000000,
  parameter integer DP_CLK_HZ  = 250000000,
  parameter integer FIFO_DEPTH = 4096,
  parameter integer EGR_FIFO_DEPTH = 4096
) (
  // Source clock domain
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 src_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis:m_axis_snk, ASSOCIATED_RESET src_resetn" *)
  input  wire          src_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 src_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire          src_resetn,

  // Datapath / register clock domain
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dp_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis:s_axi:s_axis_mm2s, ASSOCIATED_RESET dp_resetn" *)
  input  wire          dp_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dp_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire          dp_resetn,

  // Data source stream (src_clk); tready is always 1
  input  wire [127:0]  s_axis_tdata,
  input  wire          s_axis_tvalid,
  output wire          s_axis_tready,

  // Stream to the AXI DMA S2MM (dp_clk)
  output wire [127:0]  m_axis_tdata,
  output wire [15:0]   m_axis_tkeep,
  output wire          m_axis_tlast,
  output wire          m_axis_tvalid,
  input  wire          m_axis_tready,

  // Playback stream from the AXI DMA MM2S (dp_clk); TKEEP is ignored
  input  wire [127:0]  s_axis_mm2s_tdata,
  input  wire [15:0]   s_axis_mm2s_tkeep,
  input  wire          s_axis_mm2s_tlast,
  input  wire          s_axis_mm2s_tvalid,
  output wire          s_axis_mm2s_tready,

  // Playback stream to the data sink (src_clk); TLAST passed through
  output wire [127:0]  m_axis_snk_tdata,
  output wire          m_axis_snk_tlast,
  output wire          m_axis_snk_tvalid,
  input  wire          m_axis_snk_tready,

  // AXI4-Lite register interface (dp_clk)
  input  wire [11:0]   s_axi_awaddr,
  input  wire [2:0]    s_axi_awprot,
  input  wire          s_axi_awvalid,
  output wire          s_axi_awready,
  input  wire [31:0]   s_axi_wdata,
  input  wire [3:0]    s_axi_wstrb,
  input  wire          s_axi_wvalid,
  output wire          s_axi_wready,
  output wire [1:0]    s_axi_bresp,
  output wire          s_axi_bvalid,
  input  wire          s_axi_bready,
  input  wire [11:0]   s_axi_araddr,
  input  wire [2:0]    s_axi_arprot,
  input  wire          s_axi_arvalid,
  output wire          s_axi_arready,
  output wire [31:0]   s_axi_rdata,
  output wire [1:0]    s_axi_rresp,
  output wire          s_axi_rvalid,
  input  wire          s_axi_rready,

  // Test pattern generator control/status (src_clk domain)
  output wire          tpg_enable,
  output wire          tpg_seq_rst,
  output wire [31:0]   tpg_rate_inc,
  input  wire [63:0]   tpg_seq_next,

  // Playback checker control/status (src_clk domain)
  output wire          chk_enable,
  output wire          chk_reset,
  output wire [31:0]   chk_rate_inc,
  input  wire [63:0]   chk_beats,
  input  wire [63:0]   chk_errors,
  input  wire [63:0]   chk_gaps,
  input  wire [63:0]   chk_gap_beats,
  input  wire [63:0]   chk_underflows,
  input  wire [63:0]   chk_last_seq
);

  localparam integer CNT_W   = $clog2(FIFO_DEPTH) + 1;
  localparam integer SYNC_FF = 4;
  localparam integer EGR_CNT_W = $clog2(EGR_FIFO_DEPTH) + 1;

  // ===========================================================================
  // dp_clk domain: register block
  // ===========================================================================
  wire              snap_valid;
  wire [191:0]      snap_data;
  wire [CNT_W-1:0]  fifo_count;
  wire              fifo_rst_busy;
  wire [63:0]       beats_out;
  wire              dp_tpg_enable, dp_tpg_seq_rst;
  wire [31:0]       dp_tpg_rate_inc;
  wire              pkt_enable;
  wire [31:0]       pkt_len;
  wire              dp_srst_pulse, dp_srst;
  wire              chk_snap_valid;
  wire [383:0]      chk_snap_data;
  wire              dp_chk_enable, dp_chk_reset;
  wire [31:0]       dp_chk_rate_inc;
  wire              egr_flush;
  wire [63:0]       egr_beats_in, egr_discard;
  wire [EGR_CNT_W-1:0] egr_level;
  wire              egr_wr_rst_busy;

  fdrec_regs #(
    .SRC_CLK_HZ (SRC_CLK_HZ),
    .DP_CLK_HZ  (DP_CLK_HZ),
    .FIFO_DEPTH (FIFO_DEPTH),
    .CNT_W      (CNT_W),
    .EGR_FIFO_DEPTH (EGR_FIFO_DEPTH),
    .EGR_CNT_W  (EGR_CNT_W)
  ) u_regs (
    .clk             (dp_clk),
    .resetn          (dp_resetn),
    .s_axi_awaddr    (s_axi_awaddr),
    .s_axi_awprot    (s_axi_awprot),
    .s_axi_awvalid   (s_axi_awvalid),
    .s_axi_awready   (s_axi_awready),
    .s_axi_wdata     (s_axi_wdata),
    .s_axi_wstrb     (s_axi_wstrb),
    .s_axi_wvalid    (s_axi_wvalid),
    .s_axi_wready    (s_axi_wready),
    .s_axi_bresp     (s_axi_bresp),
    .s_axi_bvalid    (s_axi_bvalid),
    .s_axi_bready    (s_axi_bready),
    .s_axi_araddr    (s_axi_araddr),
    .s_axi_arprot    (s_axi_arprot),
    .s_axi_arvalid   (s_axi_arvalid),
    .s_axi_arready   (s_axi_arready),
    .s_axi_rdata     (s_axi_rdata),
    .s_axi_rresp     (s_axi_rresp),
    .s_axi_rvalid    (s_axi_rvalid),
    .s_axi_rready    (s_axi_rready),
    .snap_valid      (snap_valid),
    .snap_seq_next   (snap_data[191:128]),
    .snap_beats_in   (snap_data[127:64]),
    .snap_drop_count (snap_data[63:0]),
    .fifo_count      (fifo_count),
    .fifo_rst_busy   (fifo_rst_busy | egr_wr_rst_busy),
    .beats_out       (beats_out),
    .tpg_enable      (dp_tpg_enable),
    .tpg_seq_rst     (dp_tpg_seq_rst),
    .tpg_rate_inc    (dp_tpg_rate_inc),
    .pkt_enable      (pkt_enable),
    .pkt_len         (pkt_len),
    .srst_pulse      (dp_srst_pulse),
    .srst            (dp_srst),
    .chk_snap_valid  (chk_snap_valid),
    .snap_chk_beats      (chk_snap_data[383:320]),
    .snap_chk_errors     (chk_snap_data[319:256]),
    .snap_chk_gaps       (chk_snap_data[255:192]),
    .snap_chk_gap_beats  (chk_snap_data[191:128]),
    .snap_chk_underflows (chk_snap_data[127:64]),
    .snap_chk_last_seq   (chk_snap_data[63:0]),
    .chk_enable      (dp_chk_enable),
    .chk_reset       (dp_chk_reset),
    .chk_rate_inc    (dp_chk_rate_inc),
    .egr_flush       (egr_flush),
    .egr_beats_in    (egr_beats_in),
    .egr_discard     (egr_discard),
    .egr_level       (egr_level)
  );

  // ===========================================================================
  // dp_clk -> src_clk control crossings
  // ===========================================================================
  wire src_srst_pulse;
  wire src_seq_rst_pulse;
  wire src_tpg_enable;

  xpm_cdc_pulse #(
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .REG_OUTPUT     (1),
    .RST_USED       (0),
    .SIM_ASSERT_CHK (0)
  ) u_cdc_srst (
    .src_clk    (dp_clk),
    .src_pulse  (dp_srst_pulse),
    .src_rst    (1'b0),
    .dest_clk   (src_clk),
    .dest_rst   (1'b0),
    .dest_pulse (src_srst_pulse)
  );

  xpm_cdc_pulse #(
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .REG_OUTPUT     (1),
    .RST_USED       (0),
    .SIM_ASSERT_CHK (0)
  ) u_cdc_seq_rst (
    .src_clk    (dp_clk),
    .src_pulse  (dp_tpg_seq_rst),
    .src_rst    (1'b0),
    .dest_clk   (src_clk),
    .dest_rst   (1'b0),
    .dest_pulse (src_seq_rst_pulse)
  );

  xpm_cdc_single #(
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (1)
  ) u_cdc_tpg_en (
    .src_clk  (dp_clk),
    .src_in   (dp_tpg_enable),
    .dest_clk (src_clk),
    .dest_out (src_tpg_enable)
  );

  // TPG_RATE_INC: continuously re-sent coherent 32-bit word
  reg         rate_send;
  reg  [31:0] rate_hold;
  wire        rate_rcv;
  wire        rate_req;
  wire [31:0] rate_dest;
  reg  [31:0] src_rate_inc;

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      rate_send <= 1'b0;
      rate_hold <= 32'd0;
    end else if (!rate_send && !rate_rcv) begin
      rate_hold <= dp_tpg_rate_inc;
      rate_send <= 1'b1;
    end else if (rate_send && rate_rcv) begin
      rate_send <= 1'b0;
    end
  end

  xpm_cdc_handshake #(
    .DEST_EXT_HSK   (0),
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_SYNC_FF    (SYNC_FF),
    .WIDTH          (32)
  ) u_cdc_rate (
    .src_clk  (dp_clk),
    .src_in   (rate_hold),
    .src_send (rate_send),
    .src_rcv  (rate_rcv),
    .dest_clk (src_clk),
    .dest_req (rate_req),
    .dest_ack (1'b0),
    .dest_out (rate_dest)
  );

  // Checker controls: CHK_CTRL.ENABLE level, CHK_CTRL.RESET pulse,
  // CHK_RATE_INC continuously re-sent coherent 32-bit word
  wire src_chk_enable;
  wire src_chk_rst_pulse;

  xpm_cdc_single #(
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (1)
  ) u_cdc_chk_en (
    .src_clk  (dp_clk),
    .src_in   (dp_chk_enable),
    .dest_clk (src_clk),
    .dest_out (src_chk_enable)
  );

  xpm_cdc_pulse #(
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .REG_OUTPUT     (1),
    .RST_USED       (0),
    .SIM_ASSERT_CHK (0)
  ) u_cdc_chk_rst (
    .src_clk    (dp_clk),
    .src_pulse  (dp_chk_reset),
    .src_rst    (1'b0),
    .dest_clk   (src_clk),
    .dest_rst   (1'b0),
    .dest_pulse (src_chk_rst_pulse)
  );

  reg         crate_send;
  reg  [31:0] crate_hold;
  wire        crate_rcv;
  wire        crate_req;
  wire [31:0] crate_dest;
  reg  [31:0] src_chk_rate_inc;

  always @(posedge dp_clk) begin
    if (!dp_resetn) begin
      crate_send <= 1'b0;
      crate_hold <= 32'd0;
    end else if (!crate_send && !crate_rcv) begin
      crate_hold <= dp_chk_rate_inc;
      crate_send <= 1'b1;
    end else if (crate_send && crate_rcv) begin
      crate_send <= 1'b0;
    end
  end

  xpm_cdc_handshake #(
    .DEST_EXT_HSK   (0),
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_SYNC_FF    (SYNC_FF),
    .WIDTH          (32)
  ) u_cdc_chk_rate (
    .src_clk  (dp_clk),
    .src_in   (crate_hold),
    .src_send (crate_send),
    .src_rcv  (crate_rcv),
    .dest_clk (src_clk),
    .dest_req (crate_req),
    .dest_ack (1'b0),
    .dest_out (crate_dest)
  );

  // ===========================================================================
  // src_clk domain
  // ===========================================================================

  // Source-side soft-reset window: power-on reset, then 64 cycles after every
  // SOFT_RST pulse. Resets the ingest FIFO and counters, parks the TPG.
  reg  [5:0] srst_win_cnt;
  reg        src_srst;

  always @(posedge src_clk) begin
    if (!src_resetn || src_srst_pulse) begin
      src_srst     <= 1'b1;
      srst_win_cnt <= 6'd0;
    end else if (src_srst) begin
      srst_win_cnt <= srst_win_cnt + 6'd1;
      if (srst_win_cnt == 6'd63)
        src_srst <= 1'b0;
    end
  end

  always @(posedge src_clk) begin
    if (!src_resetn)
      src_rate_inc <= 32'd0;
    else if (rate_req)
      src_rate_inc <= rate_dest;
  end

  // CHK_RATE_INC resets to 0x8000_0000 in the register block; until the first
  // transfer lands, the checker sees 0 (never ready) -- harmless, it is also
  // disabled then.
  always @(posedge src_clk) begin
    if (!src_resetn)
      src_chk_rate_inc <= 32'd0;
    else if (crate_req)
      src_chk_rate_inc <= crate_dest;
  end

  assign chk_enable   = src_chk_enable & ~src_srst;
  assign chk_reset    = src_chk_rst_pulse | src_srst;
  assign chk_rate_inc = src_chk_rate_inc;

  assign tpg_enable   = src_tpg_enable & ~src_srst;
  assign tpg_seq_rst  = src_seq_rst_pulse | src_srst;
  assign tpg_rate_inc = src_rate_inc;

  // Ingest
  wire [127:0] fifo_tdata;
  wire         fifo_tvalid;
  wire         fifo_tready;
  wire [63:0]  beats_in;
  wire [63:0]  drop_count;

  fdrec_ingest #(
    .FIFO_DEPTH (FIFO_DEPTH)
  ) u_ingest (
    .src_clk       (src_clk),
    .src_srst      (src_srst),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),
    .beats_in      (beats_in),
    .drop_count    (drop_count),
    .dp_clk        (dp_clk),
    .fifo_tdata    (fifo_tdata),
    .fifo_tvalid   (fifo_tvalid),
    .fifo_tready   (fifo_tready),
    .fifo_count    (fifo_count),
    .fifo_rst_busy (fifo_rst_busy)
  );

  // Snapshot {seq_next, beats_in, drop_count} -> dp_clk, continuously
  reg          snap_send;
  reg  [191:0] snap_hold;
  wire         snap_rcv;

  always @(posedge src_clk) begin
    if (!src_resetn) begin
      snap_send <= 1'b0;
      snap_hold <= 192'd0;
    end else if (!snap_send && !snap_rcv) begin
      snap_hold <= {tpg_seq_next, beats_in, drop_count};
      snap_send <= 1'b1;
    end else if (snap_send && snap_rcv) begin
      snap_send <= 1'b0;
    end
  end

  xpm_cdc_handshake #(
    .DEST_EXT_HSK   (0),
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_SYNC_FF    (SYNC_FF),
    .WIDTH          (192)
  ) u_cdc_snap (
    .src_clk  (src_clk),
    .src_in   (snap_hold),
    .src_send (snap_send),
    .src_rcv  (snap_rcv),
    .dest_clk (dp_clk),
    .dest_req (snap_valid),
    .dest_ack (1'b0),
    .dest_out (snap_data)
  );

  // Snapshot of the six checker counters -> dp_clk, continuously
  reg          csnap_send;
  reg  [383:0] csnap_hold;
  wire         csnap_rcv;

  always @(posedge src_clk) begin
    if (!src_resetn) begin
      csnap_send <= 1'b0;
      csnap_hold <= 384'd0;
    end else if (!csnap_send && !csnap_rcv) begin
      csnap_hold <= {chk_beats, chk_errors, chk_gaps, chk_gap_beats, chk_underflows, chk_last_seq};
      csnap_send <= 1'b1;
    end else if (csnap_send && csnap_rcv) begin
      csnap_send <= 1'b0;
    end
  end

  xpm_cdc_handshake #(
    .DEST_EXT_HSK   (0),
    .DEST_SYNC_FF   (SYNC_FF),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_SYNC_FF    (SYNC_FF),
    .WIDTH          (384)
  ) u_cdc_chk_snap (
    .src_clk  (src_clk),
    .src_in   (csnap_hold),
    .src_send (csnap_send),
    .src_rcv  (csnap_rcv),
    .dest_clk (dp_clk),
    .dest_req (chk_snap_valid),
    .dest_ack (1'b0),
    .dest_out (chk_snap_data)
  );

  // ===========================================================================
  // dp_clk domain: egress (playback) FIFO
  // ===========================================================================
  // FIFO reset window: power-on, then 32 dp_clk cycles at the start of every
  // SOFT_RST (the register block keeps SOFT_RST busy until the write side of
  // the FIFO reports it is out of reset).
  reg  [4:0] egr_rst_cnt;
  reg        egr_fifo_rst;

  always @(posedge dp_clk) begin
    if (!dp_resetn || dp_srst_pulse) begin
      egr_fifo_rst <= 1'b1;
      egr_rst_cnt  <= 5'd0;
    end else if (egr_fifo_rst) begin
      egr_rst_cnt <= egr_rst_cnt + 5'd1;
      if (egr_rst_cnt == 5'd31)
        egr_fifo_rst <= 1'b0;
    end
  end

  fdrec_egress #(
    .FIFO_DEPTH (EGR_FIFO_DEPTH)
  ) u_egress (
    .dp_clk        (dp_clk),
    .fifo_rst      (egr_fifo_rst),
    .srst          (~dp_resetn | dp_srst),
    .flush         (egr_flush),
    .s_axis_tdata  (s_axis_mm2s_tdata),
    .s_axis_tkeep  (s_axis_mm2s_tkeep),
    .s_axis_tlast  (s_axis_mm2s_tlast),
    .s_axis_tvalid (s_axis_mm2s_tvalid),
    .s_axis_tready (s_axis_mm2s_tready),
    .beats_in      (egr_beats_in),
    .discard_count (egr_discard),
    .fifo_level    (egr_level),
    .wr_rst_busy   (egr_wr_rst_busy),
    .src_clk       (src_clk),
    .m_axis_tdata  (m_axis_snk_tdata),
    .m_axis_tlast  (m_axis_snk_tlast),
    .m_axis_tvalid (m_axis_snk_tvalid),
    .m_axis_tready (m_axis_snk_tready)
  );

  // ===========================================================================
  // dp_clk domain: packetizer
  // ===========================================================================
  fdrec_packetizer u_pkt (
    .clk           (dp_clk),
    .srst          (~dp_resetn | dp_srst),
    .enable        (pkt_enable),
    .pkt_len       (pkt_len),
    .beats_out     (beats_out),
    .s_tdata       (fifo_tdata),
    .s_tvalid      (fifo_tvalid),
    .s_tready      (fifo_tready),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tkeep  (m_axis_tkeep),
    .m_axis_tlast  (m_axis_tlast),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
  );

endmodule
