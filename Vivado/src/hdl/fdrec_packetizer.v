// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// fdrec_packetizer -- TLAST framing and enable gate in front of the AXI DMA
//
//   * Pass-through from the ingest FIFO (first-word-fall-through) to m_axis,
//     through a 2-entry register slice (registered TREADY towards the FIFO).
//   * TLAST is asserted on every pkt_len-th beat delivered on m_axis.
//     pkt_len is sampled at the start of every packet, so a change takes effect
//     at the next packet boundary. pkt_len = 0 is treated as 1.
//   * enable = 0 holds m_axis_tvalid low (data stays in the FIFO, which then
//     fills and overflows upstream -- intended and counted). A 0->1 transition
//     of enable restarts the beat-in-packet counter, so the first beat after
//     enabling is beat 1 of a new packet.
//   * beats_out counts beats delivered (m_axis_tvalid & m_axis_tready).
//   * srst (dp_clk domain, level) empties the register slice, clears beats_out
//     and restarts the packet counter.
//
// The packetizer sits downstream of the drop point, so drops never break framing.

`timescale 1ns / 1ps

module fdrec_packetizer (
  input  wire          clk,
  input  wire          srst,

  input  wire          enable,
  input  wire [31:0]   pkt_len,
  output reg  [63:0]   beats_out,

  // From the ingest FIFO (FWFT)
  input  wire [127:0]  s_tdata,
  input  wire          s_tvalid,
  output wire          s_tready,

  // To the AXI DMA S2MM stream
  output wire [127:0]  m_axis_tdata,
  output wire [15:0]   m_axis_tkeep,
  output wire          m_axis_tlast,
  output wire          m_axis_tvalid,
  input  wire          m_axis_tready
);

  // ---------------------------------------------------------------------------
  // 2-entry register slice: d0 = output register, d1 = skid register
  // ---------------------------------------------------------------------------
  reg [127:0] d0, d1;
  reg         v0, v1;
  reg         en_q;          // registered enable (gate)

  assign s_tready = ~v1;

  wire in_fire  = s_tvalid & ~v1;
  wire out_fire = v0 & en_q & m_axis_tready;

  always @(posedge clk) begin
    if (srst) begin
      v0 <= 1'b0;
      v1 <= 1'b0;
    end else begin
      if (out_fire || !v0) begin
        if (v1) begin
          d0 <= d1;
          v0 <= 1'b1;
          if (in_fire) begin d1 <= s_tdata; v1 <= 1'b1; end
          else         v1 <= 1'b0;
        end else begin
          if (in_fire) begin d0 <= s_tdata; v0 <= 1'b1; end
          else         v0 <= 1'b0;
        end
      end else if (in_fire) begin
        d1 <= s_tdata;
        v1 <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Enable gate and packet counter
  //   rem    = beats remaining in the current packet (including the current one)
  //   rem_1  = (rem == 1): the current output beat carries TLAST
  // ---------------------------------------------------------------------------
  wire [31:0] len_eff = (pkt_len == 32'd0) ? 32'd1 : pkt_len;
  reg  [31:0] rem;
  reg         rem_1;

  always @(posedge clk) begin
    if (srst) begin
      en_q      <= 1'b0;
      rem       <= len_eff;
      rem_1     <= (len_eff == 32'd1);
      beats_out <= 64'd0;
    end else begin
      en_q <= enable;
      if (out_fire)
        beats_out <= beats_out + 64'd1;
      // Restart the packet when the gate opens (0->1 of the registered enable;
      // no beat can be delivered in that cycle because en_q was 0 before it)
      if (enable && !en_q) begin
        rem   <= len_eff;
        rem_1 <= (len_eff == 32'd1);
      end else if (out_fire) begin
        if (rem_1) begin
          rem   <= len_eff;
          rem_1 <= (len_eff == 32'd1);
        end else begin
          rem   <= rem - 32'd1;
          rem_1 <= (rem == 32'd2);
        end
      end
    end
  end

  assign m_axis_tdata  = d0;
  assign m_axis_tkeep  = 16'hFFFF;
  assign m_axis_tvalid = v0 & en_q;
  assign m_axis_tlast  = rem_1;

endmodule
