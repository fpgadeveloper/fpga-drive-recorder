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
  32 GB stays **inside** the cache of the 1 TB drives below (70-125 GB per drive), so the
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
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` (M.2 M-key Stack FMC on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-21 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` (FPGA Drive FMC Gen4 on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-21 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` (FPGA Drive FMC Gen4 on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-21 |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` (M.2 M-key Stack FMC on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-21 |

All four were measured with the shipped default of 32 x 8 MB buffers and with a fan on the
cards (no thermal throttling: at most 61 °C on the Sabrent drives on `vck190_fmcp1` and 66 °C
on `zcu106_hpc0`, 50 °C on the 980 PROs on `vck190_fmcp1` and 52 °C on `zcu106_hpc0`, with 0
warning or critical temperature time on every drive). The same two drives of each pair were
used on both boards.

Every figure on this page was measured with the current images: register map 1.1, an ingest
FIFO of 16384 beats, an egress FIFO of 4096 beats and `fdrec` driver 1.2, which pins the AXI
DMA interrupts and keeps the DMA armed across buffer boundaries (`xilinx_dma` patch 0002, see
[Kernel driver](driver.md)). "FIFO high-water" figures are therefore of 16384 beats.

## Results: recording, playback and CPU

Targets `vck190_fmcp1` (Versal, two Cortex-A72 cores at 1.4 GHz) and `zcu106_hpc0` (Zynq
UltraScale+, four Cortex-A53 cores at 1.2 GHz), with the SSD pairs of [Setups](#setups). RAID0 =
both drives of a pair, 512 KB chunks (`fdsetup-raid0.sh` defaults). The recordings used the
shipped default ring of 32 x 8 MB buffers unless noted. "FIFO high-water" is the highest fill
level the ingest FIFO reached during a recording, in beats of 16384; "full" means it
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
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 3200 MB/s (the generator maximum), in the cache | 4583 MB/s, in the cache | **1750 MB/s** over 143 GiB and 200 GiB (2000 MB/s dropped from 96.11 GB, past the ~70-75 GB cache) |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (2500, 3000 and 3200 MB/s clean 3 of 3 each) | 4547 MB/s, in the cache | **3200 MB/s** over 350 GiB (2500, 2750, 3000 and 3200 MB/s clean, one run each; 2750 MB/s also over 240 GiB) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3200 MB/s (the generator maximum), in the cache (3 of 3) | 4716 MB/s, in the cache | **1750 MB/s** over 219 GiB and 240 GiB (2000 MB/s dropped from 126.03 GB, past the ~115-125 GB cache) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (2500, 3000 and 3200 MB/s clean 3 of 3 each) | 4771 MB/s, in the cache | **3200 MB/s** over 480 GiB (2250, 2500, 2750, 3000 and 3200 MB/s clean, one run each) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3000 MB/s, in the cache (3200 MB/s exceeds the drive's ~3.04 GB/s on Gen3 x4) | 2978 MB/s, in the cache | **1750 MB/s** over 200 GiB and 222 GiB (2000 MB/s dropped from 126.65 GB, past the ~115-125 GB cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (high-water mark 7) | 3433 MB/s, in the cache (fio CPU-bound) | **3200 MB/s** over 350 GiB (2500, 2750, 3000 (twice) and 3200 MB/s clean) |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2750 MB/s, in the cache (3 of 3; 3000 and 3200 MB/s exceed the drive's ~2.94 GB/s on Gen3 x4) | 2871 MB/s, in the cache | **1750 MB/s** over 200 GiB (2000 MB/s dropped from 90.30 GB, past the ~69-70 GB cache) |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (2750 MB/s clean 4 of 4; 2250, 2500, 3000 and 3200 MB/s 2 of 2 each) | 3321 MB/s, in the cache (fio CPU-bound) | **3200 MB/s** over 350 GiB (2500, 2750, 3000 and 3200 MB/s clean, one run each) |

`vck190_fmcp1` with two Sabrent Rocket 2230 1TB (Gen4 x4), same method, 32 x 8 MB buffers: every
step from 250 to 3200 MB/s (the generator maximum) was clean, single and RAID0, and 2500, 3000
and 3200 MB/s RAID0 were clean in 3 of 3 runs each. The FIFO high-water mark was 1 beat up to
1500 MB/s, 2 at 1750-2000, 3 at 2250, 4 at 2500, 6 at 2750 and 7 at 3000-3200 MB/s, on both
layouts. All of these steps run inside the drives' SLC cache (~70-75 GB per drive). Past the
cache one drive holds 1750 MB/s (clean over 143 GiB and 200 GiB; 2000 MB/s drops from
96.11 GB, where the drive falls to its ~1.8 GB/s post-cache rate), the pair 3200 MB/s, the
generator maximum (clean over 350 GiB at 2500, 2750, 3000 and 3200 MB/s); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`vck190_fmcp1` with two Samsung 980 PRO 1TB (Gen4 x4), same method, 32 x 8 MB buffers: every
step from 250 to 3200 MB/s (the generator maximum) was clean, single and RAID0; 3200 MB/s
single and 2500, 3000 and 3200 MB/s RAID0 were clean in 3 of 3 runs each. The FIFO high-water
mark was 1 beat up to 1500 MB/s, 2 at 1750-2000, 3 at 2250, 4 at 2500, 6 at 2750 and 7 at
3000-3200 MB/s, on both layouts (6 in one RAID0 run at 3200 MB/s); read every 0.5 s over
32 GiB RAID0 recordings at 3000 and 3200 MB/s, every sample was 7 beats. These steps run inside
the drives' SLC cache (~115-125 GB per drive). Past the cache one drive holds 1750 MB/s (over
219 and 240 GiB; 2000 MB/s drops from 126.03 GB, where the drive falls to its ~1.77 GB/s
post-cache rate), the pair 3200 MB/s, the generator maximum (clean over 480 GiB at 2250, 2500,
2750, 3000 and 3200 MB/s); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`zcu106_hpc0` with two Samsung 980 PRO 1TB (Gen3 x4), same method, 32 x 8 MB buffers. Single
drive: clean up to 3000 MB/s (high-water mark 7 beats); 3200 MB/s drops from 4.51 GB while
writing 3036 MB/s, the drive on its Gen3 x4 link. RAID0: clean at every step up to the
generator's 3200 MB/s (high-water marks 1-7 beats, 7 at 3000 and 3200 MB/s). All of these steps
run inside the 980 PRO's SLC cache (~115-125 GB per drive). Past the cache one drive held
1750 MB/s, the RAID0 pair 3200 MB/s (see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)).

`zcu106_hpc0` with two Sabrent Rocket 2230 1TB (Gen3 x4), same method, 32 x 8 MB buffers. Single
drive: clean up to 2750 MB/s (high-water mark 6 beats; 2750 MB/s in 3 of 3 runs); 3000 MB/s
drops from 4.91 GB and 8.18 GB (two runs) while writing 2928-2943 MB/s, and 3200 MB/s from
2.16 GB at 2950 MB/s: the drive on its Gen3 x4 link, a fixed rate deficit, not a random event.
In a further 32 GiB recording at 3000 MB/s with 1 s statistics, all 8 writes of the io_uring
queue were in flight in every sample, and the drive wrote 2873-2970 MB/s per second. RAID0:
clean at every step up to the generator's 3200 MB/s, 2750 MB/s in 4 of 4 runs and 2250, 2500,
3000 and 3200 MB/s in 2 of 2, with high-water marks of 1-7 beats. These steps run inside the
SLC cache (~69-70 GB per drive). Past the cache one drive holds 1750 MB/s (over 200 GiB;
2000 MB/s drops from 90.30 GB), the RAID0 pair 2500 to 3200 MB/s (over 350 GiB); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

fio reference: `fio --name=w --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8
--size=32G --filename=/mnt/rec/fio.dat` on the freshly created filesystem, before the sweep.
It is an average over 32 GB: fio has no fixed input rate, so it rides the SLC cache at full
speed and does not show the post-cache write rate that limits a constant-rate recording.

Every step of the sweeps ("first gap" is the file offset of the first discontinuity
reported by `fdverify`; "avg MB/s" is the data written divided by the recording time;
"gaps (20)" = the first 20 of many discontinuities); 32 x 8 MB buffers:

| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | avg MB/s | fdverify | first gap |
|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1000 | pass | 0 | 1 | 999.7 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1250 | pass | 0 | 1 | 1249.5 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1500 | pass | 0 | 1 | 1499.3 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1750 | pass | 0 | 2 | 1749.0 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 2000 | pass | 0 | 2 | 1998.8 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 2250 | pass | 0 | 3 | 2248.5 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 2500 | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 2750 | pass | 0 | 6 | 2747.7 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 3000 | pass | 0 | 7 | 2997.2 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | **3200** | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 1 | 999.7 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 1 | 1249.5 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1 | 1499.3 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 2 | 1749.0 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 2 | 1998.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 3 | 2248.5 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 (#2) | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 (#3) | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 6 | 2747.7 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 7 | 2997.4 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 (#2) | pass | 0 | 7 | 2997.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 (#3) | pass | 0 | 7 | 2997.4 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 7 | 3195.7 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 (#2) | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 (#3) | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1000 | pass | 0 | 1 | 999.7 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1250 | pass | 0 | 1 | 1249.5 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1500 | pass | 0 | 1 | 1499.3 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 1750 | pass | 0 | 2 | 1749.0 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2000 | pass | 0 | 2 | 1998.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2250 | pass | 0 | 3 | 2248.4 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2750 | pass | 0 | 6 | 2747.7 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3000 | pass | 0 | 7 | 2997.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | **3200** | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3200 (#2) | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3200 (#3) | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 1 | 999.7 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 1 | 1249.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1 | 1499.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 2 | 1749.0 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 2 | 1998.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 3 | 2248.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 (#2) | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 (#3) | pass | 0 | 4 | 2498.2 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 6 | 2747.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 7 | 2997.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 (#2) | pass | 0 | 7 | 2997.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 (#3) | pass | 0 | 7 | 2997.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 7 | 3196.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 (#2) | pass | 0 | 6 | 3197.1 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 (#3) | pass | 0 | 7 | 3197.1 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1000 | pass | 0 | 1 | 999.6 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1250 | pass | 0 | 1 | 1249.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1500 | pass | 0 | 1 | 1499.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1750 | pass | 0 | 2 | 1748.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2000 | pass | 0 | 2 | 1998.6 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2250 | pass | 0 | 3 | 2248.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 4 | 2497.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2750 | pass | 0 | 6 | 2747.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | **3000** | pass | 0 | 7 | 2996.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3200 | drops | 98 428 446 | full | 3036.4 | gaps (20) | 4.51 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 1 | 999.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 1 | 1249.5 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1 | 1499.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 2 | 1748.9 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 2 | 1998.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 3 | 2248.4 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 4 | 2498.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 6 | 2747.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 7 | 2997.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 7 | 3196.6 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1000 | pass | 0 | 1 | 999.6 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1250 | pass | 0 | 1 | 1249.4 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1500 | pass | 0 | 1 | 1499.2 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1750 | pass | 0 | 2 | 1748.9 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2000 | pass | 0 | 2 | 1998.6 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2250 | pass | 0 | 3 | 2245.3 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2500 | pass | 0 | 4 | 2497.8 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | **2750** | pass | 0 | 6 | 2747.2 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2750 (#2) | pass | 0 | 6 | 2747.2 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2750 (#3) | pass | 0 | 6 | 2747.2 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 | drops | 24 863 072 | full | 2943.3 | gaps (20) | 8.18 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 (#2) | drops | 36 600 177 | full | 2928.5 | gaps (20) | 4.91 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3200 | drops | 161 243 278 | full | 2949.6 | gaps (20) | 2.16 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 250 | pass | 0 | 1 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 500 | pass | 0 | 1 | 499.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 750 | pass | 0 | 1 | 749.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 1 | 999.6 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 1 | 1249.4 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1 | 1499.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 2 | 1748.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 2 | 1998.6 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 3 | 2248.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2250 (#2) | pass | 0 | 3 | 2248.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 4 | 2497.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 (#2) | pass | 0 | 4 | 2497.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 6 | 2747.5 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 (#2) | pass | 0 | 6 | 2747.2 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 (#3) | pass | 0 | 6 | 2747.5 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 (#4) | pass | 0 | 6 | 2747.5 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 7 | 2996.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 (#2) | pass | 0 | 7 | 2996.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 7 | 3196.3 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 (#2) | pass | 0 | 7 | 3196.3 | pass | - |

"(#2)" to "(#4)" are repeats; the `vck190_fmcp1` Sabrent RAID0 repeats ran on a second freshly
created filesystem, and the `vck190_fmcp1` 980 PRO and `zcu106_hpc0` Sabrent rows combine two
sessions of the same day, each on its own freshly created filesystem (one of them the full
sweep).
In the failing 980 PRO step the gaps sum exactly to the drop count in the file header. Every
failing step starts its first gap 262 256 bytes (16384 + 7 beats) after an 8 MiB buffer
boundary: the ring ran out behind the drive (see
[Where the bottlenecks are](#5-latency-budgets-not-bandwidth)).

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): no step failed on either layout, up to the
  3.2 GB/s generator maximum.
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): the single-drive failure at 3200 MB/s writes
  3036 MB/s, the drive on its Gen3 x4 link (first gap at 4.51 GB); no other step failed on
  either layout.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`, Gen4 x4): every step from 250 to 3200 MB/s was
  clean on one drive and on the RAID0 pair (fio 32 GB 4716 / 4771 MB/s); no step failed.
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): the single-drive failures at 3000 and 3200 MB/s
  write 2928-2950 MB/s, the drive on its Gen3 x4 link (a fixed rate deficit); the io_uring
  queue was full in every 1 s sample of a further recording at 3000 MB/s. No RAID0 step failed.

### Burst and 40 GB recordings

Single recordings at a fixed rate: 32 x 8 MB buffers, `rm` + `fstrim` + 30 s idle before each,
10 GB from 1000 MB/s upwards, then 40 GB at the highest rates. "Burst" rows are 10 GB
recordings; the 40 GB rows are still inside the SLC caches of these drives.

| target | SSD | layout | recording | rate (MB/s) | result | FIFO high-water (beats) |
|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 10 GB | 1000-3000 (9 steps) | pass, all | 1-7 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 10 GB | **3200** | pass (highest burst = the generator maximum) | 7 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 7 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 1-7 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 7 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 7 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 10 GB | 1000-3000 (9 steps) | pass, all | 1-7 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 10 GB | **3200** | pass (highest burst = the generator maximum) | 7 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 7 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 1-7 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 7 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 7 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 1000-2750 (8 steps) | pass, all | 1-6 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | **3000** | pass (highest burst) | 7 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 3200 | drops from 5.07 GB (above the drive's ~3.04 GB/s write rate on Gen3 x4) | full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | **3000** | pass (in the cache) | 7 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | 3200 | drops from 4.91 GB | full |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 1-7 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 7 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3000** | pass (in the cache) | 7 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 7 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 1000-2500 (7 steps) | pass, all | 1-4 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | **2750** | pass (highest burst) | 6 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 3000 | drops from 9.14 GB (above the drive's ~2.94 GB/s write rate on Gen3 x4) | full |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | **2750** | pass (in the cache) | 6 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | 3000 | drops from 9.97 GB | full |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 1-7 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 7 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3000** | pass (in the cache) | 7 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 7 |

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): no step failed. Both layouts record 10 GB and
  40 GB at 3.2 GB/s, the generator maximum.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`): no step failed. One drive and the RAID0 pair burst
  10 and 40 GB at 3200 MB/s, the generator maximum; every 10 GB step from 1000 MB/s was clean
  (high-water mark 1-7).
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): one drive bursts 10 and 40 GB at 3000 MB/s
  (3200 MB/s exceeds its ~3.04 GB/s write rate on Gen3 x4). RAID0 records 10 and 40 GB at the
  generator's 3200 MB/s, and 32 GB at 2750, 3000 and 3200 MB/s in 5 of 5 runs (high-water marks
  6-7).
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): one drive bursts 10 and 40 GB at 2750 MB/s
  (3000 MB/s exceeds its ~2.94 GB/s write rate on Gen3 x4: drops from 9.14 and 9.97 GB). RAID0
  records 10 and 40 GB at the generator's 3200 MB/s, and 40 GB at 3000 MB/s.

