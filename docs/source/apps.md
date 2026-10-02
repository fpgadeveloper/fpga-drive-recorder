# Applications

The Linux image contains five recorder tools, in `/usr/bin`:

| Tool | Purpose |
|------|---------|
| `fdsetup-raid0.sh` | Prepare the recording filesystem: RAID0 across both SSDs, or a single SSD, mounted at `/mnt/rec` |
| `fdrec` | Record the fabric data stream to a file (zero-copy, io_uring + `O_DIRECT`) |
| `fdplay` | Play a recording back into the fabric (zero-copy, io_uring `O_DIRECT` reads → AXI DMA MM2S), verified by the hardware checker |
| `fdverify` | Verify a recording beat by beat |
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
high-water mark against its depth, and the drop count:

```
     12.0s   1000.2 MB/s (avg   999.8)       11.998 GB  inflight  2  fifo_hwm   311/4096  drops 0
```

The summary ends with one machine-readable line, used by `fdbench.sh`:

```
RESULT bytes=10737418240 seconds=10.737 rate_bps=1000000000 drops=0 fifo_hwm=311 fifo_depth=4096 error=0
```

Exit codes: **0** = recording complete with zero dropped beats, **2** = beats were dropped (the
recording is not valid), **1** = error, including a stall.

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

**Ring size (`--buffers`).** The ring absorbs the time an SSD takes to complete a write. The
default of 32 × 8 MB (256 MB) covers a write stall of about 128 ms at 2 GB/s; 16 buffers
proved too few at 1.7 GB/s right after an `fstrim` (see
[Benchmarks](benchmarks.md#the-fstrim-finding-and-the-ring-size)).

Notes:

* With `--size`, the size is rounded up to a multiple of 4096 bytes (an `O_DIRECT`
  requirement) and the last buffer is written only partly.
* A recording always consists of whole beats in order; when it stops, buffers that were
  filled but not yet written are discarded.
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
pattern generator, default every `src_clk` cycle = 3.2 GB/s) and checks every beat of a test
pattern recording in hardware.

What it does:

1. Reads and checks the file header (see [File format](file_format)). It plays `data_bytes`
   (a recording without the COMPLETE flag: everything after the header). Without
   `--no-check` the file must be a test-pattern recording.
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
   to `EGR_FIFO_DEPTH` beats -- 4096 in the reference design -- after the DMA is done), then
   stops and reads the checker counters.

The live stats line shows elapsed time, instantaneous and average playback rate (bytes the
DMA has read), total data, reads in flight, buffers owned by the DMA, and the checker's
underflow count:

```
      8.0s   1000.1 MB/s (avg  1000.0)        8.000 GB  reads  8  in DMA  2  underflows 0
```

The summary prints the checker counters, any problem found, and one machine-readable line:

```
fdplay: /mnt/rec/test.dat: 10737418240 of 10737418240 bytes (1280 buffers) in 10.74 s, 1000.0 MB/s
fdplay: checker: beats 671088640 (expected 671088640), errors 0, gaps 0, gap beats 0 (recording drop_count 0), underflows 0, last seq 671088639, sink rate 1000.0 MB/s
RESULT bytes=10737418240 seconds=10.737 sink_rate_bps=1000000000 beats=671088640 errors=0 gaps=0 gap_beats=0 drop_count=0 underflows=0 egr_discard=0 max_reads=8 complete=1 error=0
```

Exit codes: **0** = playback complete and, with the checker, ERRORS = 0, UNDERFLOWS = 0,
GAP_BEATS = the recording's `drop_count`, the checker saw every beat and the first beat it
saw is the header's `first_seq`; **2** = complete, but the checker found a problem; **1** =
error or incomplete playback (Ctrl-C, read error, stall). With `--no-check`, 0 means a
complete playback.

Notes:

* **Underflows** are the playback equivalent of the recorder's drops: the sink was ready but
  no data had arrived, because the SSD (or the filesystem / RAID) reads slower than `--rate`.
  A playback at a sink rate below the drive's sustained read rate must show 0; above it, the
  ring drains and underflows appear. Underflow ticks after the last beat of the file are not
  counted, so a complete playback reads 0 unless it starved.
* A recording made with drops still plays cleanly: the checker counts the missing sequence
  numbers as GAP_BEATS, which must equal the header's `drop_count` -- an end-to-end check that
  the file, the read path and the MM2S are lossless.
* `--no-check` is for your own sink in place of `user_data_sink` (see
  [Replacing the checker with your own data sink](custom_sink)). On the reference design the
  checker *is* the sink and holds TREADY low while disabled: enable it by hand
  (`echo 1 > /sys/class/misc/fdrec0/chk_enable`, optionally `chk_rate_bps`) or the stream
  stalls and `fdplay` gives up after `--timeout`.
