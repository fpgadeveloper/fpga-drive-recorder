// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_check -- FPGA Drive Recorder playback checker (data sink)
//
// Models a DAC-like data sink that consumes at a fixed average rate and checks
// the test pattern written by fdrec_tpg:
//
//   * s_axis_tready is asserted on a rate-throttle tick: a 31-bit fractional
//     accumulator advanced by chk_rate_inc (Q1.31 beats per snk_clk cycle,
//     0x8000_0000 = ready on every clock = the maximum; larger values clamp),
//     the same scheme as fdrec_tpg. While chk_enable is low, tready is low.
//   * Every accepted beat (tvalid & tready) is checked:
//       - pattern: TDATA[127:64] must equal ~TDATA[63:0]. A beat that fails is
//         counted in ERRORS and is NOT used for sequence tracking (the expected
//         sequence number simply advances by one), so a single corrupted beat
//         counts exactly one ERROR and never a phantom gap.
//       - sequence (pattern-good beats): seq = TDATA[63:0] is compared with the
//         expected number. The first good beat after a reset defines it.
//         seq == expected : OK
//         seq >  expected : GAPS += 1, GAP_BEATS += seq - expected
//         seq <  expected : ERRORS += 1 (sequence went backwards)
//         after the beat  : expected := seq + 1
//   * UNDERFLOWS counts throttle ticks on which tvalid was low, after the first
//     beat, while enabled -- but only ticks that are FOLLOWED by another beat
//     (starvation inside the stream). Ticks after the last beat of a stream are
//     held as pending and committed only if more data arrives, so the trailing
//     idle time after a playback never counts as underflow.
//   * BEATS counts accepted beats; LAST_SEQ is TDATA[63:0] of the last accepted
//     pattern-good beat.
//   * chk_reset (level, active high) clears all counters, the expected
//     sequence number, the throttle accumulator and the pipeline.
//   * s_axis_tlast is accepted and ignored.
//
// All signals are in the snk_clk domain. fdrec_core synchronises the controls
// (chk_enable, chk_reset, chk_rate_inc) into snk_clk (= src_clk) and samples
// the counters back into its register clock domain as one coherent snapshot.
//
// This module lives in the user_data_sink block-design hierarchy, which is the
// documented insertion point for a customer's own data sink (DAC, ...).

`timescale 1ns / 1ps

module fdrec_check (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 snk_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis, ASSOCIATED_RESET snk_resetn" *)
  input  wire         snk_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 snk_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire         snk_resetn,

  // Control (snk_clk domain)
  input  wire         chk_enable,
  input  wire         chk_reset,
  input  wire [31:0]  chk_rate_inc,

  // Counters (snk_clk domain)
  output reg  [63:0]  chk_beats,
  output reg  [63:0]  chk_errors,
  output reg  [63:0]  chk_gaps,
  output reg  [63:0]  chk_gap_beats,
  output reg  [63:0]  chk_underflows,
  output reg  [63:0]  chk_last_seq,

  // AXI4-Stream slave
  input  wire [127:0] s_axis_tdata,
  input  wire         s_axis_tvalid,
  output reg          s_axis_tready,
  input  wire         s_axis_tlast
);

  localparam [31:0] INC_ONE = 32'h8000_0000;

  wire rst = ~snk_resetn | chk_reset;

  // ---------------------------------------------------------------------------
  // Rate throttle: tready on every carry out of the 31-bit accumulator
  // ---------------------------------------------------------------------------
  reg  [31:0] inc_q;
  reg  [30:0] acc;
  wire [31:0] sum = {1'b0, acc} + inc_q;

  always @(posedge snk_clk) begin
    if (!snk_resetn)
      inc_q <= 32'd0;
    else
      inc_q <= (chk_rate_inc > INC_ONE) ? INC_ONE : chk_rate_inc;
  end

  always @(posedge snk_clk) begin
    if (rst) begin
      acc           <= 31'd0;
      s_axis_tready <= 1'b0;
    end else if (chk_enable) begin
      acc           <= sum[30:0];
      s_axis_tready <= sum[31];
    end else begin
      s_axis_tready <= 1'b0;
    end
  end

  wire accept = s_axis_tvalid & s_axis_tready;
  wire starve = ~s_axis_tvalid & s_axis_tready;   // a tick with no data

  // ---------------------------------------------------------------------------
  // Stage A: register the accepted beat, pattern check, seq + 1
  // ---------------------------------------------------------------------------
  reg         a_v;
  reg         a_pat_ok;
  reg  [63:0] a_seq;
  reg  [63:0] a_seq_p1;

  always @(posedge snk_clk) begin
    if (rst) begin
      a_v      <= 1'b0;
      a_pat_ok <= 1'b0;
      a_seq    <= 64'd0;
      a_seq_p1 <= 64'd0;
    end else begin
      a_v <= accept;
      if (accept) begin
        a_pat_ok <= (s_axis_tdata[127:64] == ~s_axis_tdata[63:0]);
        a_seq    <= s_axis_tdata[63:0];
        a_seq_p1 <= s_axis_tdata[63:0] + 64'd1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage B: sequence check against the expected number
  // ---------------------------------------------------------------------------
  reg         have_exp;     // expected sequence number is defined
  reg  [63:0] expected;
  reg         b_v, b_err, b_gap;
  reg  [63:0] b_gap_len;
  reg         started;      // a beat has been accepted since the reset
  reg  [63:0] uf_pending;   // starvation ticks not yet followed by a beat

  always @(posedge snk_clk) begin
    if (rst) begin
      have_exp     <= 1'b0;
      expected     <= 64'd0;
      b_v          <= 1'b0;
      b_err        <= 1'b0;
      b_gap        <= 1'b0;
      b_gap_len    <= 64'd0;
      chk_last_seq <= 64'd0;
    end else begin
      b_v   <= a_v;
      b_err <= 1'b0;
      b_gap <= 1'b0;
      if (a_v) begin
        if (!a_pat_ok) begin
          b_err <= 1'b1;
          if (have_exp) expected <= expected + 64'd1;
        end else begin
          chk_last_seq <= a_seq;
          have_exp     <= 1'b1;
          expected     <= a_seq_p1;
          if (have_exp) begin
            if (a_seq < expected)
              b_err <= 1'b1;
            else if (a_seq != expected)
              b_gap <= 1'b1;
          end
        end
        b_gap_len <= a_seq - expected;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Counters
  // ---------------------------------------------------------------------------
  always @(posedge snk_clk) begin
    if (rst) begin
      started        <= 1'b0;
      uf_pending     <= 64'd0;
      chk_beats      <= 64'd0;
      chk_errors     <= 64'd0;
      chk_gaps       <= 64'd0;
      chk_gap_beats  <= 64'd0;
      chk_underflows <= 64'd0;
    end else begin
      if (accept) begin
        started    <= 1'b1;
        chk_beats  <= chk_beats + 64'd1;
        // starvation ticks followed by this beat are real underflows
        chk_underflows <= chk_underflows + uf_pending;
        uf_pending     <= 64'd0;
      end else if (starve && started && chk_enable) begin
        uf_pending <= uf_pending + 64'd1;
      end
      if (b_v && b_err) chk_errors <= chk_errors + 64'd1;
      if (b_v && b_gap) begin
        chk_gaps      <= chk_gaps + 64'd1;
        chk_gap_beats <= chk_gap_beats + b_gap_len;
      end
    end
  end

endmodule