### Long recordings past the SLC cache

For the 1 TB drives a 32 GB or 40 GB recording stays inside the SLC cache, so the rate that
holds for a long recording was measured with single recordings of about 1.5 to three times
the cache (fresh XFS, `rm` + `fstrim` and **300 s** of idle before each, 32 x 8 MB buffers). Sizes are the
`fdrec --size` values (GiB), with GB (10⁹ bytes) in brackets. In most of these recordings the
ingest FIFO high-water mark was also read and cleared every second while the recording ran;
the table gives the highest of those samples. For the 143 GiB recording at 1750 MB/s on
`vck190_fmcp1` and the 219 GiB and 222 GiB recordings it is `fdrec`'s own figure, and for the
480 GiB recordings at 3000 and 3200 MB/s the highest of the 10 s statistics.

| target | SSD | layout | recording | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | first gap |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 143 GiB (153.5 GB, ~2x the cache) | 1000 | pass, `fdverify` PASS | 0 | 1 | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 143 GiB | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 200 GiB (214.7 GB, ~2.9x the cache) | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 200 GiB | 2000 | drops | 764 364 890 | full | 96.11 GB (the cache end; one isolated gap of 35 196 beats at 1.65 GB before it) |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 240 GiB (257.7 GB, ~1.8x the cache) | **2750** | pass, `fdverify` PASS | 0 | 6 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | 2500 | pass, `fdverify` PASS | 0 | 4 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | 2750 | pass, `fdverify` PASS | 0 | 6 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | 3000 | pass, `fdverify` PASS | 0 | 7 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3200** | pass, `fdverify` PASS | 0 | 7 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB (257.7 GB, ~2.1x the cache) | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB | 2000 | drops | 978 093 034 | full | 126.03 GB (the cache end) |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 219 GiB (235.1 GB, after a 300 GiB fio write and 300 s idle) | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB (515.4 GB, ~2x the pair's cache) | 2250 | pass, `fdverify` PASS | 0 | 3 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2500 | pass, `fdverify` PASS | 0 | 4 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2750 | pass, `fdverify` PASS | 0 | 6 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 3000 | pass, `fdverify` PASS | 0 | 7 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | **3200** | pass, `fdverify` PASS | 0 | 7 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB (214.7 GB, ~1.8x the cache) | 3000 | drops | 3 919 574 609 | full | 121.91 GB (the cache end) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | 3200 | drops (above the drive's write rate) | 4 873 386 810 | full | 0.90 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | 2000 | drops (past the cache, TLC ~1.77 GB/s) | 631 940 198 | full | 126.65 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 222 GiB (238.4 GB, ~2x the cache) | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~1.5x the pair's cache) | **2500** | pass, `fdverify` PASS | 0 | 4 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **2750** | pass, `fdverify` PASS | 0 | 6 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **3000** | pass, `fdverify` PASS | 0 | 7 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **3000** (repeat) | pass, `fdverify` PASS | 0 | 7 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **3200** | pass, `fdverify` PASS | 0 | 7 | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB (214.7 GB, ~3x the cache) | 3000 | drops (above the drive's write rate) | 5 574 583 047 | full | 3.76 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | 2000 | drops (past the cache, ~1.81 GB/s) | 794 648 136 | full | 90.30 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 2 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | **2500** | pass, `fdverify` PASS | 0 | 4 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **2750** | pass, `fdverify` PASS | 0 | 6 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3000** | pass, `fdverify` PASS | 0 | 7 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3200** | pass, `fdverify` PASS | 0 | 7 | - |

* **Sabrent Rocket 2230 1TB on `vck190_fmcp1`**: the ~70-75 GB cache shows. One drive holds
  1750 MB/s over 143 GiB and 200 GiB (2000 MB/s drops from 96.11 GB, just past the cache: the
  post-cache rate is ~1.8 GB/s, see [The SLC cache](#the-slc-cache)); writes in flight were
  0-5 per 10 s sample at 1750 MB/s. The 2000 MB/s run also had one isolated gap at 1.65 GB, a
  write stall longer than the ring lasts at that rate. The RAID0 pair recorded 2500, 2750, 3000
  and 3200 MB/s cleanly over 350 GiB and 2750 MB/s over 240 GiB (one run each), with 0-4 writes
  in flight in every 10 s sample (at most 8 of 32 buffers). The FIFO high-water mark, read
  every second, was 4, 6, 7 and 7 beats in every sample of the 350 GiB runs (1 and 2 for the
  single drive).
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, single**: 1750 MB/s holds over 240 GiB (and over
  219 GiB after a 300 GiB fio write); 2000 MB/s drops from 126.03 GB, where the cache ends (the
  drive then writes ~1.77-1.80 GB/s). Up to the cache end 0-1 writes were in flight, after it
  8 (the queue full) at 2000 MB/s; at 1750 MB/s the margin is about 1 % (post-cache median
  1766 MB/s) and one 10 s sample just past the cache end had 8 writes in flight without a drop.
  The FIFO high-water mark, read every second, was 2 beats in every sample of the 1750 MB/s
  run.
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, RAID0**: the pair recorded 480 GiB at 2250, 2500,
  2750, 3000 and 3200 MB/s (the generator maximum) with 0 drops, one run each, with at most 8
  of 32 buffers in flight. The FIFO high-water mark was 3, 4, 6, 7 and 7 beats in every sample
  (1 s samples at 2250-2750 MB/s, 10 s statistics at 3000-3200 MB/s), inside the cache, at its
  end and past it.
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, single**: 1750 MB/s holds over 200 GiB and 222 GiB;
  2000 MB/s drops from 126.65 GB, just past the cache (the drive then writes ~1.78-1.81 GB/s),
  and 3000 MB/s from 121.91 GB, where the cache ends. Up to the cache end 0-1 writes were in
  flight, after it up to 4-8: the margin at 1750 MB/s is about 1 % (the post-cache rate is
  1771 MB/s, median). Every first gap starts 262 256 bytes after a buffer boundary with the
  io_uring queue full: the drive, not the DMA.
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, RAID0**: 2500, 2750, 3000 (twice) and 3200 MB/s hold
  over 350 GiB with 0 drops; the FIFO high-water mark, read every second while the recording
  ran, was 4, 6, 7, 7 and 7 beats. Writes in flight were 0-1 in most 10 s samples (at most 8 of
  32 buffers).
* **Sabrent Rocket 2230 1TB on `zcu106_hpc0`, single**: one drive holds 1750 MB/s over
  200 GiB (high-water mark 2 in every 1 s sample, 0-3 writes in flight per 10 s sample).
  2000 MB/s drops from 90.30 GB, past the cache, where the drive writes 1803-1819 MB/s;
  3000 MB/s drops from 3.76 GB, above its ~2.94 GB/s in-cache rate on Gen3 x4. The margin at
  1750 MB/s is about 3 % (post-cache median 1805 MB/s, fio). At 2000 MB/s the cache lasted to
  ~90 GB, longer than the ~69-70 GB that fio fills at full speed (on `vck190_fmcp1`: 96.11 GB).
  Every first gap starts 262 256 bytes after a buffer boundary with the io_uring queue full:
  the drive, not the DMA.
* **Sabrent Rocket 2230 1TB on `zcu106_hpc0`, RAID0**: the pair recorded 2500, 2750, 3000 and
  3200 MB/s cleanly over 350 GiB (one run each), with 0-3 writes in flight in every 10 s
  sample. The FIFO high-water mark, read every second, was 4, 6, 7 and 7 beats in every sample
  of these runs.

### Playback

Design 1.1 (AXI DMA MM2S, 4096-beat egress FIFO, `fdrec_check` sink), XFS, `fdplay` with
queue depth 8. Each run plays a 10 GB test-pattern recording made at 1000 MB/s with 0 drops.
"Runs" lists underflow-free runs / runs at that rate.

| target | SSD | layout | buffers | highest clean playback rate | runs | first rate with underflows | read fio reference |
|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean; 3 of 3 at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s with each buffer count) | none (no higher rate exists) | 4446 and 4041 MB/s; 4521 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean; 3 of 3 at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s with each buffer count) | none (no higher rate exists) | 4312 and 4274 MB/s; 7820 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean; 3 of 3 at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s with each buffer count) | none (no higher rate exists) | 4730 and 4517 MB/s; 6309 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean; 3 of 3 at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s with each buffer count) | none (no higher rate exists) | 4591 and 4246 MB/s; 7936 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean) | none (no higher rate exists) | 3054 and 3153 MB/s (fio CPU-bound); 6022 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean) | none (no higher rate exists) | 3014 and 3032 MB/s (fio CPU-bound); 3183 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **3000 MB/s** | 3/3 each (every sweep step from 1000 MB/s clean) | 3200 MB/s (3 359 878 and 3 252 026 ticks with 32 buffers, 9 879 003 and 12 607 744 with 16, sweep and recheck: above the slot's ~3.12 GB/s read rate on Gen3 x4) | 2841 and 2876 MB/s (fio CPU-bound); 3124 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each (every sweep step from 1000 MB/s clean) | none (no higher rate exists) | 2755 and 2878 MB/s (fio CPU-bound); 5128 MB/s with hugepage fixed buffers |

All rows were measured on 2026-10-21 with 10 GB playbacks.

With the Sabrent Rocket 2230 1TB pair (Gen4 x4 on `vck190_fmcp1`) one drive and the RAID0 pair
play back at the 3.2 GB/s sink maximum, with 32 or 16 buffers: 80 of 80 runs from 1000 to
3200 MB/s were clean. fio without fixed buffers is CPU-bound at ~4.0-4.4 GB/s on this board;
with hugepage fixed buffers it reads one drive at 4521 MB/s and the RAID0 at 7820 MB/s.

The Samsung 980 PRO 1TB pair (Gen4 x4 on `vck190_fmcp1`) plays back at the 3.2 GB/s sink maximum
from one drive and from RAID0, with 32 or 16 buffers: 80 of 80 runs from 1000 to 3200 MB/s were
clean (every sweep step, then 3 of 3 runs at 2500, 2750 and 3000 MB/s and 5 of 5 at 3200 MB/s
in each configuration). fio reads one drive at 6309 MB/s and the pair at 7936 MB/s with
hugepage fixed buffers.

On `zcu106_hpc0` the 980 PRO 1TB, single or in RAID0, plays back at the 3.2 GB/s sink maximum
with 32 or 16 buffers: 48 of 48 sweep runs from 1000 to 3200 MB/s were clean (fio reads the
same file at 3014-3032 MB/s from one drive, CPU-bound, and at 3183 MB/s with hugepage fixed
buffers), and so were 17 of 17 further single-drive runs at 2500-3200 MB/s.

The Sabrent Rocket 2230 1TB on `zcu106_hpc0` plays back at 3000 MB/s from one drive (3200 MB/s
is above what one Gen3 x4 slot reads, ~3.12 GB/s even with fixed buffers, so it underflows
every time) and at the 3.2 GB/s sink maximum from RAID0, with 32 or 16 buffers: all 52 runs at
or below those rates were clean. fio without fixed buffers is CPU-bound on this board
(2.75-2.9 GB/s); with hugepage fixed buffers it reads one drive at 3124 MB/s and the pair at
5128 MB/s.

Read fio reference: `fio --name=rd --filename=<the recording> --readonly --rw=read --bs=8M
--direct=1 --ioengine=io_uring --iodepth=8 --size=10G` on the same filesystem; "hugepage fixed
buffers" adds `--iomem=mmaphuge --fixedbufs`, which is how `fdplay` reads (hugepage buffers
registered with io_uring).

