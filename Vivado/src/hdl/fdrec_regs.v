// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_regs -- AXI4-Lite register block of fdrec_core (dp_clk domain)
//
// Implements the register map in include/fdrec_regs.h (documented in
// docs/source/register_map.md). Keep the three in sync.
//
// All inputs/outputs are in the dp_clk (AXI-Lite) clock domain. Values from the
// src_clk domain (seq_next, beats_in, drop_count) arrive here as one consistent
// snapshot (snap_*), refreshed continuously by fdrec_core; snap_valid pulses
// when a new snapshot is loaded.
//
//   * 64-bit counters: reading *_LO returns the low half and latches the high
//     half of the SAME value; *_HI returns the latched half.
//   * ING_STATUS.OVERFLOW is set when a new snapshot shows the drop counter has
//     changed (and is non-zero); write 1 to clear.
//   * ING_FIFO_HWM tracks the maximum FIFO occupancy seen from dp_clk; any write
//     clears it.
//   * GLOBAL_CTRL.SOFT_RST starts a soft reset sequence: srst_pulse (1 cycle,
//     crossed to src_clk by fdrec_core) resets the FIFO and the source-side
//     counters and holds the TPG in seq reset; locally TPG/packetizer enables,
//     HWM, OVERFLOW, snapshots and beats_out (via srst) are cleared. The bit
//     reads 1 until the sequence is complete (at least 128 dp_clk cycles and
//     until the FIFO read side is out of reset), then 0. Writes of SOFT_RST
//     while it is in progress are ignored.
//   * Playback (1.1): CHK_* registers control the checker (fdrec_check, src_clk
//     domain, outside fdrec_core) and read back its counters as one coherent
//     snapshot (chk_snap_*). CHK_CTRL.RESET clears the local copies and ignores
//     snapshots for CHK_RST_CYCLES dp_clk cycles (it reads 1 meanwhile), so no
//     stale pre-reset snapshot can reappear. EGR_* registers belong to the
//     egress FIFO (dp_clk domain). SOFT_RST also disables the checker, clears
//     EGR_CTRL.FLUSH and all CHK_/EGR_ counters; CHK_RATE_INC survives.

