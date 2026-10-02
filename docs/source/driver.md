# Kernel driver

The `fdrec` kernel module (`sw/fdrec-driver/`) connects the recorder hardware to user space.
It drives the `fdrec_core` register block (test pattern generator, ingest FIFO, packetizer,
and from register map 1.1 the playback checker and egress FIFO) and the S2MM (record) and
MM2S (playback) channels of the AMD AXI DMA, through the standard `xilinx_dma` dmaengine
driver of the kernel. The image built by the Yocto flow loads it at boot; it binds to the
`compatible = "opsero,fdrec"` device-tree node and creates `/dev/fdrec0`.

The user-space API is defined in [`include/fdrec_uapi.h`](https://github.com/fpgadeveloper/fpga-drive-recorder/blob/dev/include/fdrec_uapi.h),
which is shared by the driver and the apps. The register map is in
[`include/fdrec_regs.h`](https://github.com/fpgadeveloper/fpga-drive-recorder/blob/dev/include/fdrec_regs.h)
(see [Register map](register_map)).

## Buffer model

The recording is **zero-copy**: the AXI DMA writes the samples into buffers in PS DDR, and
the NVMe controller reads the very same buffers when the recorder app writes them to the
file with `O_DIRECT`. The CPU never copies sample data; it only does the bookkeeping.

User space owns the memory and the driver pins it:

1. The app allocates N buffers (default 32 × 8 MB) from 2 MB hugepages (`mmap` with
   `MAP_HUGETLB`). These are ordinary pages, so `O_DIRECT` writes from them work.
   (Buffers allocated in the driver and mapped to user space with `remap_pfn_range` would
   make `O_DIRECT` fail with `EFAULT`, which is why the driver does not do that.)
2. `FDREC_IOC_REGISTER_BUFS` pins the pages (`pin_user_pages_fast` with
   `FOLL_WRITE | FOLL_LONGTERM`), builds an `sg_table` per buffer and maps it with
   `dma_map_sgtable(..., DMA_FROM_DEVICE)` against the DMA channel's device.
3. `FDREC_IOC_START` resets the datapath (`GLOBAL_CTRL.SOFT_RST`: FIFO flushed, counters
   cleared), sets `PKT_LEN = buffer_size / 16`, puts every buffer in the driver's DMA queue
   and submits the first two as `dmaengine_prep_slave_sg` descriptors with a completion
   callback (one active, one pending; each completion submits the next queued buffer, see
   below), then enables the packetizer and (optionally) the test pattern generator.
4. `FDREC_IOC_WAIT_FILLED` blocks until a buffer is complete and returns its index and byte
   count. Before it returns, the driver calls `dma_sync_sgtable_for_cpu(DMA_FROM_DEVICE)`.
5. `FDREC_IOC_RELEASE` gives a buffer back once the app has written it to disk. The driver
   calls `dma_sync_sgtable_for_device(DMA_FROM_DEVICE)` and puts it back in the DMA queue.
6. `FDREC_IOC_STOP` reads the final counters, lets the buffers the DMA still owns fill up
   (at most two; with the test pattern generator it runs at full rate meanwhile, so this
   takes a few ms; their data is discarded), then disables the packetizer, stops the DMA
   (`dmaengine_terminate_sync`) and returns the counters.
7. Closing the file stops everything, unmaps and unpins the buffers and resets the hardware.

Because the packetizer asserts TLAST every `PKT_LEN` beats, every DMA descriptor ends exactly
on a buffer boundary. If no buffer is free, the DMA stalls, the packetizer is back-pressured,
the ingest FIFO fills and beats are dropped and counted. That is the only failure mode, and
it is always reported: the drop count is in the stats, in every `WAIT_FILLED` result and in
the file header.

### Cache coherency

The AXI DMA writes DDR through an `S_AXI_HP` port, which is **not** coherent with the APU
caches, and the buffers are ordinary cacheable pages that two devices use in turn: the AXI
DMA writes them, then the NVMe controller reads them (the NVMe driver maps them
`DMA_TO_DEVICE` for the `O_DIRECT` write, which cleans the cache). Both syncs in the buffer
model are therefore mandatory, and the driver source explains them in a comment:

* **Before a buffer is (re)queued** (`START`, `RELEASE`): `dma_sync_sgtable_for_device`, which
  on arm64 is a clean to the point of coherency. No dirty cache line of the buffer may exist
  while the fabric writes it; a later clean or eviction of such a line (for example the clean
  done by the NVMe driver's `DMA_TO_DEVICE` mapping) would overwrite fabric data with stale
  CPU data.
* **Before a buffer is handed to user space** (`WAIT_FILLED`): `dma_sync_sgtable_for_cpu`, an
  invalidate, so that neither the CPU nor the NVMe mapping's clean can see or write back lines
  that were speculatively fetched while the DMA was filling the buffer.

These are cache-maintenance operations only; no data is copied. If the DMA node were marked
`dma-coherent` (HPC port through the CCI), they would become no-ops, which is also correct.
The Zynq UltraScale+ designs use `S_AXI_HP2_FPD`, and the device tree must not mark the DMA
`dma-coherent`; the driver logs `DMA device is marked dma-coherent` at probe if it is.

## Playback

Playback is the mirror image: the NVMe controller reads the file straight into the hugepage
buffers (`O_DIRECT` reads), and the AXI DMA MM2S channel streams the same buffers into the
fabric, through the egress FIFO to the data sink (`user_data_sink`; in the reference design
the `fdrec_check` checker, see [Register map](register_map)). Again no sample data is copied
by the CPU.

1. The app registers its buffers with `fdrec_bufs.flags = FDREC_DIR_PLAY`: the driver pins
   them the same way and maps them `DMA_TO_DEVICE`. A registered set has one direction;
   the record ioctls refuse a playback set and vice versa (`EINVAL`).
2. `FDREC_IOC_PLAY_START` arms the MM2S channel. With `FDREC_PLAY_CHECK` it first issues
   `GLOBAL_CTRL.SOFT_RST` (empties the egress FIFO of anything an aborted playback left,
   clears every counter; `CHK_RATE_INC` is kept) and resets the checker with `ENABLE` = 0,
   so its expected sequence number is set by the first beat of this playback. The checker
   is **enabled only once the stream has primed the egress FIFO**: the first `PLAY_SUBMIT`
   waits (≤ 100 ms) until `EGR_FIFO_LEVEL` reaches 31/32 of `EGR_FIFO_DEPTH`, or the whole
   first buffer if that is smaller (a first buffer that completes earlier enables it from
   the completion callback). Enabled any earlier, the sink would start on the first beat
   while the MM2S is still ramping up and count those starved cycles as underflows.
   Without the flag nothing in the fabric is touched. Every buffer now belongs to the app.
3. The app fills a buffer and calls `FDREC_IOC_PLAY_SUBMIT(index, bytes)`: the driver calls
   `dma_sync_sgtable_for_device(DMA_TO_DEVICE)` and queues the buffer as one
   `dmaengine_prep_slave_sg(DMA_MEM_TO_DEV)` descriptor (a shortened copy of the
   scatterlist when `bytes` is less than the buffer size). Buffers are played in submission
   order, with the same **one active + one pending** feed as for recording. Each buffer is
   one AXI-Stream packet: `xilinx_dma` sets SOP on its first and EOP (TLAST) on its last
   buffer descriptor.
4. `FDREC_IOC_PLAY_WAIT_DONE` returns the next buffer the DMA has finished reading; the app
   refills it. Done means the DMA has read it -- its last beats may still be in the egress
   FIFO (`EGR_FIFO_DEPTH` beats, 4096 = 64 KB in the reference design) on their way to the
   sink.
5. `FDREC_IOC_PLAY_STOP` returns the counters, stops feeding, sets `EGR_CTRL.FLUSH` if the
   DMA still owns buffers (the egress FIFO then accepts and discards everything, so the at
   most two in-flight descriptors complete within microseconds whatever the sink does),
   terminates the idle channel, clears `FLUSH`, renews the channel (descriptor ring, see
   below) and disables a checker that `PLAY_START` enabled (its counters keep their values).
   At the end of a complete playback the DMA is already idle and nothing is discarded.
6. Closing the file stops the playback and unpins the buffers. Unlike after a recording, the
   driver does not reset the hardware: a sink set up by hand (`fdplay --no-check`) is left
   alone.

If the app cannot refill buffers as fast as the sink consumes them, the stream runs dry and
the checker counts **underflows** -- the mirror image of the recorder's drops. The DMA is
never starved of buffers in a way that loses data: an empty queue just pauses the stream.

### Cache coherency for playback

The AXI DMA reads DDR through the same non-coherent `S_AXI_HP2_FPD` port. The buffers were
written by the NVMe controller (the app's `O_DIRECT` read: the NVMe driver maps the pages
`DMA_FROM_DEVICE` and invalidates them when it unmaps).

* **Before a buffer is queued** (`PLAY_SUBMIT`): `dma_sync_sgtable_for_device(DMA_TO_DEVICE)`,
  a clean to the point of coherency. This is the mandatory one: any line the CPU dirtied (an
  app that generates or patches data with the CPU, a page-cache fallback) must reach DDR
  before the DMA reads DDR, which it does without looking at the caches. For data that
  arrived by NVMe DMA there are no dirty lines -- at most clean lines that are stale
  (speculatively fetched while the NVMe controller was writing DDR). A clean never writes a
  clean line back, so stale-clean lines are harmless here: the AXI DMA reads the NVMe data
  from DDR, and the CPU never looks at it.
* **When a buffer is handed back** (`PLAY_WAIT_DONE`): `dma_sync_sgtable_for_cpu(DMA_TO_DEVICE)`,
  which is a no-op on arm64 (the device did not write the buffer); it is there for the DMA
  API ownership rules.

## Device node and limits

| Item | Value |
|------|-------|
| Device | `/dev/fdrec0` (misc device; one opener at a time, a second `open` gets `EBUSY`) |
| Device tree | `compatible = "opsero,fdrec"`, `reg` = the 4 KB fdrec register block, `dmas = <&axi_dma_0 1>, <&axi_dma_0 0>`, `dma-names = "rx", "tx"` (`xilinx_dma` numbers an AXI DMA's channels 0 = MM2S, 1 = S2MM). `"tx"` is optional: without it the driver probes record-only |
| Capabilities | `fdrec_info.caps`: `FDREC_CAP_TPG`, `FDREC_CAP_S2MM`; `FDREC_CAP_MM2S` when the `"tx"` channel exists; `FDREC_CAP_CHECK` when `VERSION` ≥ 1.1 (checker and egress registers) |
| Buffers | 2 to 64 per open file; size a multiple of 2 MB, at most 62 MB (`PKT_LEN` ≤ 2^22 - 1 beats); each buffer 2 MB aligned |
| DMA descriptors | all registered buffers together may need at most 511 AXI DMA buffer descriptors (one per physically contiguous run of up to 64 MB - 1; the default 32 × 8 MB of hugepages needs at most 128) |
| Module parameter | `stop_drain_ms` (default 5000, writable at `/sys/module/fdrec/parameters/stop_drain_ms`): the longest time `STOP` / `PLAY_STOP` waits for the buffers the DMA still owns to complete before it terminates the channel anyway (see below) |
| Kernel log at probe | `fdrec <addr>.fdrec_core: /dev/fdrec0: fdrec_core v1.1, src_clk … Hz, dp_clk … Hz, FIFO 4096 beats, DMA rx dma0chan1 tx dma0chan0 (max segment 67108863 bytes), checker`; without a `"tx"` channel: `no DMA channel "tx" (…): record only` |
| Addressing | the buffers must be directly addressable by the AXI DMA (no swiotlb bouncing): the driver refuses a buffer whose DMA address differs from its physical address. The design's AXI DMA uses 64-bit addressing, so all of PS DDR is reachable |

## ioctl reference

All ioctls use the magic `0xBD` and the fixed-layout structures of `fdrec_uapi.h` (identical
for 32-bit and 64-bit user space).

| ioctl | Argument | Description |
|-------|----------|-------------|
| `FDREC_IOC_GET_INFO` | `struct fdrec_info` (out) | API version, `VERSION` register, `SRC_CLK_HZ`, `DP_CLK_HZ`, beat size (16), FIFO depth, buffer limits, the AXI DMA's maximum segment length |
| `FDREC_IOC_REGISTER_BUFS` | `struct fdrec_bufs` (in) | Pin and map `count` buffers of `buf_size` bytes whose user addresses are in the `__u64` array `addrs`. Replaces any previous set; `count = 0` unregisters. Only while stopped and with no buffer held by user space (`EBUSY`) |
| `FDREC_IOC_START` | `struct fdrec_start` (in/out) | Start recording. `flags`: `FDREC_START_TPG` resets the TPG sequence and enables the TPG once the datapath runs; without it the TPG enable state from before `START` is restored unchanged. Returns `pkt_len`, `first_seq` (0) and `start_time_ns` (`CLOCK_REALTIME` when the packetizer was enabled) |
| `FDREC_IOC_WAIT_FILLED` | `struct fdrec_filled` (in/out) | Wait up to `timeout_ms` (< 0: forever, 0: poll) for the next filled buffer, in fill order. Returns `index`, `bytes`, `seq` (0, 1, 2, … since `START`), `drop_count` (read when the buffer completed) and `flags` (`FDREC_FILLED_SHORT`: fewer bytes than the buffer size; `FDREC_FILLED_ERROR`: DMA error). Errors: `ETIMEDOUT`, `EINTR`, `ENODATA` (stopped, nothing left), `EIO` (DMA error; the buffer is still returned) |
| `FDREC_IOC_RELEASE` | `struct fdrec_release` (in) | Return buffer `index` to the driver; it is re-queued while running |
| `FDREC_IOC_STOP` | `struct fdrec_stats` (out) | Stop and return the final counters. Buffers that were queued or filled but not collected are discarded; buffers user space holds stay held until `RELEASE` |
| `FDREC_IOC_GET_STATS` | `struct fdrec_stats` (out) | Hardware counters (drop count, beats in/out, TPG sequence, FIFO high-water mark and depth, overflow flag) and buffer accounting (filled, owned by the DMA, ready, held by user space, DMA errors) |
| `FDREC_IOC_SET_RATE` | `struct fdrec_rate` (in/out) | Program `TPG_RATE_INC` for `rate_bps` bytes/s (clamped to `SRC_CLK_HZ` × 16); returns the rate actually programmed. Does not change the TPG enable |
| `FDREC_IOC_PLAY_START` | `struct fdrec_play_start` (in/out) | Start a playback (needs a `FDREC_DIR_PLAY` set, `FDREC_CAP_MM2S`). `flags`: `FDREC_PLAY_CHECK` = `SOFT_RST`, reset the checker, enable it once the egress FIFO has primed (first `PLAY_SUBMIT`) (`EOPNOTSUPP` without `FDREC_CAP_CHECK`). Returns `start_time_ns` |
| `FDREC_IOC_PLAY_SUBMIT` | `struct fdrec_play_submit` (in) | Queue buffer `index` with `bytes` bytes (multiple of 16, 1 … buffer size) for the MM2S; played in submission order, one packet per buffer. `EINVAL` bad arguments, `EBUSY` the driver still owns the buffer, `EPIPE` not playing |
| `FDREC_IOC_PLAY_WAIT_DONE` | `struct fdrec_play_done` (in/out) | Wait up to `timeout_ms` for the next buffer the DMA has finished reading. Returns `index`, `bytes`, `seq` (0, 1, … since `PLAY_START`), `flags` (`FDREC_DONE_ERROR`). Errors as `WAIT_FILLED` |
| `FDREC_IOC_PLAY_STOP` | `struct fdrec_play_stats` (out) | Stop the playback (flush, terminate, see above) and return the counters read after the stop (checker frozen, so one coherent set; `egr_discard` includes the flushed beats) |
| `FDREC_IOC_GET_PLAY_STATS` | `struct fdrec_play_stats` (out) | Buffer accounting (done, bytes, owned by the DMA, ready, DMA errors), the checker counters (`chk.beats/errors/gaps/gap_beats/underflows/last_seq/rate_bps/enabled`) and the egress FIFO (`egr_beats_in`, `egr_discard`, `egr_level`, `egr_depth`) |
| `FDREC_IOC_SET_SINK_RATE` | `struct fdrec_rate` (in/out) | Program the checker's TREADY throttle `CHK_RATE_INC` for `rate_bps` bytes/s (same Q1.31 scheme as the TPG); `0` is refused (`EINVAL`: a sink that is never ready would stall the MM2S). `EOPNOTSUPP` without `FDREC_CAP_CHECK` |

**API compatibility.** `FDREC_API_VERSION` is still 1: playback only adds to it -- the
direction lives in the formerly must-be-zero `fdrec_bufs.flags` (`FDREC_DIR_RECORD` = 0), and
the playback ioctls and capability bits are new. Phase-1 binaries work unchanged; new apps
check `caps` before using playback.

The device also supports `poll()`: `POLLIN` when a filled (playback: finished) buffer is
waiting (`WAIT_FILLED` / `PLAY_WAIT_DONE` will not block), `POLLHUP` once stopped with nothing
left, `POLLERR` after a DMA error. The
`fdrec` app uses it as an io_uring poll request, next to its write requests, so it waits for
"buffer filled" and "write complete" in one place.

A minimal recording loop:

```c
int fd = open("/dev/fdrec0", O_RDWR);
/* bufs: N x 8 MB from mmap(MAP_HUGETLB) */
struct fdrec_bufs reg = { .addrs = (uintptr_t)addrs, .buf_size = 8 << 20, .count = N };
ioctl(fd, FDREC_IOC_REGISTER_BUFS, &reg);
struct fdrec_start st = { .flags = FDREC_START_TPG };
ioctl(fd, FDREC_IOC_START, &st);
for (;;) {
    struct fdrec_filled f = { .timeout_ms = 1000 };
    ioctl(fd, FDREC_IOC_WAIT_FILLED, &f);
    pwrite(out_fd /* O_DIRECT */, bufs[f.index], f.bytes, offset);
    offset += f.bytes;
    struct fdrec_release r = { .index = f.index };
    ioctl(fd, FDREC_IOC_RELEASE, &r);
}
```

## sysfs reference

The attributes are on the misc device, `/sys/class/misc/fdrec0/`. They work while a
recording runs (for scripting and monitoring) and while the device is closed.

| Attribute | Access | Description |
|-----------|--------|-------------|
| `rate_bps` | rw | TPG rate in bytes/s; writing programs `TPG_RATE_INC` (rounded), reading returns the programmed rate |
| `tpg_enable` | rw | TPG enable (`TPG_CTRL.ENABLE`), `0` / `1` |
| `drop_count` | ro | Beats dropped at the ingest FIFO (64-bit) |
| `overflow` | rw | Sticky overflow flag; write `1` to clear |
| `beats_in` | ro | Beats offered by the source (64-bit) |
| `beats_out` | ro | Beats delivered to the DMA (64-bit) |
| `fifo_hwm` | rw | Ingest FIFO high-water mark in beats; any write clears it |
| `fifo_depth` | ro | Ingest FIFO depth in beats |
| `seq_next` | ro | Next TPG sequence number |
| `src_clk_hz` | ro | Source clock frequency |
| `dp_clk_hz` | ro | Datapath clock frequency |
| `version` | ro | `fdrec_core` register map version, e.g. `1.1` |
| `chk_enable` | rw | Checker enable (`CHK_CTRL.ENABLE`): `1` / `0` (counters keep their values); writing `reset` clears the counters and the expected sequence number and keeps the enable state. While disabled the checker holds TREADY low (the stream stalls) |
| `chk_rate_bps` | rw | Sink consumption rate in bytes/s (`CHK_RATE_INC`, default = every clock = `SRC_CLK_HZ` × 16); `0` is refused |
| `chk_beats` | ro | Beats accepted by the checker |
| `chk_errors` | ro | Beats failing the pattern check, plus sequence numbers going backwards |
| `chk_gaps` | ro | Sequence discontinuities |
| `chk_gap_beats` | ro | Missing sequence numbers in total (= the recording's `drop_count` for a TPG file) |
| `chk_underflows` | ro | Sink cycles that found no data after the first beat (only ticks followed by more data count) |
| `chk_last_seq` | ro | Sequence number of the last good beat |
| `egr_beats_in` | ro | Beats written into the egress FIFO |
| `egr_discard` | ro | Beats discarded by `EGR_CTRL.FLUSH` (`PLAY_STOP` of a running playback) |
| `egr_fifo_level` | ro | Egress FIFO occupancy in beats |
| `egr_fifo_depth` | ro | Egress FIFO depth in beats |

The `chk_*` and `egr_*` attributes exist only with register map 1.1 or later.

`START` resets all counters (`GLOBAL_CTRL.SOFT_RST`), so after a recording the counters
describe that recording. Example:

```
echo 1000000000 > /sys/class/misc/fdrec0/rate_bps    # 1 GB/s
cat /sys/class/misc/fdrec0/{drop_count,fifo_hwm,fifo_depth}
```

## Interaction with the `xilinx_dma` driver

The driver uses the generic dmaengine API only. A few properties of the AMD `xilinx_dma`
driver shape how it does that:

* **Batching and interrupt coalescing.** `xilinx_dma` starts pending descriptors only when
  the channel is idle (from its interrupt handler), all of them in one go, and programs the
  AXI DMA's interrupt threshold to their number; the AXI DMA counts completed packets
  (descriptors with end-of-frame) against it. Handing it every free buffer makes the channel
  run in batches: one interrupt per batch, no buffer visible to user space until the whole
  batch is full (the SSD idles meanwhile and then gets a burst), and a DMA restart gap at
  every batch tail, which costs dropped beats at rates the SSD sustains easily. The driver
  therefore keeps
  exactly **one active and one pending descriptor** in `xilinx_dma` (`FDREC_DMA_DEPTH`): when
  the active buffer completes, the interrupt handler starts the pending one straight away
  (threshold 1, the DMA pauses only for the interrupt latency, which the ingest FIFO
  absorbs), and the completion callback submits the next buffer from the driver's queue as
  the new pending one. Every buffer reaches user space as soon as it is full: one interrupt
  per buffer.
* **The S2MM channel cannot halt mid-packet.** With the packetizer gated in the middle of a
  buffer the AXI DMA keeps waiting for the rest of the packet and never reports `Halted`;
  `xilinx_dma_terminate_all` busy-polls for it with `readl_poll_timeout_atomic(..., 0,
  1000000)`, whose timeout counts loop iterations as nanoseconds, so with ~0.4 µs per
  AXI-Lite read it spins a CPU for ~7 minutes (RCU stall warnings, `Cannot stop channel
  ...: 50008`) before it resets the channel. `STOP` therefore lets the buffers the DMA owns
  fill up first (see above); a channel that is idle at the tail of its descriptor chain
  halts at once. With a user source that stops delivering data in the middle of a buffer the
  drain waits at most `stop_drain_ms` (module parameter, default 5000) and then terminates
  anyway, with a warning in the kernel log.
* **Descriptor ring.** `xilinx_dma` pre-allocates 512 buffer descriptors per channel in a ring
  whose hardware next-pointers are fixed, and allocates them from a free list.
  `dmaengine_terminate_sync` frees descriptors list by list, which leaves the free list out
  of ring order. The driver therefore releases and re-requests the channel after every
  `STOP`, which rebuilds the ring. The MM2S channel uses the same descriptor code, so it gets
  the same treatment after every `PLAY_STOP`.
* **A terminate resets both channels.** On the AXI DMA, `xilinx_dma_terminate_all` ends in a
  channel reset, and `DMACR.Reset` resets the whole core: the *other* channel loses its
  interrupt enables too, and `xilinx_dma` re-enables only those of the channel it reset.
  That channel would then complete its first buffer and never interrupt again (seen on the
  bench: the first playback after a recording stalled after one buffer, with no MM2S interrupt, and
  a recording after a playback likewise). Requesting a channel re-enables its interrupts, so
  after every `STOP` / `PLAY_STOP` the driver renews **both** channels (only one direction
  runs at a time, so the other one is idle).
* **MM2S.** The playback channel goes through the same `prep_slave_sg` / start / IRQ code as
  S2MM, so the batching and coalescing behaviour is identical and the driver keeps one
  active + one pending descriptor there as well. `prep_slave_sg` marks a `DMA_MEM_TO_DEV`
  descriptor SOP on its first and EOP on its last BD, so a buffer of several hugepages
  (several BDs) is **one** packet with TLAST only on its last beat. Halting uses the same
  `stop_transfer` poll (`DMACR.RS = 0`, wait for `DMASR.Halted`). An MM2S channel can only
  halt once the stream side has taken the data it has fetched, so a disabled or very slowly
  throttled sink could again leave the poll spinning; `PLAY_STOP` avoids that by draining the
  in-flight descriptors into the egress FIFO's discard path (`EGR_CTRL.FLUSH`) before it
  terminates an idle channel. (The halt-mid-packet behaviour was observed on S2MM on the
  bench; for MM2S the flush makes the driver independent of it.)
* **Restart gap.** Because the pending descriptor is started from the interrupt handler, the
  DMA pauses at every buffer boundary for the interrupt latency plus the restart (~15 µs
  worst case measured on a Zynq UltraScale+ target, `uzev`). The ingest FIFO (recording) and the egress FIFO (playback) must cover
  it at the stream rate; see [the FIFO budget](apps.md#tuning-the-fifo-budget-at-buffer-boundaries).

## Verified against the kernel sources

The design targets the AMD EDF 2025.2 kernel, **6.12.40-xilinx** (linux-xlnx tag
`xilinx-v2025.2`). These facts were checked in that exact source tree:

| Fact | Where (6.12.40-xilinx) |
|------|------------------------|
| `xlnx,sg-length-width` is honoured for AXI DMA up to 26 bits (`XILINX_DMA_V2_MAX_TRANS_LEN_MAX`); without it the length field is 23 bits. `max_buffer_len = GENMASK(width - 1, 0)` | `drivers/dma/xilinx/xilinx_dma.c:174-176`, `:3097-3113` |
| `prep_slave_sg` splits a scatterlist entry longer than `max_buffer_len` into several BDs itself (`xilinx_dma_calc_copysize`, keeping the `copy_align` of the 128-bit data width = 16 bytes) | `xilinx_dma.c:2183-2240`, `:1240-1258`, `:2846-2858` |
| 512 BDs per channel (`XILINX_DMA_NUM_DESCS`), allocated once per channel allocation in a ring with fixed next-pointers | `xilinx_dma.c:186`, `:1113-1166` |
| A descriptor completes only when its **last** BD has the Cmplt bit; the residue is the sum over its BDs of `(control - status) & max_buffer_len`, passed to `callback_result` as `result.residue` | `xilinx_dma.c:1712-1742`, `:980-1021`, `:1047-1078` |
| Consequence for TLAST: a packet that ends exactly on the last BD of a descriptor completes that descriptor with residue 0. A TLAST inside a descriptor would leave its remaining BDs to the next packet, which is why `PKT_LEN` must equal the buffer size | same |
| The IOC interrupt threshold is set to the number of pending descriptors at each start; the IRQ handler marks the channel idle and starts all pending descriptors | `xilinx_dma.c:1560-1565`, `:1873-1921` |
| `terminate_all` stops and resets the channel and frees pending, done, then active descriptors; `device_synchronize` is `tasklet_kill` (no callback after `dmaengine_terminate_sync`) | `xilinx_dma.c:2485-2519`, `:2521-2526`, `:913-924` |
| Each channel node must have an interrupt (`of_irq_get` failure fails the probe) | `xilinx_dma.c:2912-2914` |
| The S2MM channel is channel id 1 for `dmas = <&axi_dma_0 1>` (`s2mm_chan_id` starts at `max_channels / 2` = 1), also on an S2MM-only DMA | `xilinx_dma.c:131`, `:2881`, `:3098`, `:3004-3012` |
| The MM2S channel is channel id 0 (`mm2s_chan_id` starts at 0, `tdest = id`), so `dmas = <&axi_dma_0 0>`; its interrupt is `of_irq_get(<mm2s dma-channel node>, 0)` -- `mm2s_introut` must be wired and described on the channel node, or the whole AXI DMA fails to probe | `xilinx_dma.c:2860-2867`, `:2912-2914` |
| `prep_slave_sg` for `DMA_MEM_TO_DEV`: every sg entry becomes one or more BDs (split at `max_buffer_len`); SOP is set on the first BD of the descriptor and EOP on its last only, so a multi-hugepage buffer is one packet with TLAST on its last beat | `xilinx_dma.c:2208-2262` |
| `start_transfer` returns while the channel is not idle; it writes `CURDESC` of the first pending descriptor and `TAILDESC` of the last, and sets the IRQ threshold to the pending count -- same code path for MM2S and S2MM (`ctrl_offset` 0x00 vs 0x30) | `xilinx_dma.c:1536-1607`, `:2867` |
| `stop_transfer` clears `DMACR.RS` and polls `DMASR.Halted` with `xilinx_dma_poll_timeout(..., 0, XILINX_DMA_LOOP_COUNT)` = `readl_poll_timeout_atomic` with a 1000000 "us" timeout counted as delay-less iterations | `xilinx_dma.c:1307-1316`, `:530-532`, `:167` |
| A failed MM2S descriptor completes with `DMA_TRANS_WRITE_FAILED` (S2MM: `READ_FAILED`) | `xilinx_dma.c:1063-1070` |
| Freed segments go to the **tail** of the free list (`xilinx_dma_free_tx_segment`), allocation takes the head -- the reason a terminate (frees pending, done, active) reorders the ring, for either direction | `xilinx_dma.c:782-788`, `:710-726`, `:913-924` |
| `device_config` (`dmaengine_slave_config`) is a no-op for AXI DMA | `xilinx_dma.c:1700-1704` |
| The DMA mask comes from `xlnx,addrwidth` | `xilinx_dma.c:3138-3152` |
| arm64 non-coherent sync: `arch_sync_dma_for_device` = clean to PoC (any direction), `arch_sync_dma_for_cpu` = invalidate unless `DMA_TO_DEVICE` (no-op then) | `arch/arm64/mm/dma-mapping.c:15-32` |
| `pin_user_pages_fast(start, nr_pages, gup_flags, pages)`; `FOLL_LONGTERM` refuses (migrates) only CMA / ZONE_MOVABLE / device-coherent folios -- boot-time hugepages are pinnable | `mm/gup.c:3538`, `include/linux/mm.h:1991-2010` |
| `dma_map_sgtable(dev, sgt, dir, attrs)`; `dma_sync_sgtable_for_cpu/device(dev, sgt, dir)` (sync over `orig_nents`) | `kernel/dma/mapping.c:288`, `include/linux/dma-mapping.h:441-466` |
| `struct dmaengine_result { result; residue; }` and `dma_async_tx_callback_result` | `include/linux/dmaengine.h:552-558`, `:618` |
| `dmaengine_get_dma_device(chan)` is the device to map buffers against | `include/linux/dmaengine.h:1662-1668` |
| `O_DIRECT` from hugetlb pages: the block layer pins the user pages with `iov_iter_extract_pages` → `pin_user_pages_fast`, and the GUP fast path handles PMD-sized (2 MB hugetlb) leaves | `block/bio.c:1337`, `lib/iov_iter.c:1821`, `mm/gup.c:3098`, `:3248` |

```{note}
For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics: see the
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).
```
