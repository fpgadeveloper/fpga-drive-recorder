/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * fdrec_regs.h -- register map of the FPGA Drive Recorder fdrec_core block.
 *
 * One AXI-Lite register block (4 KB) holds every fdrec_* register: the test
 * pattern generator (fdrec_tpg), the ingest CDC FIFO (fdrec_ingest), the
 * packetizer (fdrec_packetizer) and, since version 1.1, the playback path:
 * the checker (fdrec_check) and the egress CDC FIFO (fdrec_egress). All registers are 32 bits wide; offsets are
 * byte offsets from the block's base address.
 *
 * This header is shared by the RTL documentation, the Linux kernel driver and
 * the user-space apps, so it is plain C (macros only, no includes) and must
 * stay in sync with docs/source/register_map.md and Vivado/src/hdl.
 *
 * Access types: RO = read-only, RW = read/write, W1C = write 1 to clear.
 *
 * 64-bit counters are split in a _LO and a _HI register. Reading _LO latches
 * the matching HI half; read _LO first, then _HI, to get a coherent 64-bit
 * value:
 *
 *     lo = rd(FDREC_X_LO); hi = rd(FDREC_X_HI); v = ((u64)hi << 32) | lo;
 *
 * GLOBAL_CTRL.SOFT_RST clears the ingest FIFO, all counters (including the
 * TPG sequence number, SEQ_NEXT), the FIFO high-water mark and the sticky
 * flags, and disables both the packetizer and the TPG. TPG_RATE_INC and
 * PKT_LEN keep their values. The bit clears itself: it reads 1 while the reset
 * is in progress (about 1 us); poll until it reads 0 before using the block.
 *
 * Values that originate in the src_clk domain (TPG_SEQ_NEXT, ING_BEATS_IN,
 * ING_DROP_COUNT and the OVERFLOW flag derived from it) are transferred to the
 * register clock as one coherent snapshot that is refreshed continuously; a
 * read returns a value at most ~0.5 us old. Within one snapshot
 * ING_BEATS_IN, ING_DROP_COUNT and TPG_SEQ_NEXT are mutually consistent.
 *
 * Reset values: TPG_RATE_INC = 0, PKT_LEN = 0x0008_0000 (8 MB / 16 B),
 * CHK_RATE_INC = 0x8000_0000, all enables 0, all counters 0.
 *
 * Playback (1.1): SOFT_RST also resets the egress FIFO, clears the CHK_* and
 * EGR_* counters, disables the checker and clears EGR_CTRL.FLUSH
 * (CHK_RATE_INC keeps its value). While SOFT_RST is in progress, beats from the
 * DMA MM2S are accepted and discarded, so a soft reset never wedges the DMA.
 * The CHK_* counters come from the src_clk domain as one coherent snapshot
 * (at most ~0.5 us old), like TPG_SEQ_NEXT / ING_*.
 */

#ifndef FDREC_REGS_H
#define FDREC_REGS_H

/* Size of the AXI-Lite register block */
#define FDREC_REG_SPAN                  0x1000

/* Register map version: [31:16] major, [15:0] minor */
#define FDREC_VERSION_MAJOR_SHIFT       16
#define FDREC_VERSION_MAJOR_MASK        0xFFFF0000u
#define FDREC_VERSION_MINOR_MASK        0x0000FFFFu
#define FDREC_VERSION_1_0               0x00010000u   /* version 1.0 */
#define FDREC_VERSION_1_1               0x00010001u   /* 1.1: + playback (CHK_, EGR_) */
#define FDREC_VERSION_EXPECTED          FDREC_VERSION_1_1

/* ---------------------------------------------------------------------------
 * Global
 * ------------------------------------------------------------------------- */

/* 0x000 VERSION (RO): [31:16] major, [15:0] minor; 1.0 = 0x0001_0000 */
#define FDREC_VERSION                   0x000

/* 0x004 SRC_CLK_HZ (RO): src_clk frequency in Hz (from a BD parameter) */
#define FDREC_SRC_CLK_HZ                0x004

/* 0x008 DP_CLK_HZ (RO): datapath clock (dp_clk) frequency in Hz */
#define FDREC_DP_CLK_HZ                 0x008

/* 0x00C GLOBAL_CTRL (RW) */
#define FDREC_GLOBAL_CTRL               0x00C
/* SOFT_RST (self-clearing): clear FIFO, counters, HWM and sticky flags;
 * disable the packetizer and the TPG */
#define FDREC_GLOBAL_CTRL_SOFT_RST      (1u << 0)

/* ---------------------------------------------------------------------------
 * Test pattern generator (fdrec_tpg)
 *
 * Each 128-bit beat carries TDATA[63:0] = seq, TDATA[127:64] = ~seq, where seq
 * increments on every emitted beat (including beats later dropped by ingest).
 * ------------------------------------------------------------------------- */

/* 0x010 TPG_CTRL (RW) */
#define FDREC_TPG_CTRL                  0x010
#define FDREC_TPG_CTRL_ENABLE           (1u << 0)   /* generator running */
#define FDREC_TPG_CTRL_SEQ_RST          (1u << 1)   /* self-clearing: seq := 0 */