`timescale 1ns / 1ps

module fdrec_regs #(
  parameter integer SRC_CLK_HZ = 200000000,
  parameter integer DP_CLK_HZ  = 250000000,
  parameter integer FIFO_DEPTH = 4096,
  parameter integer CNT_W      = 13,
  parameter integer EGR_FIFO_DEPTH = 4096,
  parameter integer EGR_CNT_W  = 13,
  parameter [31:0]  VERSION    = 32'h0001_0001
) (
  input  wire          clk,
  input  wire          resetn,

  // AXI4-Lite slave
  input  wire [11:0]   s_axi_awaddr,
  input  wire [2:0]    s_axi_awprot,
  input  wire          s_axi_awvalid,
  output reg           s_axi_awready,
  input  wire [31:0]   s_axi_wdata,
  input  wire [3:0]    s_axi_wstrb,
  input  wire          s_axi_wvalid,
  output reg           s_axi_wready,
  output wire [1:0]    s_axi_bresp,
  output reg           s_axi_bvalid,
  input  wire          s_axi_bready,
  input  wire [11:0]   s_axi_araddr,
  input  wire [2:0]    s_axi_arprot,
  input  wire          s_axi_arvalid,
  output reg           s_axi_arready,
  output reg  [31:0]   s_axi_rdata,
  output wire [1:0]    s_axi_rresp,
  output reg           s_axi_rvalid,
  input  wire          s_axi_rready,

  // Snapshot of the src_clk-domain values
  input  wire          snap_valid,
  input  wire [63:0]   snap_seq_next,
  input  wire [63:0]   snap_beats_in,
  input  wire [63:0]   snap_drop_count,

  // dp_clk-domain status
  input  wire [CNT_W-1:0] fifo_count,
  input  wire          fifo_rst_busy,
  input  wire [63:0]   beats_out,

  // Controls
  output reg           tpg_enable,
  output reg           tpg_seq_rst,     // 1-cycle pulse
  output reg  [31:0]   tpg_rate_inc,
  output reg           pkt_enable,
  output reg  [31:0]   pkt_len,
  output reg           srst_pulse,      // 1-cycle pulse: start of soft reset
  output reg           srst,            // level: soft reset in progress

  // Playback checker: snapshot of the src_clk-domain counters
  input  wire          chk_snap_valid,
  input  wire [63:0]   snap_chk_beats,
  input  wire [63:0]   snap_chk_errors,
  input  wire [63:0]   snap_chk_gaps,
  input  wire [63:0]   snap_chk_gap_beats,
  input  wire [63:0]   snap_chk_underflows,
  input  wire [63:0]   snap_chk_last_seq,
  output reg           chk_enable,
  output reg           chk_reset,       // 1-cycle pulse
  output reg  [31:0]   chk_rate_inc,

  // Egress FIFO (dp_clk domain)
  output reg           egr_flush,
  input  wire [63:0]   egr_beats_in,
  input  wire [63:0]   egr_discard,
  input  wire [EGR_CNT_W-1:0] egr_level
);

  // Register offsets (include/fdrec_regs.h)
  localparam [11:0] R_VERSION         = 12'h000;
  localparam [11:0] R_SRC_CLK_HZ      = 12'h004;
  localparam [11:0] R_DP_CLK_HZ       = 12'h008;
  localparam [11:0] R_GLOBAL_CTRL     = 12'h00C;
  localparam [11:0] R_TPG_CTRL        = 12'h010;
  localparam [11:0] R_TPG_RATE_INC    = 12'h014;
  localparam [11:0] R_TPG_SEQ_NEXT_LO = 12'h018;
  localparam [11:0] R_TPG_SEQ_NEXT_HI = 12'h01C;
  localparam [11:0] R_ING_STATUS      = 12'h020;
  localparam [11:0] R_ING_FIFO_HWM    = 12'h024;
  localparam [11:0] R_ING_DROP_LO     = 12'h028;
  localparam [11:0] R_ING_DROP_HI     = 12'h02C;
  localparam [11:0] R_ING_IN_LO       = 12'h030;
  localparam [11:0] R_ING_IN_HI       = 12'h034;
  localparam [11:0] R_ING_FIFO_DEPTH  = 12'h038;
  localparam [11:0] R_PKT_CTRL        = 12'h040;
  localparam [11:0] R_PKT_LEN         = 12'h044;
  localparam [11:0] R_PKT_OUT_LO      = 12'h048;
  localparam [11:0] R_PKT_OUT_HI      = 12'h04C;
  // Playback (1.1)
  localparam [11:0] R_CHK_CTRL        = 12'h060;
  localparam [11:0] R_CHK_RATE_INC    = 12'h064;
  localparam [11:0] R_CHK_BEATS_LO    = 12'h070;
  localparam [11:0] R_CHK_BEATS_HI    = 12'h074;
  localparam [11:0] R_CHK_ERRORS_LO   = 12'h078;
  localparam [11:0] R_CHK_ERRORS_HI   = 12'h07C;
  localparam [11:0] R_CHK_GAPS_LO     = 12'h080;
  localparam [11:0] R_CHK_GAPS_HI     = 12'h084;
  localparam [11:0] R_CHK_GAPB_LO     = 12'h088;
  localparam [11:0] R_CHK_GAPB_HI     = 12'h08C;
  localparam [11:0] R_CHK_UNDER_LO    = 12'h090;
  localparam [11:0] R_CHK_UNDER_HI    = 12'h094;
  localparam [11:0] R_CHK_LAST_LO     = 12'h098;
  localparam [11:0] R_CHK_LAST_HI     = 12'h09C;
  localparam [11:0] R_EGR_CTRL        = 12'h0A0;
  localparam [11:0] R_EGR_FIFO_DEPTH  = 12'h0A4;
  localparam [11:0] R_EGR_IN_LO       = 12'h0A8;
  localparam [11:0] R_EGR_IN_HI       = 12'h0AC;
  localparam [11:0] R_EGR_DISC_LO     = 12'h0B0;
  localparam [11:0] R_EGR_DISC_HI     = 12'h0B4;
  localparam [11:0] R_EGR_FIFO_LEVEL  = 12'h0B8;

  localparam [31:0] CHK_RATE_RESET  = 32'h8000_0000;  // always ready
  localparam integer CHK_RST_CYCLES = 256;

  localparam [31:0] PKT_LEN_RESET = 32'h0008_0000;  // 8 MB / 16 B
  localparam integer SRST_MIN_CYCLES = 128;

  assign s_axi_bresp = 2'b00;
  assign s_axi_rresp = 2'b00;

  // ---------------------------------------------------------------------------
  // Write channel
  // ---------------------------------------------------------------------------
  wire        wr_fire = s_axi_awready & s_axi_awvalid & s_axi_wready & s_axi_wvalid;
  wire [11:0] wr_addr = {s_axi_awaddr[11:2], 2'b00};

  always @(posedge clk) begin
    if (!resetn) begin
      s_axi_awready <= 1'b0;
      s_axi_wready  <= 1'b0;
      s_axi_bvalid  <= 1'b0;
    end else begin
      if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
      end else begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
      end
      if (wr_fire)
        s_axi_bvalid <= 1'b1;
      else if (s_axi_bready)
        s_axi_bvalid <= 1'b0;
    end
  end

  wire wr_b0 = wr_fire & s_axi_wstrb[0];

  // ---------------------------------------------------------------------------
  // Soft reset sequencer
  // ---------------------------------------------------------------------------
  reg [7:0] srst_cnt;
  wire srst_start = wr_b0 && (wr_addr == R_GLOBAL_CTRL) && s_axi_wdata[0] && !srst;

  always @(posedge clk) begin
    if (!resetn) begin
      srst       <= 1'b0;
      srst_pulse <= 1'b0;
      srst_cnt   <= 8'd0;
    end else begin
      srst_pulse <= srst_start;
      if (srst_start) begin
        srst     <= 1'b1;
        srst_cnt <= 8'd0;
      end else if (srst) begin
        if (srst_cnt != SRST_MIN_CYCLES[7:0] - 8'd1)
          srst_cnt <= srst_cnt + 8'd1;
        else if (!fifo_rst_busy)
          srst <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Control registers
  // ---------------------------------------------------------------------------
  reg  [8:0]  chk_rst_cnt;
  reg         chk_rst_busy;   // CHK_CTRL.RESET in progress

  integer i;
  always @(posedge clk) begin
    if (!resetn) begin
      tpg_enable   <= 1'b0;
      tpg_seq_rst  <= 1'b0;
      tpg_rate_inc <= 32'd0;
      pkt_enable   <= 1'b0;
      pkt_len      <= PKT_LEN_RESET;
      chk_enable   <= 1'b0;
      chk_reset    <= 1'b0;
      chk_rate_inc <= CHK_RATE_RESET;
      egr_flush    <= 1'b0;
    end else begin
      tpg_seq_rst <= 1'b0;
      chk_reset   <= 1'b0;
      if (srst_start) begin
        tpg_enable <= 1'b0;
        pkt_enable <= 1'b0;
        chk_enable <= 1'b0;
        egr_flush  <= 1'b0;
      end else if (wr_fire) begin
        case (wr_addr)
          R_TPG_CTRL: if (s_axi_wstrb[0]) begin
            tpg_enable  <= s_axi_wdata[0];
            tpg_seq_rst <= s_axi_wdata[1];
          end
          R_TPG_RATE_INC:
            for (i = 0; i < 4; i = i + 1)
              if (s_axi_wstrb[i]) tpg_rate_inc[8*i +: 8] <= s_axi_wdata[8*i +: 8];
          R_PKT_CTRL: if (s_axi_wstrb[0])
            pkt_enable <= s_axi_wdata[0];
          R_PKT_LEN:
            for (i = 0; i < 4; i = i + 1)
              if (s_axi_wstrb[i]) pkt_len[8*i +: 8] <= s_axi_wdata[8*i +: 8];
          R_CHK_CTRL: if (s_axi_wstrb[0]) begin
            chk_enable <= s_axi_wdata[0];
            chk_reset  <= s_axi_wdata[1] & ~chk_rst_busy;
          end
          R_CHK_RATE_INC:
            for (i = 0; i < 4; i = i + 1)
              if (s_axi_wstrb[i]) chk_rate_inc[8*i +: 8] <= s_axi_wdata[8*i +: 8];
          R_EGR_CTRL: if (s_axi_wstrb[0])
            egr_flush <= s_axi_wdata[0];
          default: ;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Status: snapshot of the src_clk values, OVERFLOW, HWM
  // ---------------------------------------------------------------------------
  reg [63:0]      seq_next_q, beats_in_q, drop_q;
  reg             overflow;
  reg [CNT_W-1:0] hwm;

  wire ovf_clr = wr_b0 && (wr_addr == R_ING_STATUS) && s_axi_wdata[0];
  wire hwm_clr = wr_fire && (wr_addr == R_ING_FIFO_HWM);
  wire ovf_set = snap_valid && !srst && (snap_drop_count != drop_q) &&
                 (snap_drop_count != 64'd0);

  always @(posedge clk) begin
    if (!resetn || srst_start) begin
      seq_next_q <= 64'd0;
      beats_in_q <= 64'd0;
      drop_q     <= 64'd0;
      overflow   <= 1'b0;
      hwm        <= {CNT_W{1'b0}};
    end else begin
      if (snap_valid && !srst) begin
        seq_next_q <= snap_seq_next;
        beats_in_q <= snap_beats_in;
        drop_q     <= snap_drop_count;
      end
      if (ovf_set)
        overflow <= 1'b1;
      else if (ovf_clr)
        overflow <= 1'b0;
      if (hwm_clr || srst)
        hwm <= {CNT_W{1'b0}};
      else if (fifo_count > hwm)
        hwm <= fifo_count;
    end
  end

  // ---------------------------------------------------------------------------
  // Checker snapshot. CHK_CTRL.RESET (and SOFT_RST) clear the local copies and
  // block snapshot updates for CHK_RST_CYCLES so that a snapshot taken before
  // the reset reached the checker cannot reappear.
  // ---------------------------------------------------------------------------
  reg  [63:0] chk_beats_q, chk_err_q, chk_gaps_q, chk_gapb_q, chk_under_q, chk_last_q;

  always @(posedge clk) begin
    if (!resetn || srst_start || chk_reset) begin
      chk_rst_busy <= chk_reset;
      chk_rst_cnt  <= 9'd0;
      chk_beats_q  <= 64'd0;
      chk_err_q    <= 64'd0;
      chk_gaps_q   <= 64'd0;
      chk_gapb_q   <= 64'd0;
      chk_under_q  <= 64'd0;
      chk_last_q   <= 64'd0;
    end else begin
      if (chk_rst_busy) begin
        chk_rst_cnt <= chk_rst_cnt + 9'd1;
        if (chk_rst_cnt == CHK_RST_CYCLES[8:0] - 9'd1)
          chk_rst_busy <= 1'b0;
      end
      if (chk_snap_valid && !srst && !chk_rst_busy) begin
        chk_beats_q <= snap_chk_beats;
        chk_err_q   <= snap_chk_errors;
        chk_gaps_q  <= snap_chk_gaps;
        chk_gapb_q  <= snap_chk_gap_beats;
        chk_under_q <= snap_chk_underflows;
        chk_last_q  <= snap_chk_last_seq;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read channel
  // ---------------------------------------------------------------------------
  reg [31:0] seq_hi_l, drop_hi_l, in_hi_l, out_hi_l;
  reg [31:0] cb_hi_l, ce_hi_l, cg_hi_l, cgb_hi_l, cu_hi_l, cl_hi_l, ei_hi_l, ed_hi_l;
  wire [11:0] rd_addr = {s_axi_araddr[11:2], 2'b00};
  wire        rd_fire = s_axi_arready & s_axi_arvalid;

  always @(posedge clk) begin
    if (!resetn) begin
      s_axi_arready <= 1'b0;
      s_axi_rvalid  <= 1'b0;
      s_axi_rdata   <= 32'd0;
      seq_hi_l      <= 32'd0;
      drop_hi_l     <= 32'd0;
      in_hi_l       <= 32'd0;
      out_hi_l      <= 32'd0;
      cb_hi_l       <= 32'd0;
      ce_hi_l       <= 32'd0;
      cg_hi_l       <= 32'd0;
      cgb_hi_l      <= 32'd0;
      cu_hi_l       <= 32'd0;
      cl_hi_l       <= 32'd0;
      ei_hi_l       <= 32'd0;
      ed_hi_l       <= 32'd0;
    end else begin
      if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid)
        s_axi_arready <= 1'b1;
      else
        s_axi_arready <= 1'b0;

      if (rd_fire) begin
        s_axi_rvalid <= 1'b1;
        case (rd_addr)
          R_VERSION:         s_axi_rdata <= VERSION;
          R_SRC_CLK_HZ:      s_axi_rdata <= SRC_CLK_HZ;
          R_DP_CLK_HZ:       s_axi_rdata <= DP_CLK_HZ;
          R_GLOBAL_CTRL:     s_axi_rdata <= {31'd0, srst};
          R_TPG_CTRL:        s_axi_rdata <= {30'd0, 1'b0, tpg_enable};
          R_TPG_RATE_INC:    s_axi_rdata <= tpg_rate_inc;
          R_TPG_SEQ_NEXT_LO: begin s_axi_rdata <= seq_next_q[31:0]; seq_hi_l  <= seq_next_q[63:32]; end
          R_TPG_SEQ_NEXT_HI: s_axi_rdata <= seq_hi_l;
          R_ING_STATUS:      s_axi_rdata <= {31'd0, overflow};
          R_ING_FIFO_HWM:    s_axi_rdata <= hwm;
          R_ING_DROP_LO:     begin s_axi_rdata <= drop_q[31:0];     drop_hi_l <= drop_q[63:32]; end
          R_ING_DROP_HI:     s_axi_rdata <= drop_hi_l;
          R_ING_IN_LO:       begin s_axi_rdata <= beats_in_q[31:0]; in_hi_l   <= beats_in_q[63:32]; end
          R_ING_IN_HI:       s_axi_rdata <= in_hi_l;
          R_ING_FIFO_DEPTH:  s_axi_rdata <= FIFO_DEPTH;
          R_PKT_CTRL:        s_axi_rdata <= {31'd0, pkt_enable};
          R_PKT_LEN:         s_axi_rdata <= pkt_len;
          R_PKT_OUT_LO:      begin s_axi_rdata <= beats_out[31:0]; out_hi_l  <= beats_out[63:32]; end
          R_PKT_OUT_HI:      s_axi_rdata <= out_hi_l;
          R_CHK_CTRL:        s_axi_rdata <= {30'd0, chk_rst_busy, chk_enable};
          R_CHK_RATE_INC:    s_axi_rdata <= chk_rate_inc;
          R_CHK_BEATS_LO:    begin s_axi_rdata <= chk_beats_q[31:0]; cb_hi_l  <= chk_beats_q[63:32]; end
          R_CHK_BEATS_HI:    s_axi_rdata <= cb_hi_l;
          R_CHK_ERRORS_LO:   begin s_axi_rdata <= chk_err_q[31:0];   ce_hi_l  <= chk_err_q[63:32]; end
          R_CHK_ERRORS_HI:   s_axi_rdata <= ce_hi_l;
          R_CHK_GAPS_LO:     begin s_axi_rdata <= chk_gaps_q[31:0];  cg_hi_l  <= chk_gaps_q[63:32]; end
          R_CHK_GAPS_HI:     s_axi_rdata <= cg_hi_l;
          R_CHK_GAPB_LO:     begin s_axi_rdata <= chk_gapb_q[31:0];  cgb_hi_l <= chk_gapb_q[63:32]; end
          R_CHK_GAPB_HI:     s_axi_rdata <= cgb_hi_l;
          R_CHK_UNDER_LO:    begin s_axi_rdata <= chk_under_q[31:0]; cu_hi_l  <= chk_under_q[63:32]; end
          R_CHK_UNDER_HI:    s_axi_rdata <= cu_hi_l;
          R_CHK_LAST_LO:     begin s_axi_rdata <= chk_last_q[31:0];  cl_hi_l  <= chk_last_q[63:32]; end
          R_CHK_LAST_HI:     s_axi_rdata <= cl_hi_l;
          R_EGR_CTRL:        s_axi_rdata <= {31'd0, egr_flush};
          R_EGR_FIFO_DEPTH:  s_axi_rdata <= EGR_FIFO_DEPTH;
          R_EGR_IN_LO:       begin s_axi_rdata <= egr_beats_in[31:0]; ei_hi_l <= egr_beats_in[63:32]; end
          R_EGR_IN_HI:       s_axi_rdata <= ei_hi_l;
          R_EGR_DISC_LO:     begin s_axi_rdata <= egr_discard[31:0];  ed_hi_l <= egr_discard[63:32]; end
          R_EGR_DISC_HI:     s_axi_rdata <= ed_hi_l;
          R_EGR_FIFO_LEVEL:  s_axi_rdata <= egr_level;
          default:           s_axi_rdata <= 32'd0;
        endcase
      end else if (s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

endmodule
