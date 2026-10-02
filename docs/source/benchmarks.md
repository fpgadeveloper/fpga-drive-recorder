# Benchmarks

This page explains how the recorder is measured and lists the results per target and SSD.
Every figure was measured on hardware; the date, the target, the SSDs and the software
version are given with each table.

## Method

### Recording

Each measurement is one `fdrec` recording of test-pattern data at a fixed generator rate,
followed by `fdverify` on the file. A rate **passes** when `fdrec` exits 0 (zero dropped
beats) and `fdverify` reports a clean file. Because the generator cannot be stalled, a
pass means the whole chain (DMA, driver, filesystem, SSD) kept up with the rate for the
entire recording.

* A **burst** figure comes from a recording that is short enough to fit in the SSD's SLC
  write cache (10 GB on the drives below).
* The **sustained recording rate** is the highest passing rate over a recording long enough
  to exhaust the cache. `fdbench.sh` automates the sweep, with 32 GB per step by default.

```
sudo fdsetup-raid0.sh -y --single /dev/nvme0n1    # or: sudo fdsetup-raid0.sh -y  (RAID0)
sudo fdrec --rate 1000MB --size 10G /mnt/rec/t.dat; echo rc=$?
sudo fdverify /mnt/rec/t.dat
sudo fdbench.sh --size 32G --from 250 --step 250    # sustained-rate sweep
```

