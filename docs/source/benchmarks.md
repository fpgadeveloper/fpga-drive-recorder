# Benchmarks

This page explains how the recorder is measured and lists the results per target and SSD.
Every figure was measured on hardware; the date, the target, the SSDs and the software
version are given with each table.

## Method

### Recording method

Each measurement is one `fdrec` recording of test-pattern data at a fixed generator rate,
followed by `fdverify` on the file. A rate **passes** when `fdrec` exits 0 (zero dropped
beats) and `fdverify` reports a clean file. Because the generator cannot be stalled, a
pass means the whole chain (DMA, driver, filesystem, SSD) kept up with the rate for the
entire recording.

* A **burst** figure comes from a recording that is short enough to fit in the SSD's SLC
  write cache (10 GB on every drive below).
* The **sustained recording rate** is the highest passing rate over a recording long enough
  to exhaust the cache. `fdbench.sh` automates the sweep, with 32 GB per step by default.
  32 GB stays **inside** the cache of the 1 TB drives below (72-120 GB per drive), so the
  32 GB sweep gives an *in-cache* rate, and the sustained rate comes from single recordings
  of 143-480 GiB, well past the cache
  (see [Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)).

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

### Playback method

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

## Setups

Two SSD pairs were measured, each on two targets. Units: MB/s = 10⁶ bytes/s; figures are
medians of 3 runs unless noted.

| SSDs | target | PCIe link per SSD | measured |
|---|---|---|---|
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` (M.2 M-key Stack FMC on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-17 and 2026-10-20 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` (FPGA Drive FMC Gen4 on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-18 and 2026-10-20 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` (FPGA Drive FMC Gen4 on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-19 and 2026-10-20 |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` (M.2 M-key Stack FMC on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-19 and 2026-10-20 |

All four were measured with the playback-capable images (register map 1.1; ingest FIFO
16384 beats, egress FIFO 4096 beats, the AXI DMA interrupts pinned by the driver), with the shipped
default of 32 x 8 MB buffers, and with a fan on the cards (no thermal throttling: at most 60 °C
on the Sabrent drives on `vck190_fmcp1` and 67 °C on `zcu106_hpc0`, 49 °C on the 980 PROs on
`vck190_fmcp1` and 52 °C on `zcu106_hpc0`, 0 thermal-management transitions). The same two
drives of each pair were used on both boards.

## Results: recording, playback and CPU

Targets `vck190_fmcp1` (Versal, two Cortex-A72 cores at 1.4 GHz) and `zcu106_hpc0` (Zynq
UltraScale+, four Cortex-A53 cores at 1.2 GHz), with the SSD pairs of [Setups](#setups). RAID0 =
both drives of a pair, 512 KB chunks (`fdsetup-raid0.sh` defaults). The recordings used the
shipped default ring of 32 x 8 MB buffers unless noted. "FIFO high-water" is the highest fill
level the ingest FIFO (16384 beats) reached during a recording, in beats; "full" means it
overflowed.

### Sustained recording rate

`fdbench.sh --size 32G`, 250 MB/s steps, `fdrec` with queue depth 8, each configuration on a
freshly created XFS filesystem; before every step the previous file was deleted, the
filesystem trimmed, and the drives left idle for 60 s; 32 x 8 MB buffers, and a last step at
3200 MB/s (the generator maximum).

The last column is the rate that holds **past the SLC cache**. The 32 GB sweep runs inside the
cache of these drives, so the last column comes from the
[long recordings](#long-recordings-past-the-slc-cache).

| target | SSD | layout | 32 GB sweep: highest clean step | fio reference (32 GB) | sustained past the SLC cache |
|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1000 MB/s, in the cache (750 dropped once, see below) | 4380 MB/s, in the cache | **1000 MB/s** over 143 GiB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (2500, 3000 and 3200 MB/s clean 2 of 2 each on 2026-10-20; in the 2026-10-17 sweep 3000 and 3200 MB/s each dropped once at the start-up stall, see below) | 4428 MB/s, in the cache | **3200 MB/s** over 350 GiB (2750, 3000 and 3200 MB/s clean, one run each) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3200 MB/s (the generator maximum), in the cache | 4586 MB/s, in the cache | **1750 MB/s** over 240 GiB (2000 MB/s dropped when the cache ended, at 125 GB) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache | 4718 MB/s, in the cache | **3200 MB/s** over 480 GiB (2250, 2500, 2750, 3000 and 3200 MB/s clean, one run each) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3000 MB/s, in the cache (3200 MB/s exceeds the drive's ~3.04 GB/s on Gen3 x4) | 2984 MB/s, in the cache | **1750 MB/s** over 200 GiB and 221 GiB (2000 MB/s dropped from 127.04 GB, past the ~115-120 GB cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (high-water mark 3042) | 3493 MB/s, in the cache (fio CPU-bound) | **2750 MB/s** over 350 GiB (3000 MB/s clean in 1 of 2, 3200 MB/s dropped once: one late DMA restart each, see below) |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2750 MB/s, in the cache (3000 MB/s exceeds the drive's ~2.93 GB/s on Gen3 x4) | 2874 MB/s, in the cache | **1750 MB/s** over 200 GiB (2000 MB/s dropped from 95.95 GB, past the ~72 GB cache) |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (2750 MB/s dropped once to a late DMA restart; clean 3 of 3 in a repeat) | 3355 MB/s, in the cache (fio CPU-bound) | **3000 and 3200 MB/s** over 350 GiB, one run each; 2500 and 2750 MB/s each dropped once (one late DMA restart of 213-364 µs, see below) |

`vck190_fmcp1` with two Sabrent Rocket 2230 1TB (Gen4 x4, 2026-10-17), same method, 32 x 8 MB
buffers. Single drive: 250 and 500 MB/s clean; 750 MB/s dropped once at 30.86 GB (one gap,
14 366 016 beats); 1000 MB/s clean (high-water mark 709); 1250 MB/s dropped once at 17.36 GB
(one gap, 34 462 922 beats). Both failures are one gap each in which no write completed for
about 0.65 s (drops x 16 B plus the 256 MB ring, divided by the rate), not a bandwidth limit:
the drive writes ~1.8 GB/s even after its cache. 750 MB/s was clean in 3 further 32 GB runs,
and 1000 MB/s was clean in all 7 long recordings (5 x 32 GB, 40 GB, 143 GiB), so 1000 MB/s is
the highest step that never failed, not a hard limit (see
[Where the bottlenecks are](#5-latency-budgets-not-bandwidth)). RAID0: clean from 250 to
2750 MB/s (high-water mark 2156 at 2750); 3000 and 3200 MB/s each dropped once at the same
file offset, 268 505 200 bytes = the 4 KiB header + 256 MiB, i.e. right after the first ring's
worth: the first writes after the 60 s idle took longer than the ring lasts at 3 GB/s
(~85 ms), the start-up stall of [the fstrim finding](#the-fstrim-finding-and-the-ring-size).
The same rates passed 40 GB with 30 s of idle (see the burst table) and 32 GB with 60 s of
idle in 6 of 6 runs at 2500-3200 MB/s on 2026-10-20.

`vck190_fmcp1` with two Samsung 980 PRO 1TB (Gen4 x4, 2026-10-18), same method, 32 x 8 MB
buffers: every step from 250 to 3200 MB/s (the generator maximum) was clean, single and RAID0
(high-water marks 2692 and 1871 at 3200 MB/s). All of these steps run inside the drives'
~115-120 GB SLC cache. Past the cache one drive holds 1750 MB/s (clean over 240 GiB;
2000 MB/s drops when the cache ends at 125 GB), the pair 3200 MB/s, the generator maximum
(clean over 480 GiB at 2250, 2500, 2750, 3000 and 3200 MB/s, 2026-10-20); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`zcu106_hpc0` with two Samsung 980 PRO 1TB (Gen3 x4, 2026-10-20), same method, 32 x 8 MB
buffers. Single drive: clean up to 3000 MB/s (high-water mark 2930); 3200 MB/s drops from
5.02 GB while writing 3036 MB/s, the drive on its Gen3 x4 link. RAID0: clean at every step up
to the generator's 3200 MB/s (high-water mark 3853 at 3000 MB/s, 3042 at 3200 MB/s). All of
these steps run inside the 980 PRO's SLC cache (~115-120 GB per drive). Past the cache one
drive held 1750 MB/s, the RAID0 pair 2750 MB/s (see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)).

`zcu106_hpc0` with two Sabrent Rocket 2230 1TB (Gen3 x4, 2026-10-20), same method, 32 x 8 MB
buffers. Single drive: clean up to 2750 MB/s, where one DMA restart of about 90 µs took the
high-water mark to 15 427 of the 16384 beats; 3000 and 3200 MB/s write ~2.93 GB/s, the drive on
its Gen3 x4 link, and drop from 5.14 GB and 1.98 GB: a fixed rate deficit, not a random event.
RAID0: clean at every step up to the generator's 3200 MB/s (high-water mark 7517 at 3000 MB/s,
3560 at 3200 MB/s) except 2750 MB/s, which lost 54 968 beats in one event 0.18 GB into the
recording (a DMA restart of about 415 µs at a buffer boundary; three repeats at 2750 MB/s were
clean). All of these steps run inside the SLC cache (~72 GB per drive, then ~1.8 GB/s); one drive
held 1750 MB/s over 200 GiB, the RAID0 pair 3000 and 3200 MB/s over 350 GiB (see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)).

fio reference: `fio --name=w --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8
--size=32G --filename=/mnt/rec/fio.dat` on the freshly created filesystem, before the sweep.
It is an average over 32 GB: fio has no fixed input rate, so it rides the SLC cache at full
speed and does not show the post-cache write rate that limits a constant-rate recording.

Every step of the sweeps ("first gap" is the file offset of the first discontinuity
reported by `fdverify`; "avg MB/s" is the data written divided by the recording time;
"gaps (1)" = exactly one discontinuity); 32 x 8 MB buffers:

| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | avg MB/s | fdverify | first gap |
|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 250 | pass | 0 | 169 | 250.0 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 500 | pass | 0 | 372 | 499.9 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 750 | drops | 14 366 016 | full | 744.9 | gaps (1) | 30.86 GB |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | **1000** | pass | 0 | 709 | 999.8 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1250 | drops | 34 462 922 | full | 1229.9 | gaps (1) | 17.36 GB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 250 | pass | 0 | 168 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 500 | pass | 0 | 336 | 499.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 750 | pass | 0 | 700 | 749.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 899 | 999.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 948 | 1249.6 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1064 | 1499.5 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 1427 | 1749.3 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 1889 | 1999.1 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 1688 | 2248.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 2115 | 2498.5 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **2750** | pass | 0 | 2156 | 2748.3 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | drops | 8 499 012 | full | 2986.2 | gaps (1) | 0.27 GB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 | drops | 1 835 534 | full | 3195.1 | gaps (1) | 0.27 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 250 | pass | 0 | 173 | 250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 500 | pass | 0 | 356 | 499.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 750 | pass | 0 | 780 | 749.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1000 | pass | 0 | 853 | 999.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1250 | pass | 0 | 1082 | 1249.6 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1500 | pass | 0 | 1255 | 1499.4 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1750 | pass | 0 | 1569 | 1749.3 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2000 | pass | 0 | 1191 | 1999.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2250 | pass | 0 | 1801 | 2248.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 2144 | 2498.5 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2750 | pass | 0 | 1868 | 2748.3 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3000 | pass | 0 | 2597 | 2998.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | **3200** | pass | 0 | 2692 | 3197.7 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 217 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 405 | 499.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 1288 | 749.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 774 | 999.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 844 | 1249.7 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1198 | 1499.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 1126 | 1749.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 1647 | 1999.2 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 1766 | 2249.0 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 1813 | 2498.7 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 1997 | 2748.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 2286 | 2998.0 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 1871 | 3197.7 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 250 | pass | 0 | 208 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 500 | pass | 0 | 429 | 499.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 750 | pass | 0 | 535 | 749.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1000 | pass | 0 | 888 | 999.7 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1250 | pass | 0 | 973 | 1249.5 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1500 | pass | 0 | 1443 | 1499.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1750 | pass | 0 | 1636 | 1749.1 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2000 | pass | 0 | 1607 | 1998.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2250 | pass | 0 | 1771 | 2248.5 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 2162 | 2498.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2750 | pass | 0 | 1900 | 2747.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | **3000** | pass | 0 | 2930 | 2997.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3200 | drops | 98 954 778 | full | 3035.8 | gaps (20) | 5.02 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 207 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 402 | 499.9 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 715 | 749.9 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 809 | 999.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 974 | 1249.6 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1237 | 1499.4 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 1369 | 1749.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 1898 | 1999.1 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 1712 | 2248.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 1774 | 2498.5 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 2319 | 2748.1 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 3853 | 2997.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 3042 | 3197.1 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 250 | pass | 0 | 207 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 500 | pass | 0 | 477 | 499.9 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 750 | pass | 0 | 595 | 749.8 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1000 | pass | 0 | 1110 | 999.7 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1250 | pass | 0 | 1246 | 1249.5 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1500 | pass | 0 | 1407 | 1499.4 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1750 | pass | 0 | 2169 | 1749.1 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2000 | pass | 0 | 1562 | 1998.8 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2250 | pass | 0 | 1825 | 2248.5 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2500 | pass | 0 | 2436 | 2498.2 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | **2750** | pass | 0 | 15 427 | 2745.9 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 | drops | 33 940 536 | full | 2932.0 | gaps (20) | 5.14 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3200 | drops | 186 192 196 | full | 2923.0 | gaps (20) | 1.98 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 250 | pass | 0 | 236 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 500 | pass | 0 | 682 | 499.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 750 | pass | 0 | 711 | 749.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 1581 | 999.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 962 | 1249.6 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1205 | 1499.4 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 1581 | 1749.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 2388 | 1998.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 4335 | 2248.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 2090 | 2498.3 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 | drops (clean in 3 repeats) | 54 968 | full | 2747.9 | gaps (1) | 0.18 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 7517 | 2997.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 3560 | 3197.1 | pass | - |

In every failing step the gaps sum exactly to the drop count in the file header.

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): every failing step has exactly one gap, at
  no fixed offset (30.86 and 17.36 GB single; 0.27 GB, right after the first ring, on RAID0).
  These are isolated write stalls, not a rate the drive cannot keep up with.
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): the single-drive failure at 3200 MB/s writes
  3036 MB/s, the drive on its Gen3 x4 link; no other step failed on either layout.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`, Gen4 x4): no step failed on either layout, up to the
  3.2 GB/s generator maximum.
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): the single-drive failures write ~2.93 GB/s, the
  drive on its Gen3 x4 link (a fixed rate deficit). The one RAID0 failure (2750 MB/s) is a single
  54 968-beat FIFO overflow 262 256 bytes after an 8 MiB buffer boundary, i.e. the DMA restart
  after that boundary took about 415 µs; the drives had one write in flight (see
  [Where the bottlenecks are](#5-latency-budgets-not-bandwidth)). No isolated ~0.65 s write
  stall as on `vck190_fmcp1` appeared in any recording on this board.

### Burst and 40 GB recordings

Single recordings at a fixed rate: 32 x 8 MB buffers, `rm` + `fstrim` + 30 s idle before each,
10 GB from 1000 MB/s upwards, then 40 GB at the sweep's rate and one step above. "Burst" rows
are 10 GB recordings; the 40 GB rows are still inside the SLC caches of these drives.

| target | SSD | layout | recording | rate (MB/s) | result | FIFO high-water (beats) |
|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 10 GB | 1000-3000 (9 steps) | pass, all | 628-2302 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 10 GB | **3200** | pass (highest burst = the generator maximum) | 2174 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 40 GB | **1000** | pass (in the cache) | 838 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 40 GB | 1250 | pass (in the cache) | 1053 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 851-2305 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 2933 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **2750** | pass (in the cache) | 2031 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | 3000 | pass (in the cache) | 2457 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 10 GB | 1000-3000 (9 steps) | pass, all | 10-86 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 10 GB | **3200** | pass (highest burst = the generator maximum) | 21 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 2 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 773-2300 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 2607 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 2 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 1000-2750 (8 steps) | pass, all | 974-2121 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | **3000** | pass (highest burst) | 2107 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 3200 | drops from 4.74 GB (above the drive's ~3.04 GB/s write rate on Gen3 x4) | full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | **3000** | pass (in the cache) | 2312 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | 3200 | drops from 5.07 GB | full |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 722-2114 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 2392 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3000** | pass (in the cache) | 4344 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 2747 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 1000-2500 (7 steps) | pass, all | 774-3953 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | **2750** | pass (highest burst) | 2129 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 3000 | drops from 7.18 GB (above the drive's ~2.93 GB/s write rate) | full |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | **2750** | pass (in the cache) | 2912 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | 3000 | drops from 7.26 GB | full |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 746-2819 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 2486 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3000** | pass (in the cache) | 2263 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 3744 |

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): no step failed. Both layouts record 10 GB at
  3.2 GB/s, the generator maximum, and the "one step above" 40 GB recordings passed too.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`): no step failed either; both layouts record 10 GB and
  40 GB at 3.2 GB/s, the generator maximum. The FIFO high-water marks of the single-drive bursts
  and of both 40 GB recordings (2-86 beats) are far lower than in every other recording of that
  session; this was not investigated (the drop counters and `fdverify` are what the table is
  judged by).
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): one drive bursts 10 and 40 GB at 2750 MB/s
  (3000 MB/s exceeds its ~2.93 GB/s write rate on Gen3 x4); RAID0 records 10 and 40 GB at the
  generator's 3200 MB/s (40 GB with a high-water mark of 3744 of 16384).
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): one drive bursts 10 and 40 GB at 3000 MB/s (3200 MB/s
  exceeds its ~3.04 GB/s write rate on Gen3 x4). RAID0 records 10 and 40 GB at the generator's
  3200 MB/s, and 32 GB at 2750, 3000 and 3200 MB/s in 9 of 9 further runs (high-water marks
  2187-4271).