/*
 * 0x014 TPG_RATE_INC (RW): average output rate as a Q1.31 fraction of one
 * beat per src_clk cycle. 0x8000_0000 = 1 beat/clock (maximum); larger values
 * clamp to the maximum. With 16-byte beats:
 *
 *     rate_bps = TPG_RATE_INC / 2^31 * SRC_CLK_HZ * 16
 *     TPG_RATE_INC = rate_bps * 2^31 / (SRC_CLK_HZ * 16)
 */
#define FDREC_TPG_RATE_INC              0x014
#define FDREC_TPG_RATE_INC_ONE          0x80000000u /* 1 beat per src_clk */
#define FDREC_TPG_RATE_INC_FRAC_BITS    31

/* 0x018/0x01C TPG_SEQ_NEXT (RO, 64-bit): next sequence number to emit */
#define FDREC_TPG_SEQ_NEXT_LO           0x018       /* read first: latches HI */
#define FDREC_TPG_SEQ_NEXT_HI           0x01C

/* ---------------------------------------------------------------------------
 * Ingest (fdrec_ingest): src_clk -> dp_clk CDC FIFO, drops when full
 * ------------------------------------------------------------------------- */

/* 0x020 ING_STATUS (RW) */
#define FDREC_ING_STATUS                0x020
#define FDREC_ING_STATUS_OVERFLOW       (1u << 0)   /* sticky, W1C: a beat was dropped */

/* 0x024 ING_FIFO_HWM (RW): FIFO high-water mark in beats; any write clears it.
 * Measured on the read side of the FIFO; a completely full FIFO can read
 * ING_FIFO_DEPTH + 1 (first-word-fall-through output register). */
#define FDREC_ING_FIFO_HWM              0x024

/* 0x028/0x02C ING_DROP_COUNT (RO, 64-bit): beats dropped because the FIFO was full */
#define FDREC_ING_DROP_COUNT_LO         0x028       /* read first: latches HI */
#define FDREC_ING_DROP_COUNT_HI         0x02C

/* 0x030/0x034 ING_BEATS_IN (RO, 64-bit): beats offered by the source */
#define FDREC_ING_BEATS_IN_LO           0x030       /* read first: latches HI */
#define FDREC_ING_BEATS_IN_HI           0x034

/* 0x038 ING_FIFO_DEPTH (RO): ingest FIFO depth in beats (RTL parameter) */
#define FDREC_ING_FIFO_DEPTH            0x038

/* ---------------------------------------------------------------------------
 * Packetizer (fdrec_packetizer): TLAST every PKT_LEN beats, gated by ENABLE
 * ------------------------------------------------------------------------- */

/* 0x040 PKT_CTRL (RW) */
#define FDREC_PKT_CTRL                  0x040
/* ENABLE: pass data to the DMA; a 0->1 transition resets the beat-in-packet
 * counter. While 0, TVALID to the DMA is held low. */
#define FDREC_PKT_CTRL_ENABLE           (1u << 0)

/* 0x044 PKT_LEN (RW): beats per packet; TLAST on the PKT_LEN-th beat.
 * The driver sets PKT_LEN = buffer_size / FDREC_BEAT_BYTES. The value is
 * sampled at the start of each packet (a change takes effect at the next
 * packet boundary); 0 is treated as 1. */
#define FDREC_PKT_LEN                   0x044

/* 0x048/0x04C PKT_BEATS_OUT (RO, 64-bit): beats delivered to the DMA */
#define FDREC_PKT_BEATS_OUT_LO          0x048       /* read first: latches HI */
#define FDREC_PKT_BEATS_OUT_HI          0x04C

/* ---------------------------------------------------------------------------
 * Playback checker (fdrec_check, user_data_sink hierarchy) -- version 1.1
 *
 * Models a DAC-like sink on src_clk: TREADY is asserted on a rate-throttle
 * tick (Q1.31, same scheme as the TPG). Each accepted beat is checked against
 * the TPG pattern (TDATA[127:64] == ~TDATA[63:0], TDATA[63:0] = seq).
 * Offsets 0x060-0x0BF are reserved for the playback path; unlisted offsets in
 * that range read 0.
 * ------------------------------------------------------------------------- */

/* 0x060 CHK_CTRL (RW) */
#define FDREC_CHK_CTRL                  0x060
/* ENABLE: sink consumes data (TREADY on throttle ticks). While 0, TREADY is
 * low: the egress FIFO fills and the DMA MM2S is backpressured. */
#define FDREC_CHK_CTRL_ENABLE           (1u << 0)
/* RESET (self-clearing): clear all CHK_ counters and the expected sequence
 * number (the next good beat defines it). Reads 1 while in progress (~1 us,
 * 256 dp_clk cycles); poll until 0. Write it with ENABLE = 0. */
#define FDREC_CHK_CTRL_RESET            (1u << 1)

