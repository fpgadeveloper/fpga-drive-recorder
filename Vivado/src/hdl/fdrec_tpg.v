// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_tpg -- FPGA Drive Recorder test pattern generator
//
// Models an ADC-like data source that cannot be stalled:
//
//   * The pattern is defined on 16-byte WORDS: word[63:0] = seq,
//     word[127:64] = ~seq, where seq is a 64-bit counter.
//   * Each emitted DATA_WIDTH-bit beat carries WORDS_PER_BEAT = DATA_WIDTH/128
//     consecutive words: word k (TDATA[128k+127:128k]) carries seq + k, and seq
//     advances by WORDS_PER_BEAT on every emitted beat. The byte stream is the
//     same for every DATA_WIDTH (word n of the stream carries seq n).
//   * The average output rate is set by tpg_rate_inc, a Q1.31 fraction of one
//     beat per src_clk cycle (0x8000_0000 = 1 beat/clock = the maximum; larger
//     values clamp to the maximum). A 31-bit fractional accumulator emits a beat
//     on every carry-out, so the long-term rate is exactly inc / 2^31 beats/clock.
//   * m_axis_tready is IGNORED: the generator never stalls (no backpressure).
//
// All inputs are in the src_clk domain. fdrec_core synchronises the control
// signals (tpg_enable, tpg_seq_rst, tpg_rate_inc) into src_clk and samples
// tpg_seq_next (seq of word 0 of the next beat) back into its register clock
// domain.
//
// tpg_seq_rst is level sensitive: while it is high seq is held at 0 and no beat
// is emitted.
//
// This module lives in the user_data_source block-design hierarchy, which is the
// documented insertion point for a customer's own data source.

`timescale 1ns / 1ps

module fdrec_tpg #(
  parameter integer DATA_WIDTH = 256    // 128 or 256
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 src_clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET src_resetn" *)
  input  wire                  src_clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 src_resetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                  src_resetn,

  // Control / status (src_clk domain)
  input  wire                  tpg_enable,
  input  wire                  tpg_seq_rst,
  input  wire [31:0]           tpg_rate_inc,
  output wire [63:0]           tpg_seq_next,

  // AXI4-Stream master (no backpressure: tready is ignored)
  output reg  [DATA_WIDTH-1:0] m_axis_tdata,
  output reg                   m_axis_tvalid,
  input  wire                  m_axis_tready
);

  localparam integer WORDS_PER_BEAT = DATA_WIDTH / 128;
  localparam [31:0]  INC_ONE = 32'h8000_0000;

  generate
    if (DATA_WIDTH != 128 && DATA_WIDTH != 256) begin : g_bad_width
      DATA_WIDTH_must_be_128_or_256 u_param_error ();
    end
  endgenerate

  reg  [63:0] seq;
  reg  [30:0] acc;
  reg  [31:0] inc_q;

  // Register the (quasi-static) increment and clamp it to 1 beat/clock
  always @(posedge src_clk) begin
    if (!src_resetn)
      inc_q <= 32'd0;
    else
      inc_q <= (tpg_rate_inc > INC_ONE) ? INC_ONE : tpg_rate_inc;
  end

  // Fractional accumulator: carry out of bit 30 = emit a beat
  wire [31:0] sum  = {1'b0, acc} + inc_q;
  wire        emit = tpg_enable & ~tpg_seq_rst & sum[31];

  // The pattern words of the next beat: seq, seq + 1, ...
  wire [DATA_WIDTH-1:0] beat;
  genvar k;
  generate
    for (k = 0; k < WORDS_PER_BEAT; k = k + 1) begin : g_word
      wire [63:0] s = seq + k;
      assign beat[128*k +: 128] = {~s, s};
    end
  endgenerate

  always @(posedge src_clk) begin
    if (!src_resetn) begin
      seq           <= 64'd0;
      acc           <= 31'd0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata  <= {DATA_WIDTH{1'b0}};
    end else begin
      m_axis_tvalid <= emit;
      if (tpg_seq_rst) begin
        seq <= 64'd0;
        acc <= 31'd0;
      end else if (tpg_enable) begin
        acc <= sum[30:0];
        if (emit) begin
          m_axis_tdata <= beat;
          seq          <= seq + WORDS_PER_BEAT;
        end
      end
    end
  end

  assign tpg_seq_next = seq;

endmodule
