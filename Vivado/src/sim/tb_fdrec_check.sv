// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_fdrec_check -- self-checking testbench for the playback path
//
// AXI DMA MM2S model (dp_clk 250 MHz) -> fdrec_core egress FIFO -> fdrec_check
// (src_clk 200 MHz), wired as in the block design, registers driven through an
// AXI4-Lite BFM. The DMA model emits the TPG pattern (TDATA[63:0] = seq,
// TDATA[127:64] = ~seq) with TLAST every TLAST_EVERY beats and can inject bit
// errors, backwards sequence numbers, gaps and starvation.
//
// Checks:
//   1. Register block 1.1: VERSION, reset values, RW, unmapped offsets
//   2. Clean stream: all checker counters zero, BEATS / LAST_SEQ / EGR_BEATS_IN
//      exact, every beat reaches the sink in order (no loss), TLAST carried
//   3. Bit errors + backwards sequence numbers: ERRORS exact, no gaps
//   4. Gaps (incl. one before the first beat): GAPS and GAP_BEATS exact
//   5. Throttle rate accuracy (< 1 %) at 5 rates incl. clamping; no underflow
//      while the source keeps up; trailing idle after the stream not counted
//   6. Starving source: UNDERFLOWS exact against an interface-level reference
//   7. Slow sink: backpressure through the egress FIFO, no loss, counters
//      consistent, FIFO fills to its depth
//   7b. Full-rate sink across an upstream DMA stall of 4000 beat times: no
//      underflow (the FIFO bridges it); a 4600-beat stall underflows exactly
//   8. CHK_CTRL.RESET (busy bit, counters cleared); EGR_CTRL.FLUSH drains a
//      stalled DMA (DISCARD exact); SOFT_RST resets checker + egress FIFO while
//      the DMA streams into a disabled sink, then a clean run works again
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_fdrec_check;

  localparam integer SRC_HZ = 200000000;
  localparam integer DP_HZ  = 250000000;
  localparam integer DEPTH  = 256;    // ingest FIFO (unused here)
  localparam integer EDEPTH = 4096;   // egress FIFO (as on uzev)
  localparam integer TLAST_EVERY = 64;

  // Register offsets (include/fdrec_regs.h)
  localparam [11:0] VERSION = 12'h000, GLOBAL_CTRL = 12'h00C,
                    CHK_CTRL = 12'h060, CHK_RATE_INC = 12'h064,
                    CHK_BEATS_LO = 12'h070, CHK_ERRORS_LO = 12'h078,
                    CHK_GAPS_LO = 12'h080, CHK_GAP_BEATS_LO = 12'h088,
                    CHK_UNDERFLOWS_LO = 12'h090, CHK_LAST_SEQ_LO = 12'h098,
                    EGR_CTRL = 12'h0A0, EGR_FIFO_DEPTH = 12'h0A4,
                    EGR_BEATS_IN_LO = 12'h0A8, EGR_DISCARD_LO = 12'h0B0,
                    EGR_FIFO_LEVEL = 12'h0B8;

  // ---------------------------------------------------------------------------
  // Clocks / resets
  // ---------------------------------------------------------------------------
  reg src_clk = 1'b0, dp_clk = 1'b0;
  reg src_resetn = 1'b0, dp_resetn = 1'b0;
  always #2.5 src_clk = ~src_clk;                       // 200 MHz
  initial begin #1.3; forever #2.0 dp_clk = ~dp_clk; end // 250 MHz, offset phase

  // ---------------------------------------------------------------------------
  // DUT: fdrec_core + fdrec_check
  // ---------------------------------------------------------------------------
  reg  [127:0] mm2s_tdata = 0;
  reg          mm2s_tvalid = 0, mm2s_tlast = 0;
  wire         mm2s_tready;

  wire [127:0] snk_tdata;
  wire         snk_tlast, snk_tvalid, snk_tready;

  wire         chk_enable, chk_reset;
  wire [31:0]  chk_rate_inc;
  wire [63:0]  chk_beats, chk_errors, chk_gaps, chk_gap_beats, chk_underflows, chk_last_seq;

  reg  [11:0]  awaddr = 0, araddr = 0;
  reg          awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [31:0]  wdata = 0;
  reg  [3:0]   wstrb = 0;
  wire         awready, wready, bvalid, arready, rvalid;
  wire [1:0]   bresp, rresp;
  wire [31:0]  rdata;

  fdrec_core #(
    .SRC_CLK_HZ     (SRC_HZ),
    .DP_CLK_HZ      (DP_HZ),
    .FIFO_DEPTH     (DEPTH),
    .EGR_FIFO_DEPTH (EDEPTH)
  ) dut (
    .src_clk       (src_clk),
    .src_resetn    (src_resetn),
    .dp_clk        (dp_clk),
    .dp_resetn     (dp_resetn),
    .s_axis_tdata  (128'd0),
    .s_axis_tvalid (1'b0),
    .s_axis_tready (),
    .m_axis_tdata  (),
    .m_axis_tkeep  (),
    .m_axis_tlast  (),
    .m_axis_tvalid (),
    .m_axis_tready (1'b1),
    .s_axis_mm2s_tdata  (mm2s_tdata),
    .s_axis_mm2s_tkeep  (16'hFFFF),
    .s_axis_mm2s_tlast  (mm2s_tlast),
    .s_axis_mm2s_tvalid (mm2s_tvalid),
    .s_axis_mm2s_tready (mm2s_tready),
    .m_axis_snk_tdata   (snk_tdata),
    .m_axis_snk_tlast   (snk_tlast),
    .m_axis_snk_tvalid  (snk_tvalid),
    .m_axis_snk_tready  (snk_tready),
    .s_axi_awaddr  (awaddr),
    .s_axi_awprot  (3'b000),
    .s_axi_awvalid (awvalid),
    .s_axi_awready (awready),
    .s_axi_wdata   (wdata),
    .s_axi_wstrb   (wstrb),
    .s_axi_wvalid  (wvalid),
    .s_axi_wready  (wready),
    .s_axi_bresp   (bresp),
    .s_axi_bvalid  (bvalid),
    .s_axi_bready  (bready),
    .s_axi_araddr  (araddr),
    .s_axi_arprot  (3'b000),
    .s_axi_arvalid (arvalid),
    .s_axi_arready (arready),
    .s_axi_rdata   (rdata),
    .s_axi_rresp   (rresp),
    .s_axi_rvalid  (rvalid),
    .s_axi_rready  (rready),
    .tpg_enable    (),
    .tpg_seq_rst   (),
    .tpg_rate_inc  (),
    .tpg_seq_next  (64'd0),
    .chk_enable     (chk_enable),
    .chk_reset      (chk_reset),
    .chk_rate_inc   (chk_rate_inc),
    .chk_beats      (chk_beats),
    .chk_errors     (chk_errors),
    .chk_gaps       (chk_gaps),
    .chk_gap_beats  (chk_gap_beats),
    .chk_underflows (chk_underflows),
    .chk_last_seq   (chk_last_seq)
  );

  fdrec_check chk (
    .snk_clk        (src_clk),
    .snk_resetn     (src_resetn),
    .chk_enable     (chk_enable),
    .chk_reset      (chk_reset),
    .chk_rate_inc   (chk_rate_inc),
    .chk_beats      (chk_beats),
    .chk_errors     (chk_errors),
    .chk_gaps       (chk_gaps),
    .chk_gap_beats  (chk_gap_beats),
    .chk_underflows (chk_underflows),
    .chk_last_seq   (chk_last_seq),
    .s_axis_tdata   (snk_tdata),
    .s_axis_tvalid  (snk_tvalid),
    .s_axis_tready  (snk_tready),
    .s_axis_tlast   (snk_tlast)
  );

  // ---------------------------------------------------------------------------
  // Error reporting
  // ---------------------------------------------------------------------------
  integer errors = 0;
  task automatic fail(input string msg);
    begin
      $display("FAIL: %s (t=%0t)", msg, $time);
      errors = errors + 1;
    end
  endtask

  task automatic check(input string what, input longint got, input longint exp);
    if (got !== exp) fail($sformatf("%s: got %0d (0x%0h) expected %0d (0x%0h)", what, got, got, exp, exp));
  endtask

  // ---------------------------------------------------------------------------
  // AXI4-Lite BFM (dp_clk)
  // ---------------------------------------------------------------------------
  task automatic axi_write(input [11:0] a, input [31:0] d, input [3:0] s = 4'hF);
    begin
      @(posedge dp_clk);
      awaddr <= a; awvalid <= 1'b1; wdata <= d; wstrb <= s; wvalid <= 1'b1; bready <= 1'b1;
      do @(posedge dp_clk); while (!(awready && wready));
      awvalid <= 1'b0; wvalid <= 1'b0;
      while (!bvalid) @(posedge dp_clk);
      if (bresp != 2'b00) fail("BRESP not OKAY");
      bready <= 1'b0;
    end
  endtask

  task automatic axi_read(input [11:0] a, output [31:0] d);
    begin
      @(posedge dp_clk);
      araddr <= a; arvalid <= 1'b1; rready <= 1'b1;
      do @(posedge dp_clk); while (!arready);
      arvalid <= 1'b0;
      do @(posedge dp_clk); while (!rvalid);
      d = rdata;
      if (rresp != 2'b00) fail("RRESP not OKAY");
      rready <= 1'b0;
    end
  endtask

  task automatic read64(input [11:0] lo_addr, output longint v);
    reg [31:0] lo, hi;
    begin
      axi_read(lo_addr, lo);
      axi_read(lo_addr + 12'h4, hi);
      v = {hi, lo};
    end
  endtask

  task automatic wait_dp(input integer n);
    repeat (n) @(posedge dp_clk);
  endtask

  // ---------------------------------------------------------------------------
  // AXI DMA MM2S model (dp_clk)
  //   dma_total : beats to send (the model sends until dma_sent == dma_total)
  //   dma_pct   : probability (%) that a beat is offered in a cycle
  //   gap_at[i] : skip that many sequence numbers before beat i
  //   uerr_at / lerr_at : flip a bit in the upper / lower half of beat i
  //   rep_at[i] : beat i repeats the previous sequence number (goes backwards)
  // ---------------------------------------------------------------------------
  longint dma_total = 0, dma_sent = 0, dma_seq = 0;
  integer dma_pct = 100;
  longint gap_at[longint];
  bit     uerr_at[longint], lerr_at[longint], rep_at[longint];

  // reference queue of beats that must reach the sink (not flushed/discarded)
  reg [128:0] ref_q[$];
  bit         tb_flush = 1'b0;
  longint     stall_cycles = 0;   // tvalid & !tready on the MM2S stream

  always @(posedge dp_clk) begin : dma
    bit fire;
    longint s;
    reg [127:0] d;
    fire = mm2s_tvalid && mm2s_tready;
    if (mm2s_tvalid && !mm2s_tready) stall_cycles = stall_cycles + 1;
    if (fire) begin
      dma_sent = dma_sent + 1;
      if (!tb_flush && !dut.u_regs.srst) ref_q.push_back({mm2s_tlast, mm2s_tdata});
    end
    if (!mm2s_tvalid || fire) begin
      if (dma_sent < dma_total && ($urandom % 100) < dma_pct) begin
        if (gap_at.exists(dma_sent)) dma_seq = dma_seq + gap_at[dma_sent];
        if (rep_at.exists(dma_sent)) s = dma_seq - 1;
        else begin s = dma_seq; dma_seq = dma_seq + 1; end
        d = {~s, s};
        if (uerr_at.exists(dma_sent)) d[100] = ~d[100];
        if (lerr_at.exists(dma_sent)) d[5]   = ~d[5];
        mm2s_tdata  <= d;
        mm2s_tlast  <= (((dma_sent + 1) % TLAST_EVERY) == 0);
        mm2s_tvalid <= 1'b1;
      end else begin
        mm2s_tvalid <= 1'b0;
      end
    end
  end

  task automatic dma_reset_model();
    begin
      gap_at.delete(); uerr_at.delete(); lerr_at.delete(); rep_at.delete();
      @(posedge dp_clk);
      dma_total = 0; dma_sent = 0; dma_seq = 0; dma_pct = 100;
      stall_cycles = 0;
      ref_q.delete();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Sink monitor (src_clk): in-order, lossless delivery; interface-level
  // reference for UNDERFLOWS (ticks with tvalid low after the first beat,
  // committed when another beat follows)
  // ---------------------------------------------------------------------------
  longint snk_beats = 0, ref_uf = 0, ref_uf_pend = 0;
  bit     snk_started = 1'b0, mon_on = 1'b1;
  longint win_beats = 0;          // beats accepted in the rate window
  bit     win_on = 1'b0;

  always @(posedge src_clk) begin : snk_mon
    reg [128:0] e;
    if (chk_reset) begin
      snk_started = 1'b0; ref_uf_pend = 0;
    end else if (snk_tready && snk_tvalid) begin
      snk_beats = snk_beats + 1;
      if (win_on) win_beats = win_beats + 1;
      snk_started = 1'b1;
      ref_uf = ref_uf + ref_uf_pend; ref_uf_pend = 0;
      if (mon_on) begin
        if (ref_q.size() == 0) fail("sink received a beat the DMA never sent");
        else begin
          e = ref_q.pop_front();
          if ({snk_tlast, snk_tdata} !== e)
            fail($sformatf("sink beat %0d: got %b/%h expected %b/%h", snk_beats,
                           snk_tlast, snk_tdata, e[128], e[127:0]));
        end
      end
    end else if (snk_tready && !snk_tvalid && snk_started) begin
      ref_uf_pend = ref_uf_pend + 1;
    end
  end

  task automatic reset_monitors();
    begin
      @(posedge src_clk);
      snk_beats = 0; ref_uf = 0; ref_uf_pend = 0; snk_started = 1'b0;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic soft_reset();
    reg [31:0] v;
    integer    n;
    begin
      axi_write(GLOBAL_CTRL, 32'h1);
      n = 0;
      do begin axi_read(GLOBAL_CTRL, v); n = n + 1; end while (v[0] && n < 1000);
      if (v[0]) fail("SOFT_RST never self-cleared");
    end
  endtask

  task automatic chk_reset_wait();
    reg [31:0] v;
    integer    n;
    begin
      axi_write(CHK_CTRL, 32'h2);            // RESET, ENABLE = 0
      axi_read(CHK_CTRL, v);
      if (v[1] !== 1'b1) fail("CHK_CTRL.RESET did not read 1 while in progress");
      n = 0;
      do begin axi_read(CHK_CTRL, v); n = n + 1; end while (v[1] && n < 1000);
      if (v[1]) fail("CHK_CTRL.RESET never self-cleared");
    end
  endtask

  // Start a fresh playback of n beats: reset checker + model, prime the FIFO
  // (sink disabled), then enable the sink at the given rate
  task automatic start_play(input longint n, input [31:0] rate, input integer pct = 100,
                            input integer prime = 1);
    begin
      chk_reset_wait();
      axi_write(CHK_RATE_INC, rate);
      reset_monitors();
      dma_total = n;
      dma_pct   = pct;
      if (prime) begin
        // let the egress FIFO fill (or the stream end) before the sink starts
        while (!(dut.u_egress.full || dma_sent == dma_total)) @(posedge dp_clk);
        wait_dp(20);
      end
      axi_write(CHK_CTRL, 32'h1);
    end
  endtask

  // Wait until the DMA has sent everything and the sink has drained it
  task automatic wait_done();
    begin
      while (dma_sent < dma_total || mm2s_tvalid || snk_tvalid || ref_q.size() != 0)
        @(posedge src_clk);
      repeat (300) @(posedge dp_clk);       // > snapshot refresh latency
    end
  endtask

  task automatic read_chk(output longint b, e, g, gb, u, l);
    begin
      read64(CHK_BEATS_LO, b);
      read64(CHK_ERRORS_LO, e);
      read64(CHK_GAPS_LO, g);
      read64(CHK_GAP_BEATS_LO, gb);
      read64(CHK_UNDERFLOWS_LO, u);
      read64(CHK_LAST_SEQ_LO, l);
    end
  endtask

  task automatic check_chk(input string tag, input longint xb, xe, xg, xgb, xu, xl);
    longint b, e, g, gb, u, l, ei;
    begin
      read_chk(b, e, g, gb, u, l);
      read64(EGR_BEATS_IN_LO, ei);
      $display("%s: BEATS %0d ERRORS %0d GAPS %0d GAP_BEATS %0d UNDERFLOWS %0d LAST_SEQ %0d EGR_BEATS_IN %0d (sink %0d, ref underflows %0d)",
               tag, b, e, g, gb, u, l, ei, snk_beats, ref_uf);
      check({tag, " BEATS"}, b, xb);
      check({tag, " ERRORS"}, e, xe);
      check({tag, " GAPS"}, g, xg);
      check({tag, " GAP_BEATS"}, gb, xgb);
      if (xu >= 0) check({tag, " UNDERFLOWS"}, u, xu);
      check({tag, " LAST_SEQ"}, l, xl);
      check({tag, " BEATS == sink monitor"}, b, snk_beats);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  reg [31:0] v;
  longint    q, q2, q0, d0, b, e, g, gb, u, l;
  integer    k;
  real       r, exp_r;
  reg [31:0] rates[5];

  initial begin
    repeat (20) @(posedge src_clk);
    src_resetn = 1'b1;
    dp_resetn  = 1'b1;
    wait_dp(400);

    // ---------------- 1. Register block ----------------
    $display("--- 1. register block 1.1");
    axi_read(VERSION, v);         check("VERSION", v, 32'h0001_0001);
    axi_read(CHK_RATE_INC, v);    check("CHK_RATE_INC reset value", v, 32'h8000_0000);
    axi_read(CHK_CTRL, v);        check("CHK_CTRL reset value", v, 0);
    axi_read(EGR_CTRL, v);        check("EGR_CTRL reset value", v, 0);
    axi_read(EGR_FIFO_DEPTH, v);  check("EGR_FIFO_DEPTH", v, EDEPTH);
    axi_read(EGR_FIFO_LEVEL, v);  check("EGR_FIFO_LEVEL idle", v, 0);
    axi_read(12'h068, v);         check("unmapped 0x068", v, 0);
    axi_read(12'h06C, v);         check("unmapped 0x06C", v, 0);
    axi_read(12'h0BC, v);         check("unmapped 0x0BC", v, 0);
    axi_write(CHK_RATE_INC, 32'h1234_5678);
    axi_read(CHK_RATE_INC, v);    check("CHK_RATE_INC rw", v, 32'h1234_5678);
    axi_write(CHK_RATE_INC, 32'hAB00_0000, 4'b1000);
    axi_read(CHK_RATE_INC, v);    check("CHK_RATE_INC byte strobe", v, 32'hAB34_5678);
    wait_dp(100);
    if (chk_rate_inc !== 32'hAB34_5678) fail("CHK_RATE_INC not transferred to src_clk");
    axi_write(EGR_CTRL, 32'h1);
    axi_read(EGR_CTRL, v);        check("EGR_CTRL.FLUSH rw", v, 1);
    axi_write(EGR_CTRL, 32'h0);
    read_chk(b, e, g, gb, u, l);
    check("power-on BEATS", b, 0); check("power-on ERRORS", e, 0);
    check("power-on UNDERFLOWS", u, 0);
    // checker disabled: no tready, nothing consumed
    dma_total = 10;
    wait_dp(500);
    if (snk_beats != 0) fail("disabled sink consumed data");
    axi_read(EGR_FIFO_LEVEL, v);
    if (v < 10 || v > 11) fail($sformatf("EGR_FIFO_LEVEL %0d after 10 beats", v));
    soft_reset();
    dma_reset_model();
    axi_read(EGR_FIFO_LEVEL, v);  check("EGR_FIFO_LEVEL after SOFT_RST", v, 0);

    // ---------------- 2. Clean stream ----------------
    $display("--- 2. clean stream: 20000 beats, sink rate 1.0");
    start_play(20000, 32'h8000_0000);
    wait_done();
    check_chk("clean", 20000, 0, 0, 0, 0, 19999);
    read64(EGR_BEATS_IN_LO, q);   check("clean EGR_BEATS_IN", q, 20000);
    read64(EGR_DISCARD_LO, q);    check("clean EGR_DISCARD", q, 0);
    // trailing idle after the stream: still no underflows
    repeat (2000) @(posedge src_clk);
    read64(CHK_UNDERFLOWS_LO, q); check("clean UNDERFLOWS after trailing idle", q, 0);
    check("clean ref underflows", ref_uf, 0);

    // ---------------- 3. Bit errors + backwards sequence ----------------
    $display("--- 3. injected errors: 5 upper-half, 3 lower-half bit flips, 2 backwards beats");
    dma_reset_model();
    uerr_at[10] = 1; uerr_at[500] = 1; uerr_at[501] = 1; uerr_at[3000] = 1; uerr_at[7999] = 1;
    lerr_at[100] = 1; lerr_at[2000] = 1; lerr_at[6000] = 1;
    rep_at[1234] = 1; rep_at[5000] = 1;
    start_play(8000, 32'h8000_0000);
    wait_done();
    // 8000 beats carry seq 0..7997 (two repeats); the last beat (7999) has an
    // upper-half error, so LAST_SEQ is the seq of beat 7998 = 7996
    check_chk("errors", 8000, 10, 0, 0, 0, 7996);

    // ---------------- 4. Gaps ----------------
    $display("--- 4. injected gaps: 1, 5, 1000, 3 (+ 7 before the first beat)");
    dma_reset_model();
    gap_at[0] = 7;                          // first beat defines the expectation
    gap_at[50] = 1; gap_at[51] = 5; gap_at[4000] = 1000; gap_at[9999] = 3;
    start_play(10000, 32'h8000_0000);
    wait_done();
    check_chk("gaps", 10000, 0, 4, 1009, 0, 7 + 10000 - 1 + 1009);

    // ---------------- 5. Throttle rate accuracy ----------------
    $display("--- 5. throttle rate accuracy");
    rates[0] = 32'h4000_0000;   // 0.5
    rates[1] = 32'h1999_999A;   // 0.2
    rates[2] = 32'h0CCC_CCCD;   // 0.1
    rates[3] = 32'h0444_4444;   // 1/30
    rates[4] = 32'h9000_0000;   // clamps to 1.0
    for (k = 0; k < 5; k = k + 1) begin
      dma_reset_model();
      start_play(64'd1 << 40, rates[k]);    // effectively endless
      repeat (500) @(posedge src_clk);
      win_beats = 0; win_on = 1'b1;
      repeat (40000) @(posedge src_clk);
      win_on = 1'b0;
      exp_r = (rates[k] > 32'h8000_0000) ? 1.0 : rates[k] / 2.0 ** 31;
      r = win_beats / 40000.0;
      $display("rate: INC 0x%08h expected %f beats/clk measured %f (%0d beats), error %f %%",
               rates[k], exp_r, r, win_beats, 100.0 * (r - exp_r) / exp_r);
      if ((r - exp_r) / exp_r > 0.01 || (exp_r - r) / exp_r > 0.01)
        fail($sformatf("rate error > 1%% at INC 0x%08h", rates[k]));
      // stop the source, drain, then: no underflow (source always kept up,
      // trailing idle not counted)
      dma_total = dma_sent;
      wait_done();
      read64(CHK_UNDERFLOWS_LO, q); check("rate UNDERFLOWS", q, 0);
      read64(CHK_ERRORS_LO, q);     check("rate ERRORS", q, 0);
      read64(CHK_GAPS_LO, q);       check("rate GAPS", q, 0);
      read64(CHK_BEATS_LO, q);      check("rate BEATS == sink", q, snk_beats);
    end

    // ---------------- 6. Starving source: underflows ----------------
    $display("--- 6. starving source: DMA offers 40%% of dp_clk cycles + 2 long pauses");
    dma_reset_model();
    start_play(6000, 32'h8000_0000, 40, 0);
    while (dma_sent < 2000) @(posedge dp_clk);
    dma_pct = 0; repeat (1000) @(posedge dp_clk); dma_pct = 40;
    while (dma_sent < 4000) @(posedge dp_clk);
    dma_pct = 0; repeat (777) @(posedge dp_clk); dma_pct = 40;
    wait_done();
    repeat (1000) @(posedge src_clk);       // trailing idle
    if (ref_uf < 1500) fail($sformatf("starve: only %0d reference underflows", ref_uf));
    check_chk("starve", 6000, 0, 0, 0, ref_uf, 5999);

    // ---------------- 7. Slow sink: backpressure, no loss ----------------
    $display("--- 7. slow sink: rate 0.1, DMA full speed, 6000 beats");
    dma_reset_model();
    read64(EGR_BEATS_IN_LO, q0);            // EGR_ counters only clear on SOFT_RST
    start_play(6000, 32'h0CCC_CCCD, 100, 0);
    q2 = 0;
    while (dma_sent < 5000) begin
      @(posedge dp_clk);
      if (dut.u_egress.fifo_level > q2) q2 = dut.u_egress.fifo_level;
    end
    axi_read(EGR_FIFO_LEVEL, v);
    $display("slow: EGR_FIFO_LEVEL %0d, max level %0d, MM2S stall cycles %0d", v, q2, stall_cycles);
    if (q2 < EDEPTH - 4) fail("slow: egress FIFO never filled");
    if (v < EDEPTH - 8)  fail($sformatf("slow: EGR_FIFO_LEVEL %0d while backpressured", v));
    if (stall_cycles < 1000) fail("slow: no backpressure seen on the MM2S stream");
    wait_done();
    check_chk("slow", 6000, 0, 0, 0, 0, 5999);
    read64(EGR_BEATS_IN_LO, q);   check("slow EGR_BEATS_IN delta", q - q0, 6000);
    check("slow: reference queue empty (no loss)", ref_q.size(), 0);

    // ---------------- 7b. Upstream stall bridged by the FIFO ----------------
    $display("--- 7b. full-rate sink, DMA stalls for 4000 and then 4600 sink-beat times");
    dma_reset_model();
    // DMA 250 MHz vs sink 200 MHz: the FIFO refills at 50 M beats/s after a stall
    start_play(60000, 32'h8000_0000);       // primed: FIFO full, sink 1 beat/clk
    while (dma_sent < 8000) @(posedge dp_clk);
    if (dut.u_egress.fifo_level < EDEPTH - 16) fail("stall: FIFO not full before the stall");
    dma_pct = 0; repeat (4000) @(posedge src_clk); dma_pct = 100;
    while (dut.u_egress.fifo_level < EDEPTH - 16) @(posedge dp_clk);
    read64(CHK_UNDERFLOWS_LO, q);
    $display("stall 4000: UNDERFLOWS %0d (ref %0d)", q, ref_uf);
    check("stall 4000: UNDERFLOWS", q, 0);
    dma_pct = 0; repeat (4600) @(posedge src_clk); dma_pct = 100;
    wait_done();
    $display("stall 4600: ref underflows %0d", ref_uf);
    if (ref_uf < 300 || ref_uf > 700) fail($sformatf("stall 4600: %0d reference underflows", ref_uf));
    check_chk("stall", 60000, 0, 0, 0, ref_uf, 59999);

    // ---------------- 8. RESET, FLUSH, SOFT_RST ----------------
    $display("--- 8. CHK_CTRL.RESET, EGR_CTRL.FLUSH, SOFT_RST while streaming");
    read64(CHK_BEATS_LO, q);
    if (q == 0) fail("BEATS already 0 before CHK_CTRL.RESET");
    chk_reset_wait();
    read_chk(b, e, g, gb, u, l);
    check("RESET BEATS", b, 0); check("RESET LAST_SEQ", l, 0); check("RESET UNDERFLOWS", u, 0);
    repeat (500) @(posedge dp_clk);
    read64(CHK_BEATS_LO, q);      check("RESET BEATS stays 0", q, 0);
    // stalled DMA into a disabled sink, then FLUSH drains it
    dma_reset_model();
    reset_monitors();
    read64(EGR_BEATS_IN_LO, q0);
    read64(EGR_DISCARD_LO, d0);
    dma_total = 7000;
    while (!dut.u_egress.full) @(posedge dp_clk);
    wait_dp(200);
    q = dma_sent;
    if (q > EDEPTH + 4) fail($sformatf("disabled sink: DMA sent %0d beats into a %0d FIFO", q, EDEPTH));
    tb_flush = 1'b1;
    axi_write(EGR_CTRL, 32'h1);
    while (dma_sent < dma_total) @(posedge dp_clk);
    wait_dp(20);
    axi_write(EGR_CTRL, 32'h0);
    tb_flush = 1'b0;
    read64(EGR_DISCARD_LO, q2);
    read64(EGR_BEATS_IN_LO, q);
    $display("flush: EGR_BEATS_IN +%0d EGR_DISCARD +%0d", q - q0, q2 - d0);
    check("flush: BEATS_IN + DISCARD == sent", (q - q0) + (q2 - d0), 7000);
    if (q2 - d0 < 2500) fail("flush: too few beats discarded");
    axi_read(EGR_FIFO_LEVEL, v);
    if (v < EDEPTH - 8) fail("flush: FIFO content lost");
    // SOFT_RST while the DMA streams into the disabled sink
    dma_reset_model();
    mon_on = 1'b0;
    dma_total = 64'd1 << 40;
    wait_dp(EDEPTH + 3000);
    if (mm2s_tready) fail("DMA not backpressured before SOFT_RST");
    // SOFT_RST accepts and discards the stream while it is in progress (the
    // DMA is not wedged); stop the DMA model before the reset completes
    axi_write(GLOBAL_CTRL, 32'h1);
    wait_dp(20);
    if (!mm2s_tready) fail("SOFT_RST: MM2S stream not drained during the reset");
    q = dma_sent;
    wait_dp(20);
    if (dma_sent < q + 15) fail("SOFT_RST: DMA not streaming during the reset");
    dma_total = dma_sent;                     // stop the DMA
    soft_reset();                             // (already in progress: just polls)
    wait_dp(100);
    axi_read(EGR_FIFO_LEVEL, v);  check("SOFT_RST: EGR_FIFO_LEVEL", v, 0);
    read64(EGR_BEATS_IN_LO, q);   check("SOFT_RST: EGR_BEATS_IN", q, 0);
    read64(EGR_DISCARD_LO, q);    check("SOFT_RST: EGR_DISCARD", q, 0);
    axi_read(CHK_CTRL, v);        check("SOFT_RST: CHK_CTRL", v, 0);
    axi_read(EGR_CTRL, v);        check("SOFT_RST: EGR_CTRL", v, 0);
    axi_read(CHK_RATE_INC, v);    check("SOFT_RST: CHK_RATE_INC kept", v, 32'h8000_0000);
    read_chk(b, e, g, gb, u, l);
    check("SOFT_RST BEATS", b, 0); check("SOFT_RST ERRORS", e, 0);
    check("SOFT_RST GAPS", g, 0);  check("SOFT_RST LAST_SEQ", l, 0);
    // clean run afterwards, sequence starting at an arbitrary number
    mon_on = 1'b1;
    dma_reset_model();
    gap_at[0] = 123456;
    start_play(3000, 32'h8000_0000);
    wait_done();
    check_chk("after SOFT_RST", 3000, 0, 0, 0, 0, 123456 + 2999);

    if (errors == 0) $display("PASS: tb_fdrec_check");
    else             $display("FAIL: tb_fdrec_check (%0d errors)", errors);
    $finish;
  end

  initial begin
    #10ms;
    $display("FAIL: tb_fdrec_check watchdog timeout");
    $finish;
  end

endmodule
