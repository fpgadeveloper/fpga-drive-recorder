# Replacing the checker with your own data sink

Playback sends a recording back into the fabric: the AXI DMA MM2S channel reads the DDR
buffers and `fdrec_core` streams them out to the `user_data_sink` hierarchy. On the reference
design that hierarchy holds `fdrec_check`, which verifies the test pattern. For a real
application (a DAC, a transmitter, a stimulus generator) you replace it with your own logic.
`fdrec_core`, the AXI DMA and the driver stay the same.

![The user_data_sink insertion point](images/fdrec-custom-sink.png)

## Hierarchy pins

| Pin | Direction | Width | Description |
|---|---|---|---|
| `snk_clk` | in | 1 | Sink clock. This is the same clock as `src_clk`, 250 MHz (PS `pl_clk2` on the Zynq UltraScale+ designs, CIPS `pl2_ref_clk` on Versal). |
| `snk_resetn` | in | 1 | Active-low reset, synchronous to `snk_clk` (from `rst_src_clk`). |
| `S_AXIS` | in | AXI4-Stream | `TDATA[255:0]` (`DATA_WIDTH` bits, see [Clocking and width](#clocking-and-width)), `TVALID`, `TREADY`, `TLAST`. No `TKEEP` or `TUSER`. |
| `chk_enable` | in | 1 | `CHK_CTRL.ENABLE`, synchronised to `snk_clk` (forced low during a soft reset). Optional. |
| `chk_reset` | in | 1 | `CHK_CTRL.RESET` pulse (also held high during a soft reset), synchronous to `snk_clk`. Optional. |
| `chk_rate_inc` | in | 32 | `CHK_RATE_INC`, synchronous to `snk_clk`. Optional. |
| `chk_beats`, `chk_errors`, `chk_gaps`, `chk_gap_beats`, `chk_underflows`, `chk_last_seq` | out | 64 each | Read back as the `CHK_*` registers (one coherent snapshot). Tie to 0 if unused, or reuse them for your own status counters. |

## The stream contract

* **Data**: each beat is 32 bytes of the file, little-endian — `TDATA[7:0]` is the first byte
  of each 32-byte block, exactly as `fdrec` recorded it. The file is played in whole beats:
  trailing bytes that do not fill a beat are not sent.
* **`TLAST`** marks the last beat of each DMA buffer (the playback app's `--buf-size`). It is
  not a frame marker of your data; ignore it unless you want buffer boundaries.
* **Backpressure is allowed.** Deassert `TREADY` whenever you are not ready. Nothing is lost:
  the egress FIFO (4096 beats × 32 B = 128 KB) fills and then the DMA waits. Data only arrives
  as fast as the DMA and the SSDs can deliver it, so the playback rate is set by the sink, up
  to the 8 GB/s of the 256-bit fabric datapath at 250 MHz (on Zynq UltraScale+ the
  `S_AXI_HP2_FPD` memory port, 5.16 / 5.24 GB/s peak, is lower). A sink at the full 8 GB/s
  leaves the egress FIFO no time to refill after a pause of the DMA: measured without an SSD,
  playback from DDR is clean up to 7500 MB/s on `vck190_fmcp1` and 5000 MB/s on `zcu106_hpc0`
  (see [Benchmarks](benchmarks.md#fabric-only-no-ssd)).
* **Underflow.** A sink that must consume at a fixed rate (a DAC) sees `TVALID` low when the
  SSD, the DMA or the driver cannot keep up. Your logic decides what to output then (repeat
  the last sample, output zero, ...). `fdrec_check` counts these events in `CHK_UNDERFLOWS`:
  ticks of its rate throttle on which `TVALID` was low, after the first beat, and only when
  more data followed — the idle time after the end of a playback is not an underflow. A
  playback of a TPG recording is clean when `CHK_ERRORS` = 0, `CHK_UNDERFLOWS` = 0 and
  `CHK_GAP_BEATS` equals the drop count in the file header (both in beats, for a recording
  made with the same beat size).
* **Priming.** At the start of a playback the egress FIFO is empty. A fixed-rate sink should
  start consuming only once data is buffered: start the DMA first, wait for the egress FIFO
  to fill (`EGR_FIFO_LEVEL`), then set `CHK_CTRL.ENABLE`. If you use `chk_enable` as your
  sink's run control you get the same behaviour.
* **Stopping.** If your sink stops consuming (for example `chk_enable` = 0) while a DMA
  transfer is in progress, the DMA stalls. Set `EGR_CTRL.FLUSH` to let it finish: beats are
  then accepted and discarded (counted in `EGR_DISCARD`).

## Rate throttle (`fdrec_check`)

`CHK_RATE_INC` is a Q1.31 fraction of one beat per `snk_clk` cycle, exactly like
`TPG_RATE_INC`: `0x8000_0000` = ready on every clock (the default, 8 GB/s with 32-byte beats
at 250 MHz), larger values clamp. `rate_bps = CHK_RATE_INC / 2^31 × SRC_CLK_HZ × BEAT_BYTES`.
A 31-bit fractional accumulator asserts `TREADY` on every carry, so the long-term rate is
exact. While `CHK_CTRL.ENABLE` is 0, `TREADY` is 0.

The checker verifies every 16-byte word of each beat: `upper == ~lower`, and word `k` of the
beat carries the sequence number of word 0 plus `k`. A beat that fails either counts as one
error. Sequence tracking is per beat, on the sequence number of word 0; `CHK_GAP_BEATS`
counts the missing beats, and `CHK_LAST_SEQ` is the sequence number (in words) of word 0 of
the last good beat.

## Clocking and width

The read side of the egress FIFO runs on `fdrec_core`'s `src_clk`, so the sink shares the
source's clock. If your sink needs a different clock, put an independent-clock AXI4-Stream
FIFO (`axis_data_fifo` with `IS_ACLK_ASYNC = 1`) inside `user_data_sink` between `S_AXIS` and
your logic.

The stream is 256 bits wide on the reference designs: the `DATA_WIDTH` parameter of the
`fdrec_*` modules, 256 (default) or 128, set together with the AXI DMA widths by the
`fdrec_data_width` variable of the block-design script (see
[custom data source](custom_source.md#data-width); the driver reads the beat size from
`BEAT_BYTES`, so software needs no change). For a narrower sink, use an
`axis_dwidth_converter` (32 bytes → your width, for example 16 bytes for a sink written for
the 128-bit interface) in the hierarchy; it hands out the lowest bits of each beat first, so
the file order is kept, and with backpressure allowed it works without any special care.

## Step by step

1. In the block-design script of your target's device family
   (`Vivado/src/bd/bd_zynqmp.tcl` for Zynq UltraScale+), find the `user_data_sink` hierarchy. Replace
   `create_bd_cell -type module -reference fdrec_check user_data_sink/fdrec_check_0` and its
   connections with your own IP or module reference. Keep the hierarchy pins; tie the
   `chk_*` counter outputs to 0 (an `xlconstant` of width 64) if you have nothing to report.
   Using `chk_enable` as your sink's run control is a good idea: it lets software start
   your sink after the egress FIFO has primed, and stop it.
2. Put your RTL in `Vivado/src/hdl/` (top module in a `.v` file, as for the source).
3. Rebuild with `./build.sh xsa --target <target>` and check timing, then rebuild the
   Linux image (`./build.sh yocto --target <target>`).
4. Play a recording with `fdplay --no-check <file>`. `--no-check` makes `fdplay` leave
   the checker registers alone: it does not reset or enable them and it does not compare
   the checker counters. If your sink uses `chk_enable`, set it by hand first
   (`echo 1 | sudo tee /sys/class/misc/fdrec0/chk_enable`), otherwise the stream stalls
   and `fdplay` gives up after `--timeout` seconds with exit code 1. Without the checker
   the exit code only tells you whether the playback was complete; underflow detection is
   up to your sink.