* The default sink rate (every clock, 3.2 GB/s) is above any SSD's read rate here, so a
  checked playback without `--rate` normally reports underflows; use `--rate` below the
  drive's read rate.
* `fdplay` and `fdrec` cannot run at the same time (one opener of `/dev/fdrec0`).

### Tuning: the FIFO budget at buffer boundaries

At every buffer boundary the AXI DMA pauses briefly: `xilinx_dma` lets the channel go idle at
the end of the current buffer and its interrupt handler starts the next one (see
[Kernel driver](driver.md), "Interaction with the `xilinx_dma` driver").
The gap is about **15 µs** worst case on the Zynq UltraScale+ target measured (`uzev`) (interrupt latency plus DMA restart; derived from
the ingest FIFO high-water marks of the Phase-1 benchmarks). The FIFO between the DMA and the
fabric must bridge it at the stream rate:

    FIFO bytes / rate  >  ~15 µs

| FIFO | Size | Covers 15 µs up to |
|------|------|--------------------|
| ingest (recording) | 4096 beats = 64 KB | 4.4 GB/s (above the 3.2 GB/s source maximum) |
| egress (playback) | 4096 beats = 64 KB | 4.4 GB/s |
| (a 512-beat FIFO, for comparison) | 8 KB | ~550 MB/s |

Below that bound, underflows (playback) or drops (recording) mean the SSD or filesystem is too
slow; above it they also appear at buffer boundaries however fast the SSD is. `fdplay` and
`fdrec` print a warning when the programmed rate exceeds the budget of the design's FIFO
(read from `EGR_FIFO_DEPTH` / `ING_FIFO_DEPTH`). Larger buffers (`--buf-size`) mean fewer
boundaries but do not shorten the gap. A custom sink or source with its own buffering adds to
the FIFO.

## fdverify

```
fdverify [options] <file>
  --max-errors <n>   print at most n discontinuities and n corrupted beats (default 20)
  --header-only      only parse and print the header
  --pattern          check the test pattern even if the header says the source was not the TPG
  -q, --quiet        no progress output
```

Prints the header, then streams the data with large reads and checks every beat:
`upper == ~lower` and `lower == previous + 1`. It reports the total beats, the first and last
sequence numbers, each discontinuity (beat index, file offset, expected and found sequence
number, gap size; the printed list is capped by `--max-errors`, but all are counted), each
corrupted beat, and compares the beat count with `data_bytes` and the missing beats with the
header's `drop_count`:

```
GAP at beat 1048576 (file offset 16781312): expected 1048576, found 1052672, 4096 beats missing
  beats           671088640 (10737418240 bytes)
  discontinuities 1, beats missing 4096
note: missing beats match the header drop_count exactly
RESULT FAIL
```

Exit code **0** only for a clean file: complete header, consistent size, no corrupted beats,
no discontinuities and `drop_count` 0. **1** if any problem was found, **2** on a usage or I/O
error. For a recording of your own data source (header flag bit0 clear), only the header is
checked unless `--pattern` is given.

## fdbench.sh

```
fdbench.sh [options]
  --dir <dir>          directory on the SSD filesystem (default /mnt/rec)
  --size <bytes>       data per step (default 32G)
  --from <MB/s>        first rate (default 250)
  --to <MB/s>          last rate (default: generator maximum, src_clk x 16)
  --step <MB/s>        rate step (default 250)
  --stop-on-fail       stop at the first failing rate
  --keep               keep the recordings
  --fdrec-args "<..>"  extra fdrec options (e.g. "--buffers 32 --qd 16")
```

For each rate it records `--size` bytes with `fdrec --rate`, verifies the file with
`fdverify`, deletes it and prints one table row. A step whose recording stalled (`fdrec`
exit code 1, see `--timeout`) is reported as `ERROR`:

```
 rate MB/s  result           drops    fifo_hwm/depth      avg MB/s    fdverify
 ---------  ------           -----    --------------      --------    --------
       250  PASS                 0          29/4096         250.0        PASS
       ...
      1750  DROPS          1234567        4097/4096        1702.3        gaps

fdbench: sustained recording rate: 1500 MB/s (/dev/md0, xfs, 32G per step)
```

The highest passing rate is the **sustained recording rate** of that board + SSD(s) +
filesystem. The default 32 GB per step is large enough to exhaust the SLC write cache of
typical smaller SSDs, so the result is the sustained rate rather than the cache rate; use a
larger `--size` for drives with very large caches. Run it once on a single drive
(`fdsetup-raid0.sh --single`) and once on RAID0; the [Benchmarks](benchmarks) page has
the results measured so far.
