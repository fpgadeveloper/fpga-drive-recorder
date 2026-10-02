// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_fdrec_tpg -- self-checking testbench for fdrec_tpg
//
// Checks:
//   * pattern: every beat has TDATA[127:64] == ~TDATA[63:0] and TDATA[63:0] ==
//     the expected sequence number (contiguous from 0)
//   * TREADY is ignored (held low for the whole test; the TPG keeps emitting)
//   * rate accuracy within 1% (and within 2 beats) for 6 rates incl. the
//     maximum and a clamped value above the maximum
//   * tpg_seq_next readback == number of beats emitted
//   * tpg_seq_rst returns seq to 0; tpg_enable = 0 stops emission
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_fdrec_tpg;

  reg          clk = 1'b0;
  reg          resetn = 1'b0;
  reg          tpg_enable = 1'b0;
  reg          tpg_seq_rst = 1'b0;
  reg  [31:0]  tpg_rate_inc = 32'd0;
  wire [63:0]  tpg_seq_next;
  wire [127:0] tdata;
  wire         tvalid;

  always #2.5 clk = ~clk;   // 200 MHz

  fdrec_tpg dut (
    .src_clk       (clk),
    .src_resetn    (resetn),
    .tpg_enable    (tpg_enable),
    .tpg_seq_rst   (tpg_seq_rst),
    .tpg_rate_inc  (tpg_rate_inc),
    .tpg_seq_next  (tpg_seq_next),
    .m_axis_tdata  (tdata),
    .m_axis_tvalid (tvalid),
    .m_axis_tready (1'b0)            // ignored by design
  );

  integer errors = 0;
  task automatic fail(input string msg);
    begin
      $display("FAIL: %s (t=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Monitor: pattern + contiguity, beat counter
  // ---------------------------------------------------------------------------
  reg  [63:0] exp_seq = 64'd0;
  longint     beats = 0;

  always @(posedge clk) begin
    if (tvalid) begin
      if (tdata[127:64] !== ~tdata[63:0])
        fail($sformatf("pattern: upper %h != ~lower %h", tdata[127:64], tdata[63:0]));
      if (tdata[63:0] !== exp_seq)
        fail($sformatf("sequence: got %0d expected %0d", tdata[63:0], exp_seq));
      exp_seq <= tdata[63:0] + 64'd1;
      beats   <= beats + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Rate measurement
  // ---------------------------------------------------------------------------
  task automatic measure_rate(input [31:0] inc, input integer ncyc);
    longint b0, b1, got;
    real    frac, expect_b, err_pct;
    begin
      tpg_rate_inc = inc;
      repeat (4) @(posedge clk);       // let the increment register settle
      b0 = beats;
      @(negedge clk) tpg_enable = 1'b1;
      repeat (ncyc) @(posedge clk);
      @(negedge clk) tpg_enable = 1'b0;
      repeat (4) @(posedge clk);       // flush the output register
      b1  = beats;
      got = b1 - b0;
      frac = (inc > 32'h8000_0000) ? 1.0 : (inc / 2147483648.0);
      expect_b = ncyc * frac;
      err_pct = (expect_b > 0) ? 100.0 * (got - expect_b) / expect_b : 0.0;
      if (err_pct < 0) err_pct = -err_pct;
      $display("rate: inc=0x%08h  beats/clk expected %f  measured %f  (%0d beats in %0d clk, err %0.4f%%)",
               inc, frac, got * 1.0 / ncyc, got, ncyc, err_pct);
      if (err_pct > 1.0)
        fail($sformatf("rate error %0.4f%% > 1%% for inc=0x%08h", err_pct, inc));
      if ((got - expect_b > 2.0) || (expect_b - got > 2.0))
        fail($sformatf("rate off by more than 2 beats for inc=0x%08h", inc));
    end
  endtask

  initial begin
    repeat (10) @(posedge clk);
    @(negedge clk) resetn = 1'b1;
    repeat (5) @(posedge clk);

    // Disabled: no output even with a rate set
    tpg_rate_inc = 32'h8000_0000;
    repeat (100) @(posedge clk);
    if (beats != 0) fail("beats emitted while disabled");

    measure_rate(32'h8000_0000, 20000);   // 1 beat/clk (max)
    measure_rate(32'hFFFF_FFFF, 20000);   // clamps to max
    measure_rate(32'h4000_0000, 40000);   // 0.5
    measure_rate(32'h1999_999A, 50000);   // 0.2
    measure_rate(32'h0147_AE14, 400000);  // 0.01
    measure_rate(32'h6666_6666, 50000);   // 0.8

    // Readback: seq_next == beats emitted so far (contiguous from 0)
    if (tpg_seq_next !== beats[63:0])
      fail($sformatf("tpg_seq_next %0d != beats emitted %0d", tpg_seq_next, beats));
    else
      $display("seq_next readback ok: %0d", tpg_seq_next);

    // Sequence reset: seq returns to 0, next beat carries 0
    @(negedge clk) tpg_seq_rst = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk) tpg_seq_rst = 1'b0;
    @(posedge clk);
    if (tpg_seq_next !== 64'd0) fail("seq not reset by tpg_seq_rst");
    exp_seq = 64'd0;
    measure_rate(32'h8000_0000, 1000);
    if (tpg_seq_next !== 64'd1000)
      fail($sformatf("after seq_rst + 1000 beats, seq_next = %0d", tpg_seq_next));

    // seq_rst while enabled holds output off
    @(negedge clk) begin tpg_enable = 1'b1; tpg_seq_rst = 1'b1; end
    begin : hold_chk
      longint b0;
      b0 = beats;
      repeat (50) @(posedge clk);
      if (beats - b0 > 1) fail("beats emitted while tpg_seq_rst held");
    end
    @(negedge clk) begin tpg_enable = 1'b0; tpg_seq_rst = 1'b0; end
    exp_seq = 64'd0;
    repeat (5) @(posedge clk);

    if (errors == 0) $display("PASS: tb_fdrec_tpg (%0d beats checked)", beats);
    else             $display("FAIL: tb_fdrec_tpg (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("FAIL: tb_fdrec_tpg watchdog timeout");
    $finish;
  end

endmodule