Functional checks of `fdplay` (design 1.1, 10 GB test-pattern recordings unless stated):

| measurement | result |
|---|---|
| 10 GB clean recording, `--rate 1000MB` | 10.83 s on `zcu106_hpc0` (10.80 s on `vck190_fmcp1`), beats 671 088 640, errors 0, gaps 0, gap beats 0, underflows 0, last seq 671 088 639, egr_discard 0 |
| 10 GB recording made at 3200 MB/s on one 980 PRO on `zcu106_hpc0` (drop count 19 453 644, 681 discontinuities in `fdverify`), `--rate 500MB` | 21.56 s, beats 671 088 640, errors 0, gaps 681, gap beats 19 453 644, underflows 0 |
| `--rate` above what the SSDs and the ring deliver | underflow ticks counted by the checker; exit code 2 (22 238 ticks at 3200 MB/s with a 2-buffer ring on `vck190_fmcp1`) |
| 256 MB recording resident in the ring (32 x 8 MB, 64 x 4 MB), `--rate 3200MB` | 0 underflows over 31 and 63 buffer boundaries at the full sink rate, 2 of 2 runs each on both targets |
| Ctrl-C (SIGINT) after 4 s at 1000 MB/s (all four setups) | exit code 1 within 0.11 s of the signal, 3.83-3.88 GB played, egr_discard 1 057 486-1 567 462 beats (the flushed in-flight buffers), no `Cannot stop channel`; the next playback is complete with 0 underflows |
| Checker prime wait (driver, at most 100 ms) | never timed out (no `did not prime` message in any playback; about 150 playbacks in each of the two full sessions) |

### CPU load

Measured per core from `/proc/stat` over 10 GB transfers at 1000 MB/s (two runs each,
32 x 8 MB buffers), and per process. On `vck190_fmcp1` (two Cortex-A72 cores):

| transfer | per core (busy) | transfer process |
|---|---|---|
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | run 1: core 0 8.2 %, core 1 9.5 %; run 2: core 0 10.8 %, core 1 7.2 % | `fdrec` 16.2–16.3 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent) | core 0 8.6–10.0 %, core 1 8.2–9.4 % | `fdrec` 16.7–16.8 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | run 1: core 0 8.5 %, core 1 5.6 %; run 2: core 0 2.7 %, core 1 11.4 % | `fdplay` 12.4–12.5 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent) | runs on one core (13.4 / 12.0 %; the other 0.6 / 1.4 %) | `fdplay` 11.9–12.0 % of one core |
| `fdrec`, 1000 MB/s to the Samsung 980 PRO 1TB | run 1: core 0 10.1 %, core 1 6.6 %; run 2: core 0 4.9 %, core 1 11.7 % | `fdrec` 15.5 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | core 0 8.9–9.8 %, core 1 8.1–8.6 % | `fdrec` 16.2–16.4 % of one core |
| `fdplay`, 1000 MB/s from the Samsung 980 PRO 1TB | runs on one core (12.4 / 10.9 %; the other 0.8 / 2.6 %) | `fdplay` 11.8–11.9 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | runs on one core (12.0 / 11.8 %; the other 1.5 / 1.4 %) | `fdplay` 12.2–12.3 % of one core |

Nearly all of it is system time; the core the app runs on shows 48–87 % I/O wait (waiting, not
busy). A `top` cross-check gave the same per-process figures: `fdrec` 13.4–16.8 %, `fdplay`
10.7–13.1 % of one core. Both drives cost about the same: the load follows the rate.

On `zcu106_hpc0` (four Cortex-A53 cores at 1.2 GHz), same method (10 GB at 1000 MB/s, two runs,
32 x 8 MB buffers), the load spreads mostly over two cores (the app's thread and the core
taking the DMA / NVMe interrupts):

| transfer | busy, summed over the cores | share of the 4-core total | transfer process |
|---|---|---|---|
| `fdrec`, 1000 MB/s to the 980 PRO 1TB | 25.3–25.6 % of one core | about 6.5 % | `fdrec` 23.6 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | 26.9–27.1 % of one core | about 7 % | `fdrec` 25.0–25.4 % of one core |
| `fdplay`, 1000 MB/s from the 980 PRO 1TB | 20.1–20.3 % of one core | about 5 % | `fdplay` 16.5–16.6 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | 22.6–24.6 % of one core | about 6 % | `fdplay` 20.4–22.1 % of one core |
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | 26.6–27.1 % of one core | about 6.7 % | `fdrec` 24.7 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent Rocket 2230 1TB) | 28.0–28.5 % of one core | about 7 % | `fdrec` 25.6 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | 22.2–22.6 % of one core | about 5.6 % | `fdplay` 19.0 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent Rocket 2230 1TB) | 21.3–22.6 % of one core | about 5.5 % | `fdplay` 18.6 % of one core |