Between measurements the previous file is deleted and the filesystem trimmed
(`fstrim /mnt/rec`), and the drives are left idle before the next recording (see
[the fstrim finding](#the-fstrim-finding-and-the-ring-size) for why the idle time
matters). The filesystem is XFS unless noted.

### Playback

Each measurement is one `fdplay` of a test-pattern recording at a fixed sink rate
(`--rate`). A rate is **clean** when the hardware checker reports 0 underflows, 0 errors,
and gap beats equal to the recording's drop count; the highest clean rate is the fastest
constant-rate stream that the SSDs deliver into the fabric. `fdplay` fills the whole buffer
ring from the file before the first buffer is played, so the ring absorbs read stalls up to
its length at the sink rate.

```
sudo fdrec --rate 1000MB --size 10G /mnt/rec/t.dat; echo rc=$?
sudo fdplay --rate 2000MB /mnt/rec/t.dat; echo rc=$?
```

### References and CPU load

* **fio** gives a reference for what the filesystem and SSDs can do without a fixed input
  rate: `fio --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8` (writes) and the
  same with `--rw=read` (reads), on the same filesystem.
* **CPU load** is given as a share of all CPU cores of the target (user + system, and I/O
  wait separately) and as the share of one core used by the transfer process.

The results so far are for `uzev`. Figures for the Versal target `vck190_fmcp1` follow once
it has been measured on the bench.

## Results: uzev (UltraZed-EV)

Target `uzev` (Zynq UltraScale+ XCZU7EV, four Cortex-A53 cores at 1.1 GHz), FPGA Drive FMC
Gen4 (OP063), both SSDs linked at PCIe Gen3 x4. SSDs: Samsung 970 EVO 250GB (firmware
1B2QEXE7) and Samsung 950 PRO 256GB (firmware 1B0QBXX7); RAID0 = both, 512 KB chunks
(`fdsetup-raid0.sh` defaults). All measured on 2026-10-02 with the driver and apps of that
date. The recordings used the then-default ring of **16 x 8 MB** buffers unless noted; the
default is now 32 x 8 MB.

### Sustained recording rate

`fdbench.sh --size 32G`, 250 MB/s steps, `fdrec` with 16 x 8 MB buffers and queue depth 8,
each configuration on a freshly created XFS filesystem; before every step the previous file was deleted, the filesystem trimmed, and
the drives left idle for 60 s. Design 1.0.

| SSD | layout | sustained rate (32 GB) | fio reference (32 GB) |
|---|---|---|---|
| Samsung 970 EVO 250GB | single | 250 MB/s | 484 MB/s |
| Samsung 950 PRO 256GB | single | 750 MB/s | 962 MB/s |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 500 MB/s | 1416 MB/s |

fio reference: `fio --name=w --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8
--size=32G --filename=/mnt/rec/fio.dat` on the freshly created filesystem, before the sweep.
It is an average over 32 GB: fio has no fixed input rate, so it rides the SLC cache at full
speed and does not show the post-cache write rate that limits a constant-rate recording.

Every step of the sweeps ("first gap" is the file offset of the first discontinuity
reported by `fdverify`; "avg MB/s" is the data written divided by the recording time):

| SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (of 4096) | avg MB/s | fdverify | first gap |
|---|---|---|---|---|---|---|---|---|
| Samsung 970 EVO 250GB | single | **250** | pass | 0 | 260 | 250.0 | pass | - |
| Samsung 970 EVO 250GB | single | 500 | drops | 632 577 164 | full | 384.6 | gaps | 14.40 GB |
| Samsung 970 EVO 250GB | single | 750 | drops | 1 591 855 641 | full | 428.6 | gaps | 14.26 GB |
| Samsung 950 PRO 256GB | single | 250 | pass | 0 | 249 | 250.0 | pass | - |
| Samsung 950 PRO 256GB | single | 500 | pass | 0 | 538 | 499.9 | pass | - |
| Samsung 950 PRO 256GB | single | **750** | pass | 0 | 853 | 749.8 | pass | - |
| Samsung 950 PRO 256GB | single | 1000 | drops | 84 401 144 | full | 958.7 | gaps | 3.57 GB |
| Samsung 950 PRO 256GB | single | 1250 | drops | 652 697 593 | full | 955.2 | gaps | 0.59 GB |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 250 | pass | 0 | 267 | 250.0 | pass | - |
| 970 EVO + 950 PRO | RAID0, 512K chunk | **500** | pass | 0 | 625 | 499.9 | pass | - |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 750 | drops | 45 579 326 | full | 731.4 | gaps | 29.17 GB |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 1000 | drops | 188 352 364 | full | 914.6 | gaps | 28.44 GB |

In every failing step the gaps sum exactly to the drop count in the file header.

* **970 EVO SLC cache.** Above its post-cache rate the 970 EVO records cleanly until about
  14.3-14.4 GB and drops after that, at 500 and at 750 MB/s alike. The earlier 40 GB
  measurement (300 MB/s clean) lies between the 250 and 500 MB/s steps.
* **950 PRO** has no comparable cache cliff; at 1000 MB/s and above it drops within the first
  few GB, writing ~955-960 MB/s.
* **RAID0** at 750 and 1000 MB/s drops at ~28-29 GB, i.e. when the 970 EVO's half of the
  stripe (~14.5 GB) exhausts its SLC cache. The array's sustained rate is limited by the
  970 EVO.

### Burst and 40 GB recordings

Single recordings at a fixed rate, design 1.0, 16 x 8 MB buffers unless the row says
otherwise. "Burst" rows are 10 GB recordings (inside the
SLC cache of the 970 EVO); the 40 GB rows run well past it.

| SSD | layout | recording | rate (MB/s) | result | FIFO high-water (of 4096 beats) |
|---|---|---|---|---|---|
| Samsung 970 EVO 250GB | single | 10 GB | 250 | pass | 228 |
| Samsung 970 EVO 250GB | single | 10 GB | 500 | pass | 377 |
| Samsung 970 EVO 250GB | single | 10 GB | 1000 | pass | 842 |
| Samsung 970 EVO 250GB | single | 10 GB | 1250 | pass | 1732 |
| Samsung 970 EVO 250GB | single | 10 GB | **1400** | pass (highest burst) | 1101 |
| Samsung 970 EVO 250GB | single | 10 GB | 1500 | drops after ~8.5 GB | full |
| Samsung 970 EVO 250GB | single | 40 GB | **300** | pass (sustained) | 363 |
| Samsung 950 PRO 256GB | single | 40 GB | **800** | pass (sustained) | 739 |
| Samsung 950 PRO 256GB | single | 40 GB | 1000 | drops (SSD writes ~950 MB/s) | full |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 10 GB | 1400 | pass | 1058 |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 10 GB | **1850** | pass with `--buffers 32` (highest burst) | 1596 |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 10 GB | 2000 | drops (array writes ~1.9 GB/s) | full |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 40 GB | **600** | pass (sustained) | 639 |
| 970 EVO + 950 PRO | RAID0, 512K chunk | 40 GB | 700 | drops after ~31 GB | full |

Reference: `fio --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8 --size=10G`
on the same XFS filesystem writes 1502 MB/s to the 970 EVO (inside its SLC cache).

### Playback

Design 1.1 (AXI DMA MM2S, 4096-beat egress FIFO, `fdrec_check` sink), XFS, `fdplay` with
queue depth 8. Each run plays a 10 GB test-pattern recording made at 1000 MB/s with 0 drops.
"Runs" lists underflow-free runs / runs at that rate.

| date | SSD | layout | buffers | highest clean playback rate | runs | first rate with underflows | read fio reference |
|---|---|---|---|---|---|---|---|
| 2026-10-02 | 970 EVO + 950 PRO | RAID0, 512K chunk | 16 x 8 MB | **2000 MB/s** | 9/9 | 2200 MB/s (1 of 3 runs), 2400 MB/s (1 of 6), 2600 MB/s (1 of 2) | 2161-2498 MB/s; 3184 MB/s with hugepage fixed buffers |
| 2026-10-02 | 970 EVO + 950 PRO | RAID0, 512K chunk | 32 x 8 MB | **2600 MB/s** | 6/6 | 2800 MB/s (1 of 1) | as above |
| 2026-10-02 | 950 PRO 256GB | single | 16 x 8 MB | **1500 MB/s** | 4/4 | 1600 MB/s (1 of 3), 1700 MB/s (1 of 1) | 1583 MB/s; 1593 MB/s with hugepage fixed buffers |

Read fio reference: `fio --name=rd --filename=<the recording> --readonly --rw=read --bs=8M
--direct=1 --ioengine=io_uring --iodepth=8 --size=10G` on the same filesystem (two runs on
RAID0: 2161 and 2498 MB/s; 2426 MB/s with `--iodepth=16`); "hugepage fixed buffers" adds
`--iomem=mmaphuge --fixedbufs`, which is how `fdplay` reads (hugepage buffers registered with
io_uring).

Other playback figures on the same setup:

| measurement | result |
|---|---|
| 10 GB clean recording, `--rate 1000MB` | 10.78 s, beats 671 088 640, errors 0, gaps 0, gap beats 0, underflows 0, last seq 671 088 639, egr_discard 0 |
| 10 GB recording made at 3000 MB/s (drop count 361 884 621, 1216 discontinuities in `fdverify`), `--rate 500MB` | 21.52 s, beats 671 088 640, errors 0, gaps 1216, gap beats 361 884 621, underflows 0 |
| `--rate 3200MB` from RAID0 (above the read rate) | 40 896 598 underflow ticks (16 buffers), 44 007 277 (32 buffers); exit code 2 |
| 256 MB recording resident in the ring (32 x 8 MB, 64 x 4 MB), `--rate 3200MB` | 0 underflows over 31 and 63 buffer boundaries at the full sink rate (the egress FIFO covers the MM2S restart gap at 3.2 GB/s: < 20 µs) |
| Ctrl-C (SIGINT) after 4 s at 1000 MB/s | exit code 1, 4.0 GB played, egr_discard 809 668-1 042 442 beats (the flushed in-flight buffers), no `Cannot stop channel`; the next playback is complete with 0 underflows |
| CPU during a 1000 MB/s playback (`top`, 2 s samples) | 6 % of the four Cortex-A53 cores in total (user + system + softirq), 17 % I/O wait; the `fdplay` process 24 % of one core. One MM2S interrupt per 8 MB buffer |
| Checker prime wait (driver, at most 100 ms) | never timed out (no `did not prime` message in any playback of the session, about 50) |

* **Read stalls.** Isolated underflow bursts at 2200 and 2400 MB/s with 16 buffers (465 979
  and 1638 ticks) mean the RAID0 delivered nothing for longer than the 128 MB ring lasts at
  that rate (~55 ms); 32 buffers (256 MB) absorbed them in every run up to 2600 MB/s.
* **Single 950 PRO**: a sink above the drive's read rate drains the ring at the difference
  of the two rates, so a 10 GB playback at 1600 MB/s (~7 MB/s above the read rate) sometimes
  ends before the 128 MB ring runs dry.
### CPU load

Measured with `top` during a transfer, after it had settled:

With 16 x 8 MB buffers:

| transfer | total CPU (4 cores) | transfer process |
|---|---|---|
| `fdrec`, 1000 MB/s to the 970 EVO | about 2 % (user + system); the rest idle or I/O wait | `fdrec` 8 % of one core (3 s samples) |
| `fdplay`, 1000 MB/s from RAID0 | 6 % (user + system + softirq), 17 % I/O wait | `fdplay` 24 % of one core (2 s samples) |

There is one DMA interrupt per 8 MB buffer in both directions. The
[comparison with the dd method](#comparison-with-fpga-drive-aximm-pcie-dd-method) below
measures CPU time differently (over the whole transfer, from the process's own accounting),
so its per-process figures are not directly comparable with these `top` samples.

## The SLC cache

Most consumer SSDs write into a fast pseudo-SLC cache first and move the data to their TLC
flash later. While the cache lasts, the SSD writes at its datasheet rate; once it is full,
the write rate drops. For a recorder, which writes at a constant rate for as long as the
recording lasts, the rate after the cache is the one that counts.

* The **970 EVO 250GB** writes at up to ~1.5 GB/s while its cache lasts (about 13-14 GB on
  an empty, trimmed drive) and at ~330 MB/s after that. A 1000 MB/s recording therefore runs
  clean for ~14 GB and then drops; above its post-cache rate, it drops at 14.3-14.4 GB
  whatever the rate (500 and 750 MB/s alike). Its sustained recording rate is 250 MB/s in
  250 MB/s steps (300 MB/s passed over 40 GB).
* The **950 PRO 256GB** shows no comparable cliff: above ~950 MB/s it drops within the first
  few GB, and its sustained rate is 750 MB/s.
* **RAID0** stripes every chunk across both drives, so the array is limited by its slower
  member: about twice the 970 EVO's post-cache rate. At 750 and 1000 MB/s it drops at
  ~28-29 GB, when the 970 EVO's half of the stripe (~14.5 GB) exhausts its cache.

Size the rate for the longest recording you need: a short burst test, such as a 10 GB
recording, a 4 GB `dd`, or fio over 32 GB (which runs at full speed through the cache and
then slower), overstates what a drive sustains.

## The fstrim finding and the ring size

During the first RAID0 measurements, a 1700 MB/s recording with the 16 x 8 MB ring had one
gap of about 84 MB right after the first 128 MB of the file. The cause turned out to be
`fstrim` run **immediately** before the recording: the SSDs were still processing the
discards, and no write completed for more than 100 ms. The 128 MB ring lasts 75 ms at
1.7 GB/s, so it ran dry and the FIFO overflowed. Waiting 3 s or more after `fstrim`, not
trimming, or a larger ring (24 x 8 MB, 32 x 8 MB or 16 x 16 MB) each removed the gap. This is
why `fdrec` now defaults to 32 x 8 MB buffers (256 MB), and why the benchmark steps wait after
trimming.

RAID0 (970 EVO + 950 PRO, 512K chunk), 10 GB recordings at 1700 MB/s, `fdrec --stats 0.1`.
"Trim" is `rm` of the previous file, `sync` and `fstrim /mnt/rec`; "idle" is the pause between
that and `fdrec`. The CPU frequency is fixed (only the `userspace` governor is available; all
cores at 1.1 GHz, the highest available setting), so a frequency ramp is not a factor.

| filesystem | before the run | buffers | drops (beats) | first gap | FIFO high-water |
|---|---|---|---|---|---|
| XFS | trim, idle 15 s | 16 x 8 MB | 0 | - | 2196 |
| XFS | trim, idle 15 s | 16 x 8 MB | 0 | - | 1201 |
| XFS | trim, idle 15 s | 16 x 8 MB | 0 | - | 1919 |
| XFS | trim, idle 15 s | 16 x 8 MB | 0 | - | 1469 |
| XFS | trim, idle 3 s | 16 x 8 MB | 0 | - | 2335 |
| XFS | no trim (rm + sync only) | 16 x 8 MB | 0 | - | 1747 |
| XFS | existing 10 GB file at the same path (see note) | 16 x 8 MB | 0 | - | 2049 |
| XFS | trim, idle 15 s | 24 x 8 MB | 0 | - | 2129 |
| XFS | trim, idle 15 s | 32 x 8 MB | 0 | - | 3806 |
| XFS | trim, idle 15 s | 16 x 16 MB | 0 | - | 1303 |
| XFS | trim, no idle | 16 x 8 MB | 307 099 | 3.43 GB | full |
| XFS | trim, no idle | 16 x 8 MB | 5 489 794 | 134 287 472 (128 MB) | full |
| XFS | trim, no idle | 16 x 8 MB | 4 947 845 | 134 287 472 (128 MB) | full |
| XFS | trim, no idle | 24 x 8 MB | 0 | - | 2284 |
| XFS | trim, no idle | 32 x 8 MB | 0 | - | 3361 |
| XFS | trim, no idle | 16 x 16 MB | 0 | - | 1394 |
| ext4 | trim, idle 15 s | 16 x 8 MB | 0 | - | 1160 |
| ext4 | trim, idle 15 s | 16 x 8 MB | 0 | - | 1580 |
| ext4 | trim, no idle | 16 x 8 MB | 0 | - | 1929 |
| ext4 | trim, no idle | 16 x 8 MB | 0 | - | 1605 |

* In the two runs with the gap at 128 MB, the 0.1 s statistics line shows 0 bytes written with
  8 writes in flight and the FIFO already full: the first writes had not completed after
  100 ms. `fstrim` itself returned in ~0.03 s on XFS.
* `fdrec` opens the output with `O_TRUNC` and preallocates it with `posix_fallocate`, so
  recording over an existing file starts from freshly allocated (unwritten) extents, the same
  as a new file.
* On ext4 only the first `fstrim` after `mkfs` took long (7.1 s); later ones took ~0.2 s.
  ext4 skips block groups it has already trimmed, whereas XFS discards all free space on every
  `fstrim`, so the ext4 runs issued far fewer discards before the recording.
* The `fifo_hwm` and `drop_count` sysfs attributes read 0 once `fdrec` has exited (the driver
  resets the core on close); the values above are from `fdrec`'s `RESULT` line.

## Comparison with fpga-drive-aximm-pcie (dd method)

The [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
reference design measures SSD throughput with four `dd` scripts, which are also in this
design's image (see [Test the design in Linux](linux_test.md#4-measure-the-ssds-with-the-dd-speed-test-scripts)).
This section compares the two methods on the same board, SSDs and image.

### Method

All measured on `uzev` on 2026-10-02, with the playback-capable image (register map 1.1),
the 970 EVO 250GB and 950 PRO 256GB described above, XFS on a freshly created filesystem
with 30 s of idle time per configuration and 20 s between runs, RAID0 = both drives with
512 KB chunks. Figures are medians of 3 runs, with [min–max], unless noted.

* **dd** (`single_write_test.sh`, `single_read_test.sh`, `dual_*_test.sh`, run verbatim):
  one `dd` process moves 1000 blocks of 4 MiB with `O_DIRECT` between a file on the SSD
  filesystem and `/dev/zero`, one block at a time (queue depth 1). The dual scripts run one
  `dd` per SSD in parallel, each on its own filesystem, and report the aggregate.
* **fdrec / fdplay**: recordings and playbacks of the same 4000 MiB at fixed rates in
  250 MB/s steps, **16 x 8 MB buffers** (the image default when these runs were made; the
  shipped default is now 32), queue depth 8. The table gives the highest rate that was clean
  (`fdrec`: 0 drops and `fdverify` PASS; `fdplay`: 0 underflows) and the rate it achieved.
* **Units.** The scripts print "MBytes/s" but move 4000 MiB, so their figure is in MiB/s.
  All figures here are MB/s (10⁶ bytes/s), like `fdrec` and `fdplay`: script figure × 1.0486.
* **CPU** is measured the same way for every row, over the whole transfer: the total CPU from
  `/proc/stat` deltas (share of all four cores: user / system / IRQ + softirq / I/O wait),
  and the transfer process's (user + system) / real time from `time -p`, as a share of one
  core. The per-process figure is the stable one. "MB/s per % core" is the rate divided by
  the per-process figure. (The `top` figures in the [CPU load](#cpu-load) section above were
  taken with another method and are not comparable with these.)

### Results: uzev

| method | config | direction | size | MB/s | total CPU % (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | 970 EVO | write | 4000 MiB | 1024 [1013–1035] | 0.0 / 12.2 / 1.0 / 10.2 | 55 [54–58] | 18 |
| dd (script) | 970 EVO | read | 4000 MiB | 1398 [1379–1402] | 0.2 / 10.2 / 2.2 / 10.9 | 43 [42–44] | 32 |
| dd (script) | 950 PRO | write | 4000 MiB | 948 [926–948] | 0.1 / 12.7 / 0.4 / 10.4 | 53 [52–54] | 18 |
| dd (script) | 950 PRO | read | 4000 MiB | 1267 [1259–1278] | 0.2 / 9.1 / 1.2 / 11.4 | 39 [39–41] | 32 |
| dd (script) | RAID0 | write | 4000 MiB | 1302 [1148–1335] | 0.1 / 18.6 / 1.3 / 4.1 | 79 [75–90] | 16 |
| dd (script) | RAID0 | read | 4000 MiB | 1705 [1658–1769] | 0.2 / 13.7 / 3.5 / 5.7 | 65 [62–67] | 26 |
| dd (dual script) | both drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 1915 [1819–1919] | 0.1 / 24.7 / 0.3 / 19.7 | 103 [102–108] | 19 |
| dd (dual script) | both drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 2533 [2519–2549] | 0.2 / 18.4 / 3.6 / 22.2 | 77 [76–80] | 33 |
| `fdrec`, highest clean: 1500 | 970 EVO | record | 4000 MiB | 1493 | 0.1 / 9.1 / 0.0 / 18.7 | 36 [36–37] | 41 |
| `fdrec`, highest clean: 750 | 950 PRO | record | 4000 MiB | 748 | 0.0 / 5.6 / 0.0 / 21.9 | 22 | 35 |
| `fdrec` at 750 | 950 PRO | record | 32 GB | 750 | 0.1 / 5.3 / 0.1 / 21.8 | 21 | 36 |
| `fdrec`, highest clean: 1750 | RAID0 | record | 4000 MiB | 1742 | 0.1 / 13.1 / 0.2 / 17.8 | 51 | 34 |
| `fdplay`, highest clean: 1500 | 970 EVO | play | 4000 MiB | 1455 | 0.0 / 6.0 / 1.0 / 16.2 | 26 | 56 |
| `fdplay`, highest clean: 1500 | 950 PRO | play | 4000 MiB | 1455 | 0.0 / 8.7 / 0.0 / 13.8 | 34 | 43 |
| `fdplay`, highest clean: 2750 | RAID0 | play | 4000 MiB | 2651 | 0.1 / 14.4 / 4.4 / 4.6 | 74 | 36 |

Notes:

* Raw script output (MiB/s, medians): 970 EVO write 977, read 1333; 950 PRO write 904, read
  1208; RAID0 write 1242, read 1626; dual write 1826, read 2416 (aggregate).
* `fdrec` clean runs: 970 EVO 1500 MB/s 3/3 (ingest FIFO high-water mark 1020–1889 of 4096),
  1750 drops. 950 PRO 750 3/3 (the 32 GB run included, high-water mark 733); 1000 was clean
  in 2 of 3 runs (one run dropped 63 988 beats; 972 MB/s, 28 % of a core); 1250 drops at the
  drive's limit (~972 MB/s). RAID0 1750 1/1; 2000 clean in 2 of 3 (one run dropped 718 847
  beats; 1943 MB/s, 58 % of a core); 2250 drops.
* `fdplay` clean runs: 3/3 at each rate in the table; the next step (1750, 1750, 3000 MB/s)
  had underflows.
* At 1000 MB/s: `fdrec` 25 % of a core (970 EVO) and 31 % (RAID0); `fdplay` 16 / 22 / 27 %
  (970 EVO / 950 PRO / RAID0). Recorder CPU time is almost all system time (io_uring
  submission and the DMA ioctls) and scales linearly with the rate.

Variations, to separate the effects (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| 970 EVO | dd bs=1M | 818 | 1059 | 52 / 33 |
| 970 EVO | dd bs=16M | 1076 | 1525 | 57 / 47 |
| 970 EVO | two dd streams on the drive (aggregate) | 1517 | 1586 | 84 / 43 |
| 970 EVO | dd 32 GB (read: 1 run) | 460 | 1380 | 25 / 39 |
| 950 PRO | dd bs=1M | 846 | 1159 | 55 / 41 |
| 950 PRO | dd bs=16M | 945 | 1441 | 53 / 49 |
| 950 PRO | two dd streams on the drive (aggregate) | 963 | 1583 | 53 / 46 |
| 950 PRO | dd 32 GB (read: 1 run) | 956 | 1340 | 53 / 41 |
| RAID0 | dd bs=1M | 1036 | 1487 | 71 / 54 |
| RAID0 | dd bs=16M | 1219 | 1906 | 75 / 78 |
| RAID0 | two dd streams on the array (aggregate) | 1894 | 2923 | 119 / 98 |
| RAID0 | dd 32 GB (1 run) | 1176 | 1699 | 76 / 59 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`; fio's own bandwidth and
CPU figures):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| 970 EVO | 1535 MB/s, 22 % of a core | 1574 MB/s, 46 % | 487 MB/s, 6 % | 1596 MB/s, 43 % |
| 950 PRO | 971 MB/s, 14 % | 1568 MB/s, 54 % | 963 MB/s, 13 % | 1590 MB/s, 57 % |
| RAID0 | 1936 MB/s, 34 % | 2271 MB/s, 94 % | 1423 MB/s, 25 % | 2253 MB/s, 95 % |

fio's write CPU is mostly user time spent filling its buffers; it is a reference for the
drives, not for the recorder.

### Why the figures differ

The two methods answer different questions, and neither measures the PCIe link.

**CPU cost.** A `dd` write is a CPU-bound copy of zeros: every 4 MiB block is first
zero-filled by the kernel from `/dev/zero` into `dd`'s buffer, then written with `O_DIRECT`.
That costs about 55 % of one Cortex-A53 core per ~1 GB/s, and on RAID0 a single `dd`
becomes CPU-bound at 80–90 % of a core. `fdrec` never produces or copies the data: the AXI
DMA fills the hugepage buffers and the NVMe controller reads the same buffers, and the CPU
only issues io_uring requests and ioctls and does the cache maintenance. Measured, that is
about **2× more data per unit of CPU for writes** (`dd` 15–19 MB/s per % of a core,
`fdrec` 33–41). For reads the gap is smaller, **about 1.1–1.9×** (`dd` 25–37, `fdplay`
36–56): a `dd` read lands in its buffer by DMA and is handed to `/dev/zero`, which discards
it without a copy, so `dd` pays only the per-I/O work (a system call, pinning 1024 pages of
4 KiB per block, a wake-up per completion). The recorder's remaining cost is the kernel's
I/O path itself.

**Queue depth 1 vs 8 in flight.** `dd` has one 4 MiB request in flight; the drive idles
while `dd` prepares the next one. On the 970 EVO one `dd` writes 1024 MB/s, two `dd`
streams 1517 MB/s and fio at queue depth 8 1535 MB/s. On RAID0 one `dd` (each block spans
both drives) reaches 1302 MB/s write and 1705 MB/s read, against fio's 1936 / 2271 and
`fdplay`'s 2651 MB/s. The 950 PRO's write is limited by the drive (~950–970 MB/s) whatever
the queue depth. Block size matters too: 1 MiB blocks lose 15–25 %, 16 MiB gain 5–15 % on
reads.

**Burst vs sustained.** 4000 MiB fits inside the 970 EVO's SLC cache (which ends after
about 14 GB): the 4 GB `dd` write gives 1024 MB/s, a 32 GB `dd` write 460 MB/s on average.
The 950 PRO has no such cliff: 948 MB/s over 4 GB, 956 over 32 GB. The recorder's
"highest clean rate" is stricter than any average: a recorder must never fall behind, not
even briefly, so the drive's worst moment sets it (on the 970 EVO at 1500 MB/s the ingest
FIFO reached 1889 of 4096 beats). That is why the recorder's rates in this table are
4000 MiB bursts too; for long recordings the
[32 GB sustained rates](#sustained-recording-rate) apply: 970 EVO 250, 950 PRO 750, RAID0
500 MB/s.

**What else differs.** Both methods bypass the page cache (`O_DIRECT`); no cache effect
was seen. `dd` extends its file block by block, while `fdrec` preallocates the full size
first. And the `dd` data never touches the FPGA, whereas the `fdrec` and `fdplay` figures
include the AXI DMA, the fabric FIFO and the DDR traffic of the DMA and the SSD using the
same buffers.

**Neither measures the PCIe link.** A PCIe Gen3 x4 link carries close to 4 GB/s in each
direction. Every figure here is below that: the SSDs (and their caches), the filesystem and
the Linux I/O path set the limits, never the link. To check the link itself, look at its
negotiated speed and width (`lspci -vv`, see
[Test the design in Linux](linux_test.md#1-check-that-the-pcie-links-are-up)).

The sibling design's own documentation quotes lower `dd` figures for `uzev` (read 790–970,
write ~585 MB/s); those were measured with a different SSD (Samsung 980 PRO) and an older
image, and do not apply to this setup.

For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics. See their
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).
