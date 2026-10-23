# Applications

The Linux image contains five recorder tools, in `/usr/bin`:

| Tool | Purpose |
|------|---------|
| `fdsetup-raid0.sh` | Prepare the recording filesystem: RAID0 across both SSDs, or a single SSD, mounted at `/mnt/rec` |
| `fdrec` | Record the fabric data stream to a file (zero-copy, io_uring + `O_DIRECT`) |
| `fdplay` | Play a recording back into the fabric (zero-copy, io_uring `O_DIRECT` reads → AXI DMA MM2S), verified by the hardware checker |
| `fdverify` | Verify a recording word by word |
| `fdbench.sh` | Sweep the generator rate to find the sustained recording rate |

It also contains the four `dd` speed-test scripts of fpga-drive-aximm-pcie
(`single_write_test.sh`, `single_read_test.sh`, `dual_write_test.sh`,
`dual_read_test.sh`, in `/usr/bin`; they take the mount point(s) as arguments, write a
`test.img` file into each and need `bash` and `dc`, which the image includes), described in [Test the design in Linux](linux_test.md#4-measure-the-ssds-with-the-dd-speed-test-scripts)
and compared with the recorder in [Benchmarks](benchmarks.md#comparison-with-fpga-drive-aximm-pcie-dd-method).

Their sources are in `sw/fdrec-apps/` with a `Makefile`, so they can also be built on the
board or on any Linux machine (`fdrec` and `fdplay` need liburing ≥ 2.2):

```
make -C sw/fdrec-apps                         # native
make -C sw/fdrec-apps CC=aarch64-linux-gnu-gcc LIBURING_CFLAGS=-I<liburing>/include \
     LIBURING_LIBS=<liburing>/lib/liburing.a  # cross
```

All of them need root (or access to `/dev/fdrec0` and the block devices). Every tool prints
its options with `--help`.

**Units.** The tools take the size of a fabric beat from the driver (`fdrec_info.beat_bytes`,
the `beat_bytes` sysfs attribute): 32 bytes on the 256-bit reference designs, 16 on a
128-bit datapath. Drop counts, FIFO depths and high-water marks, and the checker's
counters are in these beats. The test pattern, and so `fdverify`, works on 16-byte words; a
32-byte beat carries two of them (see [File format](file_format)). The driver's probe line in
the kernel log (`fdrec_core v1.2`) and the `version` sysfs attribute give the version of the
hardware's register map; the driver's own version is `modinfo -F version fdrec` (1.3).

## Quick start

```
# 1. Filesystem on the SSD(s) -- ERASES THEM. Both slots populated: RAID0.
sudo fdsetup-raid0.sh
#    or a single SSD:
sudo fdsetup-raid0.sh --single /dev/nvme0n1

# 2. Record 10 GB of test pattern at 1 GB/s
sudo fdrec --rate 1000MB --size 10G /mnt/rec/test.dat

# 3. Verify it
sudo fdverify /mnt/rec/test.dat

# 4. Play it back into the fabric; the hardware checker consumes it at 1 GB/s
sudo fdplay --rate 1000MB /mnt/rec/test.dat
```

## fdsetup-raid0.sh

```
fdsetup-raid0.sh [options] [<nvme-dev> <nvme-dev>]
  --chunk <size>     RAID0 chunk size (mdadm units, default 512K)
  --fs xfs|ext4      filesystem (default xfs)
  --mount <dir>      mount point, created if missing (default /mnt/rec);
                     give the same --mount to --teardown
  --single <dev>     no RAID: format and mount this one drive instead
                     (an md array that uses it is unmounted and stopped)
  --teardown         unmount the mount point and stop /dev/md0 (data is kept)
  -y, --yes          do not ask for confirmation
```

Without device arguments it uses the two NVMe namespaces it finds (`/dev/nvme0n1`,
`/dev/nvme1n1`). It stops any old array, wipes the drives, creates `/dev/md0` with `mdadm`
(RAID0, metadata 1.2), formats it (XFS by default; `mkfs.xfs` picks up the stripe geometry
from md; for ext4 the `stride`/`stripe_width` hints are computed from the chunk size) and
mounts it at `/mnt/rec` (or the `--mount` directory, which it creates if it does not exist)
with `noatime`. **All data on the drives is destroyed**; it asks for confirmation unless
`--yes` is given. With `--single` it formats and mounts one drive the same way, without md.
Use `--teardown` (with the same `--mount`) before you switch from RAID0 to single drives.

Two single drives on two mount points (for example for the dual `dd` speed tests):

```
sudo fdsetup-raid0.sh --teardown
sudo fdsetup-raid0.sh -y --single /dev/nvme0n1 --mount /mnt/ssd1
sudo fdsetup-raid0.sh -y --single /dev/nvme1n1 --mount /mnt/ssd2
```

The mounts do not survive a reboot. Re-assemble and mount the array without reformatting:

```
sudo mdadm --assemble /dev/md0 /dev/nvme0n1 /dev/nvme1n1
sudo mkdir -p /mnt/rec && sudo mount /dev/md0 /mnt/rec
```

or, for a single drive, `sudo mkdir -p /mnt/rec && sudo mount /dev/nvme0n1 /mnt/rec`.

`fdrec` needs no options for RAID0: it simply writes to a file on `/mnt/rec`. Benchmark
single-drive and RAID0 configurations separately (see [Benchmarks](benchmarks)).

## fdrec

```
fdrec [options] <output-file>
  --size <bytes>        stop after this many bytes (suffixes K/M/G/T)
  --duration <sec>      stop after this many seconds
  --rate <bytes/s>      program the test pattern generator rate (default: leave as is)
  --buffers <n>         number of buffers (default 32)
  --buf-size <bytes>    buffer size, multiple of 2 MB (default 8 MB)
  --qd <n>              io_uring queue depth: writes in flight (default 8)
  --no-tpg              do not touch the generator (user's own data source)
  --no-write            run the DMA ring but write nothing (no <output-file>)
  --timeout <sec>       stall watchdog: abort cleanly when no buffer completes
                        for this long (default 10)
  --stats <sec>         live stats interval, 0 = off (default 1)
  --device <path>       recorder device (default /dev/fdrec0)
  --target <name>       target name stored in the header (default: the image's target)
  -q, --quiet           no live stats line
```

Sizes and rates accept `K`, `M`, `G`, `T` (powers of 1024, also `Ki`/`KiB`…) and `KB`, `MB`,
`GB`, `TB` (powers of 1000): `--size 10G` is 10 GiB, `--rate 1000MB` is 10^9 bytes/s. Without
`--size` or `--duration`, `fdrec` records until Ctrl-C.

What it does:

1. Allocates `--buffers` × `--buf-size` from 2 MB hugepages and registers them with the
   driver. The image reserves 256 hugepages (512 MB) at boot; the default ring
   (32 × 8 MB = 256 MB) needs 128. If the allocation fails, `fdrec` says how many hugepages
   are needed and free (`echo <N> > /proc/sys/vm/nr_hugepages` adds more at run time).
2. Opens the output with `O_CREAT | O_WRONLY | O_DIRECT` (truncating an existing file) and,
   with `--size`, preallocates it with `fallocate`. Writes the 4 KB header.
3. Starts the recorder. Unless `--no-tpg` is given, the test pattern generator is restarted
   from sequence 0 after the datapath is running, so the first recorded beat is beat 0.
   With `--no-tpg` the generator is left exactly as it was.
4. Main loop: takes each filled buffer and submits an io_uring write of it at the next file
   offset (registered buffers when possible); when the write completes, the buffer goes back
   to the DMA. Up to `--qd` writes are in flight. One io_uring wait covers both "buffer
   filled" (a poll request on `/dev/fdrec0`) and "write done".
5. Stops when `--size` or `--duration` is reached or on SIGINT/SIGTERM: stops the DMA, drains
   the writes in flight, rewrites the header with the final counts, trims the file to the
   recorded length, `fsync`s and prints a summary.

The live stats line (every `--stats` seconds, on stderr) shows elapsed time, instantaneous
and average write rate (MB/s = 10^6 bytes/s), total data, writes in flight, the ingest FIFO
high-water mark against its depth (in beats), and the drop count (in beats):

```
     12.0s   1000.2 MB/s (avg   999.8)       11.998 GB  inflight  2  fifo_hwm     1/8192  drops 0
```

The summary ends with one machine-readable line, used by `fdbench.sh`:

```
RESULT bytes=10737418240 seconds=10.737 rate_bps=1000000000 drops=0 fifo_hwm=1 fifo_depth=8192 error=0 beat_bytes=32 no_write=0
```

Exit codes: **0** = recording complete with zero dropped beats, **2** = beats were dropped (the
recording is not valid), **1** = error, including a stall.

**Without an SSD (`--no-write`).** `fdrec --no-write [options]` runs everything up to the
memory exactly as a recording does -- the source, the ingest FIFO, the AXI DMA into the
hugepage ring through the HP port (Zynq UltraScale+) or the NoC (Versal), the descriptor
chain and the buffer recycling with its cache maintenance -- but hands every filled buffer
straight back to the DMA: no output file is created and no file I/O is issued. It measures
the fabric → DDR path on its own, for example the highest generator rate a board sustains
before any SSD is involved:

```
sudo fdrec --no-write --rate 8000MB --size 64G
```

* Give no `<output-file>` (`fdrec` refuses one with `--no-write`, so a forgotten file name
  cannot be mistaken for a recording). `--qd` has no effect.
* `--size` and `--duration` count the bytes the DMA delivered; the stall watchdog, the live
  stats and the summary work as for a recording (the rates are the DMA's).
* The exit codes are the same: **0** = no beat dropped, **2** = beats were dropped (the path
  did not keep up with the source), **1** = error or stall. The `RESULT` line carries
  `no_write=1`.

**Stall watchdog (`--timeout`).** If no buffer has been filled by the DMA or written to the
file for `--timeout` seconds (default 10, must be greater than 0), `fdrec` prints
`recording stalled: ...` with a hint at the likely cause (the SSD is not completing writes,
the source is not producing data, or the DMA is not filling buffers), then stops the
recorder, drains the writes in flight, rewrites the header, `fsync`s, prints the summary and
exits with code 1. The file keeps everything recorded up to the stall. With `--no-tpg`, a
source that is idle for longer than `--timeout` therefore ends the recording: raise the
timeout for bursty or slow sources. Below about 0.8 MB/s one 8 MB buffer takes more than
10 s to fill, and `fdrec` warns about it at start-up when the rate is known (`--rate`).
What a stall looks like in the kernel log, and why it is harmless, is described in
[Troubleshooting](troubleshooting.md#recording-stops-with-recording-stalled-exit-code-1).

**Ring size (`--buffers`, `--buf-size`).** The ring absorbs the time an SSD takes to complete
a write. The default of 32 × 8 MB (256 MB) covers a write stall of about 128 ms at 2 GB/s, but
only 57 ms at 4.5 GB/s and 39 ms at 6.5 GB/s. At high rates use a 512 MB ring, the whole
hugepage pool of the image: `--buffers 64` (64 × 8 MB) or `--buf-size 16M` (32 × 16 MB, which
also halves the number of buffer boundaries). Measured with RAID0 pairs (see
[Benchmarks](benchmarks.md#start-up-stalls-and-the-ring-size)):

* **Zynq UltraScale+**: `--buffers 64` above ~3.5 GB/s with the Sabrent Rocket 2230 1TB pair and
  above ~4.5 GB/s with the Samsung 980 PRO 1TB pair (on `zcu106_hpc0` they recorded 4500 and
  5000 MB/s cleanly only with it).
* **Versal**: `--buf-size 16M` above ~4 GB/s with the Sabrent pair and above ~6.5 GB/s with the
  980 PRO pair (on `vck190_fmcp1` both recorded 7000 MB/s cleanly with it; with the default ring
  the Sabrent pair was clean up to 4000 MB/s and the 980 PRO pair up to 6500 MB/s).

A ring larger than 512 MB needs more hugepages.

**NVMe power saving (APST) and the first writes.** After idle time, NVMe drives with APST
(enabled by the kernel by default, and in this image) may be in a deep power state when a
recording starts, and its first writes then complete late: two Sabrent Rocket 2230 1TB in RAID0
on `vck190_fmcp1` took ~63-65 ms after 60 s of idle time and lost data at 4500-5000 MB/s with
the default ring, in one gap right after the first pass through the ring. A 512 MB ring covers
it, or turn APST off before recording, per controller (until the next reboot):

```
echo 0 | sudo tee /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us
echo 0 | sudo tee /sys/class/nvme/nvme1/power/pm_qos_latency_tolerance_us
```

or for every drive with `nvme_core.default_ps_max_latency_us=0` on the kernel command line
(not tested). APST off costs the drives' idle power savings; see
[Benchmarks](benchmarks.md#start-up-stalls-and-the-ring-size).

Notes:

* With `--size`, the size is rounded up to a multiple of 4096 bytes (an `O_DIRECT`
  requirement) and the last buffer is written only partly.
* A recording always consists of whole beats in order; when it stops, buffers that were
  filled but not yet written are discarded. The header records the beat size
  (`beat_bytes`, from the driver).
* The file must be on a filesystem that supports `O_DIRECT` (XFS and ext4 do; tmpfs does not).

## fdplay

```
fdplay [options] <file>
  --rate <bytes/s>      program the sink's consumption rate (checker throttle; default: leave as is)
  --buffers <n>         number of buffers (default 32)
  --buf-size <bytes>    buffer size, multiple of 2 MB (default 8 MB)
  --qd <n>              io_uring queue depth: reads in flight (default 8)
  --no-check            do not touch the checker (your own data sink)
  --timeout <sec>       stall watchdog: abort cleanly when no buffer completes
                        for this long (default 10)
  --stats <sec>         live stats interval, 0 = off (default 1)
  --device <path>       recorder device (default /dev/fdrec0)
  -q, --quiet           no live stats line
```

Plays a recording back into the FPGA fabric: file → `O_DIRECT` reads into hugepage buffers
→ AXI DMA MM2S → egress FIFO → data sink. Zero-copy like `fdrec`: the NVMe controller writes
the buffers and the AXI DMA reads the same buffers. Each buffer is one AXI-Stream packet
(TLAST on its last beat). In the reference design the sink is the `fdrec_check` checker,
which models a DAC: it consumes one beat per throttle tick (`--rate`, same scheme as the test
pattern generator, default every `src_clk` cycle = `SRC_CLK_HZ` × `beat_bytes`, 8 GB/s at
250 MHz × 32 B) and checks every word of every beat of a test pattern recording in hardware.

What it does:

1. Reads and checks the file header (see [File format](file_format)). It plays `data_bytes`
   (a recording without the COMPLETE flag: everything after the header), in whole beats of
   the design: trailing bytes that do not fill a beat are not played (a note says so).
   Without `--no-check` the file must be a test-pattern recording.
2. Allocates and registers the buffers for playback (`FDREC_DIR_PLAY`).
3. `PLAY_START`: unless `--no-check` is given, the checker is reset before any data can
   reach it, so the first beat of the file sets its expected sequence number; the driver
   enables it once the first buffer has primed the egress FIFO (no start-up underflows).
4. Fills **the whole ring** with `O_DIRECT` reads (up to `--qd` in flight) before it submits
   the first buffer, so the stream starts with N buffers of headroom; then submits buffers
   strictly in file order. Each buffer the DMA has finished takes the next chunk of the file.
   One io_uring wait covers "read done" and "buffer played" (a poll request on
   `/dev/fdrec0`).
5. After the last buffer, waits until the sink has taken every beat (the egress FIFO holds up
   to `EGR_FIFO_DEPTH` beats -- 4096 × 32 B = 128 KB in the reference designs -- after the
   DMA is done), then stops and reads the checker counters.

The live stats line shows elapsed time, instantaneous and average playback rate (bytes the
DMA has read), total data, reads in flight, buffers owned by the DMA, and the checker's
underflow count:

```
      8.0s   1000.1 MB/s (avg  1000.0)        8.000 GB  reads  8  in DMA  2  underflows 0
```

The summary prints the checker counters, any problem found, and one machine-readable line:

```
fdplay: /mnt/rec/test.dat: 10737418240 of 10737418240 bytes (1280 buffers) in 10.74 s, 1000.0 MB/s
fdplay: checker: beats 335544320 (expected 335544320, 32 bytes each), errors 0, gaps 0, gap beats 0 (recording drop_count 0), underflows 0, last seq 671088638, sink rate 1000.0 MB/s
RESULT bytes=10737418240 seconds=10.737 sink_rate_bps=1000000000 beats=335544320 errors=0 gaps=0 gap_beats=0 drop_count=0 underflows=0 egr_discard=0 max_reads=8 complete=1 error=0 beat_bytes=32 file_beat_bytes=32
```

The checker counts beats (`beats`, `gap beats`), while `last seq` is the sequence number of
word 0 of the last beat, in 16-byte words: 10 GiB are 671 088 640 words in 335 544 320 beats
of two words, and the last beat starts with word 671 088 638.

Exit codes: **0** = playback complete and, with the checker, ERRORS = 0, UNDERFLOWS = 0,
GAP_BEATS = the recording's `drop_count`, the checker saw every beat and the first beat it
saw is the header's `first_seq`; **2** = complete, but the checker found a problem; **1** =
error or incomplete playback (Ctrl-C, read error, stall). With `--no-check`, 0 means a
complete playback. GAP_BEATS and `drop_count` are compared as missing 16-byte words (beats ×
`beat_bytes` / 16 of the design and of the recording respectively), so a recording made with
another beat size is judged correctly.

Notes:

* **Underflows** are the playback equivalent of the recorder's drops: the sink was ready but
  no data had arrived, because the SSD (or the filesystem / RAID) reads slower than `--rate`.
  A playback at a sink rate below the drive's sustained read rate must show 0; above it, the
  ring drains and underflows appear. Underflow ticks after the last beat of the file are not
  counted, so a complete playback reads 0 unless it starved.
* A recording made with drops still plays cleanly: the checker counts the missing beats as
  GAP_BEATS, which must equal the header's `drop_count` -- an end-to-end check that the file,
  the read path and the MM2S are lossless.
* **Recordings made with 16-byte beats** (a 128-bit datapath) play on a 256-bit design: the
  file is the same byte stream of 16-byte words. A clean recording verifies exactly. One
  with drops can have gaps of an odd number of words, which the 32-byte checker cannot
  represent: such a gap is truncated in GAP_BEATS, or counted as a bad beat when it falls in
  the middle of a beat, and `fdplay` then reports a problem (it prints a note at the start).
  If the recording has an odd number of words, its last word is not played (not a whole
  32-byte beat).
* `--no-check` is for your own sink in place of `user_data_sink` (see
  [Replacing the checker with your own data sink](custom_sink)). On the reference design the
  checker *is* the sink and holds TREADY low while disabled: enable it by hand
  (`echo 1 > /sys/class/misc/fdrec0/chk_enable`, optionally `chk_rate_bps`) or the stream
  stalls and `fdplay` gives up after `--timeout`.
* The default sink rate (every clock, 8 GB/s) is above the read rate of the SSDs measured
  here, so a checked playback without `--rate` normally reports underflows; use `--rate`
  below the drive's read rate.
* `fdplay` and `fdrec` cannot run at the same time (one opener of `/dev/fdrec0`).

### Tuning: the FIFO budget at buffer boundaries

At a buffer boundary the AXI DMA moves on to the next buffer by itself: the driver keeps the
next two buffers appended to the DMA's running descriptor chain (see
[Kernel driver](driver.md), "Interaction with the `xilinx_dma` driver"). The FIFO between the
DMA and the fabric only bridges the DMA's own descriptor fetch and short DDR back-pressure.

`fdrec` and `fdplay` still check a conservative budget of **15 µs**: the pause at a boundary
when `xilinx_dma` cannot append and restarts the DMA from its interrupt handler instead (the
fallback when its descriptor ring is out of order, or a kernel without the `meta-fdrec`
patch), measured on a Zynq UltraScale+ target as about 9 µs with a tail of 15-20 µs
(interrupt latency plus restart):

    FIFO bytes / rate  >  ~15 µs

| FIFO | Size | At 8 GB/s it lasts | Covers 15 µs up to |
|------|------|--------------------|--------------------|
| ingest (recording) | 8192 beats × 32 B = 256 KB | 32 µs | 17 GB/s (above the 8 GB/s source maximum) |
| egress (playback) | 4096 beats × 32 B = 128 KB | 16 µs | 8.7 GB/s (above the 8 GB/s sink maximum) |
| (a 512-beat FIFO of 32-byte beats, for comparison) | 16 KB | 2 µs | ~1.1 GB/s |

In the fallback the 15-20 µs tail is typical, not a hard bound: on a Cortex-A53 target an
interrupt is rarely several hundred µs late, more than any FIFO here covers, which is why the
driver keeps the DMA chained across boundaries.

The interrupt latency still matters in one place: each buffer's completion interrupt lets
the driver append the next free buffer to the chain, and with two buffers queued behind the
one being transferred it has two buffer periods (2.1 ms at 8 GB/s with 8 MiB buffers) to do
so. The driver pins the AXI DMA interrupts to a CPU of their own (`dma_irq_cpu`, default the
last online CPU), away from CPU0 of a Zynq UltraScale+ target, where they would queue behind
the NVMe completion bursts.

Within the budget, underflows (playback) or drops (recording) mean the SSD or filesystem is
too slow. `fdplay` and `fdrec` print a warning when the programmed rate exceeds the budget of
the design's FIFO (read from `EGR_FIFO_DEPTH` / `ING_FIFO_DEPTH`, times the beat size). The
warning concerns only the fallback, and says so: with the chain in place the FIFO bridges
the DMA's descriptor fetch, and the ingest FIFO high-water mark that `fdrec` reports
(`fifo_hwm`) shows how little of it a recording uses (see
[Benchmarks](benchmarks.md#5-latency-budgets-not-bandwidth)). With the reference designs'
FIFOs the warning does not appear at any rate up to the 8 GB/s maximum. Larger buffers
(`--buf-size`) mean fewer boundaries and more time for the recycling. A custom sink or source
with its own buffering adds to the FIFO.

## fdverify

```
fdverify [options] <file>
  --max-errors <n>   print at most n discontinuities and n corrupted words (default 20)
  --header-only      only parse and print the header
  --pattern          check the test pattern even if the header says the source was not the TPG
  -q, --quiet        no progress output
```

Prints the header, then streams the data with large reads and checks every 16-byte pattern
**word**: `upper == ~lower` and `lower == previous + 1`. The check is the same for recordings
with 16-byte and 32-byte beats (the header's `beat_bytes`; a 32-byte beat holds two words).
It reports the total words (and beats), the first and last sequence numbers, each
discontinuity (word index, file offset, expected and found sequence number, gap size in
words; the printed list is capped by `--max-errors`, but all are counted), each corrupted
word, and compares the size with `data_bytes` and the missing words with the header's
`drop_count`. `drop_count` is in beats; a dropped beat leaves a gap of `beat_bytes` / 16
words at a beat boundary, so fdverify compares the missing words with `drop_count` ×
`beat_bytes` / 16 -- the same relation as between the checker's GAP_BEATS (beats) and the
words missing in the file. A gap that is not a whole beat at a beat boundary, or data that
is not a whole number of beats, is reported as a problem of its own (corruption, not a
drop):

```
GAP at word 2097152 (file offset 33558528): expected 2097152, found 2105344, 8192 words missing
  words           671088640 (10737418240 bytes, 335544320 beats of 32 bytes)
  discontinuities 1, words missing 8192 (4096 beats)
note: missing words match the header drop_count exactly (4096 beats x 2 words)
RESULT FAIL
```

Exit code **0** only for a clean file: complete header, consistent size, no corrupted words,
no discontinuities and `drop_count` 0. **1** if any problem was found, **2** on a usage or I/O
error. For a recording of your own data source (header flag bit0 clear), only the header is
checked unless `--pattern` is given.

## fdbench.sh

```
fdbench.sh [options]
  --dir <dir>          directory on the SSD filesystem (default /mnt/rec)
  --size <bytes>       data per step (default 32G)
  --from <MB/s>        first rate (default 500)
  --to <MB/s>          last rate (default: generator maximum, src_clk x beat_bytes)
  --step <MB/s>        rate step (default 500)
  --stop-on-fail       stop at the first failing rate
  --keep               keep the recordings
  --fdrec-args "<..>"  extra fdrec options (e.g. "--buffers 32 --qd 16")
```

The default sweep runs from 500 MB/s in 500 MB/s steps up to the generator maximum,
`SRC_CLK_HZ` × `beat_bytes` read from sysfs: 8000 MB/s on the 256-bit reference designs
(250 MHz × 32 B), 16 steps. (With a driver older than 1.3, which has no `beat_bytes`
attribute, it assumes the 16-byte beats of a 128-bit datapath.) Steps above the board's
SSD write rate drop beats and still record `--size` bytes each: add `--stop-on-fail`, or
narrow the sweep with `--from` / `--to` / `--step` (for example `--from 2000 --to 3500 --step
250` around a drive's limit).

For each rate it records `--size` bytes with `fdrec --rate`, verifies the file with
`fdverify`, deletes it and prints one table row. A step whose recording stalled (`fdrec`
exit code 1, see `--timeout`) is reported as `ERROR`:

```
 rate MB/s  result           drops    fifo_hwm/depth      avg MB/s    fdverify
 ---------  ------           -----    --------------      --------    --------
       500  PASS                 0            1/8192         500.0        PASS
       ...
      2000  DROPS          1234567         8193/8192        1952.3        gaps

fdbench: sustained recording rate: 1500 MB/s (/dev/md0, xfs, 32G per step)
```

The highest passing rate is the **sustained recording rate** of that board + SSD(s) +
filesystem. The default 32 GB per step is large enough to exhaust the SLC write cache of
typical smaller SSDs, so the result is the sustained rate rather than the cache rate; use a
larger `--size` for drives with very large caches (the 1 TB drives on the
[Benchmarks](benchmarks.md#long-recordings-past-the-slc-cache) page cache 66-125 GB each, so
32 GB stays inside the cache), or confirm the result with one `fdrec` recording longer than
the cache. Run it once on a single drive
(`fdsetup-raid0.sh --single`) and once on RAID0; the [Benchmarks](benchmarks) page has
the results measured so far.