The rows were cross-checked with `top` (`fdrec` 21.4–25.2 %, `fdplay` 16.1–22.6 % of one core);
during `fdplay` the I/O wait sits on one or two cores (33–79 % on the busiest). At higher rates
`fdrec` uses 66–68 % of one core at 3000 MB/s (one 980 PRO), 69–73 % at 3000 MB/s (980 PRO
RAID0) and 78 % at 3200 MB/s (980 PRO RAID0, 32 GB), and `fdplay` 56 % at 3000 MB/s (one
980 PRO) and 56–59 % (980 PRO RAID0). With the Sabrent drives `fdrec` uses 66 % at 2750 MB/s
(one drive, 32 GB), 70 % at 3000 MB/s (one drive, 4000 MiB), 75 % at 3000 MB/s and 78 % at
3200 MB/s (RAID0), and `fdplay` 62 % (one drive) and 55 % (RAID0) at 3000 MB/s; see
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
  70-75 GB on an empty, trimmed drive on `vck190_fmcp1`, then a flat ~1.8 GB/s (1774-1825 MB/s
  from 80 to 320 GB). On `zcu106_hpc0` it writes into the cache at ~2.9 GB/s (the Gen3 x4
  link) for ~69-70 GB and then the same flat ~1.8 GB/s (median 1805 MB/s, against 1804 on
  `vck190_fmcp1`): the cache and the post-cache rate are the drive's. This sets its sustained
  single-drive rate on both boards: 1750 MB/s (over 143 and 200 GiB on `vck190_fmcp1`, over
  200 GiB on `zcu106_hpc0`; 2000 MB/s drops just past the cache, see
  [Long recordings](#long-recordings-past-the-slc-cache)). The pair caches ~136-143 GB on
  `vck190_fmcp1` and then writes a flat ~3.6 GB/s, above the generator maximum. On
  `zcu106_hpc0` one fio job writes only ~3.2 GB/s to the pair (CPU-bound), below that
  post-cache rate, so no knee shows there in 534 GB.
* The **Samsung 980 PRO 1TB** caches about 115-125 GB on an empty, trimmed drive, on both
  boards. It writes into the cache at ~4.7 GB/s on `vck190_fmcp1` (Gen4 x4; fio CPU-bound, a
  lower bound for the drive) and ~2.99 GB/s on `zcu106_hpc0` (the Gen3 x4 link), and at a flat
  **~1.77 GB/s** after it on both boards (median 1766 MB/s on `vck190_fmcp1`, 1771 MB/s on
  `zcu106_hpc0`). The pair caches ~245 GB on `vck190_fmcp1` and then writes a flat
  ~3.46 GB/s; on `zcu106_hpc0` one fio job writes ~3.4-3.5 GB/s to the pair, so only a 5 % knee
  shows, at ~236-256 GB. One drive records 1750 MB/s cleanly past the cache on both boards,
  2000 MB/s only until the cache ends. This is the drive's TurboWrite cliff.

Measured with one sequential fio write (queue depth 8, 8 MB blocks, `O_DIRECT`) on a freshly
created XFS, 60 s of idle first, bandwidth logged every 2 s:

| SSD | target | layout | written | rate inside the cache | cache size (empty, trimmed) | rate after the cache |
|---|---|---|---|---|---|---|
| Sabrent Rocket 2230 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.5-4.6 GB/s | **~70-75 GB** (full rate to 64 GB, down to the post-cache rate by 74 GB) | **~1.8 GB/s**, flat (1774-1825 MB/s from 80 to 320 GB, median 1804) |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.5 GB/s (fio CPU-bound) | **~136-143 GB** (~70 GB per drive) | **~3.6 GB/s**, flat (3406-3654 MB/s, median 3599) |
| Sabrent Rocket 2230 1TB | `zcu106_hpc0` | single | 300 GiB | 2840-2921 MB/s (the Gen3 x4 link) | **~69-70 GB** (full rate to 64 GB, down to the post-cache rate by 73 GB) | **~1.8 GB/s**, flat (1777-1831 MB/s from 80 to 320 GB, median 1805) |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3105-3355 MB/s, median 3207 (fio CPU-bound) | not visible (no knee in 534 GB: one fio job writes below the pair's post-cache rate) | not visible (~3.2 GB/s throughout, fio-bound) |
| Samsung 980 PRO 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.7 GB/s (fio CPU-bound: a lower bound for the drive) | **~115-125 GB** (full rate to 114 GB, flat from 129.5 GB) | **~1.77 GB/s**, flat (1719-1814 MB/s, median 1766) |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.7 GB/s (fio CPU-bound) | **~245 GB** (~122 GB per drive; full rate to 227 GB, a knee to 245 GB, flat from 259 GB) | **~3.46 GB/s**, flat (3372-3520 MB/s, median 3462) |
| Samsung 980 PRO 1TB | `zcu106_hpc0` | single | 300 GiB | 2978-2999 MB/s (the Gen3 x4 link) | **~115-125 GB** (full rate to ~114 GB, flat from 128 GB) | **~1.77 GB/s**, flat (1716-1825 MB/s, median 1771) |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3358-3521 MB/s (fio CPU-bound) | **~250 GB** (a 5 % knee, 236-256 GB) | ~3.30 GB/s (3240-3331 MB/s; partly fio-bound) |

The cache size and the post-cache rate are properties of the drive: measured on both boards,
they agree within a few percent. The in-cache rate is the Gen3 x4 link's for one drive on
`zcu106_hpc0`, and fio's on `vck190_fmcp1` and for the RAID0 pairs on `zcu106_hpc0` (one fio
thread is CPU-bound there). None of the drives throttled (fan on the cards).

**In-cache and post-cache rates.** A recording shorter than the cache only needs the
in-cache rate; a longer one needs the post-cache rate, and the 32 GB sweep shows only the
first for the 1 TB drives. The cache refills only while the drive is idle (how fast was not
measured), so back-to-back recordings may not each get a full cache. Size the rate for the
longest recording you need: a short burst test, such as a 10 GB recording, a 4 GB `dd`, or
fio over 32 GB (entirely inside the cache of these 1 TB drives), overstates what a drive
sustains.

## The fstrim finding and the ring size

`fstrim` run **immediately** before a recording can stall its first writes: the SSDs are still
processing the discards. With the 16 x 8 MB ring (128 MB, 75 ms at 1.7 GB/s) that is enough to
run the ring dry and overflow the FIFO. Waiting after `fstrim`, not trimming, or the default
ring of 32 x 8 MB (256 MB) each removed the gap. This is why `fdrec` defaults to 32 x 8 MB
buffers, and why the benchmark steps wait after trimming.

Measured with the Samsung 980 PRO 1TB pair on `zcu106_hpc0` (RAID0, 512K chunk), 10 GB
recordings at 1700 MB/s, `fdrec --stats 0.1`. "Trim" is `rm` of the previous file, `sync` and
`fstrim /mnt/rec`; "idle" is the pause between that and `fdrec`:

| filesystem | before the run | buffers | recordings with drops |
|---|---|---|---|
| XFS | trim, no idle | 16 x 8 MB | **2 of 3** (13 397 425 beats, first gap 128 MiB + 262 256 bytes into the data; 1 574 088 beats in 4 gaps, the first at 256 MiB + 262 256 bytes) |
| XFS | trim, no idle | 32 x 8 MB | 0 of 3 |
| XFS | trim, idle 15 s | 16 x 8 MB | 0 of 2 |
| XFS | no trim (`rm` + `sync` only) | 16 x 8 MB | 0 of 2 |

* The first gap of both failing runs starts 16384 + 7 beats after a buffer boundary, with the
  ring exhausted: the first writes had not completed in time. One of the clean 32-buffer runs
  wrote 0 bytes in its first 0.2 s and still held. `fstrim` itself returned in 0.02-0.25 s
  on XFS. The FIFO high-water mark of every clean run was 2 beats.
* `fdrec` opens the output with `O_TRUNC` and preallocates it with `posix_fallocate`, so
  recording over an existing file starts from freshly allocated (unwritten) extents, the same
  as a new file.
* The `fifo_hwm` and `drop_count` sysfs attributes read 0 once `fdrec` has exited (the driver
  resets the core on close); read them from `fdrec`'s `RESULT` line.

Ring size, 32 GB recordings on one drive (fresh XFS, `rm` + `fstrim` + 60 s idle before each):

| SSD | target | ring | rate (MB/s) | recordings with drops | FIFO high-water (beats) |
|---|---|---|---|---|---|
| Sabrent Rocket 2230 1TB | `vck190_fmcp1` | 32 x 8 MB (default) | 750, 1000 | 0 of 3 at each rate | 1 |
| Samsung 980 PRO 1TB | `zcu106_hpc0` | 32 x 8 MB (default) | 750, 1000 | 0 of 3 at each rate | 1 |
| Samsung 980 PRO 1TB | `zcu106_hpc0` | 64 x 8 MB (512 MB) | 1250, 1500, 1750 | 0 of 1 at each rate | 1, 1, 2 |

At these rates the ring size made no difference on either drive. `fdrec` accepts at most 64
buffers.

## Comparison with fpga-drive-aximm-pcie (dd method)

The [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
reference design measures SSD throughput with four `dd` scripts, which are also in this
design's image (see [Test the design in Linux](linux_test.md#4-measure-the-ssds-with-the-dd-speed-test-scripts)).
This section compares the two methods on the same board, SSDs and image.

### At a glance

All figures in MB/s (10⁶ bytes/s), measured 2026-10-21 (see [Setups](#setups)).
**b** = burst (the write fits inside the drive's SLC write cache), **s** = sustained (the
recording ran past the cache). Reads have no cache effect. The 32 GB columns are inside the
cache of these drives (**b**), so the "fdrec sustained" cell also gives the rate that held over
a recording past the cache.

| target / config | WRITE: drive ceiling (fio QD8, 4 GB) | WRITE: dd script (4 GB) | WRITE: fdrec highest clean (4 GB) | WRITE: dd (32 GB) | WRITE: fdrec sustained (32 GB) | READ: drive ceiling (fio QD8, 4 GB) | READ: dd script (4 GB) | READ: fdplay highest clean (4 GB) |
|---|---|---|---|---|---|---|---|---|
| vck190: Sabrent Rocket 2230 1TB (Gen4 x4) | 4414 **b** (fio CPU-bound) | 1503 **b** | 3000 **b** (top step; 16 buffers: 3000 in 1 of 3) | 2056 **b** (inside the ~70-75 GB cache) | 3200 **b**; past the cache (143 and 200 GiB): **1750 s** | 4040 (fio CPU-bound; 4521 with fixed buffers, 10 GB) | 3201 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 4347 **b** (fio CPU-bound) | 2139 **b** | 3000 **b** (top step; 16 buffers: 2000) | 1981 **b** (one run) | 3200 **b**; past the cache (350 GiB): **3200 s** (2500 to 3200 clean, one run each) | 3984 (fio CPU-bound; 7820 with fixed buffers, 10 GB) | 3302 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| vck190: Samsung 980 PRO 1TB (Gen4 x4) | 4756 **b** (fio CPU-bound) | 1678 **b** | 3000 **b** (top step; 16 buffers: 3000) | 2072 **b** (inside the ~115-125 GB cache) | 3200 **b**; past the cache (219 and 240 GiB): **1750 s** | 4540 (fio CPU-bound; 6309 with fixed buffers, 10 GB) | 2496 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 4715 **b** (fio CPU-bound) | 2118 **b** | 3000 **b** (top step; 16 buffers: 3000) | 2222 **b** (one run) | 3200 **b**; past the cache (480 GiB): **3200 s** (2250 to 3200 clean, one run each) | 4265 (fio CPU-bound; 7936 with fixed buffers, 10 GB) | 3813 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| zcu106: Samsung 980 PRO 1TB (Gen3 x4) | 2956 **b** | 1451 **b** | 3000 **b** (top step; 16 buffers: 3000) | 1436 **b** (inside the ~115 GB cache) | 3000 **b**; past the cache (200 GiB): **1750 s** | 2946 (fio CPU-bound; 3183 with fixed buffers, 10 GB) | 1960 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 3492 **b** (fio CPU-bound) | 1671 **b** | 3000 **b** (top step; 16 buffers: 3000) | 1615 **b** (one run) | 3200 **b**; past the cache (350 GiB): **3200 s** (2500 to 3200 clean, 3000 twice) | 2930 (fio CPU-bound; 6022 with fixed buffers, 10 GB) | 2605 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |
| zcu106: Sabrent Rocket 2230 1TB (Gen3 x4) | 2778 **b** | 1389 **b** | 3000 **b** (top step, ring-assisted: 2866 MB/s achieved, the drive writes ~2.94 GB/s; 16 buffers: 2750 in 2 of 3) | 1549 **b** (inside the ~69-70 GB cache) | 2750 **b**; past the cache (200 GiB): **1750 s** | 2910 (fio CPU-bound; 3124 with fixed buffers, 10 GB) | 2219 | 3000 (top step; 16 buffers: 3000; 10 GB: 3000, 3200 underflows) |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 3237 **b** (fio CPU-bound) | 1398 **b** | 3000 **b** (top step; 16 buffers: 2000 in 2 of 3) | 1629 **b** (one run) | 3200 **b**; past the cache (350 GiB): **3200 s** (2500 to 3200 clean, one run each) | 2722 (fio CPU-bound; 5128 with fixed buffers, 10 GB) | 2162 | 3000 (top step; 16 buffers: 3000; 10 GB: 3200, the sink maximum) |

| target / config | dd write: rate / % of one core / MB/s per % core | fdrec: rate / % of one core / MB/s per % core |
|---|---|---|
| vck190 (Cortex-A72, 1.4 GHz): Sabrent Rocket 2230 1TB | 1503 / 57 % / 27 | 2978 / 49 % / 61 |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 2139 / 87 % / 25 | 2978 / 50 % / 59 |
| vck190: Samsung 980 PRO 1TB | 1678 / 64 % / 26 | 2978 / 46 % / 65 |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 2118 / 87 % / 24 | 2979 / 49 % / 61 |
| zcu106 (Cortex-A53, 1.2 GHz): Samsung 980 PRO 1TB | 1451 / 69 % / 21 | 2974 / 68 % / 44 |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 1671 / 88 % / 19 | 2977 / 73 % / 41 |
| zcu106: Sabrent Rocket 2230 1TB | 1389 / 65 % / 21 | 2866 / 70 % / 41 |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 1398 / 80 % / 18 | 2975 / 75 % / 40 |

Selection rule: dd and fio cells are the median of three runs at their own speed (one run where
marked); `fdrec` / `fdplay` cells are the highest 250 MB/s step that was clean over 4000 MiB (0
drops / 0 underflows) and, in the CPU table, the rate it achieved; "fdrec sustained" is the
highest clean step of the 32 GB [fdbench.sh sweep](#sustained-recording-rate). The recorder rows
used the shipped default of 32 x 8 MB buffers (the 16-buffer result is given where it differs).
The `fdrec` and `fdplay` sweeps stop at 3000 MB/s, the last 250 MB/s step below the 3.2 GB/s
generator and sink maximum. The 16-buffer `fdrec` cells of the Sabrent drives (on `vck190_fmcp1`
3000 single in 1 of 3 runs and 2000 RAID0, on `zcu106_hpc0` 2750 single and 2000 RAID0 in 2 of
3 runs each) are decided by drive write stalls longer than the 128 MB ring (8 writes in flight
when it ran out); the 32 GB and 10-40 GB recordings are the better guide there. The 3000 MB/s
cell of one Sabrent on `zcu106_hpc0` is clean (3 of 3) only because the 256 MB ring absorbs the
drive's deficit over 4000 MiB: the drive writes ~2.94 GB/s on its Gen3 x4 link, the recording
achieves 2866-2884 MB/s with all 8 writes in flight, and every longer recording at 3000 MB/s
drops (10 GB from 9.14 GB, 32 GB from 4.91 GB, 200 GiB from 3.76 GB). Its in-cache rate is
2750 MB/s, as the 32 GB column shows.

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
writes faster than the recorder can feed it: fio writes 4.3-4.6 GB/s (fio itself CPU-bound),
`fdrec` is clean at the 3000 MB/s top step over 4 GB on one drive, and 10 GB and 40 GB
recordings pass at the 3.2 GB/s generator maximum. Here the generator, not the SSD, sets the
burst rate, and a single `dd` write is CPU-bound on one A72 core (~2.0 GB/s at 75-83 % of a
core in the variations below). The Samsung 980 PRO 1TB on `vck190_fmcp1` behaves the same way:
fio writes 4.7-4.8 GB/s (CPU-bound), `fdrec` is clean at the 3000 MB/s top step on one drive
and on RAID0, with 32 and with 16 buffers, and 10 GB and 40 GB recordings pass at 3.2 GB/s.
On `zcu106_hpc0` (Gen4 drives on Gen3 Root Ports) the Samsung 980 PRO 1TB runs at its Gen3 x4
link's rate inside the cache: it writes 2956-2970 MB/s per slot (fio 4 GB) and reads
2940-3172 MB/s (raw device). One drive records 32 GB at 3000 MB/s, the RAID0 pair at
3200 MB/s, and the drive shows its ~115-125 GB cache and ~1.77 GB/s post-cache rate. The
Sabrent Rocket 2230 1TB also runs at its link's rate there: it writes 2737-2837 MB/s (fio 4 GB)
and 2928-2950 MB/s at the 3000 and 3200 MB/s sweep steps, and reads 2929-3156 MB/s (raw
device). One drive records 32 GB at 2750 MB/s, the RAID0 pair at 3200 MB/s, and the drive
shows its ~69-70 GB cache and ~1.8 GB/s post-cache rate.

### Method

Measured with both pairs (Sabrent and 980 PRO) on both `vck190_fmcp1` and `zcu106_hpc0`, all
on 2026-10-21, with the images of [Setups](#setups) (register map 1.1, driver 1.2).
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
Sabrent Rocket 2230 1TB rows (two drives on the M.2 M-key Stack FMC, measured 2026-10-21)
and the Samsung 980 PRO 1TB rows (two drives on the FPGA Drive FMC Gen4, also measured
2026-10-21) linked at **Gen4 x4** (16 GT/s, `LnkSta` of Root Port and SSD). "Sabrent" is one
Sabrent Rocket 2230 1TB, "980 PRO" one Samsung 980 PRO 1TB. Same method as above, with 60 s of
idle time after each `mkfs`. `fdrec` / `fdplay` used the shipped default of **32 x 8 MB
buffers**; 16-buffer runs were added for comparison. The board has **two** cores, so the total CPU column is a share of two cores
(50 % = one full core); the per-process column (% of one core) and MB/s per % core are directly
comparable with `zcu106_hpc0`.

| method | config | direction | size | MB/s | total CPU % of 2 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | Sabrent | write | 4000 MiB | 1503 [1339–2035] | 0.3 / 27.7 / 0.0 / 9.7 | 57 [50–77] | 27 |
| dd (script) | Sabrent | read | 4000 MiB | 3201 [3130–3225] | 0.0 / 28.5 / 4.5 / 13.2 | 54 [51–55] | 59 |
| dd (script) | Sabrent RAID0 | write | 4000 MiB | 2139 [1322–2267] | 0.3 / 42.7 / 2.5 / 3.3 | 87 [54–87] | 25 |
| dd (script) | Sabrent RAID0 | read | 4000 MiB | 3302 [2605–3584] | 0.3 / 30.0 / 12.8 / 6.6 | 70 [56–78] | 47 |
| dd (dual script) | both Sabrent drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 3251 [2786–3277] | 0.0 / 72.3 / 2.9 / 16.9 | 142 [121–144] | 23 |
| dd (dual script) | both Sabrent drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 5825 [4194–5866] | 0.0 / 56.1 / 11.5 / 18.7 | 119 [81–124] | 49 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | Sabrent | record | 4000 MiB | 2978 | 0.0 / 25.2 / 0.7 / 24.6 | 49 [48–49] | 61 |
| `fdrec` at 3200 (32 buffers) | Sabrent | record | 32 GB | 3197 | 0.3 / 24.2 / 0.4 / 28.4 | 46 | 69 |
| `fdrec` at 3000 (16 buffers; clean 1 of 3) | Sabrent | record | 4000 MiB | 2977 | sys 25.3 | 47 | 63 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | Sabrent RAID0 | record | 4000 MiB | 2978 | 0.0 / 26.2 / 0.7 / 28.0 | 50 [50–50] | 59 |
| `fdrec` at 3200 (32 buffers) | Sabrent RAID0 | record | 32 GB | 3197 | 0.3 / 27.6 / 0.3 / 27.3 | 52 | 61 |
| `fdrec` at 2000, highest clean (16 buffers) | Sabrent RAID0 | record | 4000 MiB | 1990 | sys 17.5 | 33 | 60 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | Sabrent | play | 4000 MiB | 2875 | 0.0 / 18.9 / 0.0 / 26.4 | 36 | 79 |
| `fdplay` at 3000, top step (16 buffers) | Sabrent | play | 4000 MiB | 2934 | 0.3 / 18.3 / 0.0 / 26.6 | 35 | 84 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | Sabrent RAID0 | play | 4000 MiB | 2870 | 0.3 / 19.1 / 0.0 / 25.2 | 35 | 82 |
| `fdplay` at 3000, top step (16 buffers) | Sabrent RAID0 | play | 4000 MiB | 2903 | 0.3 / 18.5 / 0.0 / 25.7 | 33 | 87 |
| dd (script) | 980 PRO | write | 4000 MiB | 1678 [1678–1684] | 0.2 / 31.9 / 1.4 / 6.4 | 64 [64–66] | 26 |
| dd (script) | 980 PRO | read | 4000 MiB | 2496 [1815–3847] | 0.3 / 25.0 / 4.8 / 6.9 | 48 [30–75] | 52 |
| dd (script) | 980 PRO RAID0 | write | 4000 MiB | 2118 [1824–2161] | 0.3 / 41.9 / 2.7 / 4.3 | 87 [62–88] | 24 |
| dd (script) | 980 PRO RAID0 | read | 4000 MiB | 3813 [2605–3956] | 0.3 / 28.6 / 0.0 / 5.2 | 67 [55–75] | 57 |
| dd (dual script) | both 980 PRO drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 3289 [3238–3424] | 0.8 / 69.4 / 2.0 / 18.8 | 137 [136–139] | 24 |
| dd (dual script) | both 980 PRO drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 5592 [5446–5866] | 0.4 / 49.2 / 4.2 / 36.6 | 97 [93–98] | 58 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | 980 PRO | record | 4000 MiB | 2978 | 0.0 / 24.2 / 0.0 / 31.1 | 46 [46–46] | 65 |
| `fdrec` at 3200 (32 buffers) | 980 PRO | record | 32 GB | 3197 | 0.2 / 22.6 / 0.0 / 28.9 | 44 | 73 |
| `fdrec` at 3000, top step (16 buffers) | 980 PRO | record | 4000 MiB | 2978 | 0.0 / 23.5 / 0.0 / 31.2 | 45 [44–45] | 66 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | 980 PRO RAID0 | record | 4000 MiB | 2979 | 0.0 / 25.2 / 0.3 / 29.8 | 49 [48–49] | 61 |
| `fdrec` at 3200 (32 buffers) | 980 PRO RAID0 | record | 32 GB | 3197 | 0.1 / 26.3 / 0.2 / 28.8 | 50 | 64 |
| `fdrec` at 3000, top step (16 buffers) | 980 PRO RAID0 | record | 4000 MiB | 2979 | 0.3 / 24.5 / 0.0 / 30.9 | 47 [47–47] | 63 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | 980 PRO | play | 4000 MiB | 2908 | 0.0 / 14.0 / 0.0 / 21.1 | 27 [27–27] | 108 |
| `fdplay` at 3000, top step (16 buffers) | 980 PRO | play | 4000 MiB | 2951 | 0.3 / 18.3 / 0.0 / 28.4 | 34 [33–34] | 88 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | 980 PRO RAID0 | play | 4000 MiB | 2914 | 0.7 / 19.7 / 0.3 / 26.4 | 37 [37–37] | 80 |
| `fdplay` at 3000, top step (16 buffers) | 980 PRO RAID0 | play | 4000 MiB | 2949 | 0.4 / 18.3 / 0.0 / 27.1 | 35 [35–35] | 84 |

Notes:

* Raw script output (MiB/s, medians): write 1433, read 3053; RAID0 write 2040, read 3149; dual
  write 3100, read 5555 (aggregate). Every `dd` write is CPU-bound on one A72 core (one `dd`
  75–87 % in the variations and in the RAID0 script runs, two streams 139–159 %), not
  drive-bound.
* The first `dd` write runs after each `mkfs` and 60 s of idle were slow (one drive: 1277 and
  1433 MiB/s, then 1941; RAID0: 1261, then 2040 and 2162). Every later `dd` write ran at
  ~2.0 GB/s (see the variations), so the single-drive script median (1503 MB/s) understates
  the drive; the likely cause is the drives' background work after the whole-device discard of
  `mkfs.xfs`, which was not investigated. With 16 MiB blocks one `dd` writes 1997 MB/s to one
  drive and to the RAID0.
* Sabrent `fdrec`: clean at the 3000 MB/s top step 3/3 with 32 buffers on both layouts
  (2978 MB/s achieved, high-water mark 7), 1 of 3 with 16 buffers on one drive (the other two
  dropped 237 934 and 77 055 beats), and RAID0 to 2000 MB/s with 16 buffers (2250 dropped
  1 694 145 beats). Each failure had 8 writes in flight and the 128 MB ring exhausted: a drive
  write stall longer than 43 ms (3000 MB/s) or 57 ms (2250 MB/s). 3200 MB/s over 32 GB was
  clean on both layouts (high-water mark 7).
* Sabrent `fdplay`: 3000 MB/s 3/3 with 32 and with 16 buffers on both layouts (0 underflows in
  all 56 playbacks).
* At 1000 MB/s: `fdrec` 17 % (Sabrent) and 18 % (Sabrent RAID0) of a core, `fdplay` 13 / 13 %.
  Each Sabrent got two NVMe I/O queues (one per core).
* 980 PRO raw script output (MiB/s, medians): write 1600, read 2380; RAID0 write 2020, read
  3636; dual write 3137, read 5333 (aggregate). The `dd` writes are CPU-bound on one A72 core
  (62–90 % in the script and variation runs, two streams 145–154 %). The first `dd` reads
  after `mkfs` and 60 s of idle were slow (1731, 2380, then 3669 MiB/s; RAID0 first write 1739,
  first read 2484), so the single-drive read median (2496 MB/s) understates the drive.
* 980 PRO `fdrec`: clean at the 3000 MB/s top step 3/3 with 32 and with 16 buffers on both
  layouts (2978-2979 MB/s, high-water mark 7), and at every sweep step below it; 3200 MB/s over
  32 GB clean on both layouts (high-water mark 7).
* 980 PRO `fdplay`: 3000 MB/s 3/3 with 32 and with 16 buffers on both layouts (0 underflows in
  all 56 playbacks).
* At 1000 MB/s: `fdrec` 16 % (980 PRO) and 17 % (980 PRO RAID0) of a core, `fdplay` 12 / 13 %.
  Each 980 PRO got two NVMe I/O queues (one per core).

Variations (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| Sabrent | dd bs=1M | 1651 | 3084 | 80 / 62 |
| Sabrent | dd bs=16M | 1997 | 3848 | 77 / 63 |
| Sabrent | two dd streams on the drive (aggregate) | 3178 | 5866 | 139 / 105 |
| Sabrent | dd 32 GB (read: 1 run; inside the cache) | 2056 | 3770 | 83 / 75 |
| Sabrent RAID0 | dd bs=1M | 1417 | 3084 | 69 / 65 |
| Sabrent RAID0 | dd bs=16M | 1997 | 3779 | 75 / 75 |
| Sabrent RAID0 | two dd streams on the array (aggregate) | 3342 | 4584 | 159 / 108 |
| Sabrent RAID0 | dd 32 GB (1 run; inside the cache) | 1981 | 3704 | 82 / 74 |
| 980 PRO | dd bs=1M | 1536 | 2497 | 71 / 44 |
| 980 PRO | dd bs=16M | 2007 | 3920 | 72 / 58 |
| 980 PRO | two dd streams on the drive (aggregate) | 3540 | 5178 | 145 / 88 |
| 980 PRO | dd 32 GB (read: 1 run; inside the cache) | 2072 | 3118 | 82 / 50 |
| 980 PRO RAID0 | dd bs=1M | 1589 | 2724 | 77 / 49 |
| 980 PRO RAID0 | dd bs=16M | 2542 | 3813 | 90 / 89 |
| 980 PRO RAID0 | two dd streams on the array (aggregate) | 3424 | 5866 | 154 / 113 |
| 980 PRO RAID0 | dd 32 GB (1 run; inside the cache) | 2222 | 3962 | 90 / 82 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| Sabrent | 4414 MB/s, 86 % of a core | 4040 MB/s, 98 % | 4548 MB/s, 89 % | 4483 MB/s, 98 % |
| Sabrent RAID0 | 4347 MB/s, 90 % | 3984 MB/s, 98 % | 4564 MB/s, 92 % | 4338 MB/s, 98 % |
| 980 PRO | 4756 MB/s, 89 % of a core | 4540 MB/s, 98 % | 4756 MB/s, 89 % | 4816 MB/s, 98 % |
| 980 PRO RAID0 | 4715 MB/s, 92 % | 4265 MB/s, 98 % | 4771 MB/s, 92 % | 4756 MB/s, 99 % |

fio itself is CPU-bound (one fio thread at 86–99 % of a core; reads are almost all system time,
pinning the pages of each 8 MB request), so these are the host's figures, not the drives'. With
hugepage fixed buffers (`--iomem=mmaphuge --fixedbufs`, how `fdplay` reads) fio reads one
Sabrent at 4521 MB/s and the RAID0 at 7820 MB/s, one 980 PRO at 6309 MB/s and the RAID0 at
7936 MB/s (10 GB). The 32 GB writes are inside the SLC cache (~70-75 GB per Sabrent,
~115-125 GB per 980 PRO). The second Sabrent alone: 4483 MB/s write, 4252 MB/s read; the second
980 PRO alone: 3014 MB/s write (47 % of a core, the first write after `mkfs`), 4419 MB/s read
(fio 4 GB, one run each).

### Results: zcu106_hpc0

AMD ZCU106 (XCZU7EV, four Cortex-A53 cores at 1.2 GHz, 4 GB DDR4), XDMA Gen3 x4 Root Ports,
`zcu106_hpc0` image, measured 2026-10-21. The Samsung 980 PRO 1TB rows (two drives on the FPGA
Drive FMC Gen4 on HPC0) and the Sabrent Rocket 2230 1TB rows (two drives on the M.2 M-key Stack
FMC on HPC0) are Gen4 drives; they link at Gen3 x4 here (`LnkSta 8GT/s (downgraded)`). Same
method, with 60 s of idle time after each `mkfs`. `fdrec` / `fdplay` used
the shipped default of **32 x 8 MB buffers**; 16-buffer results are in brackets where they
differ. Total CPU is a share of four cores (25 % = one full core).

| method | config | direction | size | MB/s | total CPU % of 4 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | 980 PRO 1TB | write | 4000 MiB | 1451 [1446–1477] | 0.1 / 16.8 / 0.7 / 6.6 | 69 [65–72] | 21 |
| dd (script) | 980 PRO 1TB | read | 4000 MiB | 1960 [1951–2292] | 0.2 / 10.0 / 2.4 / 9.2 | 47 [42–71] | 42 |
| dd (script) | RAID0 (2x 980 PRO) | write | 4000 MiB | 1671 [1509–1705] | 0.3 / 21.0 / 0.4 / 2.2 | 88 [81–90] | 19 |
| dd (script) | RAID0 (2x 980 PRO) | read | 4000 MiB | 2605 [2467–2605] | 0.2 / 16.4 / 4.7 / 2.5 | 81 [74–84] | 32 |
| dd (dual script) | both 980 PRO, two filesystems | write (aggregate) | 2 x 4000 MiB | 2787 [2558–2853] | 0.2 / 36.3 / 0.6 / 10.8 | 146 [135–151] | 19 |
| dd (dual script) | both 980 PRO, two filesystems | read (aggregate) | 2 x 4000 MiB | 3762 [3712–3938] | 0.2 / 22.2 / 3.1 / 14.1 | 100 [98–106] | 37 |
| `fdrec`, highest clean: 3000, top step (16: 3000) | 980 PRO 1TB | record | 4000 MiB | 2974 | 0.2 / 17.8 / 0.0 / 10.7 | 68 | 44 |
| `fdrec` at 3000 | 980 PRO 1TB | record | 32 GB | 2997 | 0.2 / 17.3 / 0.2 / 11.3 | 67 | 45 |
| `fdrec`, highest clean: 3000, top step (16: 3000) | RAID0 (2x 980 PRO) | record | 4000 MiB | 2977 | 0.2 / 18.5 / 0.5 / 10.7 | 73 | 41 |
| `fdrec` at 3000 | RAID0 (2x 980 PRO) | record | 32 GB | 2997 | 0.2 / 18.4 / 0.3 / 11.5 | 73 | 41 |
| `fdrec` at 3200 | RAID0 (2x 980 PRO) | record | 32 GB | 3195 | 0.1 / 19.5 / 0.4 / 10.5 | 78 | 41 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | 980 PRO 1TB | play | 4000 MiB | 2824 | 0.0 / 12.3 / 2.7 / 8.5 | 56 | 50 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | RAID0 (2x 980 PRO) | play | 4000 MiB | 2889 | 0.2 / 12.8 / 2.1 / 7.2 | 59 | 49 |
| dd (script) | Sabrent Rocket 2230 1TB | write | 4000 MiB | 1389 [1332–1446] | 0.1 / 16.5 / 0.4 / 7.0 | 65 [65–71] | 21 |
| dd (script) | Sabrent Rocket 2230 1TB | read | 4000 MiB | 2219 [2007–2231] | 0.3 / 14.5 / 2.8 / 5.3 | 59 [56–71] | 37 |
| dd (script) | RAID0 (2x Sabrent) | write | 4000 MiB | 1398 [1389–1427] | 0.2 / 19.2 / 1.0 / 3.4 | 80 [77–80] | 18 |
| dd (script) | RAID0 (2x Sabrent) | read | 4000 MiB | 2162 [2076–2317] | 0.3 / 15.3 / 3.9 / 2.7 | 75 [70–76] | 29 |
| dd (dual script) | both Sabrent, two filesystems | write (aggregate) | 2 x 4000 MiB | 2706 [2467–2796] | 0.2 / 33.8 / 0.8 / 12.1 | 137 [130–165] | 20 |
| dd (dual script) | both Sabrent, two filesystems | read (aggregate) | 2 x 4000 MiB | 3695 [3585–4033] | 0.1 / 24.5 / 5.8 / 9.0 | 113 [103–126] | 33 |
| `fdrec`, highest clean: 3000, top step, ring-assisted (16: 2750, 2 of 3) | Sabrent Rocket 2230 1TB | record | 4000 MiB | 2866 | 0.2 / 17.8 / 0.2 / 11.0 | 70 | 41 |
| `fdrec` at 2750 | Sabrent Rocket 2230 1TB | record | 32 GB | 2747 | 0.1 / 15.1 / 0.2 / 13.3 | 66 | 42 |
| `fdrec`, highest clean: 3000, top step (16: 2000, 2 of 3) | RAID0 (2x Sabrent) | record | 4000 MiB | 2975 | 0.3 / 18.8 / 0.2 / 8.9 | 75 | 40 |
| `fdrec` at 3000 | RAID0 (2x Sabrent) | record | 32 GB | 2997 | 0.2 / 18.2 / 0.5 / 9.8 | 75 | 40 |
| `fdrec` at 3200 | RAID0 (2x Sabrent) | record | 32 GB | 3196 | 0.3 / 19.9 / 0.7 / 9.9 | 78 | 41 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | Sabrent Rocket 2230 1TB | play | 4000 MiB | 2821 | 0.2 / 15.9 / 0.0 / 6.8 | 62 | 45 |
| `fdplay`, highest clean: 3000, top step (16: 3000) | RAID0 (2x Sabrent) | play | 4000 MiB | 2844 | 0.2 / 13.7 / 2.4 / 6.3 | 55 | 51 |

Notes:

* 980 PRO raw script output (MiB/s, medians): write 1398, read 1895; RAID0 write 1612, read
  2531; dual write 2684, read 3636 (aggregate). One `dd` at queue depth 1 is CPU- and
  latency-bound (19-21 MB/s per % of a core writing). Four NVMe I/O queues on both slots.
* 980 PRO `fdrec` with 32 and with 16 buffers: clean at every step up to the 3000 MB/s top
  step, 3/3 there, on one drive and on RAID0 (high-water mark 7 at 3000 MB/s;
  2974-2977 MB/s); 3000 MB/s over 32 GB clean on both (high-water mark 7 and 7), and
  3200 MB/s over 32 GB on RAID0. Recording at 3 GB/s costs 66-73 % of one A53 core.
* 980 PRO `fdplay` with 32 and with 16 buffers: clean at every step up to the 3000 MB/s top
  step, 3/3 there, on one drive and on RAID0 (0 underflows in all 56 playbacks). The tool's own
  rate at that step (2824-2932 MB/s) includes the ring prefill. Playback at 3 GB/s costs
  56-59 % of a core.
* At 1000 MB/s: `fdrec` 24 % of a core (980 PRO) and 26 % (RAID0); `fdplay` 17 / 21 %.
* Sabrent raw script output (MiB/s, medians): write 1333, read 2162; RAID0 write 1346, read
  2094; dual write 2605, read 3571 (aggregate); 18-21 MB/s per % of a core writing. Four NVMe
  I/O queues on both slots.
* Sabrent `fdrec` with 32 buffers: clean at every step up to the 3000 MB/s top step, 3/3 there,
  on one drive and on RAID0 (high-water mark 7 at 3000 MB/s). On one drive the 3000 MB/s step
  achieves only 2866-2884 MB/s (RAID0: 2975 MB/s) with all 8 writes in flight: the drive writes
  ~2.94 GB/s on its Gen3 x4 link, and the 256 MB ring absorbs the deficit over 4000 MiB; every
  longer single-drive recording at 3000 MB/s drops (10 GB from 9.14 GB, 32 GB from 4.91 GB,
  40 GB from 9.97 GB, 200 GiB from 3.76 GB), so 2750 MB/s is the drive's in-cache rate. With 16
  buffers: one drive 2750 MB/s in 2 of 3 runs (3000 MB/s drops), RAID0 2000 MB/s in 2 of 3
  (2250 MB/s drops); each failure had 8 writes in flight and the 128 MB ring exhausted, drive
  write stalls longer than the ring, as with the Sabrent drives on `vck190_fmcp1`. Over 32 GB,
  2750 MB/s on one drive (high-water mark 6) and 3000 and 3200 MB/s on RAID0 (7 and 6) were
  clean. Recording at ~3 GB/s costs 66-78 % of one A53 core.
* Sabrent `fdplay` with 32 and with 16 buffers: clean at every step up to the 3000 MB/s top step,
  3/3 there, on one drive and on RAID0 (0 underflows in all 56 playbacks). The tool's own rate
  at that step (2821-2905 MB/s) includes the ring prefill. Playback at 3 GB/s costs 53-62 % of
  a core.
* At 1000 MB/s: `fdrec` 25 % of a core (Sabrent) and 27 % (Sabrent RAID0); `fdplay` 20 / 20 %.

Variations (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| 980 PRO 1TB | dd bs=1M | 1156 | 1601 | 65 / 45 |
| 980 PRO 1TB | dd bs=16M | 1380 | 2066 | 64 / 46 |
| 980 PRO 1TB | two dd streams on the drive (aggregate) | 2565 | 2655 | 129 / 64 |
| 980 PRO 1TB | dd 32 GB (read: 1 run; inside the cache) | 1436 | 2340 | 66 / 72 |
| RAID0 (2x 980 PRO) | dd bs=1M | 1298 | 1942 | 75 / 57 |
| RAID0 (2x 980 PRO) | dd bs=16M | 1824 | 2621 | 93 / 92 |
| RAID0 (2x 980 PRO) | two dd streams on the array (aggregate) | 2883 | 4324 | 157 / 133 |
| RAID0 (2x 980 PRO) | dd 32 GB (1 run; inside the cache) | 1615 | 2284 | 91 / 79 |
| Sabrent Rocket 2230 1TB | dd bs=1M | 1188 | 1792 | 69 / 51 |
| Sabrent Rocket 2230 1TB | dd bs=16M | 1375 | 2280 | 67 / 62 |
| Sabrent Rocket 2230 1TB | two dd streams on the drive (aggregate) | 2527 | 3062 | 130 / 72 |
| Sabrent Rocket 2230 1TB | dd 32 GB (read: 1 run; inside the cache) | 1549 | 2462 | 74 / 84 |
| RAID0 (2x Sabrent) | dd bs=1M | 1319 | 2151 | 80 / 63 |
| RAID0 (2x Sabrent) | dd bs=16M | 1509 | 2370 | 77 / 78 |
| RAID0 (2x Sabrent) | two dd streams on the array (aggregate) | 2706 | 4324 | 163 / 150 |
| RAID0 (2x Sabrent) | dd 32 GB (1 run; inside the cache) | 1629 | 2482 | 89 / 83 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| 980 PRO 1TB | 2956 MB/s, 72 % of a core | 2946 MB/s, 98 % | 2974 MB/s, 73 % | 3064 MB/s, 98 % |
| RAID0 (2x 980 PRO) | 3492 MB/s, 95 % | 2930 MB/s, 96 % | 3446 MB/s, 95 % | 3098 MB/s, 98 % |
| Sabrent Rocket 2230 1TB | 2778 MB/s, 71 % of a core | 2910 MB/s, 97 % | 2849 MB/s, 74 % | 3008 MB/s, 97 % |
| RAID0 (2x Sabrent) | 3237 MB/s, 93 % | 2722 MB/s, 96 % | 3312 MB/s, 95 % | 2785 MB/s, 97 % |

The second 980 PRO alone: 2970 MB/s write, 3050 MB/s read (fio 4 GB, one run): the same
~2.96 GB/s write on both slots, the drive on its Gen3 x4 link. The second Sabrent alone:
2468 MB/s write (58 % of a core), 2906 MB/s read (fio 4 GB, one run). Every read row and the
RAID0 write rows have the fio thread at 90-98 % of one A53 core, so they measure fio, not the
storage (with hugepage fixed buffers fio reads one 980 PRO at 3183 MB/s and the RAID0 at
6022 MB/s, one Sabrent at 3124 MB/s and the RAID0 at 5128 MB/s, 10 GB). The 32 GB writes are
inside the SLC cache (~115-125 GB per 980 PRO, ~69-70 GB per Sabrent).

### Why the figures differ

The two methods answer different questions, and neither measures the PCIe link.

**CPU cost.** A `dd` write is a CPU-bound copy of zeros: every 4 MiB block is first zero-filled
by the kernel from `/dev/zero` into `dd`'s buffer, then written with `O_DIRECT`. That costs
about 50 % of one 1.2 GHz Cortex-A53 core per ~1 GB/s, and on RAID0 a single `dd` becomes
CPU-bound at 80–90 % of a core. `fdrec` never produces or copies the data: the AXI DMA fills the
hugepage buffers and the NVMe controller reads the same buffers, and the CPU only issues
io_uring requests and ioctls and does the cache maintenance. Measured, that is about **2× more
data per unit of CPU for writes** on `zcu106_hpc0` (`dd` 18–21 MB/s per % of a core, `fdrec`
40–45) and 2.2–2.8× on `vck190_fmcp1` (`dd` 24–27, `fdrec` 59–73). For reads the gap is smaller,
**about 1.2–1.8×** (on `zcu106_hpc0` `dd` 29–42, `fdplay` 45–51): a `dd` read lands in its
buffer by DMA and is handed to `/dev/zero`, which discards it without a copy, so `dd` pays only
the per-I/O work (a system call, pinning 1024 pages of 4 KiB per block, a wake-up per
completion). The recorder's remaining cost is the kernel's I/O path itself.

**Queue depth 1 vs 8 in flight.** `dd` has one 4 MiB request in flight; the drive idles
while `dd` prepares the next one. On `zcu106_hpc0` one `dd` writes 1451 MB/s to a Samsung
980 PRO 1TB, two `dd` streams 2565 MB/s and fio at queue depth 8 2956 MB/s. On its RAID0 one
`dd` (each block spans both drives) reaches 1671 MB/s write and 2605 MB/s read, against fio's
3492 / 2930 MB/s (both CPU-bound). With the Sabrent Rocket 2230 1TB on the same board: one
`dd` writes 1389 MB/s, two `dd` streams 2527 MB/s and fio 2778 MB/s; on its RAID0 one `dd`
reaches 1398 MB/s write and 2162 MB/s read, against fio's 3237 / 2722 MB/s (both CPU-bound).
Block size matters too: against the scripts' 4 MiB, 1 MiB blocks lose 18–25 % with the 980 PRO
on `zcu106_hpc0`, 14–19 % with one Sabrent there and 0.5–6 % with its RAID0 pair, and up to
25–34 % with the RAID0 writes on `vck190_fmcp1`; 16 MiB blocks change the `zcu106_hpc0` figures
by -5 to +10 % and raise most `vck190_fmcp1` figures by 14–20 % (see the variations tables; on
`vck190_fmcp1` some single-drive script figures are held down by the slow first runs after
`mkfs`).

**Burst vs sustained.** The 1 TB drives cache 70-125 GB, so on them a 4 GB and even a 32 GB
`dd` is a burst (the 980 PRO on `zcu106_hpc0` writes 1436 MB/s over 32 GB and 1451 MB/s over
4 GB, on `vck190_fmcp1` 2072 MB/s over 32 GB; the Sabrent on `vck190_fmcp1` 2056 MB/s over
32 GB, on `zcu106_hpc0` 1549 MB/s). The recorder's "highest clean rate"
is stricter than any average: a recorder must never fall behind, not even briefly, so the
drive's worst moment sets it. The recorder's rates in these tables are 4000 MiB bursts too;
only the [long recordings](#long-recordings-past-the-slc-cache) show the sustained rate.

**What else differs.** Both methods bypass the page cache (`O_DIRECT`); no cache effect
was seen. `dd` extends its file block by block, while `fdrec` preallocates the full size
first. And the `dd` data never touches the FPGA, whereas the `fdrec` and `fdplay` figures
include the AXI DMA, the fabric FIFO and the DDR traffic of the DMA and the SSD using the
same buffers.

**Neither measures the PCIe link directly.** A PCIe Gen3 x4 link carries 3.94 GB/s raw in each
direction, ~3.1-3.3 GB/s of payload with 128-byte MaxPayload. Almost every figure here is below
that: the SSDs (and their caches), the filesystem and the Linux I/O path set the limits. The
exception is a fast Gen4 drive on the Gen3 x4 Root Ports of `zcu106_hpc0`: inside its cache
the Samsung 980 PRO 1TB writes ~2.96-3.04 GB/s per slot and reads 2940-3172 MB/s (raw device),
and the Sabrent Rocket 2230 1TB writes ~2.94 GB/s and reads 2929-3156 MB/s (raw device), the
link's practical rate. To check the link
itself, look at its negotiated speed and width (`lspci -vv`, see [Test the design in
Linux](linux_test.md#1-check-that-the-pcie-links-are-up)).

The sibling design's own documentation quotes lower `dd` figures for a Zynq UltraScale+ target
(read 790–970, write ~585 MB/s); those were measured with a Samsung 980 PRO and an older image,
and do not apply to this setup. With this design, a Samsung 980 PRO 1TB on `zcu106_hpc0` gives
1451 MB/s write and 1960 MB/s read with the same scripts, and a Sabrent Rocket 2230 1TB
1389 MB/s write and 2219 MB/s read.

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
x4 for ~70-75 GB and then a flat ~1.8 GB/s; the Samsung 980 PRO 1TB writes ~4.7 GB/s on Gen4
x4 (fio-bound) and ~3.0 GB/s on the Gen3 x4 link of `zcu106_hpc0` for ~115-125 GB and then a
flat ~1.77 GB/s (see [The SLC cache](#the-slc-cache)). Where nothing else comes first, the
post-cache rate sets the sustained single-drive rate: 1750 MB/s for both drives on both boards
(the Sabrent over 143 and 200 GiB on the VCK190 and over 200 GiB on `zcu106_hpc0`, the 980 PRO
over 219 and 240 GiB on the VCK190 and over 200 and 222 GiB on `zcu106_hpc0`; in every case
2000 MB/s drops just past the cache). Smaller drives show the cliff sooner: Samsung rates the 970 EVO 250GB at up to
1500 MB/s sequential write, and 300 MB/s once its TurboWrite (SLC) cache is full
([data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung-NVMe-SSD-970-EVO-Data-Sheet_Rev.1.0.pdf)).

**Reads: the rating assumes a fast host with many commands outstanding.** Drive read ratings
are measured with many read commands in flight on a fast desktop host. With one request at a
time (`dd`, queue depth 1) one Sabrent Rocket 2230 1TB reads 3201 MB/s on `vck190_fmcp1`
(Gen4 x4); with 8 requests in flight fio reads it at 4040 MB/s, CPU-bound, and at 4521 MB/s
with hugepage fixed buffers, the way `fdplay` reads. On `zcu106_hpc0` the Gen3 x4 link sets the
per-slot read rate: a Samsung 980 PRO 1TB reads 2940-3172 MB/s per slot and a Sabrent Rocket
2230 1TB 2929-3156 MB/s (raw device, 1 MB requests at queue depth 8 and 32).

**The recorder's criterion is the drive's worst moment.** A recording passes only if no beat
is dropped over its whole length, so its rate is set by the drive's slowest stretch
(garbage collection, the cache end, a write-latency spike), not by its average. That is why
the sustained recording rates sit below the drives' average write rates (one 980 PRO 1TB:
1750 MB/s against a post-cache median of 1771 MB/s).

A write-latency spike can cost data even below the drive's bandwidth, if it outlasts the ring
(section 5). The Sabrent Rocket 2230 1TB on `vck190_fmcp1` shows such spikes: three 4000 MiB
recordings with the 16-buffer ring (128 MB; two on one drive, one on the RAID0 pair) dropped
with the io_uring queue full, i.e. write stalls longer than 43 ms at 3000 MB/s and 57 ms at
2250 MB/s, and one 200 GiB recording at 2000 MB/s had one isolated gap at 1.65 GB, a stall
longer than the default ring lasts at that rate. That was the only such stall in about 54
single-drive recordings with the default ring (sweep steps, 4000 MiB runs, bursts, ring tests
and long recordings). An earlier measurement series saw rare write stalls of about 0.65 s on
this drive, which the 2026-10-21 runs did not reproduce. On `zcu106_hpc0` the same drives
dropped 4000 MiB recordings with the 16-buffer ring at 2750 MB/s (one drive) and at 2000 and
2250 MB/s (the RAID0 pair), each with the io_uring queue full (and one drive at 3000 MB/s,
above its write rate on that link).

### 2. The host I/O path and the CPU

Every write and read goes through the kernel's filesystem, block layer and NVMe driver, and
that path costs CPU time per byte even without a data copy. On `zcu106_hpc0` (four 1.2 GHz
Cortex-A53 cores) `fdrec` uses about 2.4–2.6 % of one core per 100 MB/s (23.6–25.6 % at
1000 MB/s), almost all of it system time, and the cost grows almost linearly with the rate:
66–75 % at 3000 MB/s and 78 % at 3200 MB/s (32 GB), so one core would saturate at about
4 GB/s. `fdplay` uses 16.5–22.1 % at 1000 MB/s and 55–62 % at 3000 MB/s. `dd` additionally
has the CPU produce every byte (zero-fill from `/dev/zero`) and runs one request at a time:
about 5 % of a core per 100 MB/s, and on RAID0 a single `dd` is CPU-bound at ~1.4-1.7 GB/s
(77–90 % of a core). The AXI DMA writes DDR through a non-coherent port, so the driver does a
cache-maintenance pass over each buffer (one invalidate after the DMA, one clean before the
buffer goes back); that is part of the system time above.

On the VCK190 (two 1.4 GHz Cortex-A72 cores) the same work costs less: `fdrec` uses about
1.5–1.7 % of one core per 100 MB/s, at 1000 MB/s (15.5–16.8 %) as at 3000 MB/s (46–50 %),
`fdplay` about 1.2 % (11.8–12.5 % at 1000 MB/s), and a `dd` write about 4 % (75–83 % of a core
at ~2.0 GB/s). A core goes about 1.5 times as far as a ZCU106 core, but there are only two of
them, and during a recording one of them spends much of its time waiting for I/O completions.
With the Gen4 drives the VCK190's CPU becomes the limit of the reference tools: one fio thread
reaches 86-98 % of a core at ~4.0-4.6 GB/s with the Sabrent Rocket 2230 1TB and 89-99 % at
~4.3-4.8 GB/s with the Samsung 980 PRO 1TB, and one `dd` write stream 75-87 % at ~2.0 GB/s.
`fdrec` records 3 GB/s on one drive with 46-49 % of a core.

On `zcu106_hpc0` the reference tools hit the same wall on one A53 core: fio reads of a file
(2.7-3.1 GB/s) and fio writes to the RAID0 pairs (~3.2-3.5 GB/s) keep the fio thread at
90-98 % of a core, so they measure fio, not the storage (with hugepage fixed buffers fio reads
the RAID0 pairs at 5128 MB/s (Sabrent) and 6022 MB/s (980 PRO)).

**What limits a Zynq UltraScale+ slot.** Each XDMA Root Port reaches the PS DDR through its own
HP port (`S_AXI_HP0_FPD`, `S_AXI_HP1_FPD`), 128 bits at 250 MHz = 4.0 GB/s each, and the
recorder's own AXI DMA path through `S_AXI_HP2_FPD` carries the generator's full 3.2 GB/s;
neither is the limit. Inside the SLC cache the limit is the Gen3 x4 link at 128-byte MaxPayload
(MaxReadReq 512 bytes): the link carries 3.94 GB/s raw, and each 128-byte payload travels in a
TLP with ~20-24 bytes of header, sequence number, LCRC and framing, plus acknowledgement and
flow-control packets, which leaves ~3.1-3.3 GB/s of payload per direction. Measured on
`zcu106_hpc0`: one slot writes up to ~3.04 GB/s with the 980 PRO (fio 2956-2970 MB/s; the
3200 MB/s sweep step 3036 MB/s) and ~2.94 GB/s with the Sabrent (2928-2950 MB/s at the 3000
and 3200 MB/s steps), and reads 2940-3172 MB/s (980 PRO) and 2929-3156 MB/s (Sabrent, raw
device), against ~4.3-4.8 GB/s in the cache on the VCK190's Gen4 x4 link. So one drive
records 3000 MB/s (980 PRO) or 2750 MB/s (Sabrent), and RAID0 across both slots is the way
past that. Past the cache the drive's post-cache rate (~1.77 GB/s for the 980 PRO, ~1.8 GB/s
for the Sabrent) is the limit; a RAID0 pair of either drive records the
generator's 3200 MB/s over 350 GiB. The per-slot figure is consistent with
[fpga-drive-nvme-offload](https://offload.fpgadrive.com), the hardware NVMe host design (AMD
NVMe Host Accelerator) on the same board and Root Ports, which reaches ~3.04 GB/s per Gen3 x4
slot.

### 3. The NVMe queue count

The Linux NVMe driver gives a drive one I/O queue per CPU core if the drive supports it: the
Samsung 980 PRO 1TB got four on `zcu106_hpc0` (`4/0/0 default/read/poll queues` in the kernel
log) and the Sabrent Rocket 2230 1TB two on `vck190_fmcp1` (`2/0/0`). Some drives get a single
I/O queue whatever the board; the Samsung 970 EVO 250GB, an older drive also tried with this
design, is one (`1/0/0`). With one queue, every command and completion of the drive goes
through one queue and one interrupt, on one core: a limiter for parallel I/O to that drive.
Check yours with `dmesg | grep queues`.

### 4. RAID0 and the filesystem

With 512 KB chunks, md splits every 8 MB request into 16 stripe writes, alternating between the
drives; the array then runs at up to twice the slower drive's rate. md itself is not the limit:
on `zcu106_hpc0` two 980 PRO 1TB write 3.4-3.5 GB/s and two Sabrent Rocket 2230 1TB
3.2-3.3 GB/s through md (fio, CPU-bound), and on `vck190_fmcp1` two Sabrent Rocket 2230 1TB
4.3-4.6 GB/s and two 980 PRO 1TB 4.7-4.8 GB/s (fio, CPU-bound). On the filesystem
side, `fdrec` preallocates the whole file (`fallocate`), so XFS does no allocation work during
the recording, and an `fstrim` immediately before a recording can stall the first writes past
what a 128 MB ring covers (see [the fstrim finding](#the-fstrim-finding-and-the-ring-size)).

### 5. Latency budgets, not bandwidth

Two buffers decide whether a short stall costs data, although neither limits throughput:

* **The buffer ring** (buffers × buffer size) must cover the longest write-latency spike of
  the drive at the recording rate. 16 × 8 MB = 128 MB lasts 75 ms at 1.7 GB/s, which was not
  always enough after an `fstrim`, nor for every write stall of the Sabrent Rocket 2230 1TB
  at 2000-3000 MB/s; the default is 32 × 8 MB (256 MB), which lasts 128 ms at 2 GB/s.
  `fdrec` accepts up to 64 buffers (`--buffers 64`, 512 MB with 8 MB buffers, which is also
  the default hugepage pool); 64 × 8 MB was clean at 1250-1750 MB/s over 32 GB on one 980 PRO.
  A larger ring (larger buffers and a larger hugepage pool reserved at boot) was not tested.
* **The fabric FIFO** must cover the AXI DMA's pauses. Driver 1.2 keeps the DMA armed across
  buffer boundaries, with the next two buffers appended to its running descriptor chain
  (`xilinx_dma` patch 0002, see [Kernel driver](driver.md)), so the DMA does not wait for
  software at a boundary. The ingest FIFO's high-water mark is then a floor set by the rate:
  1 beat up to 1500 MB/s, 2 at 1750-2000 MB/s, 3 at 2250 MB/s, 4 at 2500 MB/s, 6 at
  2750 MB/s and 7 at 3000-3200 MB/s, on both `vck190_fmcp1` and `zcu106_hpc0`, with both
  drive pairs. It was the same in every sampled interval (0.5 s to 10 s) of recordings from
  4 GiB to 480 GiB, inside and past the SLC cache. The 256 KB ingest FIFO (16384 beats, 82 µs
  at 3.2 GB/s) is therefore margin against DDR and interconnect back-pressure, not against
  software; the 64 KB egress FIFO lasts 20 µs at 3.2 GB/s (see
  [the FIFO budget](apps.md#tuning-the-fifo-budget-at-buffer-boundaries)). The DMA stops at a
  boundary only when the chain is empty, which in practice means that the ring has run out
  behind a slow drive. The overflow then starts 16384 + 7 beats (262 256 bytes) after the
  boundary, so a gap at that offset means that the ring ran out behind the drive. The
  statistics of `fdrec --stats` show it: the io_uring queue is full (`inflight` at `--qd`) and
  the write rate is below the recording rate, as with one Sabrent Rocket 2230 1TB at 3000 MB/s
  on `zcu106_hpc0`.

Both set what "sustainable" means: a rate is sustainable if the drive's worst stall fits in
the ring.

### 6. What is not the bottleneck at these rates

* **The PCIe link**, with one exception. Gen3 x4 carries about 3.1-3.3 GB/s of payload at
  128-byte MaxPayload (Gen4 x4 on the Versal targets about 6.5 GB/s), above almost every figure
  here. The exception: a Gen4 SSD in a Gen3 design is capped at the Gen3 rate. The Samsung
  980 PRO 1TB and the Sabrent Rocket 2230 1TB link at Gen3 x4 (`8GT/s (downgraded)`) on the Zynq
  UltraScale+ Root Ports, where inside their caches both run at the link's rate (~2.94-3.04 GB/s
  write, ~2.9-3.2 GB/s read per slot), and at Gen4 x4 (16 GT/s) on the VCK190's QDMA Root Ports
  (see [What limits a Zynq UltraScale+ slot](#2-the-host-io-path-and-the-cpu)). PCIe
  MaxPayload is 128 bytes and MaxReadReq 512 bytes on both boards.
* **The PS DDR memory.** A recording moves every byte through DDR twice (the AXI DMA writes it,
  the SSD reads it), so 1.75 GB/s of recording is 3.5 GB/s of DDR traffic, well within the
  bandwidth of a 64-bit DDR4 interface. RAID0 recordings at 3.2 GB/s (6.4 GB/s of DDR traffic)
  passed over 350 GiB on both the ZCU106 and the VCK190.
* **The fabric datapath and the AXI DMA:** 128 bits at 250 MHz = 4 GB/s. The test pattern
  generator tops out at 3.2 GB/s (200 MHz × 16 bytes), a design parameter (`src_clk`). With
  either drive pair on `vck190_fmcp1`, the generator is the burst limit: 10 GB and 40 GB
  recordings pass at 3.2 GB/s on one drive and on RAID0. RAID0 pairs record 350 GiB at
  3.2 GB/s on both boards, and the 980 PRO pair on `vck190_fmcp1` 480 GiB.

### 7. How to get more

* SSDs without an SLC cliff: drives designed for sustained writes (enterprise, industrial,
  MLC or SLC flash), or larger capacities with a bigger cache. See
  [supported SSDs](supported_ssds.md#choosing-ssds-for-recording).
* RAID0 of two good, identical drives. On the Zynq UltraScale+ targets it is the way past
  the ~2.94-3.04 GB/s that one Gen3 x4 slot writes.
* A Gen4 target (`vck190_fmcp1`) for Gen4 drives.
* More buffers (`--buffers`, `--buf-size`) to ride out latency spikes.
* Larger I/Os or more requests in flight (`--buf-size`, `--qd`).
* SSDs that expose several NVMe I/O queues.

For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics. See their
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).
