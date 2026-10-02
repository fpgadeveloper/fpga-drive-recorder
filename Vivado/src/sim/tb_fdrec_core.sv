// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_fdrec_core -- self-checking testbench for fdrec_core (+ fdrec_tpg as source)
//
// fdrec_tpg (src_clk 200 MHz) -> fdrec_core -> DMA sink model (dp_clk 250 MHz),
// registers driven through an AXI4-Lite BFM. The FIFO depth is reduced to 256
// beats to keep the simulation short.
//
// Checks (spec section 9, Phase-1 RTL criteria):
//   1. Register block: RO identification registers, RW readback, byte strobes
//   2. No-drop recording: contiguous data, TLAST framing, accounting
//   3. Drops under a stalled/slow sink: DROP_COUNT == offered - accepted,
//      every sequence gap seen by the sink adds up to DROP_COUNT, OVERFLOW
//      sticky + W1C, FIFO_HWM reaches the FIFO depth + clears on write,
//      TLAST exactly every PKT_LEN beats while drops are occurring
//   4. ENABLE gating (TVALID held low while disabled) and packet-counter
//      restart on re-enable (mid-packet disable)
//   5. 64-bit LO/HI latch semantics
//   6. TPG_CTRL.SEQ_RST self-clearing, SOFT_RST semantics
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_fdrec_core;

  localparam integer SRC_HZ = 200000000;
  localparam integer DP_HZ  = 250000000;
  localparam integer DEPTH  = 256;

  // Register offsets (include/fdrec_regs.h)
  localparam [11:0] VERSION = 12'h000, SRC_CLK_HZ = 12'h004, DP_CLK_HZ = 12'h008,
                    GLOBAL_CTRL = 12'h00C, TPG_CTRL = 12'h010, TPG_RATE_INC = 12'h014,
                    TPG_SEQ_NEXT_LO = 12'h018, TPG_SEQ_NEXT_HI = 12'h01C,
                    ING_STATUS = 12'h020, ING_FIFO_HWM = 12'h024,
                    ING_DROP_COUNT_LO = 12'h028, ING_DROP_COUNT_HI = 12'h02C,
                    ING_BEATS_IN_LO = 12'h030, ING_BEATS_IN_HI = 12'h034,
                    ING_FIFO_DEPTH = 12'h038, PKT_CTRL = 12'h040, PKT_LEN = 12'h044,
                    PKT_BEATS_OUT_LO = 12'h048, PKT_BEATS_OUT_HI = 12'h04C;

  // ---------------------------------------------------------------------------
  // Clocks / resets
  // ---------------------------------------------------------------------------
  reg src_clk = 1'b0, dp_clk = 1'b0;
  reg src_resetn = 1'b0, dp_resetn = 1'b0;
  always #2.5 src_clk = ~src_clk;                       // 200 MHz
  initial begin #1.3; forever #2.0 dp_clk = ~dp_clk; end // 250 MHz, offset phase

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  wire [127:0] src_tdata;
  wire         src_tvalid, src_tready;
  wire         tpg_enable, tpg_seq_rst;
  wire [31:0]  tpg_rate_inc;
  wire [63:0]  tpg_seq_next;

  wire [127:0] m_tdata;
  wire [15:0]  m_tkeep;
  wire         m_tlast, m_tvalid;
  reg          m_tready = 1'b1;

  reg  [11:0]  awaddr = 0, araddr = 0;
  reg          awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [31:0]  wdata = 0;
  reg  [3:0]   wstrb = 0;
  wire         awready, wready, bvalid, arready, rvalid;
  wire [1:0]   bresp, rresp;
  wire [31:0]  rdata;

  fdrec_tpg tpg (
    .src_clk       (src_clk),
    .src_resetn    (src_resetn),
    .tpg_enable    (tpg_enable),
    .tpg_seq_rst   (tpg_seq_rst),
    .tpg_rate_inc  (tpg_rate_inc),
    .tpg_seq_next  (tpg_seq_next),
    .m_axis_tdata  (src_tdata),
    .m_axis_tvalid (src_tvalid),
    .m_axis_tready (src_tready)
  );

  fdrec_core #(
    .SRC_CLK_HZ (SRC_HZ),
    .DP_CLK_HZ  (DP_HZ),
    .FIFO_DEPTH (DEPTH)
  ) dut (
    .src_clk       (src_clk),
    .src_resetn    (src_resetn),
    .dp_clk        (dp_clk),
    .dp_resetn     (dp_resetn),
    .s_axis_tdata  (src_tdata),
    .s_axis_tvalid (src_tvalid),
    .s_axis_tready (src_tready),
    .m_axis_tdata  (m_tdata),
    .m_axis_tkeep  (m_tkeep),
    .m_axis_tlast  (m_tlast),
    .m_axis_tvalid (m_tvalid),
    .m_axis_tready (m_tready),
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
    .tpg_enable    (tpg_enable),
    .tpg_seq_rst   (tpg_seq_rst),
    .tpg_rate_inc  (tpg_rate_inc),
    .tpg_seq_next  (tpg_seq_next),
    // playback path unused here (covered by tb_fdrec_check)
    .s_axis_mm2s_tdata  (128'd0),
    .s_axis_mm2s_tkeep  (16'hFFFF),
    .s_axis_mm2s_tlast  (1'b0),
    .s_axis_mm2s_tvalid (1'b0),
    .s_axis_mm2s_tready (),
    .m_axis_snk_tdata   (),
    .m_axis_snk_tlast   (),
    .m_axis_snk_tvalid  (),
    .m_axis_snk_tready  (1'b0),
    .chk_enable     (),
    .chk_reset      (),
    .chk_rate_inc   (),
    .chk_beats      (64'd0),
    .chk_errors     (64'd0),
    .chk_gaps       (64'd0),
    .chk_gap_beats  (64'd0),
    .chk_underflows (64'd0),
    .chk_last_seq   (64'd0)
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

  function automatic longint u64(input [31:0] hi, input [31:0] lo);
    u64 = {hi, lo};
  endfunction

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
  // Source monitor: beats offered by the TPG (src_clk)
  // ---------------------------------------------------------------------------
  longint offered = 0;
  always @(posedge src_clk)
    if (src_tvalid) offered <= offered + 1;

  // ---------------------------------------------------------------------------
  // Sink model + monitor (dp_clk)
  //   ready_pct: probability (%) that TREADY is high in a cycle
  // ---------------------------------------------------------------------------
  integer ready_pct = 100;
  always @(posedge dp_clk)
    m_tready <= (($urandom % 100) < ready_pct);

  longint     delivered = 0;      // beats seen by the sink
  longint     gaps = 0;           // sum of sequence gaps seen by the sink
  longint     pkts = 0;           // TLAST count
  longint     mon_expect = 0;     // next expected sequence number
  integer     pkt_len_tb = 1;     // PKT_LEN the monitor checks against
  longint     pkt_cnt = 0;        // beats in the current packet
  reg         en_prev = 1'b0;
  reg         mon_on = 1'b1;      // pattern checking enabled
  longint     tvalid_while_off = 0;

  always @(posedge dp_clk) begin : sink_mon
    longint s;
    // packet counter restarts when the packetizer gate opens
    if (dut.u_pkt.en_q && !en_prev) pkt_cnt = 0;
    en_prev <= dut.u_pkt.en_q;
    if (m_tvalid && !dut.u_regs.pkt_enable && !dut.u_pkt.en_q)
      tvalid_while_off = tvalid_while_off + 1;
    if (m_tvalid && m_tready) begin
      delivered = delivered + 1;
      if (m_tkeep !== 16'hFFFF) fail("TKEEP not all ones");
      if (mon_on) begin
        s = m_tdata[63:0];
        if (m_tdata[127:64] !== ~m_tdata[63:0])
          fail($sformatf("pattern: upper %h != ~lower %h", m_tdata[127:64], m_tdata[63:0]));
        if (s < mon_expect)
          fail($sformatf("sequence went backwards: %0d after expecting %0d", s, mon_expect));
        else
          gaps = gaps + (s - mon_expect);
        mon_expect = s + 1;
      end
      pkt_cnt = pkt_cnt + 1;
      if (m_tlast !== (pkt_cnt == pkt_len_tb))
        fail($sformatf("TLAST=%0b on beat %0d of a %0d-beat packet", m_tlast, pkt_cnt, pkt_len_tb));
      if (m_tlast) begin
        pkts = pkts + 1;
        pkt_cnt = 0;
      end
    end
  end

  task automatic reset_monitors();
    begin
      delivered = 0; gaps = 0; pkts = 0; mon_expect = 0; pkt_cnt = 0;
      offered <= 0;
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
      axi_read(GLOBAL_CTRL, v);
      if (v[0] !== 1'b1) fail("GLOBAL_CTRL.SOFT_RST did not read 1 while the reset is in progress");
      n = 0;
      do begin axi_read(GLOBAL_CTRL, v); n = n + 1; end while (v[0] && n < 1000);
      if (v[0]) fail("SOFT_RST never self-cleared");
      wait_dp(50);
      reset_monitors();
    end
  endtask

  // Wait until the TPG is idle and everything has drained to the sink
  task automatic drain();
    begin
      ready_pct = 100;
      wait_dp(20);
      while (!dut.u_ingest.u_fifo.empty || dut.u_pkt.v0 || dut.u_pkt.v1) @(posedge dp_clk);
      wait_dp(300);   // > snapshot refresh latency
    end
  endtask

  task automatic check_zero_state(input string tag);
    reg [31:0] v; longint q;
    begin
      read64(ING_DROP_COUNT_LO, q); check({tag, " DROP_COUNT"}, q, 0);
      read64(ING_BEATS_IN_LO,   q); check({tag, " BEATS_IN"}, q, 0);
      read64(PKT_BEATS_OUT_LO,  q); check({tag, " BEATS_OUT"}, q, 0);
      read64(TPG_SEQ_NEXT_LO,   q); check({tag, " SEQ_NEXT"}, q, 0);
      axi_read(ING_FIFO_HWM, v);    check({tag, " FIFO_HWM"}, v, 0);
      axi_read(ING_STATUS, v);      check({tag, " ING_STATUS"}, v, 0);
      axi_read(TPG_CTRL, v);        check({tag, " TPG_CTRL"}, v, 0);
      axi_read(PKT_CTRL, v);        check({tag, " PKT_CTRL"}, v, 0);
    end
  endtask

  // Accounting after a drained run
  task automatic check_accounting(input string tag);
    longint in_c, drop_c, out_c, seqn;
    begin
      read64(ING_BEATS_IN_LO,   in_c);
      read64(ING_DROP_COUNT_LO, drop_c);
      read64(PKT_BEATS_OUT_LO,  out_c);
      read64(TPG_SEQ_NEXT_LO,   seqn);
      $display("%s: offered %0d  BEATS_IN %0d  DROP %0d  BEATS_OUT %0d  delivered %0d  gaps %0d  packets %0d  SEQ_NEXT %0d",
               tag, offered, in_c, drop_c, out_c, delivered, gaps, pkts, seqn);
      check({tag, " BEATS_IN == offered"}, in_c, offered);
      check({tag, " SEQ_NEXT == offered"}, seqn, offered);
      check({tag, " BEATS_OUT == delivered"}, out_c, delivered);
      check({tag, " DROP_COUNT == offered - accepted"}, drop_c, offered - delivered);
      // every dropped beat shows up as a sequence gap (or trails the last beat)
      check({tag, " gaps + trailing == DROP_COUNT"}, gaps + (seqn - mon_expect), drop_c);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  reg [31:0] v;
  longint    q, q2;

  initial begin
    repeat (20) @(posedge src_clk);
    src_resetn = 1'b1;
    dp_resetn  = 1'b1;
    wait_dp(400);

    // ---------------- 1. Register block ----------------
    $display("--- 1. register block");
    axi_read(VERSION, v);        check("VERSION", v, 32'h0001_0001);
    axi_read(SRC_CLK_HZ, v);     check("SRC_CLK_HZ", v, SRC_HZ);
    axi_read(DP_CLK_HZ, v);      check("DP_CLK_HZ", v, DP_HZ);
    axi_read(ING_FIFO_DEPTH, v); check("ING_FIFO_DEPTH", v, DEPTH);
    axi_read(PKT_LEN, v);        check("PKT_LEN reset value", v, 32'h0008_0000);
    axi_read(TPG_RATE_INC, v);   check("TPG_RATE_INC reset value", v, 0);
    axi_read(12'h03C, v);        check("unmapped 0x03C", v, 0);
    axi_read(12'hFFC, v);        check("unmapped 0xFFC", v, 0);
    axi_write(VERSION, 32'hDEAD_BEEF);
    axi_read(VERSION, v);        check("VERSION is RO", v, 32'h0001_0001);
    axi_write(TPG_RATE_INC, 32'h1234_5678);
    axi_read(TPG_RATE_INC, v);   check("TPG_RATE_INC rw", v, 32'h1234_5678);
    axi_write(TPG_RATE_INC, 32'hAB00_0000, 4'b1000);
    axi_read(TPG_RATE_INC, v);   check("TPG_RATE_INC byte strobe", v, 32'hAB34_5678);
    axi_write(PKT_LEN, 32'h0000_0040);
    axi_read(PKT_LEN, v);        check("PKT_LEN rw", v, 64);
    wait_dp(100);
    if (tpg_rate_inc !== 32'hAB34_5678) fail("TPG_RATE_INC not transferred to src_clk");
    check_zero_state("after power-on");

    // ---------------- 2. No-drop recording ----------------
    $display("--- 2. no-drop recording: rate 0.5 beat/clk, PKT_LEN 64, sink always ready");
    pkt_len_tb = 64;
    ready_pct  = 100;
    axi_write(TPG_RATE_INC, 32'h4000_0000);
    axi_write(PKT_CTRL, 32'h1);
    axi_write(TPG_CTRL, 32'h1);
    repeat (20000) @(posedge src_clk);
    axi_write(TPG_CTRL, 32'h0);
    drain();
    check_accounting("no-drop");
    read64(ING_DROP_COUNT_LO, q); check("no-drop DROP_COUNT", q, 0);
    axi_read(ING_STATUS, v);      check("no-drop OVERFLOW", v, 0);
    if (offered < 9900) fail("no-drop: too few beats offered");
    if (pkts < 150) fail("no-drop: too few packets");

    // ---------------- 3. Drops under a slow/stalled sink ----------------
    $display("--- 3. drops: rate 1 beat/clk, PKT_LEN 100, sink 50%% ready + stalls");
    soft_reset();
    check_zero_state("after SOFT_RST");
    axi_read(TPG_RATE_INC, v);   check("TPG_RATE_INC kept over SOFT_RST", v, 32'h4000_0000);
    axi_read(PKT_LEN, v);        check("PKT_LEN kept over SOFT_RST", v, 64);
    pkt_len_tb = 100;
    axi_write(PKT_LEN, 100);
    axi_write(TPG_RATE_INC, 32'h8000_0000);
    axi_write(PKT_CTRL, 32'h1);
    axi_write(TPG_CTRL, 32'h1);
    ready_pct = 50;
    repeat (6000) @(posedge dp_clk);
    ready_pct = 0;                          // full stall: FIFO fills, drops
    repeat (2000) @(posedge dp_clk);
    ready_pct = 30;
    repeat (6000) @(posedge dp_clk);
    ready_pct = 100;                        // fast sink: no new drops
    repeat (2000) @(posedge dp_clk);
    ready_pct = 0;
    repeat (2000) @(posedge dp_clk);
    ready_pct = 70;
    repeat (4000) @(posedge dp_clk);
    axi_write(TPG_CTRL, 32'h0);
    drain();
    check_accounting("drops");
    read64(ING_DROP_COUNT_LO, q);
    if (q == 0) fail("drops: no beats were dropped");
    axi_read(ING_STATUS, v);     check("drops OVERFLOW sticky", v, 1);
    axi_read(ING_FIFO_HWM, v);
    $display("drops: FIFO_HWM = %0d (depth %0d)", v, DEPTH);
    if (v < DEPTH - 8 || v > DEPTH + 2) fail($sformatf("FIFO_HWM %0d not at the FIFO depth", v));
    if (pkts < 50) fail("drops: too few packets");
    axi_write(ING_STATUS, 32'h0);
    axi_read(ING_STATUS, v);     check("OVERFLOW not cleared by writing 0", v, 1);
    axi_write(ING_STATUS, 32'h1);
    axi_read(ING_STATUS, v);     check("OVERFLOW W1C", v, 0);
    axi_write(ING_FIFO_HWM, 32'h0);
    axi_read(ING_FIFO_HWM, v);   check("FIFO_HWM cleared by write", v, 0);
    read64(ING_DROP_COUNT_LO, q2); check("DROP_COUNT unaffected by W1C", q2, q);

    // ---------------- 4. ENABLE gating + re-enable ----------------
    $display("--- 4. ENABLE gating: packetizer disabled while TPG runs, mid-packet disable/re-enable");
    soft_reset();
    pkt_len_tb = 50;
    axi_write(PKT_LEN, 50);
    axi_write(TPG_RATE_INC, 32'h2000_0000);  // 0.25 beat/clk
    tvalid_while_off = 0;
    axi_write(TPG_CTRL, 32'h1);               // packetizer still disabled
    repeat (4000) @(posedge src_clk);        // ~1000 beats offered, FIFO 256: drops
    check("gating: beats delivered while disabled", delivered, 0);
    check("gating: TVALID while disabled", tvalid_while_off, 0);
    read64(PKT_BEATS_OUT_LO, q); check("gating: BEATS_OUT while disabled", q, 0);
    axi_read(ING_STATUS, v);     check("gating: OVERFLOW while disabled", v, 1);
    axi_read(ING_FIFO_HWM, v);
    if (v < DEPTH - 8) fail($sformatf("gating: FIFO_HWM %0d, FIFO did not fill", v));
    // enable, deliver a few packets, then disable in the middle of a packet
    ready_pct = 100;
    axi_write(PKT_CTRL, 32'h1);
    while (delivered < 175) @(posedge dp_clk);
    axi_write(PKT_CTRL, 32'h0);
    wait_dp(20);
    q = delivered;
    $display("gating: disabled after %0d beats (beat %0d of a packet)", q, pkt_cnt);
    if (pkt_cnt == 0) $display("gating: note, disable landed on a packet boundary");
    repeat (2000) @(posedge dp_clk);
    check("gating: no beats after disable", delivered, q);
    check("gating: TVALID while disabled (2)", tvalid_while_off, 0);
    // re-enable: monitor restarts its packet count on the gate opening; the
    // TLAST check proves the packetizer restarted too
    axi_write(PKT_CTRL, 32'h1);
    repeat (6000) @(posedge src_clk);
    axi_write(TPG_CTRL, 32'h0);
    drain();
    check_accounting("gating");
    read64(PKT_BEATS_OUT_LO, q); check("gating: BEATS_OUT not reset by re-enable", q, delivered);

    // ---------------- 5. 64-bit latch semantics ----------------
    $display("--- 5. 64-bit LO/HI latch");
    mon_on = 1'b0;
    // preset BEATS_OUT just below a 2^32 boundary, then let it count across
    @(negedge dp_clk) dut.u_pkt.beats_out = 64'h0000_0001_FFFF_FF00;
    axi_write(TPG_RATE_INC, 32'h8000_0000);
    axi_write(TPG_CTRL, 32'h1);
    axi_read(PKT_BEATS_OUT_LO, v);
    $display("latch: LO = 0x%08h", v);
    if (v < 32'hFFFF_FF00) fail("latch: unexpected LO before the wrap");
    while (dut.u_pkt.beats_out[63:32] != 32'h2) @(posedge dp_clk);
    wait_dp(10);
    axi_read(PKT_BEATS_OUT_HI, v); check("latch: HI after LO (latched before wrap)", v, 1);
    axi_read(PKT_BEATS_OUT_HI, v); check("latch: HI re-read stays latched", v, 1);
    axi_read(PKT_BEATS_OUT_LO, v);
    axi_read(PKT_BEATS_OUT_HI, q2); check("latch: HI after new LO read", q2, 2);
    axi_write(TPG_CTRL, 32'h0);

    // ---------------- 6. SEQ_RST + SOFT_RST while running ----------------
    $display("--- 6. SEQ_RST and SOFT_RST while running");
    drain();
    read64(TPG_SEQ_NEXT_LO, q);
    if (q == 0) fail("SEQ_NEXT is 0 before SEQ_RST");
    axi_write(TPG_CTRL, 32'h2);               // SEQ_RST, TPG disabled
    axi_read(TPG_CTRL, v);       check("TPG_CTRL.SEQ_RST self-clears", v, 0);
    wait_dp(300);
    read64(TPG_SEQ_NEXT_LO, q);  check("SEQ_NEXT after SEQ_RST", q, 0);
    // run everything, then SOFT_RST in the middle of traffic with drops
    axi_write(TPG_RATE_INC, 32'h8000_0000);
    axi_write(PKT_CTRL, 32'h1);
    axi_write(TPG_CTRL, 32'h1);
    ready_pct = 40;
    repeat (3000) @(posedge dp_clk);
    axi_read(ING_STATUS, v);     check("before SOFT_RST: OVERFLOW", v, 1);
    soft_reset();                            // TPG/packetizer are disabled by it
    repeat (500) @(posedge dp_clk);
    check_zero_state("after SOFT_RST while running");
    check("no beats after SOFT_RST", delivered, 0);
    axi_read(TPG_RATE_INC, v);   check("TPG_RATE_INC kept", v, 32'h8000_0000);
    // the datapath works normally afterwards
    mon_on = 1'b1;
    pkt_len_tb = 32;
    axi_write(PKT_LEN, 32);
    axi_write(TPG_RATE_INC, 32'h4000_0000);
    axi_write(PKT_CTRL, 32'h1);
    axi_write(TPG_CTRL, 32'h1);
    ready_pct = 100;
    repeat (4000) @(posedge src_clk);
    axi_write(TPG_CTRL, 32'h0);
    drain();
    check_accounting("after SOFT_RST");
    read64(ING_DROP_COUNT_LO, q); check("after SOFT_RST: DROP_COUNT", q, 0);
    if (mon_expect == 0) fail("after SOFT_RST: nothing delivered");
    // first beat after the soft reset carried seq 0
    if (gaps != 0) fail("after SOFT_RST: sequence did not restart at 0");

    if (errors == 0) $display("PASS: tb_fdrec_core");
    else             $display("FAIL: tb_fdrec_core (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("FAIL: tb_fdrec_core watchdog timeout");
    $finish;
  end

endmodule
