# Register map

All `fdrec_*` registers live in one 4 KB AXI-Lite register block (`fdrec_core`). Registers
are 32 bits wide; offsets are byte offsets from the block's base address. The same map is
defined for software in [`include/fdrec_regs.h`](https://github.com/fpgadeveloper/fpga-drive-recorder/blob/dev/include/fdrec_regs.h),
which is shared by the kernel driver and the apps. Keep this page, the header and the RTL
(`Vivado/src/hdl/fdrec_regs.v`) in sync.

The base address of the block depends on the target: on the Zynq UltraScale+ designs it
is **`0x4_2001_0000`** (see the [address map](architecture.md#address-map-zynq-ultrascale-designs)).
Software does not need to know it: the kernel driver takes it from the device tree, and the
apps use the driver. To poke a register by hand, use `devmem2` (in the image) with the base
address plus the offset, for example `sudo devmem2 0x420010000 w` reads `VERSION`.

## How to read the register map

* **Access types.** **RO** = read-only (writes are ignored). **RW** = read/write.
  **W1C** = write 1 to clear: writing 1 to the bit clears it, writing 0 leaves it alone
  (`ING_STATUS.OVERFLOW`). Unmapped offsets read as 0 and ignore writes.
* **Self-clearing bits** (`GLOBAL_CTRL.SOFT_RST`, `TPG_CTRL.SEQ_RST`, `CHK_CTRL.RESET`)
  start an action when you write 1 and return to 0 by themselves. `SOFT_RST` and
  `CHK_CTRL.RESET` read 1 while the action is in progress, so poll them until they read 0;
  `SEQ_RST` always reads 0.
* **"Any write clears"** (`ING_FIFO_HWM`): writing any value resets the high-water mark.
* **64-bit counters** are split into a `*_LO` and a `*_HI` register; read `*_LO` first (see
  below).
* **Parameter** in the reset column means the value is set when the design is built
  (block-design parameters of `fdrec_core`), not at run time.

## Conventions

* **64-bit counters** are split into a `*_LO` and a `*_HI` register. Reading `*_LO` latches
  the matching HI half; read `*_LO` first, then `*_HI`, to get a coherent 64-bit value:

  ```c
  lo = rd(FDREC_X_LO); hi = rd(FDREC_X_HI); v = ((uint64_t)hi << 32) | lo;
  ```

  Reading `*_HI` again returns the same latched value until `*_LO` is read again.
* **`GLOBAL_CTRL.SOFT_RST`** clears the ingest FIFO, all counters (including the TPG sequence
  number `SEQ_NEXT`), the FIFO high-water mark and the sticky flags, and disables the
  packetizer and the TPG. Since 1.1 it also resets the egress FIFO and the checker, clears
  the `CHK_*` / `EGR_*` counters, disables the checker and clears `EGR_CTRL.FLUSH`; while it
  is in progress, beats from the DMA MM2S are accepted and discarded, so a soft reset never
  wedges the DMA. `TPG_RATE_INC`, `PKT_LEN` and `CHK_RATE_INC` keep their values. The bit clears
  itself: it reads 1 while the reset is in progress (about 1 µs), so poll it until it reads 0
  before you use the block. Writing `SOFT_RST` while a reset is in progress has no effect.
* **Source-clock values.** `TPG_SEQ_NEXT`, `ING_BEATS_IN`, `ING_DROP_COUNT` and the
  `OVERFLOW` flag (which is derived from the drop counter) come from the `src_clk` domain.
  They cross to the register clock as one coherent snapshot that is refreshed all the time,
  so a read returns a value that is at most about 0.5 µs old. Within one snapshot the three
  counters are consistent with each other. The six `CHK_*` counters of the playback checker
  come from the `src_clk` domain the same way, as one separate coherent snapshot.
* **TPG rate:** `TPG_RATE_INC` is a Q1.31 fraction of one beat per `src_clk` cycle
  (`0x8000_0000` = 1 beat/clock, the maximum; larger values clamp). With 16-byte beats:

  ```
  rate_bps     = TPG_RATE_INC / 2^31 × SRC_CLK_HZ × 16
  TPG_RATE_INC = rate_bps × 2^31 / (SRC_CLK_HZ × 16)
  ```

  For example, at `SRC_CLK_HZ` = 199 998 001 the maximum rate is 3.19997 GB/s, and
  1 GB/s (10⁹ B/s) is `TPG_RATE_INC` = `0x2800_1A34`.

## Registers

| Offset | Name | Access | Reset | Bits |
|---|---|---|---|---|
| 0x000 | `VERSION` | RO | `0x0001_0001` | [31:16] major, [15:0] minor (1.1 = `0x0001_0001`; 1.0 had no playback registers) |
| 0x004 | `SRC_CLK_HZ` | RO | parameter | `src_clk` frequency in Hz (from BD parameter) |
| 0x008 | `DP_CLK_HZ` | RO | parameter | datapath clock frequency in Hz |
| 0x00C | `GLOBAL_CTRL` | RW | 0 | bit0 `SOFT_RST` (self-clearing; reads 1 while in progress) |
| 0x010 | `TPG_CTRL` | RW | 0 | bit0 `ENABLE`, bit1 `SEQ_RST` (self-clearing, reads 0; seq := 0) |
| 0x014 | `TPG_RATE_INC` | RW | 0 | Q1.31 beats/clock: `0x8000_0000` = 1 beat/clk (max; larger clamps) |
| 0x018 | `TPG_SEQ_NEXT_LO` | RO | 0 | next sequence number to emit (low 32 bits; latches HI) |
| 0x01C | `TPG_SEQ_NEXT_HI` | RO | 0 | next sequence number to emit (high 32 bits) |
| 0x020 | `ING_STATUS` | RW | 0 | bit0 `OVERFLOW` sticky (W1C) |
| 0x024 | `ING_FIFO_HWM` | RW | 0 | FIFO high-water mark in beats; any write clears |
| 0x028 | `ING_DROP_COUNT_LO` | RO | 0 | beats dropped (64-bit, low; latches HI) |
| 0x02C | `ING_DROP_COUNT_HI` | RO | 0 | beats dropped (high) |
| 0x030 | `ING_BEATS_IN_LO` | RO | 0 | beats offered by the source (64-bit, low; latches HI) |
| 0x034 | `ING_BEATS_IN_HI` | RO | 0 | beats offered by the source (high) |
| 0x038 | `ING_FIFO_DEPTH` | RO | parameter | FIFO depth in beats (parameter) |
| 0x040 | `PKT_CTRL` | RW | 0 | bit0 `ENABLE` (0→1 resets the beat-in-packet counter) |
| 0x044 | `PKT_LEN` | RW | `0x0008_0000` | beats per packet (TLAST on the `PKT_LEN`-th beat) |
| 0x048 | `PKT_BEATS_OUT_LO` | RO | 0 | beats delivered to the DMA (64-bit, low; latches HI) |
| 0x04C | `PKT_BEATS_OUT_HI` | RO | 0 | beats delivered to the DMA (high) |
| 0x060 | `CHK_CTRL` | RW | 0 | bit0 `ENABLE`, bit1 `RESET` (self-clearing; reads 1 while in progress) |
| 0x064 | `CHK_RATE_INC` | RW | `0x8000_0000` | Q1.31 beats/clock the sink accepts: `0x8000_0000` = every clock (max; larger clamps) |
| 0x068–0x06C | — | | 0 | reserved |
| 0x070 | `CHK_BEATS_LO` | RO | 0 | beats accepted by the checker (64-bit, low; latches HI) |
| 0x074 | `CHK_BEATS_HI` | RO | 0 | (high) |
| 0x078 | `CHK_ERRORS_LO` | RO | 0 | pattern errors + backwards sequence numbers (64-bit, low; latches HI) |
| 0x07C | `CHK_ERRORS_HI` | RO | 0 | (high) |
| 0x080 | `CHK_GAPS_LO` | RO | 0 | sequence gap events (64-bit, low; latches HI) |
| 0x084 | `CHK_GAPS_HI` | RO | 0 | (high) |
| 0x088 | `CHK_GAP_BEATS_LO` | RO | 0 | missing sequence numbers, summed (64-bit, low; latches HI) |
| 0x08C | `CHK_GAP_BEATS_HI` | RO | 0 | (high) |
| 0x090 | `CHK_UNDERFLOWS_LO` | RO | 0 | throttle ticks without data inside the stream (64-bit, low; latches HI) |
| 0x094 | `CHK_UNDERFLOWS_HI` | RO | 0 | (high) |
| 0x098 | `CHK_LAST_SEQ_LO` | RO | 0 | sequence number of the last good beat (64-bit, low; latches HI) |
| 0x09C | `CHK_LAST_SEQ_HI` | RO | 0 | (high) |
| 0x0A0 | `EGR_CTRL` | RW | 0 | bit0 `FLUSH` (accept and discard the DMA stream) |
| 0x0A4 | `EGR_FIFO_DEPTH` | RO | parameter | egress FIFO depth in beats (`EGR_FIFO_DEPTH` parameter, 4096 = 64 KB) |
| 0x0A8 | `EGR_BEATS_IN_LO` | RO | 0 | beats written into the egress FIFO (64-bit, low; latches HI) |
| 0x0AC | `EGR_BEATS_IN_HI` | RO | 0 | (high) |
| 0x0B0 | `EGR_DISCARD_LO` | RO | 0 | beats discarded while `FLUSH` = 1 (64-bit, low; latches HI) |
| 0x0B4 | `EGR_DISCARD_HI` | RO | 0 | (high) |
| 0x0B8 | `EGR_FIFO_LEVEL` | RO | 0 | current egress FIFO fill level in beats (DMA side) |
| 0x0BC | — | | 0 | reserved |

## Register details

**`TPG_CTRL`** — `ENABLE` starts and stops the test pattern generator. Writing 1 to
`SEQ_RST` sets the sequence number back to 0; the bit always reads 0. These bits only control
the built-in TPG. A custom data source in `user_data_source` can use them or ignore them
(see [Replacing the test pattern generator](custom_source.md)).

**`ING_STATUS.OVERFLOW`** — set when beats are dropped because the ingest FIFO is full. Write 1
to clear it. If drops are still happening, the flag sets again on the next snapshot.

**`ING_FIFO_HWM`** — the highest FIFO fill level seen since the last clear, in beats. It is
measured on the read side of the FIFO, so a completely full FIFO can read
`ING_FIFO_DEPTH + 1` (the extra beat is the first-word-fall-through output register).

**`ING_BEATS_IN` / `ING_DROP_COUNT` / `PKT_BEATS_OUT`** — at any time
`BEATS_IN = beats accepted into the FIFO + DROP_COUNT`. Once the FIFO has drained,
`PKT_BEATS_OUT = BEATS_IN − DROP_COUNT`. A recording is valid only if `DROP_COUNT` is 0.

**`PKT_CTRL.ENABLE`** — while 0, TVALID towards the DMA is held low and data builds up in (and
then overflows from) the ingest FIFO. A 0→1 transition restarts the packet, so the first beat
after enabling is beat 1 of a new `PKT_LEN`-beat packet. `PKT_BEATS_OUT` is not reset by
enable; use `SOFT_RST` for that.

**`PKT_LEN`** — the packetizer reads it at the start of each packet, so a change takes effect at
the next packet boundary. 0 is treated as 1. The driver sets `PKT_LEN = buffer_size / 16`, so
every DMA descriptor ends exactly on a buffer boundary. The AXI DMA buffer length register is
26 bits wide, so a buffer (and a packet) can be up to 64 MB − 16 B (`PKT_LEN` ≤ 4 194 303).

## Playback registers (1.1)

**`CHK_CTRL.ENABLE`** — while 1, the checker (`fdrec_check` in `user_data_sink`) asserts
`TREADY` on the ticks of its rate throttle; while 0, `TREADY` is 0, so the egress FIFO fills and
the DMA MM2S channel waits. Start a playback by starting the DMA first and setting `ENABLE` once
the egress FIFO has filled (`EGR_FIFO_LEVEL` ≥ `EGR_FIFO_DEPTH`, or a few µs), so the sink does
not starve at the start.

**`CHK_CTRL.RESET`** — write 1 (with `ENABLE` = 0) to clear all `CHK_*` counters and the
expected sequence number. The bit reads 1 for about 1 µs while the reset is in progress; poll
until 0. The first good beat after the reset sets the expected sequence number, so a
playback may start at any sequence number. `RESET` does not clear the `EGR_*` counters.

**`CHK_RATE_INC`** — the sink's consumption rate, the same Q1.31 format as `TPG_RATE_INC`:
`rate_bps = CHK_RATE_INC / 2^31 × SRC_CLK_HZ × 16`. Default `0x8000_0000` (every `src_clk`
cycle, 3.2 GB/s). The playback app's `--rate` option programs it.

**Checker counters.** For every accepted beat, `seq = TDATA[63:0]`:

* `TDATA[127:64] ≠ ~TDATA[63:0]` → `CHK_ERRORS` += 1. The beat is not used for sequence
  tracking (the expected number just advances by one), so one corrupted beat is exactly one
  error and never a false gap.
* otherwise, against the expected number: equal → OK; `seq` greater → `CHK_GAPS` += 1 and
  `CHK_GAP_BEATS` += `seq − expected`; `seq` smaller → `CHK_ERRORS` += 1. Then
  expected := `seq + 1` and `CHK_LAST_SEQ` := `seq`.
* `CHK_UNDERFLOWS` counts throttle ticks on which `TVALID` was low, after the first beat, while
  enabled. Ticks are only committed when another beat follows, so the idle time after the
  last beat of a playback is never counted: a complete playback that never starved reads 0.

For a playback of a TPG recording: `CHK_GAP_BEATS` equals the file header's drop count,
`CHK_BEATS` equals the number of beats in the file, and `CHK_ERRORS` = 0.

**`EGR_CTRL.FLUSH`** — while 1, the egress FIFO accepts every beat from the DMA and discards it
(`TREADY` = 1, nothing written; `EGR_DISCARD` counts them). The data already in the FIFO stays.
Use it to let an MM2S transfer finish when the sink is not consuming.

**`EGR_FIFO_LEVEL`** — measured on the DMA side; a completely full FIFO can read
`EGR_FIFO_DEPTH + 1` (first-word-fall-through output register).

**`EGR_BEATS_IN` / `EGR_DISCARD`** — cleared only by `SOFT_RST`. Once the FIFO has drained into
the sink, `CHK_BEATS` (since the last `CHK_CTRL.RESET`) accounts for every beat in
`EGR_BEATS_IN` (since the last `SOFT_RST`): playback never loses data.