### Long recordings past the SLC cache

For the 1 TB drives a 32 GB or 40 GB recording stays inside the SLC cache, so the rate that
holds for a long recording was measured with single recordings of about 1.5 to three times
the cache (fresh XFS, `rm` + `fstrim` and **300 s** of idle before each, 32 x 8 MB buffers). Sizes are the
`fdrec --size` values (GiB), with GB (10⁹ bytes) in brackets.

| target | SSD | layout | recording | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | first gap |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 143 GiB (153.5 GB, ~2x the cache) | **1000** | pass, `fdverify` PASS | 0 | 790 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 240 GiB (257.7 GB, ~1.8x the cache) | **2750** | pass, `fdverify` PASS | 0 | 3257 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | **2750** | pass, `fdverify` PASS | 0 | 7194 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3000** | pass, `fdverify` PASS | 0 | 6457 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3200** | pass, `fdverify` PASS | 0 | 11 812 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB (257.7 GB, ~2.1x the cache) | **1750** | pass, `fdverify` PASS | 0 | 1588 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB | 2000 | drops | 969 436 129 | full | 125.17 GB (the cache end) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB (515.4 GB, ~2x the cache) | 2250 | pass, `fdverify` PASS | 0 | 2329 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2500 | pass, `fdverify` PASS | 0 | 2604 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2750 | pass, `fdverify` PASS | 0 | 4193 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 3000 | pass, `fdverify` PASS | 0 | 7112 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | **3200** | pass, `fdverify` PASS | 0 | 8896 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB (214.7 GB, ~1.8x the cache) | 3000 | drops | 3 920 223 261 | full | 121.52 GB (the cache end) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | 3200 | drops (above the drive's write rate) | 4 920 282 959 | full | 0.88 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | 2000 | drops (past the cache, TLC ~1.77 GB/s) | 650 031 494 | full | 127.04 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 2292 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 221 GiB (237.3 GB, ~2x the cache) | **1750** | pass, `fdverify` PASS | 0 | 1896 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~1.5x the pair's cache) | **2750** | pass, `fdverify` PASS | 0 | 4359 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 3000 | drops | 29 165 (one event) | full | 16.53 GB (inside the cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **3000** (repeat) | pass, `fdverify` PASS | 0 | 4825 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 3200 | drops | 8085 (one event) | full | 257.16 GB (past the cache) |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB (214.7 GB, ~3x the cache) | 2750 | drops (above the drive's post-cache rate) | 4 350 513 076 | full | 10.39 GB (68 beats), then past the cache |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | 3000 | drops (above the drive's write rate) | 5 344 583 747 | full | 0.49 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | 2000 | drops (past the cache, TLC ~1.8 GB/s) | 785 285 387 | full | 95.95 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 2567 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | 2500 | drops | 40 425 (one event) | full | 323.92 GB (past the cache) |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | 2750 | drops | 20 256 (one event) | full | 354.75 GB (past the cache) |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3000** | pass, `fdverify` PASS | 0 | 16 363 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3200** | pass, `fdverify` PASS | 0 | 9323 | - |

* **Sabrent Rocket 2230 1TB on `vck190_fmcp1`**: the sweep's rates hold past the cache. The post-cache write
  rate (~1.8 GB/s per drive, ~3.6 GB/s for the pair, see [The SLC cache](#the-slc-cache)) is
  far above them; what limits the single drive is the rare ~0.65 s write stall. The RAID0 pair
  recorded 350 GiB at 2750, 3000 and 3200 MB/s (the generator maximum) with 0 drops, one run
  each, with 0-1 writes in flight in every 10 s sample (at most 8 of 32 buffers). The high-water
  marks of those runs (6457-11 812 of 16384) were each set by one DMA restart at a buffer boundary
  of 34-59 µs; all other boundaries stayed at 2100-3000 beats (see
  [Where the bottlenecks are](#5-latency-budgets-not-bandwidth)).
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, single**: 1750 MB/s holds over 200 GiB and 221 GiB;
  2000 MB/s drops from 127 GB, just past the cache (the drive then writes ~1.78-1.80 GB/s), and
  3000 MB/s from 121.5 GB, where the cache ends. Up to the cache end one or two writes were in
  flight, after it four to eight: the margin at 1750 MB/s is about 1 % (the post-cache rate is
  1768 MB/s, median).
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, RAID0**: 2750 MB/s holds over 350 GiB (high-water
  mark 4359 of 16384); 3000 MB/s held in one run of two (4825) and lost 29 165 beats in the
  other, and 3200 MB/s lost 8085 beats, in each case at a single 8 MiB buffer boundary where the
  AXI DMA restart took about 240 µs and 120 µs (the gap starts 262 256 bytes = 16384 + 7 beats
  after the boundary: the FIFO filled before the DMA took any of the next buffer). The other
  boundaries of those runs stayed below 46 µs (high-water marks 7155-9164). Writes in flight
  never exceeded 8 of 32 buffers, inside or past the cache: the limit is the host's restart
  latency on the Cortex-A53, not the SSDs (see
  [Where the bottlenecks are](#5-latency-budgets-not-bandwidth)).
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, single**: 1750 MB/s holds over 240 GiB. Inside the
  cache 0-1 writes were in flight, after it 1-5: the drive's post-cache rate (~1.77 GB/s) is only
  ~1 % above the recording rate. At 2000 MB/s the recording is clean until the cache ends
  (125.17 GB) and then drops 15.5 GB of data.
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, RAID0**: the pair writes ~3.47 GB/s after its cache. It
  recorded 480 GiB at 2250, 2500, 2750, 3000 and 3200 MB/s (the generator maximum) with 0 drops,
  one run each, with 0-1 writes in flight in most 10 s samples (at most 8 of 32 buffers). The
  high-water marks at 2750-3200 MB/s (4193-8896 of 16384) were each set by one DMA restart at a
  buffer boundary of 24-44 µs (at 137-256 GB, inside or at the end of the cache); all other
  boundaries stayed below 3600 beats (see
  [Where the bottlenecks are](#5-latency-budgets-not-bandwidth)).
* **Sabrent Rocket 2230 1TB on `zcu106_hpc0`**: the ~72 GB cache shows; one drive held
  1750 MB/s over 200 GiB (2000 MB/s drops from 95.95 GB, just past the cache: the post-cache
  rate is ~1.8 GB/s, as on `vck190_fmcp1`). The RAID0 pair recorded 3000 and 3200 MB/s cleanly
  over 350 GiB (one run each; the 3000 MB/s run came within 21 beats of the 16384-beat FIFO).
  At 2500 and 2750 MB/s one run each lost 40 425 and 20 256 beats in a single late DMA restart
  (about 364 and 213 µs) at a buffer boundary past the cache, with the drives keeping up (0-3
  writes in flight in every 10 s sample).

### Playback

Design 1.1 (AXI DMA MM2S, 4096-beat egress FIFO, `fdrec_check` sink), XFS, `fdplay` with
queue depth 8. Each run plays a 10 GB test-pattern recording made at 1000 MB/s with 0 drops.
"Runs" lists underflow-free runs / runs at that rate.

| target | SSD | layout | buffers | highest clean playback rate | runs | first rate with underflows | read fio reference |
|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each | none (no higher rate exists) | 4259 and 4465 MB/s; 4529 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB | **3200 MB/s** (the sink maximum) | 2/2 at every step from 1000 MB/s (2026-10-20); 2 of 3 at 3200 on 2026-10-17 (3414 ticks once) | none (no higher rate exists) | 4125 and 4258 MB/s; 7792 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 16 x 8 MB | **3000 MB/s** | 3/3 | 3200 (2865 ticks in the sweep; the recheck was clean) | as above |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean; 3 of 3 at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s with each buffer count) | none (no higher rate exists) | 4766 and 4950 MB/s; 6309 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean; 3 of 3 at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s with each buffer count) | none (no higher rate exists) | 4751 and 4966 MB/s; 7781 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean) | none (no higher rate exists) | 2958 and 2972 MB/s (fio CPU-bound); 5955 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean) | none (no higher rate exists) | 2870 and 2889 MB/s (fio CPU-bound); 3183 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **3000 MB/s** | 3/3 each (every sweep step from 1000 MB/s clean) | 3200 MB/s (3 325 445 and 3 206 566 ticks with 32 buffers, 11 477 155 and 9 887 586 with 16, sweep and recheck: above the slot's ~3.12 GB/s read rate on Gen3 x4) | 2923 and 2964 MB/s (fio CPU-bound); 3124 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean) | none (no higher rate exists) | 2823 and 2838 MB/s (fio CPU-bound); 5125 MB/s with hugepage fixed buffers |

The `vck190_fmcp1` rows were measured 2026-10-17 (Sabrent; the RAID0 confirmation 2026-10-20)
and 2026-10-20 (980 PRO), the `zcu106_hpc0` rows 2026-10-20 (Sabrent and 980 PRO),
all with 10 GB playbacks.

With the Sabrent Rocket 2230 1TB pair (Gen4 x4) one drive alone plays back at the 3.2 GB/s
sink maximum every time, and so does RAID0 (20 of 20 runs from 1000 to 3200 MB/s on 2026-10-20,
single and RAID0; one read stall of a few ms in the 2026-10-17 sweep at 3200 MB/s). fio without
fixed buffers is CPU-bound at ~4.1-4.5 GB/s on this board; with hugepage fixed buffers it reads
the RAID0 at 7792 MB/s.

The Samsung 980 PRO 1TB pair (Gen4 x4 on `vck190_fmcp1`) plays back at the 3.2 GB/s sink maximum
from one drive and from RAID0, with 32 or 16 buffers: 80 of 80 runs from 1000 to 3200 MB/s were
clean on 2026-10-20 (every sweep step, then 3 of 3 runs at 2500, 2750 and 3000 MB/s and 5 of 5
at 3200 MB/s in each configuration). fio reads one drive at 6309 MB/s and the pair at 7781 MB/s
with hugepage fixed buffers.

On `zcu106_hpc0` the 980 PRO 1TB, single or in RAID0, plays back at the 3.2 GB/s sink maximum
with 32 or 16 buffers: 52 of 52 runs from 1000 to 3200 MB/s were clean (fio reads the same file
at 2870-2889 MB/s, CPU-bound, and at 3183 MB/s with hugepage fixed buffers). Isolated short read
stalls remain possible: of 17 further single-drive runs at 2500-3200 MB/s, two showed 2553 and
14 302 underflow ticks (both at 3000 MB/s; six repeats at 3000 MB/s were clean).

The Sabrent Rocket 2230 1TB on `zcu106_hpc0` plays back at 3000 MB/s from one drive (3200 MB/s
is above what one Gen3 x4 slot reads, ~3.12 GB/s even with fixed buffers, so it underflows
every time) and at the 3.2 GB/s sink maximum from RAID0, with 32 or 16 buffers: all 52 runs at
or below those rates were clean. fio without fixed buffers is CPU-bound on this board
(2.8-3.0 GB/s, one A53 core at 92-98 %); with hugepage fixed buffers it reads one drive at
3124 MB/s and the pair at 5125 MB/s.

Read fio reference: `fio --name=rd --filename=<the recording> --readonly --rw=read --bs=8M
--direct=1 --ioengine=io_uring --iodepth=8 --size=10G` on the same filesystem; "hugepage fixed
buffers" adds `--iomem=mmaphuge --fixedbufs`, which is how `fdplay` reads (hugepage buffers
registered with io_uring).

Functional checks of `fdplay` (design 1.1, 10 GB test-pattern recordings unless stated):

| measurement | result |
|---|---|
| 10 GB clean recording, `--rate 1000MB` | 10.78 s, beats 671 088 640, errors 0, gaps 0, gap beats 0, underflows 0, last seq 671 088 639, egr_discard 0 |
| 10 GB recording made at 3000 MB/s (drop count 361 884 621, 1216 discontinuities in `fdverify`), `--rate 500MB` | 21.52 s, beats 671 088 640, errors 0, gaps 1216, gap beats 361 884 621, underflows 0 |
| `--rate` above the SSDs' read rate | underflow ticks counted by the checker; exit code 2 |
| 256 MB recording resident in the ring (32 x 8 MB, 64 x 4 MB), `--rate 3200MB` | 0 underflows over 31 and 63 buffer boundaries at the full sink rate (the egress FIFO covers the MM2S restart gap at 3.2 GB/s: < 20 µs) |
| Ctrl-C (SIGINT) after 4 s at 1000 MB/s | exit code 1, 4.0 GB played, egr_discard 809 668-1 042 442 beats (the flushed in-flight buffers), no `Cannot stop channel`; the next playback is complete with 0 underflows |
| Checker prime wait (driver, at most 100 ms) | never timed out (no `did not prime` message in any playback of the session, about 50) |

### CPU load

Measured per core from `/proc/stat` over 10 GB transfers at 1000 MB/s (two runs each,
32 x 8 MB buffers), and per process. On `vck190_fmcp1` (two Cortex-A72 cores):

| transfer | per core (busy) | transfer process |
|---|---|---|
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | run 1: core 0 11.4 %, core 1 8.2 %; run 2: core 0 6.8 %, core 1 10.9 % | `fdrec` 16.1–16.3 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent) | core 0 8.8–9.1 %, core 1 9.1–9.5 % | `fdrec` 16.6 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | runs on one core (12.1 / 13.8 %; the other 2.4 / 0.8 %) | `fdplay` 12.4 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent) | run 1: core 0 10.1 %, core 1 3.4 %; run 2: core 0 6.2 %, core 1 7.6 % | `fdplay` 11.9 % of one core |
| `fdrec`, 1000 MB/s to the Samsung 980 PRO 1TB | run 1: core 0 5.9 %, core 1 10.8 %; run 2: core 0 8.2 %, core 1 8.6 % | `fdrec` 15.5 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | core 0 8.7–9.3 %, core 1 8.5–8.7 % | `fdrec` 16.2–16.3 % of one core |
| `fdplay`, 1000 MB/s from the Samsung 980 PRO 1TB | runs on one core (11.4 / 12.9 %; the other 1.8 / 0.7 %) | `fdplay` 11.8 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | runs on one core (10.8 / 12.9 %; the other 3.0 / 1.2 %) | `fdplay` 12.4 % of one core |

Nearly all of it is system time; the core the app runs on shows 62–86 % I/O wait (waiting, not
busy) with the Sabrent drives (2026-10-17, where a `top` cross-check gave the same per-process
figures: `fdrec` 14.1–16.6 %, `fdplay` 10.8–13.5 % of one core) and 68–87 % with the 980 PROs
(2026-10-18; `top`: `fdrec` 13.4–16.2 %, `fdplay` 10.7–13.3 % of one core). The recorder's CPU
follows the rate, not the SSD: the Sabrent and 980 PRO rows cost about the same.

On `zcu106_hpc0` (four Cortex-A53 cores at 1.2 GHz), same method (10 GB at 1000 MB/s, two runs,
32 x 8 MB buffers), the load spreads over two cores at most (the app's thread and the core
taking the DMA / NVMe interrupts):

| transfer | busy, summed over the cores | share of the 4-core total | transfer process |
|---|---|---|---|
| `fdrec`, 1000 MB/s to the 980 PRO 1TB | 25.4–25.5 % of one core | about 6.5 % | `fdrec` 23.5–23.6 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | 26.6–26.8 % of one core | about 6.5 % | `fdrec` 24.9–25 % of one core |
| `fdplay`, 1000 MB/s from the 980 PRO 1TB | 19.4–19.6 % of one core | about 5 % | `fdplay` 16.4–16.6 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | 22.4–24.4 % of one core | about 6 % | `fdplay` 19.9–22 % of one core |
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | 27 % of one core | about 7 % | `fdrec` 24.5 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent Rocket 2230 1TB) | 28–29 % of one core | about 7 % | `fdrec` 25.6–25.7 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | 21.5–22 % of one core | about 5.5 % | `fdplay` 19 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent Rocket 2230 1TB) | 22–23 % of one core | about 5.5 % | `fdplay` 18.6–18.8 % of one core |

Both pairs were measured on 2026-10-19. The 980 PRO rows were cross-checked with `top`
(`fdrec` 23.9–24.6 %, `fdplay` 16–23 % of one core); during `fdplay` the I/O wait sits on one
or two cores (50–76 % on the busiest). For the Sabrent rows `top` gives `fdrec` 22–25 % and
`fdplay` 17.6–18.6 % of one core. At higher rates `fdrec` uses 67–68 % of one core at
3000 MB/s (one 980 PRO), 73–74 % at 3000 MB/s (980 PRO RAID0) and ~78 % at 3200 MB/s (Sabrent
RAID0), and `fdplay` 41 % at 2250 MB/s (one Sabrent) and 42 % at 2500 MB/s (one 980 PRO); see
[Results: zcu106_hpc0](#results-zcu106_hpc0).

There is one DMA interrupt per 8 MB buffer in both directions. The
[comparison with the dd method](#comparison-with-fpga-drive-aximm-pcie-dd-method) below
measures CPU time differently (over the whole transfer, from the process's own accounting),
so its per-process figures are not directly comparable with these.

## The SLC cache

Most consumer SSDs write into a fast pseudo-SLC cache first and move the data to their TLC
flash later. While the cache lasts, the SSD writes at its datasheet rate; once it is full,
the write rate drops. For a recorder, which writes at a constant rate for as long as the
recording lasts, the rate after the cache is the one that counts.

* The **Sabrent Rocket 2230 1TB** (DRAM-less, Gen4) writes ~4.5 GB/s for about the first
  75 GB on an empty, trimmed drive, then a flat ~1.8 GB/s (1779-1821 MB/s from 80 to 320 GB).
  On `vck190_fmcp1` its sustained recording rate is set not by the cache but by rare ~0.65 s
  write stalls (1000 MB/s clean over 143 GiB, see
  [Long recordings](#long-recordings-past-the-slc-cache)). On `zcu106_hpc0` the same cache
  shows: ~72 GB at ~2.9 GB/s (the Gen3 x4 link's rate), then a flat ~1.8 GB/s (median
  1798 MB/s), the same post-cache rate as on `vck190_fmcp1`; there it sets the sustained
  single-drive rate (1750 MB/s over 200 GiB).
* The **Samsung 980 PRO 1TB** caches about 115-120 GB on an empty, trimmed drive (the same on
  both boards). It writes into the cache at ~4.7 GB/s on `vck190_fmcp1` (Gen4 x4; the fio limit
  of that host) and ~2.98 GB/s on `zcu106_hpc0` (the Gen3 x4 link), and a flat **~1.77 GB/s**
  after it on both boards (the pair: ~3.47 GB/s after ~235-250 GB on `vck190_fmcp1`; on
  `zcu106_hpc0` one fio job writes only ~3.4 GB/s to the pair, so only a 5 % knee shows, at
  ~247 GB). One drive records 1750 MB/s cleanly past the cache on both boards, 2000 MB/s only
  until the cache ends. This is the drive's TurboWrite cliff.
* Smaller drives show the same mechanism at a smaller scale. The **Samsung 970 EVO 250GB**
  writes at up to ~1.5 GB/s while its cache lasts (about 13-14 GB on an empty, trimmed drive)
  and at ~330 MB/s after that (Samsung rates it at 300 MB/s after the TurboWrite cache), so any
  recording above its post-cache rate drops at ~14 GB, whatever the rate. The **Samsung 950 PRO
  256GB** shows no comparable cliff: ~955 MB/s throughout. In RAID0 the slower member sets the
  pace: a 970 EVO + 950 PRO array drops at ~28-29 GB, when the 970 EVO's half of the stripe
  (~14.5 GB) exhausts its cache.

Measured with one sequential fio write (queue depth 8, 8 MB blocks, `O_DIRECT`) on a freshly
created XFS, 60 s of idle first, bandwidth logged every 2 s:

| SSD | target | layout | written | rate inside the cache | cache size (empty, trimmed) | rate after the cache |
|---|---|---|---|---|---|---|
| Sabrent Rocket 2230 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.5-4.6 GB/s | **~75 GB** | **~1.8 GB/s**, flat |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.45 GB/s (fio CPU-bound) | **~140 GB** (~70 GB per drive) | **~3.6 GB/s**, flat |
| Samsung 980 PRO 1TB | `zcu106_hpc0` | single | 300 GiB | 2965-2986 MB/s (the Gen3 x4 link) | **~115-120 GB** (full rate to ~113 GB, flat from 127 GB) | **~1.77 GB/s**, flat (1717-1823 MB/s, median 1768) |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3360-3469 MB/s (fio CPU-bound) | **~247 GB** (a 5 % knee) | ~3.26 GB/s (3170-3288 MB/s; partly fio-bound) |
| Samsung 980 PRO 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.7 GB/s (fio CPU-bound: a lower bound for the drive) | **~115-120 GB** (full rate to 113.5 GB, flat from 129 GB) | **~1.77 GB/s**, flat (1729-1798 MB/s) |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.7 GB/s (fio CPU-bound) | **~235-250 GB** (~118 GB per drive) | **~3.47 GB/s**, flat (3407-3504 MB/s) |
| Sabrent Rocket 2230 1TB | `zcu106_hpc0` | single | 300 GiB | 2844-2905 MB/s (the Gen3 x4 link) | **~70-73 GB** | **~1.8 GB/s**, flat (1777-1822 MB/s, median 1798) |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3133-3363 MB/s (fio CPU-bound) | not visible (flat over 537 GB: the pair's ~3.6 GB/s post-cache rate is above what one fio job writes) | same: ~3230 MB/s |

The cache sizes and post-cache rates are the drives', the same on both boards; their in-cache
rates on `zcu106_hpc0` are the Gen3 x4 link's (~2.9 GB/s Sabrent, ~2.98 GB/s 980 PRO), and the
980 PRO's on `vck190_fmcp1` is fio's (~4.7 GB/s). None of the drives throttled (fan on the
cards).

**In-cache and post-cache rates.** A recording shorter than the cache only needs the
in-cache rate; a longer one needs the post-cache rate, and the 32 GB sweep shows only the
first for the 1 TB drives. The cache refills only while the drive is idle (how fast was not
measured), so back-to-back recordings may not each get a full cache. Size the rate for the
longest recording you need: a short burst test, such as a 10 GB recording, a 4 GB `dd`, or
fio over 32 GB (entirely inside the cache of these 1 TB drives), overstates what a drive
sustains.

## The fstrim finding and the ring size

During the first RAID0 measurements, a 1700 MB/s recording with the 16 x 8 MB ring had one
gap of about 84 MB right after the first 128 MB of the file. The cause turned out to be
`fstrim` run **immediately** before the recording: the SSDs were still processing the
discards, and no write completed for more than 100 ms. The 128 MB ring lasts 75 ms at
1.7 GB/s, so it ran dry and the FIFO overflowed. Waiting 3 s or more after `fstrim`, not
trimming, or a larger ring (24 x 8 MB, 32 x 8 MB or 16 x 16 MB) each removed the gap. This is
why `fdrec` now defaults to 32 x 8 MB buffers (256 MB), and why the benchmark steps wait after
trimming.

The finding was made with two Gen3 drives (Samsung 970 EVO 250GB + 950 PRO 256GB, RAID0,
512K chunk) on a Zynq UltraScale+ board, 10 GB recordings at 1700 MB/s, `fdrec --stats 0.1`.
"Trim" is `rm` of the previous file, `sync` and `fstrim /mnt/rec`; "idle" is the pause between
that and `fdrec`. The CPU frequency was fixed (all cores at 1.1 GHz), so a frequency ramp is not
a factor. Summary of the 20 recordings:

| filesystem | before the run | buffers | recordings with drops |
|---|---|---|---|
| XFS | trim, idle 3 s or 15 s | 16 x 8 MB | 0 of 5 |
| XFS | no trim (`rm` + `sync` only), or an existing 10 GB file at the same path (see note) | 16 x 8 MB | 0 of 2 |
| XFS | trim, idle 15 s | 24 x 8 MB, 32 x 8 MB, 16 x 16 MB | 0 of 3 |
| XFS | trim, no idle | 16 x 8 MB | **3 of 3** (two with the first gap at exactly 128 MB of the file, 4.9-5.5 M beats; one at 3.43 GB) |
| XFS | trim, no idle | 24 x 8 MB, 32 x 8 MB, 16 x 16 MB | 0 of 3 |
| ext4 | trim, idle 15 s, or no idle | 16 x 8 MB | 0 of 4 |

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
  resets the core on close); read them from `fdrec`'s `RESULT` line.

## Comparison with fpga-drive-aximm-pcie (dd method)

The [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
reference design measures SSD throughput with four `dd` scripts, which are also in this
design's image (see [Test the design in Linux](linux_test.md#4-measure-the-ssds-with-the-dd-speed-test-scripts)).
This section compares the two methods on the same board, SSDs and image.

### At a glance

All figures in MB/s (10⁶ bytes/s), measured 2026-10-17 to 2026-10-20 (see [Setups](#setups)).
**b** = burst (the write fits inside the drive's SLC write cache), **s** = sustained (the
recording ran past the cache). Reads have no cache effect. The 32 GB columns are inside the
cache of these drives (**b**), so the "fdrec sustained" cell also gives the rate that held over
a recording past the cache.

| target / config | WRITE: drive ceiling (fio QD8, 4 GB) | WRITE: dd script (4 GB) | WRITE: fdrec highest clean (4 GB) | WRITE: dd (32 GB) | WRITE: fdrec sustained (32 GB) | READ: drive ceiling (fio QD8, 4 GB) | READ: dd script (4 GB) | READ: fdplay highest clean (4 GB) |
|---|---|---|---|---|---|---|---|---|
| vck190: Sabrent Rocket 2230 1TB (Gen4 x4) | 4186 **b** (fio CPU-bound) | 1906 **b** | 3000 **b** (top step) | 1931 **b** (inside the ~75 GB cache) | 1000 **b**; past the cache (143 GiB): **1000 s** | 4186 (fio CPU-bound) | 3647 | 3000 (top step) |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 4352 **b** (fio CPU-bound) | 1711 **b** | 3000 **b** (top step; 16 buffers: 2000) | 2132 **b** (one run) | 2750 **b**; past the cache (240 GiB): **2750 s** | 3958 (fio CPU-bound) | 2689 | 1000 in the first sweep; 3000 (top step) in a repeat, 2 of 3 runs |
| vck190: Samsung 980 PRO 1TB (Gen4 x4) | 4694 **b** (fio CPU-bound) | 2006 **b** | 3000 **b** (top step) | 2073 **b** (inside the ~115 GB cache) | 3200 **b**; past the cache (240 GiB): **1750 s** | 4352 (fio CPU-bound; 6309 with fixed buffers, 10 GB) | 3678 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 4623 **b** (fio CPU-bound) | 2173 **b** | 3000 **b** (top step; 16 buffers: 3000) | 2117 **b** (one run) | 3200 **b**; past the cache (480 GiB): **3200 s** | 4356 (fio CPU-bound; 7781 with fixed buffers, 10 GB) | 3920 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| zcu106: Samsung 980 PRO 1TB (Gen3 x4) | 2956 **b** | 1398 **b** | 3000 **b** (top step; 16 buffers: 3000) | 1491 **b** (inside the ~115 GB cache) | 3000 **b**; past the cache (200 GiB): **1750 s** | 2854 (fio CPU-bound; 3183 with fixed buffers, 10 GB) | 2026 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 3401 **b** (fio CPU-bound) | 1755 **b** | 3000 **b** (top step; 16 buffers: 3000) | 1749 **b** (one run) | 3200 **b**; past the cache (350 GiB): **2750 s** (3000 clean 1 of 2, 3200 dropped once) | 2824 (fio CPU-bound; 5955 with fixed buffers, 10 GB) | 2397 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| zcu106: Sabrent Rocket 2230 1TB (Gen3 x4) | 2827 **b** | 1398 **b** | 3000 **b** (top step; 16 buffers: 2500) | 1307 **b** (inside the ~72 GB cache) | 2750 **b**; past the cache (200 GiB): **1750 s** | 2879 (fio CPU-bound; 3124 with fixed buffers, 10 GB) | 2208 | 3000 (top step; 16 buffers: 3000; 10 GB: 3000, 3200 exceeds the slot's ~3.12 GB/s read rate) |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 3229 **b** (fio CPU-bound) | 1536 **b** | 3000 **b** (top step; 16 buffers: 1750) | 1527 **b** (one run) | 3200 **b**; past the cache (350 GiB): **3000 and 3200 s** (one run each; 2500 and 2750 dropped once each) | 2653 (fio CPU-bound; 5125 with fixed buffers, 10 GB) | 2208 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |

| target / config | dd write: rate / % of one core / MB/s per % core | fdrec: rate / % of one core / MB/s per % core |
|---|---|---|
| vck190 (Cortex-A72, 1.4 GHz): Sabrent Rocket 2230 1TB | 1906 / 77 % / 25 | 2984 / 37 % / 81 |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 1711 / 69 % / 25 | 2984 / 51 % / 59 |
| vck190: Samsung 980 PRO 1TB | 2006 / 79 % / 25 | 2983 / 46 % / 64 |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 2173 / 88 % / 25 | 2985 / 48 % / 62 |
| zcu106 (Cortex-A53, 1.2 GHz): Samsung 980 PRO 1TB | 1398 / 74 % / 19 | 2980 / 68 % / 44 |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 1755 / 90 % / 20 | 2982 / 73 % / 41 |
| zcu106: Sabrent Rocket 2230 1TB | 1398 / 67 % / 21 | 2878 / 71 % / 41 |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 1536 / 80 % / 19 | 2981 / 75 % / 40 |

Selection rule: dd and fio cells are the median of three runs at their own speed (one run where
marked); `fdrec` / `fdplay` cells are the highest 250 MB/s step that was clean over 4000 MiB (0
drops / 0 underflows) and, in the CPU table, the rate it achieved; "fdrec sustained" is the
highest clean step of the 32 GB [fdbench.sh sweep](#sustained-recording-rate). The recorder rows
used the shipped default of 32 x 8 MB buffers (the 16-buffer result is given where it differs).
The `fdrec` and `fdplay` sweeps stop at 3000 MB/s, the last 250 MB/s step below the 3.2 GB/s
generator and sink maximum. On `zcu106_hpc0` the 16-buffer `fdrec` cells of the Sabrent drives
(2500 single, 1750 RAID0) are decided by single drive write stalls longer than the 128 MB ring;
the 32 GB and 10-40 GB recordings are the better guide there.

How to read it: the "drive ceiling" columns show what the SSD itself delivered under Linux with
8 requests in flight. The dd and burst columns are short transfers that a consumer drive absorbs
in its write cache; the bold **s** figure in the sustained column is what you can record for as
long as you like (the figure past the cache). The recorder figures are the strictest of all,
because one late write anywhere in the recording makes a rate fail, and they cost half the CPU
of `dd` or less for writes. The detailed tables ([vck190_fmcp1](#results-vck190_fmcp1),
[zcu106_hpc0](#results-zcu106_hpc0)) and [why the figures differ](#why-the-figures-differ)
follow, and [Where the bottlenecks are](#where-the-bottlenecks-are) explains what limits each
figure.

**Gen4 drives on a Gen4 and a Gen3 target.** The Sabrent Rocket 2230 1TB on `vck190_fmcp1`
writes faster than the recorder can feed it: fio writes 4.2-4.5 GB/s (fio itself CPU-bound),
`fdrec` is clean at the 3000 MB/s top step over 4 GB on one drive, and 10 GB recordings pass at
the 3.2 GB/s generator maximum. Here the generator, not the SSD, sets the burst rate, and a
single `dd` write is CPU-bound on one A72 core (1906 MB/s, 77 % of a core). The 980 PRO on
`vck190_fmcp1` (Gen4 x4) behaves the same way: fio is CPU-bound at ~4.4-4.8 GB/s, every 32 GB
sweep step is clean up to the 3.2 GB/s generator maximum, and the drive's post-cache rate (~1.77
GB/s) is visible. On `zcu106_hpc0` (Gen4 drives on Gen3 Root Ports) both run at their Gen3 x4
link's rate inside the cache: the Sabrent writes 2827-2890 MB/s per slot (fio 4 GB) and reads
2936-3153 MB/s (raw device), the 980 PRO writes 2956-2962 MB/s and reads 2934-3185 MB/s. One
drive records 32 GB at 2750 MB/s (Sabrent) or 3000 MB/s (980 PRO), RAID0 at 3200 MB/s with
either pair, and both drives show the
same cache and post-cache rate as on the VCK190 (Sabrent ~72 GB and ~1.8 GB/s, 980 PRO ~115-120
GB and ~1.77 GB/s).

### Method

Measured on `vck190_fmcp1` (Sabrent pair 2026-10-17, 980 PRO pair 2026-10-18, its `fdrec` / `fdplay` rows 2026-10-20) and on
`zcu106_hpc0` (Sabrent pair 2026-10-19 and 2026-10-20, 980 PRO pair 2026-10-19 and 2026-10-20), with the images of [Setups](#setups) (register map 1.1).
For each pair the second drive alone got only a fio 4 GB check. XFS on a freshly created
filesystem with 30 s of idle time per configuration and 20 s between runs, RAID0 = both drives
with 512 KB chunks. Figures are medians of 3 runs, with [min–max], unless noted.

* **dd** (`single_write_test.sh`, `single_read_test.sh`, `dual_*_test.sh`, run verbatim):
  one `dd` process moves 1000 blocks of 4 MiB with `O_DIRECT` between a file on the SSD
  filesystem and `/dev/zero`, one block at a time (queue depth 1). The dual scripts run one
  `dd` per SSD in parallel, each on its own filesystem, and report the aggregate.
* **fdrec / fdplay**: recordings and playbacks of the same 4000 MiB at fixed rates in
  250 MB/s steps, queue depth 8, with the shipped default of 32 x 8 MB buffers, plus 16-buffer
  runs. The table gives the highest rate that was clean
  (`fdrec`: 0 drops and `fdverify` PASS; `fdplay`: 0 underflows) and the rate it achieved.
* **Units.** The scripts print "MBytes/s" but move 4000 MiB, so their figure is in MiB/s.
  All figures here are MB/s (10⁶ bytes/s), like `fdrec` and `fdplay`: script figure × 1.0486.
* **CPU** is measured the same way for every row, over the whole transfer: the total CPU from
  `/proc/stat` deltas (share of all the target's cores, four on the ZCU106, two on the VCK190:
  user / system / IRQ + softirq / I/O wait),
  and the transfer process's (user + system) / real time from `time -p`, as a share of one
  core. The per-process figure is the stable one. "MB/s per % core" is the rate divided by
  the per-process figure. (The figures in the [CPU load](#cpu-load) section above were taken
  differently, per core over 10 GB transfers at 1000 MB/s, and are not directly comparable with
  these.)

### Results: vck190_fmcp1

VCK190 (XCVC1902, two Cortex-A72 cores at 1.4 GHz, 8 GB DDR4), `vck190_fmcp1` image. The
Sabrent Rocket 2230 1TB rows (two drives on the M.2 M-key Stack FMC, measured 2026-10-17) and
the Samsung 980 PRO 1TB rows (the same two drives as on `zcu106_hpc0`, on the FPGA Drive FMC
Gen4, measured 2026-10-18, the `fdrec` / `fdplay` rows 2026-10-20) linked at **Gen4 x4** (16 GT/s, `LnkSta` of Root Port and SSD).
"Sabrent" is one Sabrent Rocket 2230 1TB, "980 PRO" one Samsung 980 PRO 1TB. Same method as
above, with 60 s of idle time after each `mkfs`. `fdrec` / `fdplay` used the shipped default of
**32 x 8 MB buffers**; 16-buffer runs were added for comparison. The board has **two** cores,
so the total CPU column is a share of two cores (50 % = one full core); the per-process column
(% of one core) and MB/s per % core are directly comparable with `zcu106_hpc0`.

| method | config | direction | size | MB/s | total CPU % of 2 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | Sabrent | write | 4000 MiB | 1906 [1815–2076] | 0.4 / 36.1 / 3.7 / 8.1 | 77 [71–87] | 25 |
| dd (script) | Sabrent | read | 4000 MiB | 3647 [3584–3678] | 0.5 / 33.3 / 0.0 / 6.8 | 74 [63–84] | 49 |
| dd (script) | Sabrent RAID0 | write | 4000 MiB | 1711 [1705–1726] | 0.2 / 33.1 / 0.0 / 14.5 | 69 [62–72] | 25 |
| dd (script) | Sabrent RAID0 | read | 4000 MiB | 2689 [2396–2705] | 0.3 / 18.7 / 11.0 / 18.6 | 56 [51–58] | 48 |
| dd (dual script) | both Sabrent drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 3452 [3289–3554] | 0.4 / 73.4 / 2.4 / 19.2 | 144 [139–160] | 24 |
| dd (dual script) | both Sabrent drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 5706 [5630–6403] | 0.8 / 53.6 / 7.2 / 24.3 | 103 [101–124] | 55 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | Sabrent | record | 4000 MiB | 2984 | 0.2 / 19.5 / 0.2 / 33.7 | 37 [37–37] | 81 |
| `fdrec` at 1000 (32 buffers) | Sabrent | record | 32 GB | 1000 | 0.1 / 8.0 / 0.2 / 44.7 | 15 | 65 |
| `fdrec` at 3000 (16 buffers; clean 2 of 3) | Sabrent | record | 4000 MiB | 2984 | sys 25.3 | 47 | 63 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | Sabrent RAID0 | record | 4000 MiB | 2984 | 0.3 / 26.2 / 0.3 / 28.2 | 51 [50–51] | 59 |
| `fdrec` at 2750 (32 buffers) | Sabrent RAID0 | record | 32 GB | 2748 | 0.2 / 21.3 / 0.3 / 29.1 | 41 | 67 |
| `fdrec` at 2000, highest clean (16 buffers) | Sabrent RAID0 | record | 4000 MiB | 1993 | sys 14.1 | 27 | 74 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | Sabrent | play | 4000 MiB | 2874 | 0.5 / 14.9 / 0.0 / 31.6 | 28 | 103 |
| `fdplay` at 3000, top step (16 buffers) | Sabrent RAID0 | play | 4000 MiB | 2903 | 0.0 / 17.7 / 0.0 / 25.4 | 33 | 88 |
| dd (script) | 980 PRO | write | 4000 MiB | 2006 [1906–2087] | 0.2 / 38.5 / 0.0 / 8.3 | 79 [70–82] | 25 |
| dd (script) | 980 PRO | read | 4000 MiB | 3678 [3084–3920] | 0.4 / 25.8 / 6.1 / 8.4 | 73 [51–73] | 50 |
| dd (script) | 980 PRO RAID0 | write | 4000 MiB | 2173 [2139–2207] | 0.3 / 42.4 / 2.6 / 3.9 | 88 [87–88] | 25 |
| dd (script) | 980 PRO RAID0 | read | 4000 MiB | 3920 [3711–4033] | 0.5 / 25.3 / 13.7 / 6.4 | 77 [72–81] | 51 |
| dd (dual script) | both 980 PRO drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 3316 [2843–3410] | 0.4 / 68.9 / 1.9 / 25.9 | 137 [101–140] | 24 |
| dd (dual script) | both 980 PRO drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 5377 [4033–5519] | 0.4 / 44.4 / 4.8 / 41.7 | 87 [68–91] | 62 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | 980 PRO | record | 4000 MiB | 2983 | 0.3 / 23.6 / 0.3 / 30.2 | 46 [46–47] | 64 |
| `fdrec` at 3200 (32 buffers) | 980 PRO | record | 32 GB | 3198 | 0.2 / 24.8 / 0.1 / 28.8 | 48 | 67 |
| `fdrec` at 3000, top step (16 buffers) | 980 PRO | record | 4000 MiB | 2983 | sys 23.4 | 45 | 66 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | 980 PRO RAID0 | record | 4000 MiB | 2985 | 0.3 / 24.9 / 0.3 / 24.5 | 48 [48–49] | 62 |
| `fdrec` at 3200 (32 buffers) | 980 PRO RAID0 | record | 32 GB | 3198 | 0.3 / 24.0 / 0.2 / 28.3 | 46 | 70 |
| `fdrec` at 3000, top step (16 buffers) | 980 PRO RAID0 | record | 4000 MiB | 2985 | sys 24.2 | 47 | 64 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | 980 PRO | play | 4000 MiB | 2907 | 0.0 / 13.8 / 0.0 / 21.2 | 27 [26–27] | 110 |
| `fdplay` at 3000, top step (16 buffers) | 980 PRO | play | 4000 MiB | 2951 | sys 18.4 | 34 | 87 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | 980 PRO RAID0 | play | 4000 MiB | 2914 | 0.3 / 19.3 / 0.0 / 26.7 | 37 [37–37] | 80 |
| `fdplay` at 3000, top step (16 buffers) | 980 PRO RAID0 | play | 4000 MiB | 2948 | 0.3 / 18.9 / 0.0 / 27.3 | 35 | 84 |

Notes:

* Sabrent Rocket 2230 1TB: raw script output (MiB/s, medians): write 1818, read 3478; RAID0
  write 1632, read 2564; dual write 3292, read 5442 (aggregate). Every `dd` write is CPU-bound
  on one A72 core (one `dd` 72–88 %, two streams ~150 %), not drive-bound. One `dd` on the
  RAID0 is slower than on one drive (1711 vs 1906 MB/s): each 4 MiB block is split into
  512 KiB chunks across both drives and completes with the slower one.
* Sabrent `fdrec`: clean at the 3000 MB/s top step 3/3 with 32 buffers (2981–2984 MB/s
  achieved, high-water mark 1902–2100), 2 of 3 with 16 buffers (one run dropped 121 538
  beats); RAID0 3000 3/3 with 32 buffers (high-water mark 2067–2374), 2000 with 16 buffers
  (2250 dropped 863 516 beats). Every failure is a single short stall (one gap): neither the
  drive nor the array is bandwidth-limited at 4 GB.
* Sabrent `fdplay`: single 3000 3/3 with 32 and with 16 buffers. RAID0 with 32 buffers: the
  first sweep stopped at 1000 MB/s (1250 had 2781 underflow ticks, one read stall); a repeat
  on a new 4000 MiB file was clean to 3000 in the sweep (2921 MB/s) and in 1 of 2 confirmations
  (1048 ticks): marginal at the top step. RAID0 with 16 buffers: 3000 3/3.
* At 1000 MB/s: `fdrec` 15 % (Sabrent) and 16 % (Sabrent RAID0) of a core, `fdplay` 12 / 13 %.
  Each Sabrent got two NVMe I/O queues (one per core).
* Samsung 980 PRO 1TB (Gen4 x4, 2026-10-18): raw script output (MiB/s, medians): write 1913,
  read 3508; RAID0 write 2072, read 3738; dual write 3162, read 5128 (aggregate). As with the
  Sabrent drives, every `dd` write is CPU-bound on one A72 core (72–92 %, two streams
  139–159 %). Unlike the Sabrent pair, one `dd` on the 980 PRO RAID0 is not slower than on one
  drive (2173 vs 2006 MB/s).
* 980 PRO `fdrec`: clean at the 3000 MB/s top step 3/3 with 32 and with 16 buffers on both
  layouts (high-water mark 1690–2049 of 16384); 3200 MB/s over 32 GB clean on both. `fdplay`:
  clean at every step up to the 3000 MB/s top step, 3/3, with 32 and with 16 buffers on both
  layouts (0 underflows in all 56 playbacks, 2026-10-20).
* At 1000 MB/s: `fdrec` 16 % (980 PRO) and 17 % (980 PRO RAID0) of a core, `fdplay` 11 / 13 %.
  Each 980 PRO got two NVMe I/O queues (one per core).

Variations (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| Sabrent | dd bs=1M | 1664 | 3084 | 79 / 61 |
| Sabrent | dd bs=16M | 1960 | 3554 | 78 / 68 |
| Sabrent | two dd streams on the drive (aggregate) | 3264 | 5825 | 148 / 115 |
| Sabrent | dd 32 GB (read: 1 run; inside the cache) | 1931 | 3264 | 72 / 52 |
| Sabrent RAID0 | dd bs=1M | 1389 | 2305 | 69 / 47 |
| Sabrent RAID0 | dd bs=16M | 2056 | 3382 | 73 / 85 |
| Sabrent RAID0 | two dd streams on the array (aggregate) | 3424 | 6035 | 157 / 134 |
| Sabrent RAID0 | dd 32 GB (1 run; inside the cache) | 2132 | 3521 | 88 / 74 |
| 980 PRO | dd bs=1M | 1503 | 2527 | 72 / 44 |
| 980 PRO | dd bs=16M | 1589 | 3383 | 56 / 61 |
| 980 PRO | two dd streams on the drive (aggregate) | 3355 | 5412 | 139 / 79 |
| 980 PRO | dd 32 GB (read: 1 run; inside the cache) | 2073 | 3724 | 78 / 56 |
| 980 PRO RAID0 | dd bs=1M | 1607 | 2724 | 77 / 49 |
| 980 PRO RAID0 | dd bs=16M | 2330 | 4033 | 92 / 88 |
| 980 PRO RAID0 | two dd streams on the array (aggregate) | 3555 | 5949 | 159 / 120 |
| 980 PRO RAID0 | dd 32 GB (1 run; inside the cache) | 2117 | 3643 | 90 / 80 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| Sabrent | 4186 MB/s, 84 % of a core | 4186 MB/s, 98 % | 4542 MB/s, 88 % | 4403 MB/s, 98 % |
| Sabrent RAID0 | 4352 MB/s, 87 % | 3958 MB/s, 98 % | 4483 MB/s, 90 % | 4362 MB/s, 98 % |
| 980 PRO | 4694 MB/s, 89 % of a core | 4352 MB/s, 98 % | 4718 MB/s, 90 % | 4777 MB/s, 99 % |
| 980 PRO RAID0 | 4623 MB/s, 93 % | 4356 MB/s, 98 % | 4709 MB/s, 92 % | 4676 MB/s, 98 % |

With the Sabrent drives fio itself is CPU-bound (one fio thread at 82–98 % of a core; reads
are almost all system time, pinning the pages of each 8 MB request), so these are the host's
figures, not the drives'. With hugepage fixed buffers (`--iomem=mmaphuge --fixedbufs`, how
`fdplay` reads) fio reads one Sabrent at 4529 MB/s and the RAID0 at 7792 MB/s (10 GB). Their
32 GB writes are inside the ~75 GB SLC cache. The second Sabrent alone: 4269 MB/s write,
4248 MB/s read (fio 4 GB, one run).

The 980 PRO drives behave the same way: fio is CPU-bound (89–99 % of a core); with hugepage
fixed buffers it reads one 980 PRO at 6312 MB/s and the RAID0 at 7936 MB/s (10 GB). Their 32 GB
writes are inside the ~115–120 GB SLC cache. The second 980 PRO alone: 4638 MB/s write (median
of 3, after idle), 4428 MB/s read (fio 4 GB, one run); its first 4 GB write, minutes after the
drive's first full-drive discard of the day, gave 2794 MB/s.

### Results: zcu106_hpc0

AMD ZCU106 (XCZU7EV, four Cortex-A53 cores at 1.2 GHz, 4 GB DDR4), XDMA Gen3 x4 Root Ports,
`zcu106_hpc0` image, measured 2026-10-19 (the `fdrec` / `fdplay` rows 2026-10-20). The
Samsung 980 PRO 1TB rows (two drives on the FPGA
Drive FMC Gen4 on HPC0) and the Sabrent Rocket 2230 1TB rows (two drives on the M.2 M-key Stack
FMC on HPC0) are Gen4 drives; they link at Gen3 x4 here (`LnkSta 8GT/s (downgraded)`). Same
method, with 60 s of idle time after each `mkfs`. `fdrec` / `fdplay` used the shipped default of
**32 x 8 MB buffers**; 16-buffer results are in brackets where they differ. Total CPU is a share
of four cores (25 % = one full core).

| method | config | direction | size | MB/s | total CPU % of 4 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | 980 PRO 1TB | write | 4000 MiB | 1398 [1394–1427] | 0.2 / 17.6 / 0.5 / 5.6 | 74 [63–75] | 19 |
| dd (script) | 980 PRO 1TB | read | 4000 MiB | 2026 [1915–2292] | 0.3 / 10.8 / 2.3 / 8.2 | 50 [42–70] | 40 |
| dd (script) | RAID0 (2x 980 PRO) | write | 4000 MiB | 1755 [1651–1762] | 0.1 / 22.4 / 0.0 / 1.4 | 90 [89–91] | 20 |
| dd (script) | RAID0 (2x 980 PRO) | read | 4000 MiB | 2397 [2255–2397] | 0.3 / 20.7 / 0.0 / 1.3 | 82 [80–82] | 29 |
| dd (dual script) | both 980 PRO, two filesystems | write (aggregate) | 2 x 4000 MiB | 2741 [2646–2759] | 0.2 / 35.1 / 0.9 / 10.6 | 145 [133–160] | 19 |
| dd (dual script) | both 980 PRO, two filesystems | read (aggregate) | 2 x 4000 MiB | 4033 [3600–4052] | 0.3 / 23.8 / 4.6 / 11.4 | 111 [100–128] | 36 |
| `fdrec`, highest clean: 3000, top step (16: 3000) | 980 PRO 1TB | record | 4000 MiB | 2980 | 0.2 / 17.7 / 0.2 / 10.5 | 68 | 44 |
| `fdrec` at 3000 | 980 PRO 1TB | record | 32 GB | 2998 | 0.2 / 17.5 / 0.1 / 11.3 | 67 | 44 |
| `fdrec`, highest clean: 3000, top step (16: 3000) | RAID0 (2x 980 PRO) | record | 4000 MiB | 2982 | 0.2 / 18.6 / 0.5 / 10.8 | 73 | 41 |
| `fdrec` at 3000 | RAID0 (2x 980 PRO) | record | 32 GB | 2998 | 0.2 / 18.6 / 0.3 / 11.5 | 73 | 41 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | 980 PRO 1TB | play | 4000 MiB | 2824 | 0.2 / 11.9 / 3.0 / 8.5 | 55 | 51 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | RAID0 (2x 980 PRO) | play | 4000 MiB | 2894 | 0.2 / 16.5 / 0.2 / 6.8 | 64 | 46 |
| dd (script) | Sabrent Rocket 2230 1TB | write | 4000 MiB | 1398 [1384–1422] | 0.1 / 17.5 / 0.0 / 6.0 | 67 [67–73] | 21 |
| dd (script) | Sabrent Rocket 2230 1TB | read | 4000 MiB | 2208 [1864–2280] | 0.1 / 14.2 / 0.0 / 5.4 | 63 [52–77] | 36 |
| dd (script) | RAID0 (2x Sabrent) | write | 4000 MiB | 1536 [1394–1664] | 0.2 / 19.0 / 1.5 / 3.2 | 80 [75–90] | 19 |
| dd (script) | RAID0 (2x Sabrent) | read | 4000 MiB | 2208 [2066–2231] | 0.1 / 17.7 / 0.0 / 2.0 | 85 [70–85] | 26 |
| dd (dual script) | both Sabrent, two filesystems | write (aggregate) | 2 x 4000 MiB | 2565 [2504–2646] | 0.2 / 33.5 / 1.1 / 10.5 | 136 [122–141] | 19 |
| dd (dual script) | both Sabrent, two filesystems | read (aggregate) | 2 x 4000 MiB | 3663 [3647–4153] | 0.3 / 25.6 / 9.0 / 12.1 | 104 [101–130] | 35 |
| `fdrec`, highest clean: 3000, top step (16: 2500) | Sabrent Rocket 2230 1TB | record | 4000 MiB | 2878 | 0.2 / 18.5 / 0.0 / 11.0 | 71 | 41 |
| `fdrec` at 2750 | Sabrent Rocket 2230 1TB | record | 32 GB | 2748 | 0.2 / 14.9 / 0.3 / 13.5 | 65 | 42 |
| `fdrec`, highest clean: 3000, top step (16: 1750) | RAID0 (2x Sabrent) | record | 4000 MiB | 2981 | 0.2 / 18.9 / 0.5 / 9.0 | 75 | 40 |
| `fdrec` at 3200 | RAID0 (2x Sabrent) | record | 32 GB | 3197 | 0.2 / 20.0 / 0.8 / 9.9 | 79 | 41 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | Sabrent Rocket 2230 1TB | play | 4000 MiB | 2822 | 0.2 / 12.2 / 3.8 / 7.4 | 59 | 48 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | RAID0 (2x Sabrent) | play | 4000 MiB | 2838 | 0.2 / 15.4 / 0.0 / 5.5 | 58 | 49 |

Notes:

* 980 PRO 1TB: raw script output (MiB/s, medians): write 1351, read 1970; RAID0 write 1694,
  read 2325; dual write 2631, read 3883 (aggregate). One `dd` at queue depth 1 is CPU- and
  latency-bound (19-20 MB/s per % of a core writing). Four NVMe I/O queues on both slots.
* 980 PRO `fdrec` with 32 and with 16 buffers: clean at every step up to the 3000 MB/s top
  step, 3/3 there, on one drive and on RAID0 (high-water mark 2172-4565 at 3000 MB/s;
  2979-2983 MB/s); 3000 MB/s over 32 GB clean on both (high-water mark 2930 and 3853).
  Recording at 3 GB/s costs 66-73 % of one A53 core.
* 980 PRO `fdplay` with 32 and with 16 buffers: clean at every step up to the 3000 MB/s top
  step, 3/3 there, on one drive and on RAID0 (0 underflows in all 56 playbacks). The tool's own
  rate at that step (2824-2932 MB/s) includes the ring prefill. Playback at 3 GB/s costs
  55-64 % of a core.
* At 1000 MB/s: `fdrec` 25 % of a core (980 PRO) and 26 % (RAID0); `fdplay` 17 / 20 %.
* Sabrent Rocket 2230 1TB: raw script output (MiB/s, medians): write 1346, read 2139; RAID0
  write 1481, read 2162; dual write 2476, read 3539 (aggregate). One `dd` at queue depth 1 is
  CPU- and latency-bound on the A53 (19–21 MB/s per % of a core writing). Four NVMe I/O queues
  on both slots.
* Sabrent `fdrec` with 32 buffers: clean at every step up to the 3000 MB/s top step, 3/3 there,
  on one drive (2867-2895 MB/s, high-water mark 2172-2321) and on RAID0 (2973-2981 MB/s,
  2260-2395). With 16 buffers one drive was clean to 2500 MB/s (2750 dropped 1 751 020 beats)
  and RAID0 to 1750 MB/s (2000 dropped 191 277 beats): in both the 128 MB ring ran out behind
  stalled drive writes (8 writes in flight). `fdplay` with 32 and 16 buffers: clean at every
  step up to the 3000 MB/s top step, 3/3, on one drive and on RAID0 (0 underflows in all 56
  playbacks); the tool's own rate there is 2822-2935 MB/s. Recording at 3 GB/s costs 71-75 % of
  one A53 core, playback 56-60 %.
* At 1000 MB/s: `fdrec` 26 % of a core (Sabrent) and 27 % (RAID0); `fdplay` 19 / 19 %.

Variations (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| 980 PRO 1TB | dd bs=1M | 1149 | 1595 | 66 / 43 |
| 980 PRO 1TB | dd bs=16M | 1408 | 1960 | 71 / 46 |
| 980 PRO 1TB | two dd streams on the drive (aggregate) | 2853 | 2715 | 139 / 69 |
| 980 PRO 1TB | dd 32 GB (read: 1 run; inside the cache) | 1491 | 2014 | 76 / 48 |
| RAID0 (2x 980 PRO) | dd bs=1M | 1295 | 1942 | 75 / 57 |
| RAID0 (2x 980 PRO) | dd bs=16M | 1651 | 2778 | 76 / 86 |
| RAID0 (2x 980 PRO) | two dd streams on the array (aggregate) | 3073 | 4280 | 167 / 124 |
| RAID0 (2x 980 PRO) | dd 32 GB (1 run; inside the cache) | 1749 | 2264 | 89 / 77 |
| Sabrent Rocket 2230 1TB | dd bs=1M | 1188 | 1785 | 70 / 51 |
| Sabrent Rocket 2230 1TB | dd bs=16M | 1362 | 2097 | 69 / 52 |
| Sabrent Rocket 2230 1TB | two dd streams on the drive (aggregate) | 2565 | 3073 | 123 / 73 |
| Sabrent Rocket 2230 1TB | dd 32 GB (read: 1 run; inside the ~72 GB cache) | 1307 | 2373 | 67 / 73 |
| RAID0 (2x Sabrent) | dd bs=1M | 1319 | 2066 | 80 / 69 |
| RAID0 (2x Sabrent) | dd bs=16M | 1482 | 2383 | 78 / 81 |
| RAID0 (2x Sabrent) | two dd streams on the array (aggregate) | 2646 | 4132 | 156 / 138 |
| RAID0 (2x Sabrent) | dd 32 GB (1 run) | 1527 | 2418 | 80 / 88 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| 980 PRO 1TB | 2956 MB/s, 73 % of a core | 2854 MB/s, 98 % | 2984 MB/s, 73 % | 2892 MB/s, 97 % |
| RAID0 (2x 980 PRO) | 3401 MB/s, 96 % | 2824 MB/s, 98 % | 3389 MB/s, 96 % | 2977 MB/s, 96 % |
| Sabrent Rocket 2230 1TB | 2827 MB/s, 70 % of a core | 2879 MB/s, 98 % | 2824 MB/s, 76 % | 2920 MB/s, 98 % |
| RAID0 (2x Sabrent) | 3229 MB/s, 92 % | 2653 MB/s, 94 % | 3311 MB/s, 94 % | 2777 MB/s, 97 % |

The second 980 PRO alone: 2962 MB/s write, 2831 MB/s read (fio 4 GB, one run): the same
~2.96 GB/s write on both slots, the drive on its Gen3 x4 link. The second Sabrent alone:
2890 MB/s write, 2875 MB/s read (fio 4 GB, one run); the board writes ~2.82-2.90 GB/s per slot
with the Sabrent, also its Gen3 x4 link. Every read row and the RAID0 write rows have the fio
thread at 92-98 % of one A53 core, so they measure fio, not the storage (with hugepage fixed
buffers fio reads one 980 PRO at 3182 MB/s, the Sabrent RAID0 at 5138 MB/s and the 980 PRO
RAID0 at 5965 MB/s, 10 GB). The 32 GB writes are inside the SLC cache of both drives (~72 GB
Sabrent, ~115 GB 980 PRO).

### Why the figures differ

The two methods answer different questions, and neither measures the PCIe link.

**CPU cost.** A `dd` write is a CPU-bound copy of zeros: every 4 MiB block is first zero-filled
by the kernel from `/dev/zero` into `dd`'s buffer, then written with `O_DIRECT`. That costs
about 50 % of one 1.2 GHz Cortex-A53 core per ~1 GB/s, and on RAID0 a single `dd` becomes
CPU-bound at 80–90 % of a core. `fdrec` never produces or copies the data: the AXI DMA fills the
hugepage buffers and the NVMe controller reads the same buffers, and the CPU only issues
io_uring requests and ioctls and does the cache maintenance. Measured, that is about **2× more
data per unit of CPU for writes** on `zcu106_hpc0` (`dd` 19–21 MB/s per % of a core, `fdrec`
37–44) and 2.4–3.2× on `vck190_fmcp1` (`dd` 25, `fdrec` 59–81). For reads the gap is smaller,
**about 1.4–2×** (on `zcu106_hpc0` `dd` 26–40, `fdplay` 46–57): a `dd` read lands in its buffer
by DMA and is handed to `/dev/zero`, which discards it without a copy, so `dd` pays only the
per-I/O work (a system call, pinning 1024 pages of 4 KiB per block, a wake-up per completion).
The recorder's remaining cost is the kernel's I/O path itself.

**Queue depth 1 vs 8 in flight.** `dd` has one 4 MiB request in flight; the drive idles
while `dd` prepares the next one. On `zcu106_hpc0` one `dd` writes 1398 MB/s to a Samsung
980 PRO 1TB, two `dd` streams 2853 MB/s and fio at queue depth 8 2956 MB/s. On its RAID0 one
`dd` (each block spans both drives) reaches 1755 MB/s write and 2397 MB/s read, against fio's
3401 / 2824 MB/s (both CPU-bound). Block size matters too: against the scripts' 4 MiB, 1 MiB
blocks lose 6–31 %; 16 MiB blocks change the single-drive reads by a few percent and raise the
RAID0 reads by 3–26 %, with no consistent effect on writes (see the variations tables).

**Burst vs sustained.** The 1 TB drives cache 72-120 GB, so on them a 4 GB and even a 32 GB
`dd` is a burst (on `vck190_fmcp1` the Sabrent 1931 MB/s, the 980 PRO 2073 MB/s over 32 GB,
both about the same as over 4 GB). The recorder's "highest clean rate" is stricter than any
average: a recorder must never fall behind, not even briefly, so the drive's worst moment sets
it. The recorder's rates in these tables are 4000 MiB bursts too; only the
[long recordings](#long-recordings-past-the-slc-cache) show the sustained rate.

**What else differs.** Both methods bypass the page cache (`O_DIRECT`); no cache effect
was seen. `dd` extends its file block by block, while `fdrec` preallocates the full size
first. And the `dd` data never touches the FPGA, whereas the `fdrec` and `fdplay` figures
include the AXI DMA, the fabric FIFO and the DDR traffic of the DMA and the SSD using the
same buffers.

**Neither measures the PCIe link directly.** A PCIe Gen3 x4 link carries 3.94 GB/s raw in each
direction, ~3.1-3.3 GB/s of payload with 128-byte MaxPayload. Almost every figure here is below
that: the SSDs (and their caches), the filesystem and the Linux I/O path set the limits. The
exception is a fast Gen4 drive on the Gen3 x4 Root Ports of `zcu106_hpc0`: inside their caches
the Sabrent Rocket 2230 1TB writes ~2.95 GB/s and the Samsung 980 PRO 1TB ~2.96-3.04 GB/s per
slot, and both read ~2.9-3.2 GB/s (raw device), the link's practical rate. To check the link
itself, look at its negotiated speed and width (`lspci -vv`, see [Test the design in
Linux](linux_test.md#1-check-that-the-pcie-links-are-up)).

The sibling design's own documentation quotes lower `dd` figures for a Zynq UltraScale+ target
(read 790–970, write ~585 MB/s); those were measured with a Samsung 980 PRO and an older image,
and do not apply to this setup. With this design, a Samsung 980 PRO 1TB on `zcu106_hpc0` gives
1398 MB/s write and 2026 MB/s read with the same scripts.

For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics. See their
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).

## Where the bottlenecks are

Why don't you get the SSD's rated read and write speed? This section goes through the chain
from the SSD to the fabric, in the order in which the limits usually bite. The numbers are
the measurements on this page, on `vck190_fmcp1` (Gen4 x4) and `zcu106_hpc0` (Gen3 x4); the
reasoning applies to every target.

### 1. The SSD itself

**Writes: the SLC cache, then the flash.** The Sabrent Rocket 2230 1TB writes ~4.5 GB/s on Gen4
x4 (~2.9 GB/s on the Gen3 x4 link of `zcu106_hpc0`) for ~72-75 GB and then a flat ~1.8 GB/s, on
both boards; the Samsung 980 PRO 1TB writes ~4.7 GB/s on Gen4 x4 (~3.0 GB/s on the Gen3 x4 link)
for ~115-120 GB and then a flat ~1.77 GB/s, on both boards (see [The SLC
cache](#the-slc-cache)). Where nothing else comes first, the post-cache rate sets the sustained
single-drive rate: 1750 MB/s for the 980 PRO on both boards (over 240 GiB on the VCK190, over
200 and 221 GiB on `zcu106_hpc0`; 2000 MB/s drops when the cache ends) and for the Sabrent on
`zcu106_hpc0` (over 200 GiB; 2000 MB/s drops just past the cache). Elsewhere other limits come
first: the Sabrent's rare write stalls on `vck190_fmcp1` and, in long RAID0 recordings at
3000 MB/s and above on `zcu106_hpc0`, the rare late DMA restarts (section 5). Smaller drives show the cliff sooner, or not at all: Samsung rates the
970 EVO 250GB at up to 1500 MB/s sequential write, and 300 MB/s once its TurboWrite (SLC) cache
is full
([data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung-NVMe-SSD-970-EVO-Data-Sheet_Rev.1.0.pdf)),
and it was measured at ~1.5 GB/s for ~14 GB, then about 330 MB/s. The 950 PRO 256GB, rated at
900 MB/s write ([Samsung](https://www.samsung.com/us/computer/memory-storage/MZ-V5P256BW)), has
no such cliff: its ~955 MB/s is its real write rate.

**Reads: the rating assumes a fast host with many commands outstanding.** Drive read ratings
are measured with many read commands in flight on a fast desktop host. With one request at a
time (`dd`, queue depth 1) one Samsung 980 PRO 1TB reads 3678 MB/s on `vck190_fmcp1` (Gen4 x4);
with 8 requests in flight fio reads it at 4352 MB/s, CPU-bound, and at 6312 MB/s with hugepage
fixed buffers, the way `fdplay` reads. On `zcu106_hpc0` the Gen3 x4 link sets the per-slot read
rate: a Sabrent Rocket 2230 1TB reads ~2.9-3.15 GB/s and a Samsung 980 PRO 1TB ~2.9-3.2 GB/s
per slot (raw device, 1 MB requests at queue depth 8 and 32).

**The recorder's criterion is the drive's worst moment.** A recording passes only if no beat
is dropped over its whole length, so its rate is set by the drive's slowest stretch
(garbage collection, the cache end, a write-latency spike), not by its average. That is why
the sustained recording rates sit below the drives' average write rates (one 980 PRO 1TB:
1750 MB/s against a post-cache median of 1768 MB/s).

The Sabrent Rocket 2230 1TB on `vck190_fmcp1` shows that the worst moment need not be a
bandwidth limit. It writes 1.8 GB/s even past its cache, yet in 2 of ~13 long single-drive
recordings no write completed for about 0.65 s (one gap at the 750 and one at the 1250 MB/s
step of the sweep, none at 1000 MB/s in 7 recordings up to 143 GiB). A stall that long drops
beats at any rate above what the ring covers (section 5). On `zcu106_hpc0` the same drives
showed no such stall (more than 40 single-drive recordings of 4 GB or more at 250-2750 MB/s,
where a 0.65 s stall at 2 GB/s or more would have cost at least 80 M beats in one gap); why was
not investigated.

### 2. The host I/O path and the CPU

Every write and read goes through the kernel's filesystem, block layer and NVMe driver, and
that path costs CPU time per byte even without a data copy. On `zcu106_hpc0` (four 1.2 GHz
Cortex-A53 cores) `fdrec` uses about 2.4–2.6 % of one core per 100 MB/s (24–26 % at
1000 MB/s), almost all of it system time, and the cost grows almost linearly with the rate:
67–75 % at 3000 MB/s and ~78 % at 3200 MB/s (32 GB), so one core would saturate at about
4 GB/s. `fdplay` uses 16–22 % at 1000 MB/s and 41–42 % at 2250–2500 MB/s. `dd` additionally
has the CPU produce every byte (zero-fill from `/dev/zero`) and runs one request at a time:
about 5 % of a core per 100 MB/s, and on RAID0 a single `dd` is CPU-bound at ~1.5-1.8 GB/s
(80–90 % of a core). The AXI DMA writes DDR through a non-coherent port, so the driver does a
cache-maintenance pass over each buffer (one invalidate after the DMA, one clean before the
buffer goes back); that is part of the system time above.

On the VCK190 (two 1.4 GHz Cortex-A72 cores) the same work costs less: `fdrec` uses about
1.6 % of one core per 100 MB/s at 1000 MB/s (15.5–16.6 %) and 1.2–1.7 % at 3000 MB/s (37–51 %),
`fdplay` about 1.2 % (11.8–12.4 % at 1000 MB/s), and a `dd` write about 4 % (77–79 % of a core
at 1.9–2.0 GB/s). A core goes about 1.5 times as far as a ZCU106 core, but there are only two of
them, and during a recording one of them spends much of its time waiting for I/O completions.
With the Gen4 drives the VCK190's CPU becomes the limit of the reference tools: one fio thread
reaches 82-98 % of a core at ~4.2-4.5 GB/s with the Sabrent Rocket 2230 1TB and 89-99 % at
~4.4-4.8 GB/s with the Samsung 980 PRO 1TB, and one `dd` write stream 72-92 % at
~1.9-2.2 GB/s. `fdrec` records 3 GB/s on one drive with 37 % (Sabrent) to 46 % (980 PRO) of a
core.

On `zcu106_hpc0` the reference tools hit the same wall on one A53 core: fio reads of a file
(2.7-2.9 GB/s) and fio writes to a RAID0 pair (~3.2-3.3 GB/s Sabrent, ~3.4 GB/s 980 PRO) keep
the fio thread at 92-98 % of a core, so they measure fio, not the storage (with hugepage fixed
buffers fio reads the RAID0 pairs at 5138 and 5965 MB/s).

**What limits a Zynq UltraScale+ slot.** Each XDMA Root Port reaches the PS DDR through its own
HP port (`S_AXI_HP0_FPD`, `S_AXI_HP1_FPD`), 128 bits at 250 MHz = 4.0 GB/s each, and the
recorder's own AXI DMA path through `S_AXI_HP2_FPD` carries the generator's full 3.2 GB/s;
neither is the limit. Inside the SLC cache the limit is the Gen3 x4 link at 128-byte MaxPayload
(MaxReadReq 512 bytes): the link carries 3.94 GB/s raw, and each 128-byte payload travels in a
TLP with ~20-24 bytes of header, sequence number, LCRC and framing, plus acknowledgement and
flow-control packets, which leaves ~3.1-3.3 GB/s of payload per direction. Measured on
`zcu106_hpc0` with both 1 TB drives: one slot writes up to ~2.93 GB/s with the Sabrent and ~3.04
GB/s with the 980 PRO (fio 2824-2890 and 2956-2962 MB/s; the 3000-3200 MB/s sweep steps 2949 and
3036 MB/s) and reads 2936-3153 MB/s (Sabrent) and 2934-3185 MB/s (980 PRO, raw device), against
~4.2-4.7 GB/s in the cache on the VCK190's Gen4 x4 link. So one drive records 2750 MB/s
(Sabrent) or 3000 MB/s (980 PRO), and RAID0 across both slots is the way past that. Past the
cache the drive's post-cache rate (~1.8 GB/s Sabrent, ~1.77 GB/s 980 PRO) is the limit, and in
long RAID0 recordings at 3000 MB/s and above the rare late DMA restarts at buffer boundaries
(section 5). The per-slot
figure is consistent with [fpga-drive-nvme-offload](https://offload.fpgadrive.com), the hardware
NVMe host design (AMD NVMe Host Accelerator) on the same board and Root Ports, which reaches
~3.04 GB/s per Gen3 x4 slot.

### 3. The NVMe queue count

The Samsung 970 EVO 250GB, an older drive also tried with this design, is set up by the NVMe
driver with a single I/O queue (`nvme nvme0: 1/0/0 default/read/poll queues` in the kernel log).
This is a property of that drive: it happened on every board it was tried on, Zynq UltraScale+
and Versal alike, while the Samsung 950 PRO 256GB got two to four queues on every board, and the
Samsung 980 PRO 1TB and the Sabrent Rocket 2230 1TB one per core: four on `zcu106_hpc0`
(`4/0/0`) and two on `vck190_fmcp1` (`2/0/0`). With one queue, every command and completion of
the drive goes through one queue and one interrupt, on one core: a limiter for parallel I/O to
that drive. Other drives expose more queues; check yours with `dmesg | grep queues`.

### 4. RAID0 and the filesystem

With 512 KB chunks, md splits every 8 MB request into 16 stripe writes, alternating between the
drives; the array then runs at up to twice the slower drive's rate. md itself is not the limit:
on `zcu106_hpc0` two Sabrent Rocket 2230 1TB write 3.2-3.3 GB/s and two 980 PRO 1TB 3.4 GB/s
through md (fio, CPU-bound), and on `vck190_fmcp1` two Sabrent Rocket 2230 1TB 4.4 GB/s and two
980 PRO 1TB 4.6-4.7 GB/s (fio, CPU-bound). On the filesystem side, `fdrec` preallocates the
whole file (`fallocate`), so XFS does no allocation work during the recording, and an `fstrim`
immediately before a recording can stall the first writes for more than 100 ms (see [the fstrim
finding](#the-fstrim-finding-and-the-ring-size)).

### 5. Latency budgets, not bandwidth

Two buffers decide whether a short stall costs data, although neither limits throughput:

* **The buffer ring** (buffers × buffer size) must cover the longest write-latency spike of
  the drive at the recording rate. 16 × 8 MB = 128 MB lasts 75 ms at 1.7 GB/s, which was not
  always enough after an `fstrim`; the default is now 32 × 8 MB (256 MB). The Sabrent Rocket
  2230 1TB's rare ~0.65 s stalls need about 650 MB at 1000 MB/s; the largest ring of 8 MB
  buffers (`--buffers 64`, 512 MB, which is also the default hugepage pool) cannot bridge
  them, so on that drive 1000 MB/s is clean in practice (7 of 7 long recordings), not by
  margin. A larger ring (larger buffers and a larger hugepage pool reserved at boot) was not
  tested.
* **The fabric FIFO** must cover the AXI DMA's pause at each buffer boundary, during which
  the driver's interrupt handler starts the next buffer: about 9 µs at every boundary and
  15-20 µs in the tail on `zcu106_hpc0` (a trace of the S2MM interrupt over 32 GB RAID0
  recordings at 3200 MB/s: the handler itself takes 8 µs median, 14 µs max). The 256 KB ingest
  FIFO (16384 beats) covers 82 µs at 3.2 GB/s and the 64 KB egress FIFO 20 µs (see
  [the FIFO budget](apps.md#tuning-the-fifo-budget-at-buffer-boundaries)). Rarely the restart
  is much longer, and then the FIFO overflows while the ring is nearly empty. In 350 GiB RAID0
  recordings each run has one boundary that stalls longer than all the others: 34-59 µs on
  `vck190_fmcp1` with the Sabrent pair (high-water marks 6457-11 812 at 2750-3200 MB/s, no
  drops), 24-44 µs on `vck190_fmcp1` with the 980 PRO pair over 480 GiB (high-water marks
  4193-8896 at 2750-3200 MB/s, no drops) and 36-46 µs on `zcu106_hpc0` with the 980 PRO pair
  in the clean runs. On `zcu106_hpc0` the tail is longer: with the 980 PRO pair one run at
  3000 MB/s and the run at 3200 MB/s hit a boundary of about 240 and 120 µs and lost 29 165 and
  8085 beats; with the Sabrent pair the 350 GiB runs at 2500 and 2750 MB/s lost 40 425 and
  20 256 beats (about 364 and 213 µs), a 32 GB run at 2750 MB/s lost 54 968 beats (about
  415 µs), and the 350 GiB run at 3000 MB/s came within 21 beats of the 16384-beat FIFO. In
  every case the gap starts 16384 + 7 beats after the boundary and the drives were not involved
  (at most 8 writes in flight). For long RAID0 recordings at 2500 MB/s and above on the Zynq
  UltraScale+ targets this restart latency, not the SSDs, is the margin; the handler's 8 µs and the rare long stalls are software, so a design that keeps
  the DMA armed across buffer boundaries (a descriptor chain, see
  [Limitations](limitations.md)) would remove them.

Both set what "sustainable" means: a rate is sustainable if the drive's worst stall fits in
the ring.

### 6. What is not the bottleneck at these rates

* **The PCIe link**, with one exception. Gen3 x4 carries about 3.1-3.3 GB/s of payload at
  128-byte MaxPayload (Gen4 x4 on the Versal targets about 6.5 GB/s), above almost every figure
  here. The exception: a Gen4 SSD in a Gen3 design is capped at the Gen3 rate. The Samsung
  980 PRO 1TB and the Sabrent Rocket 2230 1TB link at Gen3 x4 (`8GT/s (downgraded)`) on the Zynq
  UltraScale+ Root Ports, where inside their caches both run at the link's rate (~2.95-3.04 GB/s
  write, ~2.9-3.2 GB/s read per slot), and at Gen4 x4 (16 GT/s) on the VCK190's QDMA Root Ports
  (see [What limits a Zynq UltraScale+ slot](#2-the-host-io-path-and-the-cpu)). PCIe
  MaxPayload is 128 bytes and MaxReadReq 512 bytes on both boards.
* **The PS DDR memory.** A recording moves every byte through DDR twice (the AXI DMA writes it,
  the SSD reads it), so 1.75 GB/s of recording is 3.5 GB/s of DDR traffic, well within the
  bandwidth of a 64-bit DDR4 interface. RAID0 recordings at 3 GB/s (6 GB/s of DDR traffic)
  passed on both the ZCU106 and the VCK190.
* **The fabric datapath and the AXI DMA:** 128 bits at 250 MHz = 4 GB/s. The test pattern
  generator tops out at 3.2 GB/s (200 MHz × 16 bytes), a design parameter (`src_clk`). With
  the Sabrent Rocket 2230 1TB on `vck190_fmcp1`, the generator is the burst limit: 10 GB
  recordings pass at 3.2 GB/s on one drive. On `zcu106_hpc0` the Sabrent RAID0 pair records 10
  and 40 GB at 3.2 GB/s, and the 980 PRO RAID0 pair 40 GB.

### 7. How to get more

* SSDs without an SLC cliff: drives designed for sustained writes (enterprise, industrial,
  MLC or SLC flash), or larger capacities with a bigger cache. See
  [supported SSDs](supported_ssds.md#choosing-ssds-for-recording).
* RAID0 of two good, identical drives. On the Zynq UltraScale+ targets it is the way past
  the ~2.95-3.04 GB/s that one Gen3 x4 slot writes.
* A Gen4 target (`vck190_fmcp1`) for Gen4 drives.
* More buffers (`--buffers`, `--buf-size`) to ride out latency spikes.
* Larger I/Os or more requests in flight (`--buf-size`, `--qd`).
* SSDs that expose several NVMe I/O queues.

For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics. See their
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).