/*
 * 0x064 CHK_RATE_INC (RW, reset 0x8000_0000): sink consumption rate as a Q1.31
 * fraction of one beat per src_clk cycle. 0x8000_0000 = ready every clock
 * (maximum, default); larger values clamp.
 *
 *     rate_bps = CHK_RATE_INC / 2^31 * SRC_CLK_HZ * 16
 */
#define FDREC_CHK_RATE_INC              0x064
#define FDREC_CHK_RATE_INC_ONE          0x80000000u

/* 0x068, 0x06C: reserved (read 0) */

/* 0x070/0x074 CHK_BEATS (RO, 64-bit): beats accepted by the checker */
#define FDREC_CHK_BEATS_LO              0x070       /* read first: latches HI */
#define FDREC_CHK_BEATS_HI              0x074

/* 0x078/0x07C CHK_ERRORS (RO, 64-bit): beats with TDATA[127:64] != ~TDATA[63:0]
 * (such a beat is not used for sequence tracking: expected just advances by
 * one) plus pattern-good beats whose seq is LOWER than expected (backwards) */
#define FDREC_CHK_ERRORS_LO             0x078       /* read first: latches HI */
#define FDREC_CHK_ERRORS_HI             0x07C

/* 0x080/0x084 CHK_GAPS (RO, 64-bit): events where seq > expected */
#define FDREC_CHK_GAPS_LO               0x080       /* read first: latches HI */
#define FDREC_CHK_GAPS_HI               0x084

/* 0x088/0x08C CHK_GAP_BEATS (RO, 64-bit): sum of (seq - expected) over all gap
 * events = missing sequence numbers. For a TPG recording this equals the
 * file header's drop count. A gap before the first beat is not counted. */
#define FDREC_CHK_GAP_BEATS_LO          0x088       /* read first: latches HI */
#define FDREC_CHK_GAP_BEATS_HI          0x08C

/* 0x090/0x094 CHK_UNDERFLOWS (RO, 64-bit): throttle ticks with no data
 * (TVALID low) after the first beat while enabled. Ticks are committed only
 * when another beat follows, so the idle time after the LAST beat of a
 * playback never counts: a complete playback reads 0 unless it starved. */
#define FDREC_CHK_UNDERFLOWS_LO         0x090       /* read first: latches HI */
#define FDREC_CHK_UNDERFLOWS_HI         0x094

/* 0x098/0x09C CHK_LAST_SEQ (RO, 64-bit): seq of the last pattern-good beat */
#define FDREC_CHK_LAST_SEQ_LO           0x098       /* read first: latches HI */
#define FDREC_CHK_LAST_SEQ_HI           0x09C

/* ---------------------------------------------------------------------------
 * Egress (fdrec_egress): dp_clk -> src_clk CDC FIFO between the DMA MM2S and
 * the sink. Lossless: when it is full, the DMA is backpressured. TLAST from
 * the DMA is passed to the sink; TKEEP is ignored (whole 16-byte beats).
 * EGR_ counters are cleared only by SOFT_RST (not by CHK_CTRL.RESET).
 * ------------------------------------------------------------------------- */

/* 0x0A0 EGR_CTRL (RW) */
#define FDREC_EGR_CTRL                  0x0A0
/* FLUSH: accept and DISCARD everything the DMA sends (TREADY = 1, nothing is
 * written; FIFO content is kept). Use it to let an MM2S transfer complete
 * when the sink is not consuming, e.g. to stop a playback cleanly. */
#define FDREC_EGR_CTRL_FLUSH            (1u << 0)

/* 0x0A4 EGR_FIFO_DEPTH (RO): egress FIFO depth in beats (RTL parameter
 * EGR_FIFO_DEPTH; 4096 = 64 KB on the reference design). At a sink rate R the
 * full FIFO bridges a DMA pause of EGR_FIFO_DEPTH * 16 / R seconds (65 us at
 * 1 GB/s, 20 us at 3.2 GB/s) -- e.g. the gap between MM2S descriptors. */
#define FDREC_EGR_FIFO_DEPTH            0x0A4

/* 0x0A8/0x0AC EGR_BEATS_IN (RO, 64-bit): beats written into the egress FIFO */
#define FDREC_EGR_BEATS_IN_LO           0x0A8       /* read first: latches HI */
#define FDREC_EGR_BEATS_IN_HI           0x0AC

/* 0x0B0/0x0B4 EGR_DISCARD (RO, 64-bit): beats discarded while FLUSH = 1 */
#define FDREC_EGR_DISCARD_LO            0x0B0       /* read first: latches HI */
#define FDREC_EGR_DISCARD_HI            0x0B4

/* 0x0B8 EGR_FIFO_LEVEL (RO): current egress FIFO occupancy in beats, seen
 * from the DMA side; a full FIFO can read EGR_FIFO_DEPTH + 1 */
#define FDREC_EGR_FIFO_LEVEL            0x0B8

/* 0x0BC: reserved (reads 0) */

/* ---------------------------------------------------------------------------
 * Datapath constants
 * ------------------------------------------------------------------------- */

#define FDREC_BEAT_BYTES                16          /* 128-bit AXI-Stream beat */

#endif /* FDREC_REGS_H */
