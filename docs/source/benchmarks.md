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
  write cache (10 GB on every drive below).
* The **sustained recording rate** is the highest passing rate over a recording long enough
  to exhaust the cache. `fdbench.sh` automates the sweep, with 32 GB per step by default.
  32 GB runs past the cache of the 250 GB drives below, but stays **inside** the cache of the
  1 TB drives (75-120 GB per drive). For those, the 32 GB sweep gives an *in-cache* rate,
  and the sustained rate comes from single recordings of 143-480 GiB, well past the cache
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

## Setups

Three SSD sets were measured. Units: MB/s = 10⁶ bytes/s; figures are medians of 3 runs
unless noted.

| SSDs | target | PCIe link per SSD | measured |
|---|---|---|---|
| Samsung 970 EVO 250GB + Samsung 950 PRO 256GB | `uzev` †, `vck190_fmcp1`, `zcu106_hpc0` † | Gen3 x4 (both are Gen3 drives) | 2026-10-02 (`uzev`), 2026-10-03 |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` (M.2 M-key Stack FMC on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-17 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` (FPGA Drive FMC Gen4 on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-19 (2026-10-17 with the pre-fix design) |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` (M.2 M-key Stack FMC on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-19 (2026-10-18 with the pre-fix design) |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` (FPGA Drive FMC Gen4 on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-18 |

The 1 TB drives were measured with the same image and register map (1.1) as the 2026-10-03
rows (on 2026-10-19 with the boot image of the current design, which differs only in the HP-port
clocking), with the shipped default of 32 x 8 MB buffers, and with a fan on the cards (no thermal
throttling: at most 60 °C on the Sabrent drives on `vck190_fmcp1` and 67 °C on `zcu106_hpc0`,
49 °C on the 980 PROs on `vck190_fmcp1` and 52 °C on `zcu106_hpc0`, 0 thermal-management
transitions). Each 1 TB pair was measured on both boards: on one on 2026-10-17, on the other on
2026-10-18, after the two FMC cards had been swapped between the boards. Both pairs were measured
again on `zcu106_hpc0` on 2026-10-19, with the current design.

**Figures marked † are pre-fix.** In the first release of the Zynq UltraScale+ designs each
XDMA Root Port reached the PS DDR through an HP port (`S_AXI_HP0_FPD`, `S_AXI_HP1_FPD`) clocked
from `pl_clk0` at 99.99 MHz. A 128-bit port at that clock carries at most 1.600 GB/s, so one SSD
slot topped out at ~1.57-1.60 GB/s in either direction, whatever the drive. The current design
clocks these ports from the 250 MHz `pl_clk1` (4.0 GB/s per port); see
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed) for the cause, the fix and the
before/after figures. The † marks the figures measured with the old clocking: every `uzev`
figure, and on `zcu106_hpc0` those of the Samsung 970 EVO 250GB and 950 PRO 256GB. Where such a
figure is near ~1.6 GB/s per slot (the reads of the 970 EVO and 950 PRO) it is the old ceiling,
not the drive; the writes of the 970 EVO and 950 PRO are the drives' own limits. All 1 TB figures
of `zcu106_hpc0` (Sabrent Rocket 2230 1TB and Samsung 980 PRO 1TB) are from the current design;
their pre-fix figures are in the before/after tables of that section. The `uzev` figures and
those of the 970 EVO and 950 PRO will not be re-measured (the `uzev` design has the same clock
change). The `vck190_fmcp1` figures are not affected.

## Results: recording, playback and CPU

Rows marked † were measured with the pre-fix design (HP0/HP1 at 99.99 MHz, see
[Setups](#setups)); the 1 TB rows of `zcu106_hpc0` with the current design.

Target `uzev` (Zynq UltraScale+ XCZU7EV, four Cortex-A53 cores at 1.1 GHz), FPGA Drive FMC
Gen4 (OP063), both SSDs linked at PCIe Gen3 x4. SSDs: Samsung 970 EVO 250GB (firmware
1B2QEXE7) and Samsung 950 PRO 256GB (firmware 1B0QBXX7); RAID0 = both, 512 KB chunks
(`fdsetup-raid0.sh` defaults). All measured on 2026-10-02 with the driver and apps of that
date. The recordings used the then-default ring of **16 x 8 MB** buffers unless noted; the
default is now 32 x 8 MB.

### Sustained recording rate

`fdbench.sh --size 32G`, 250 MB/s steps, `fdrec` with queue depth 8, each configuration on a
freshly created XFS filesystem; before every step the previous file was deleted, the
filesystem trimmed, and the drives left idle for 60 s. `uzev`: 16 x 8 MB buffers, design 1.0;
the other targets: the shipped default of 32 x 8 MB, and the 1 TB sweeps add a last step at
3200 MB/s (the generator maximum).

The last column is the rate that holds **past the SLC cache**. For the 250 GB drives the
32 GB sweep already runs past the cache, so it is the same figure; for the 1 TB drives the
32 GB sweep is inside the cache, and the last column comes from the
[long recordings](#long-recordings-past-the-slc-cache).

| target | SSD | layout | 32 GB sweep: highest clean step | fio reference (32 GB) | sustained past the SLC cache |
|---|---|---|---|---|---|
| `uzev` † | Samsung 970 EVO 250GB | single | 250 MB/s | 484 MB/s | 250 MB/s (32 GB is past the cache) |
| `uzev` † | Samsung 950 PRO 256GB | single | 750 MB/s | 962 MB/s | 750 MB/s (no cache cliff) |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 500 MB/s | 1416 MB/s | 500 MB/s (32 GB is past the cache) |
| `vck190_fmcp1` | Samsung 970 EVO 250GB | single | 250 MB/s | 483 MB/s | 250 MB/s (32 GB is past the cache) |
| `vck190_fmcp1` | Samsung 950 PRO 256GB | single | 750 MB/s | 942 MB/s | 750 MB/s (no cache cliff) |
| `vck190_fmcp1` | 970 EVO + 950 PRO | RAID0, 512K chunk | 500 MB/s | 1413 MB/s | 500 MB/s (32 GB is past the cache) |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 1000 MB/s, in the cache (750 dropped once, see below) | 4380 MB/s, in the cache | **1000 MB/s** over 143 GiB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 MB/s, in the cache | 4428 MB/s, in the cache | **2750 MB/s** over 240 GiB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3200 MB/s (the generator maximum), in the cache | 4586 MB/s, in the cache | **1750 MB/s** over 240 GiB (2000 MB/s dropped when the cache ended, at 125 GB) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache | 4718 MB/s, in the cache | **2000 MB/s** over 480 GiB (2250-3200 MB/s dropped 3897-16 643 beats each, one try per rate) |
| `zcu106_hpc0` † | Samsung 970 EVO 250GB | single | 250 MB/s | 486 MB/s | 250 MB/s (32 GB is past the cache) |
| `zcu106_hpc0` † | Samsung 950 PRO 256GB | single | 750 MB/s | 958 MB/s | 750 MB/s (no cache cliff) |
| `zcu106_hpc0` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 500 MB/s | 1428 MB/s | 500 MB/s (32 GB is past the cache) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3000 MB/s, in the cache (3200 MB/s exceeds the drive's ~3.04 GB/s on Gen3 x4) | 2974 MB/s, in the cache | **1750 MB/s** over 200 GiB and 221 GiB (2000 MB/s dropped from 127.04 GB, past the ~115-120 GB cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 MB/s, in the cache (3200 MB/s lost 430 beats, FIFO overflows) | 3444 MB/s, in the cache (fio CPU-bound) | **2500 MB/s** over 350 GiB (2750-3200 MB/s dropped 846-14 934 beats each, FIFO overflows) |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2750 MB/s, in the cache (3000 MB/s exceeds the drive's ~2.95 GB/s on Gen3 x4) | 2898 MB/s, in the cache | **1750 MB/s** over 200 GiB (2000 MB/s dropped from 95.95 GB, past the ~72 GB cache) |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3200 MB/s (the generator maximum), in the cache (1750 dropped once, see below) | 3319 MB/s, in the cache (fio CPU-bound) | **2250 MB/s** over 350 GiB (2500-3200 MB/s dropped 1226-10 150 beats each, FIFO overflows) |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

`vck190_fmcp1` sweep: same method (`fdbench.sh`, 32 GB steps, `fstrim` + 60 s idle before each
step), with the shipped default of 32 x 8 MB buffers. 970 EVO: 250 MB/s clean (FIFO high-water
mark 215); 500 MB/s fails at 14.8 GB, the SLC cliff (385 MB/s achieved). 950 PRO: 750 MB/s
clean (high-water mark 526); 1000 MB/s fails at the drive's ~950 MB/s limit. RAID0: 500 MB/s
clean (high-water mark 323); 750 MB/s fails at 30.4 GB, when the 970 EVO's half of the stripe
leaves its cache. In all six failing steps the gaps sum exactly to the header's drop count. The
sustained rates are the same as on `uzev`: they are set by the SSDs.

`zcu106_hpc0` sweep (†): same method, 32 x 8 MB buffers. 970 EVO: 250 MB/s clean (high-water mark
174); 500 MB/s fails at 14.81 GB (the SLC cliff). 950 PRO: 750 MB/s clean (high-water mark 781);
1000 MB/s fails at 7.11 GB. RAID0: 500 MB/s clean (high-water mark 438); 750 MB/s fails at
30.42 GB, when the 970 EVO's half leaves its cache. Again every failing step's gaps sum exactly
to the drop count, and the sustained rates are identical on all three boards.

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
The same rates passed 40 GB with 30 s of idle (see the burst table).

`vck190_fmcp1` with two Samsung 980 PRO 1TB (Gen4 x4, 2026-10-18), same method, 32 x 8 MB
buffers: every step from 250 to 3200 MB/s (the generator maximum) was clean, single and RAID0
(high-water marks 2692 and 1871 at 3200 MB/s), the first drives in this design to record 32 GB
at the generator maximum. All of these steps run inside the drives' ~115-120 GB SLC cache. Past
the cache one drive holds 1750 MB/s (clean over 240 GiB; 2000 MB/s drops when the cache ends at
125 GB), the pair 2000 MB/s (clean over 480 GiB); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`zcu106_hpc0` with two Samsung 980 PRO 1TB (Gen3 x4, 2026-10-19, current design), same method,
32 x 8 MB buffers. Single drive: clean up to 3000 MB/s (high-water mark 3219) except one
3296-beat FIFO overflow at 1750 MB/s (the gap starts 69 744 bytes after an 8 MiB buffer
boundary); 3200 MB/s drops from 5.06 GB while writing 3037 MB/s, the drive on its Gen3 x4 link.
RAID0: clean up to 3000 MB/s (high-water mark 2515); 3200 MB/s, the generator maximum, lost
430 beats in three small FIFO overflows while writing 3197 MB/s. All of these steps run inside
the 980 PRO's SLC cache (~115-120 GB per drive). Past the cache one drive held 1750 MB/s, the
RAID0 pair 2500 MB/s (see [Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)).
With the pre-fix design one drive stopped at 1500 MB/s (writing at most ~1.59 GB/s) and RAID0 at
3000 MB/s (3200 MB/s dropped 396 618 beats); see
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed).

`zcu106_hpc0` with two Sabrent Rocket 2230 1TB (Gen3 x4, 2026-10-19, current design), same
method, 32 x 8 MB buffers. Single drive: clean up to 2750 MB/s (high-water mark 2323); 3000 and
3200 MB/s write ~2949 MB/s, the drive on its Gen3 x4 link, and drop from 10.10 GB and 1.98 GB.
The 3000 MB/s step and the 10 GB burst at 3000 MB/s lose their first beat at the same beat
number: a fixed rate deficit, not a random event. RAID0: clean at every step up to the
generator's 3200 MB/s (high-water mark 3363), except one 28 925-beat FIFO overflow at 1750 MB/s
(the gap starts 65 648 bytes after an 8 MiB buffer boundary). All of these steps run inside the
SLC cache, which shows on this board now (~72 GB per drive, then ~1.8 GB/s); one drive held
1750 MB/s over 200 GiB, the RAID0 pair 2250 MB/s over 350 GiB (see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)). With the pre-fix
design the same drives stopped at 1500 MB/s (single) and 2500 MB/s (RAID0); see
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed).

fio reference: `fio --name=w --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8
--size=32G --filename=/mnt/rec/fio.dat` on the freshly created filesystem, before the sweep.
It is an average over 32 GB: fio has no fixed input rate, so it rides the SLC cache at full
speed and does not show the post-cache write rate that limits a constant-rate recording.

Every step of the sweeps ("first gap" is the file offset of the first discontinuity
reported by `fdverify`; "avg MB/s" is the data written divided by the recording time;
"gaps (1)" = exactly one discontinuity). The `uzev` rows used 16 x 8 MB buffers, the
`vck190_fmcp1` and `zcu106_hpc0` rows 32 x 8 MB; the steps of the 2026-10-03 sweeps of the
970 EVO / 950 PRO on those two targets are summarized in the paragraphs above:

| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (of 4096) | avg MB/s | fdverify | first gap |
|---|---|---|---|---|---|---|---|---|---|
| `uzev` † | Samsung 970 EVO 250GB | single | **250** | pass | 0 | 260 | 250.0 | pass | - |
| `uzev` † | Samsung 970 EVO 250GB | single | 500 | drops | 632 577 164 | full | 384.6 | gaps | 14.40 GB |
| `uzev` † | Samsung 970 EVO 250GB | single | 750 | drops | 1 591 855 641 | full | 428.6 | gaps | 14.26 GB |
| `uzev` † | Samsung 950 PRO 256GB | single | 250 | pass | 0 | 249 | 250.0 | pass | - |
| `uzev` † | Samsung 950 PRO 256GB | single | 500 | pass | 0 | 538 | 499.9 | pass | - |
| `uzev` † | Samsung 950 PRO 256GB | single | **750** | pass | 0 | 853 | 749.8 | pass | - |
| `uzev` † | Samsung 950 PRO 256GB | single | 1000 | drops | 84 401 144 | full | 958.7 | gaps | 3.57 GB |
| `uzev` † | Samsung 950 PRO 256GB | single | 1250 | drops | 652 697 593 | full | 955.2 | gaps | 0.59 GB |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 250 | pass | 0 | 267 | 250.0 | pass | - |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | **500** | pass | 0 | 625 | 499.9 | pass | - |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 750 | drops | 45 579 326 | full | 731.4 | gaps | 29.17 GB |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 1000 | drops | 188 352 364 | full | 914.6 | gaps | 28.44 GB |
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
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 250 | pass | 0 | 248 | 250.0 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 500 | pass | 0 | 499 | 499.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 750 | pass | 0 | 866 | 749.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1000 | pass | 0 | 1018 | 999.7 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1250 | pass | 0 | 963 | 1249.5 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1500 | pass | 0 | 1759 | 1499.3 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 1750 | drops | 3296 | full | 1749.1 | gaps (1) | 21.73 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2000 | pass | 0 | 3796 | 1998.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2250 | pass | 0 | 2388 | 2248.5 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 2430 | 2498.2 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2750 | pass | 0 | 2999 | 2747.9 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | **3000** | pass | 0 | 3219 | 2997.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3200 | drops | 97 418 114 | full | 3036.9 | gaps | 5.06 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 250 | pass | 0 | 207 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 500 | pass | 0 | 425 | 499.9 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 750 | pass | 0 | 715 | 749.9 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 792 | 999.8 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 930 | 1249.6 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1290 | 1499.4 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 1750 | pass | 0 | 1486 | 1749.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 1782 | 1999.1 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 1853 | 2248.8 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 2154 | 2498.3 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 2512 | 2748.1 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **3000** | pass | 0 | 2515 | 2998.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3200 | drops | 430 | full | 3197.1 | gaps (3) | 16.28 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 250 | pass | 0 | 210 | 250.0 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 500 | pass | 0 | 445 | 499.9 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 750 | pass | 0 | 617 | 749.8 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1000 | pass | 0 | 879 | 999.7 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1250 | pass | 0 | 1067 | 1249.5 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1500 | pass | 0 | 1488 | 1499.4 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 1750 | pass | 0 | 1810 | 1749.1 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2000 | pass | 0 | 1916 | 1998.8 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2250 | pass | 0 | 2957 | 2248.5 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2500 | pass | 0 | 3102 | 2498.3 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | **2750** | pass | 0 | 2323 | 2747.9 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 | drops | 20 928 426 | full | 2949.6 | gaps | 10.10 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3200 | drops | 164 708 184 | full | 2948.3 | gaps | 1.98 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 250 | pass | 0 | 199 | 250.0 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 500 | pass | 0 | 402 | 499.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 750 | pass | 0 | 711 | 749.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1000 | pass | 0 | 887 | 999.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1250 | pass | 0 | 990 | 1249.6 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1500 | pass | 0 | 1136 | 1499.4 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 1750 | drops | 28 925 | full | 1749.1 | gaps (1) | 25.71 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2000 | pass | 0 | 1736 | 1998.9 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2250 | pass | 0 | 2042 | 2248.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 3600 | 2498.3 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2750 | pass | 0 | 2836 | 2748.1 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 3781 | 2997.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **3200** | pass | 0 | 3363 | 3196.8 | pass | - |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

In every failing step the gaps sum exactly to the drop count in the file header.

* **970 EVO SLC cache.** Above its post-cache rate the 970 EVO records cleanly until about
  14.3-14.4 GB and drops after that, at 500 and at 750 MB/s alike. The earlier 40 GB
  measurement (300 MB/s clean) lies between the 250 and 500 MB/s steps.
* **950 PRO** has no comparable cache cliff; at 1000 MB/s and above it drops within the first
  few GB, writing ~955-960 MB/s.
* **RAID0** at 750 and 1000 MB/s drops at ~28-29 GB, i.e. when the 970 EVO's half of the
  stripe (~14.5 GB) exhausts its SLC cache. The array's sustained rate is limited by the
  970 EVO.
* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): every failing step has exactly one gap, at
  no fixed offset (30.86 and 17.36 GB single; 0.27 GB, right after the first ring, on RAID0).
  These are isolated write stalls, not a rate the drive cannot keep up with.
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): the single-drive failure at 3200 MB/s writes
  3037 MB/s, the drive on its Gen3 x4 link; the 1750 MB/s single and the 3200 MB/s RAID0
  failures are small FIFO overflows (3296 and 430 beats), each starting 69 744 bytes after an
  8 MiB buffer boundary (a late DMA restart).
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`, Gen4 x4): no step failed on either layout, up to the
  3.2 GB/s generator maximum.
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): the single-drive failures write ~2949 MB/s, the
  drive on its Gen3 x4 link, and lose their first beat at the same offset (a fixed rate
  deficit); the one RAID0 failure (1750 MB/s) is a single 28 925-beat FIFO overflow 65 648 bytes
  after an 8 MiB buffer boundary (a late DMA restart), as with the 980 PRO pair. No isolated
  ~0.65 s write stall as on `vck190_fmcp1` appeared in any recording on this board.

### Burst and 40 GB recordings

Single recordings at a fixed rate. `uzev` rows: design 1.0, 16 x 8 MB buffers unless the row
says otherwise; `vck190_fmcp1` and `zcu106_hpc0` rows: 32 x 8 MB buffers, `rm` + `fstrim` + 30 s
idle before each, 10 GB from 1000 MB/s upwards, then 40 GB at the sweep's rate and one step
above. "Burst" rows are 10 GB recordings (inside the SLC cache of every drive here); the 40 GB
rows run well past the 970 EVO's cache, but are still inside the caches of the 1 TB drives.

| target | SSD | layout | recording | rate (MB/s) | result | FIFO high-water (of 4096 beats) |
|---|---|---|---|---|---|---|
| `uzev` † | Samsung 970 EVO 250GB | single | 10 GB | 250 | pass | 228 |
| `uzev` † | Samsung 970 EVO 250GB | single | 10 GB | 500 | pass | 377 |
| `uzev` † | Samsung 970 EVO 250GB | single | 10 GB | 1000 | pass | 842 |
| `uzev` † | Samsung 970 EVO 250GB | single | 10 GB | 1250 | pass | 1732 |
| `uzev` † | Samsung 970 EVO 250GB | single | 10 GB | **1400** | pass (highest burst) | 1101 |
| `uzev` † | Samsung 970 EVO 250GB | single | 10 GB | 1500 | drops after ~8.5 GB | full |
| `uzev` † | Samsung 970 EVO 250GB | single | 40 GB | **300** | pass (sustained) | 363 |
| `uzev` † | Samsung 950 PRO 256GB | single | 40 GB | **800** | pass (sustained) | 739 |
| `uzev` † | Samsung 950 PRO 256GB | single | 40 GB | 1000 | drops (SSD writes ~950 MB/s) | full |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 10 GB | 1400 | pass | 1058 |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 10 GB | **1850** | pass with `--buffers 32` (highest burst) | 1596 |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 10 GB | 2000 | drops (array writes ~1.9 GB/s) | full |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 40 GB | **600** | pass (sustained) | 639 |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 40 GB | 700 | drops after ~31 GB | full |
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
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 1000-2750 (8 steps) | pass, all | 846-2420 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | **3000** | pass (highest burst) | 2881 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 3200 | drops from 3.30 GB (above the drive's ~3.04 GB/s write rate on Gen3 x4) | full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | **3000** | pass (in the cache) | 3146 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | 3200 | drops from 4.78 GB | full |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 1000-2500 (7 steps) | pass, all | 753-1858 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **2750** | pass (highest clean step of this sweep) | 2077 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 3000 | drops: 1167 beats, once (first gap 2.70 GB; FIFO overflows) | full |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3000** | pass (in the cache) | 2096 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; the generator maximum) | 3854 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 1000-2500 (7 steps) | pass, all | 812-2198 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | **2750** | pass (highest burst) | 2196 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 3000 | drops from 10.10 GB (above the drive's ~2.95 GB/s write rate) | full |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | **2750** | pass (in the cache) | 3453 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | 3000 | drops from 9.37 GB | full |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 1000-3000 (9 steps) | pass, all | 730-2682 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **3200** | pass (highest burst = the generator maximum) | 3528 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3200** | pass (in the cache; no step above the generator maximum) | 4034 |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

Reference: `fio --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8 --size=10G`
on the same XFS filesystem writes 1502 MB/s to the 970 EVO (inside its SLC cache).

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): no step failed. Both layouts record 10 GB at
  3.2 GB/s, the generator maximum, and the "one step above" 40 GB recordings passed too.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`): no step failed either; both layouts record 10 GB and
  40 GB at 3.2 GB/s, the generator maximum. The FIFO high-water marks of the single-drive bursts
  and of both 40 GB recordings (2-86 beats) are far lower than in every other recording of that
  session; this was not investigated (the drop counters and `fdverify` are what the table is
  judged by).
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): one drive bursts 10 and 40 GB at 2750 MB/s
  (3000 MB/s exceeds its ~2.95 GB/s write rate on Gen3 x4); RAID0 records 10 and 40 GB at the
  generator's 3200 MB/s (40 GB with 62 beats of FIFO to spare). With the pre-fix design: one drive
  1500 MB/s, RAID0 10 GB at 2500 MB/s, and 40 GB at 2500 and 2750 MB/s each lost 94-193 beats to
  a FIFO overflow at a buffer boundary.
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): one drive bursts 10 and 40 GB at 3000 MB/s (3200 MB/s
  exceeds its ~3.04 GB/s write rate on Gen3 x4). Between 2750 and 3200 MB/s the RAID0 pair was
  clean in 6 of 8 in-cache recordings of 10-40 GB (32 GB at 2750 MB/s and twice at 3000 MB/s,
  10 GB at 2750 MB/s, 40 GB at 3000 and 3200 MB/s); the two failures (430 beats at 3200 MB/s over
  32 GB, 1167 beats at 3000 MB/s over 10 GB) are single overflows of the 64 KB fabric FIFO at a
  buffer boundary, not a deficit of the SSDs or the ring; see
  [Where the bottlenecks are](#5-latency-budgets-not-bandwidth). With the pre-fix design: one
  drive 1500 MB/s, RAID0 10 GB at 2500 MB/s and 40 GB at 3000 MB/s.

### Long recordings past the SLC cache

For the 1 TB drives a 32 GB or 40 GB recording stays inside the SLC cache, so the rate that
holds for a long recording was measured with single recordings of about 1.5 to three times the cache (fresh
XFS, `rm` + `fstrim` and **300 s** of idle before each, 32 x 8 MB buffers). Sizes are the
`fdrec --size` values (GiB), with GB (10⁹ bytes) in brackets.

| target | SSD | layout | recording | rate (MB/s) | result | drops (beats) | FIFO high-water (of 4096) | first gap |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 143 GiB (153.5 GB, ~2x the cache) | **1000** | pass, `fdverify` PASS | 0 | 790 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 240 GiB (257.7 GB, ~1.8x the cache) | **2750** | pass, `fdverify` PASS | 0 | 3257 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB (257.7 GB, ~2.1x the cache) | **1750** | pass, `fdverify` PASS | 0 | 1588 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB | 2000 | drops | 969 436 129 | full | 125.17 GB (the cache end) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB (515.4 GB, ~2x the cache) | 3200 | drops | 15 181 (3 events) | full | 415.13 GB (past the cache) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 3000 | drops | 16 643 (3 events) | full | 25.69 GB (inside the cache) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2750 | drops | 3897 (one event) | full | 65.41 GB (inside the cache) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2500 | drops | 16 584 (2 events) | full | 19.98 GB (inside the cache) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 2250 | drops | 15 358 (one event) | full | 434.50 GB (past the cache) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | **2000** | pass, `fdverify` PASS | 0 | 3050 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB (214.7 GB, ~1.8x the cache) | 3000 | drops | 3 920 223 261 | full | 121.52 GB (the cache end) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | 3200 | drops (above the drive's write rate) | 4 920 282 959 | full | 0.88 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | 2000 | drops (past the cache, TLC ~1.77 GB/s) | 650 031 494 | full | 127.04 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 2292 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 221 GiB (237.3 GB, ~2x the cache) | **1750** | pass, `fdverify` PASS | 0 | 1896 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~1.5x the pair's cache) | 3000 | drops | 846 | full | 188.32 GB (past the cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 3200 | drops | 1191 | full | 3.83 GB (inside the cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 2750 | drops | 14 934 (one event) | full | 17.51 GB (inside the cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **2500** | pass, `fdverify` PASS | 0 | 2627 | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB (214.7 GB, ~3x the cache) | 2750 | drops | 4 350 513 076 | full | 10.39 GB (68 beats, a FIFO overflow inside the cache; then past the cache) |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | 3000 | drops (above the drive's write rate) | 5 344 583 747 | full | 0.49 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | 2000 | drops (past the cache, TLC ~1.8 GB/s) | 785 285 387 | full | 95.95 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 2567 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | 3200 | drops | 10 150 (2-3 events) | full | 58.29 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | 2750 | drops | 1929 (one event) | full | 232.33 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | 2500 | drops | 1226 (first event 210) | full | 74.87 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **2250** | pass, `fdverify` PASS | 0 | 3221 | - |

* **Sabrent Rocket 2230 1TB on `vck190_fmcp1`**: the sweep's rates hold past the cache. The post-cache write
  rate (~1.8 GB/s per drive, ~3.6 GB/s for the pair, see [The SLC cache](#the-slc-cache)) is
  far above them; what limits the single drive is the rare ~0.65 s write stall, and the RAID0
  run's high-water mark (3257 of 4096) shows little margin at 2750 MB/s.
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, single**: 1750 MB/s holds over 200 GiB and 221 GiB;
  2000 MB/s drops from 127 GB, just past the cache (the drive then writes ~1.78-1.80 GB/s), and
  3000 MB/s from 121.5 GB, where the cache ends. Up to the cache end one or two writes were in
  flight, after it four to eight: the margin at 1750 MB/s is about 1 % (the post-cache rate is
  1768 MB/s, median). With the pre-fix design one drive held 1500 MB/s.
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, RAID0**: 2500 MB/s holds over 350 GiB; at
  2750-3200 MB/s each 350 GiB run lost 846-14 934 beats in one or a few FIFO overflows at a
  buffer boundary, inside and past the cache. Every first gap starts 69 744 bytes (64 KiB +
  4208 B) after an 8 MiB buffer boundary: the 64 KB fabric FIFO filled while the AXI DMA restart
  at the boundary was late (the FIFO covers 26 µs at 2.5 GB/s, 22 µs at 3 GB/s). This is host
  interrupt latency on the Cortex-A53, not the SSDs. With the pre-fix design the pair held
  2250 MB/s, and 2500-3000 MB/s lost 216-2443 beats in the same way.
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, single**: 1750 MB/s holds over 240 GiB. Inside the
  cache 0-1 writes were in flight, after it 1-5: the drive's post-cache rate (~1.77 GB/s) is only
  ~1 % above the recording rate. At 2000 MB/s the recording is clean until the cache ends
  (125.17 GB) and then drops 15.5 GB of data.
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, RAID0**: the pair writes ~3.47 GB/s after its cache,
  above every rate tested, yet every 480 GiB recording from 2250 to 3200 MB/s lost 3897-16 643
  beats (62-266 KB in 515 GB) in 1-3 isolated events, inside and past the cache alike, with only
  1-8 writes in flight: FIFO overflows while a DMA restart was late (the 64 KB FIFO lasts
  20-29 µs at these rates), the same signature as on `zcu106_hpc0`, not the SSDs. The first clean
  rate over 480 GiB was 2000 MB/s. Each rate was tried once, so how often 2250-3200 MB/s passes a
  long recording is not known; over 32 and 40 GB the pair records 3200 MB/s cleanly.
* **Sabrent Rocket 2230 1TB on `zcu106_hpc0`**: the ~72 GB cache shows; one drive held
  1750 MB/s over 200 GiB (2000 MB/s drops from 95.95 GB, just past the cache: the post-cache
  rate is ~1.8 GB/s, as on `vck190_fmcp1`). The RAID0 pair held 2250 MB/s over 350 GiB; at
  2500-3200 MB/s each 350 GiB run lost 1226-10 150 beats in one to three FIFO overflows at a
  buffer boundary (every first gap starts 65 648 bytes after an 8 MiB boundary), not to the
  drives. With the pre-fix design the cache did not show (the per-slot ceiling was below the
  post-cache rate), one drive held 1500 MB/s, and the pair only 1750 MB/s (2000-2750 MB/s lost
  1649-32 340 beats in the same way; at 2000 MB/s one restart was about 160 µs late).

### Playback

Design 1.1 (AXI DMA MM2S, 4096-beat egress FIFO, `fdrec_check` sink), XFS, `fdplay` with
queue depth 8. Each run plays a 10 GB test-pattern recording made at 1000 MB/s with 0 drops.
"Runs" lists underflow-free runs / runs at that rate.

| target | SSD | layout | buffers | highest clean playback rate | runs | first rate with underflows | read fio reference |
|---|---|---|---|---|---|---|---|
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 16 x 8 MB | **2000 MB/s** | 9/9 | 2200 MB/s (1 of 3 runs), 2400 MB/s (1 of 6), 2600 MB/s (1 of 2) | 2161-2498 MB/s; 3184 MB/s with hugepage fixed buffers |
| `uzev` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 32 x 8 MB | **2600 MB/s** | 6/6 | 2800 MB/s (1 of 1) | as above |
| `uzev` † | 950 PRO 256GB | single | 16 x 8 MB | **1500 MB/s** | 4/4 | 1600 MB/s (1 of 3), 1700 MB/s (1 of 1) | 1583 MB/s; 1593 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 970 EVO + 950 PRO | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each | none (no higher rate exists) | 3650–3871 MB/s |
| `vck190_fmcp1` | 950 PRO 256GB | single | 32 x 8 MB | **2250 MB/s** | 3/3 | 2500 MB/s (41–49 M underflow ticks) | 2285–2291 MB/s |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 each | none (no higher rate exists) | 4259 and 4465 MB/s; 4529 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB | **3200 MB/s** (marginal) | sweep clean; 2 of 3 runs at 3200 | 3200 in one confirmation run (3414 ticks) | 4125 and 4258 MB/s; 7792 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 16 x 8 MB | **3000 MB/s** | 3/3 | 3200 (2865 ticks in the sweep; the recheck was clean) | as above |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 32 x 8 MB | **3000 MB/s** | 3/3 (3200 MB/s: clean in 3 of 4 runs) | 3200 MB/s (993 ticks in the sweep; the recheck was clean) | 4602 and 4828 MB/s; 6312 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 16 x 8 MB | **3000 MB/s** | 3/3 | 3200 MB/s (498 314 ticks in the sweep; the recheck was clean) | as above |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB | **3200 MB/s** in the sweep (marginal) | 1 of 3 at 3200; 14 of 20 runs clean from 2500 to 3200 MB/s over the session | 3200 in both confirmations (52 684 and 68 523 ticks); isolated stalls at any rate from 2500 | 4430 and 4531 MB/s; 7936 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 16 x 8 MB | **3200 MB/s** (the sink maximum) | 3/3 | none (no higher rate exists) | as above |
| `zcu106_hpc0` † | 970 EVO + 950 PRO | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3000 MB/s** (marginal) | sweep clean; 1 of 2 confirmations clean, each | 3000 in one confirmation run (309 and 4052 ticks); 3200 | 2479–2541 MB/s |
| `zcu106_hpc0` † | 950 PRO 256GB | single | 32 x 8 MB and 16 x 8 MB | **1500 MB/s** | 3/3 each | 1750 MB/s (50–58 M underflow ticks) | 1585 MB/s |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB | **2250 MB/s** (marginal) | 2/3 (49 785 ticks once) | 2500 MB/s (89 891 ticks; the recheck was clean) | 2812 and 2926 MB/s (fio CPU-bound); 5965 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 16 x 8 MB | **3200 MB/s** (the sink maximum) | 2/3 (231 371 ticks once) | none (no higher rate exists) | as above |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **2250 MB/s** | 3/3 each (9/9 over the session) | 2500 MB/s (53 732 to 37.7 M ticks; clean in 1 of 12 runs at 2500, 0 of 3 at 2750; 3000 clean in 3 of 5) | 2845 and 2856 MB/s (fio CPU-bound); 3182 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **2250 MB/s** | 3/3 each | 2500 MB/s (372 270 and 102 266 ticks; both rechecks clean) | 2858 and 2886 MB/s (fio CPU-bound); 3124 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB | **2250 MB/s** (marginal) | 2/3 (322 679 ticks once) | 2500 MB/s (6003 ticks; the recheck was clean) | 2784 and 2710 MB/s (fio CPU-bound); 5138 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 16 x 8 MB | **2500 MB/s** | 3/3 | 2750 MB/s (6622 ticks; the recheck was clean) | as above |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

The `uzev` rows were measured 2026-10-02; the `vck190_fmcp1` and `zcu106_hpc0` rows of the
970 EVO / 950 PRO were measured 2026-10-03 and those of the 1 TB drives 2026-10-17 to
2026-10-19, all with 10 GB playbacks. On the VCK190 RAID0 plays back cleanly at the full sink
rate of 3.2 GB/s. The 970 EVO alone reads 3264 MB/s with fio (10 GB) there. The
`zcu106_hpc0` rows (2026-10-03) sit at the sink ceiling for RAID0: 3000 MB/s is clean most of
the time, but a few hundred to a few thousand underflow ticks appear in about one run in three
at 3000 and 3200 MB/s; `fdplay` there reads faster than fio does (3000 vs ~2500 MB/s).

With the Sabrent Rocket 2230 1TB pair (Gen4 x4) one drive alone plays back at the 3.2 GB/s
sink maximum every time; RAID0 is marginal there (a read stall of a few ms in about one run
in three at 3000-3200 MB/s). fio without fixed buffers is CPU-bound at ~4.1-4.5 GB/s on this
board; with hugepage fixed buffers it reads the RAID0 at 7792 MB/s.

The Samsung 980 PRO 1TB pair (Gen4 x4 on `vck190_fmcp1`) plays back faster there than on
`zcu106_hpc0`: one drive at 3000 MB/s every time (3200 MB/s in 3 of 4 runs with 32 buffers),
RAID0 up to the 3.2 GB/s sink maximum, with an isolated read stall (7 000-70 000 underflow ticks)
in about 3 of 10 RAID0 runs at 2500-3200 MB/s (32 buffers), at any of these rates. fio reads one
drive at 6312 MB/s and the pair at 7936 MB/s with hugepage fixed buffers.

On `zcu106_hpc0` the single 980 PRO 1TB plays back cleanly up to 2250 MB/s. At 2500 and
2750 MB/s it under-runs in almost every run, although 3000 MB/s was clean in 3 of 5 runs and fio
reads the same file at 2845-2856 MB/s; see
[Single-drive playback deficit on zcu106_hpc0](#single-drive-playback-deficit-on-zcu106_hpc0).
RAID0 reaches 2250 MB/s with 32 buffers (2 of 3) and the 3200 MB/s sink maximum with 16 buffers
(2 of 3); the failures above that are short read stalls at random rates. With the pre-fix design
it was 1250 MB/s (one drive) and 2250 / 1250 MB/s (RAID0, 32 / 16 buffers).

With the current design the Sabrent Rocket 2230 1TB on `zcu106_hpc0` plays back at 2250 MB/s
from one drive and at 2250 (32 buffers, 2 of 3) / 2500 MB/s (16 buffers) from RAID0; with the
pre-fix design it was 1500 MB/s and 2000 / 2250 MB/s. Above that the failures are short read
stalls, not a rate limit: every failing sweep step was clean on its recheck, and the single
drive played 3000 MB/s cleanly once. fio without fixed buffers is CPU-bound on this board
(2.7-2.9 GB/s, one A53 core at 92-98 %); with hugepage fixed buffers it reads one drive at
3124 MB/s and the pair at 5138 MB/s.

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

#### Playback soon after a recording

With the pre-fix design (2026-10-17) the 980 PRO 1TB RAID0 on `zcu106_hpc0` had a playback limit
that depended on how long ago the file was recorded; with the current design (2026-10-19, same
drives, board and method) it does not. Each run below plays a 10 GB file recorded at 1000 MB/s
(0 drops), 32 x 8 MB buffers; times are from the end of the recording ("clean" = 0 underflows;
otherwise the underflow ticks):

| design | time since the recording | 2000 MB/s | 2250 MB/s | 2500 MB/s | 2750 MB/s | 3000 MB/s | 3200 MB/s |
|---|---|---|---|---|---|---|---|
| pre-fix | ~0.5 min | clean | | 33.4 M | | clean | |
| pre-fix | ~2-2.5 min | | | 37.0 M, then 30.3 M | 16.6 M | 0.21 M | |
| pre-fix | ~3 min | clean | clean | clean | | clean | |
| pre-fix | ~10.5 min | clean | | clean | | clean | |
| current | ~0.5 min | clean | | 7407 | | clean | clean |
| current | ~2-3.5 min | clean | clean | clean (3 runs) | clean | clean (2 runs) | 24 299, then clean |
| current | ~10.3 min | 22 627 | | clean | | 1022 | clean |

With the pre-fix design, playback at 2500-3000 MB/s underflowed in 5 of 6 runs within about
three minutes of the recording (the 10 GB file took 4.6 s at 2500 MB/s instead of 4.38 s: the
drives delivered less), and all 7 runs up to 3000 MB/s from about three minutes on were clean.
With the current design 3000 and 3200 MB/s were clean 0.5 min after the recording, and the
underflows that remain are small (1022-231 371 ticks, in 7 of 32 RAID0 10 GB runs at
2000-3200 MB/s, sweeps included) and come at random rates and times, as with the same drives on
`vck190_fmcp1` and with the Sabrent Rocket 2230 1TB pair on `zcu106_hpc0`. The effect was the
former per-slot ceiling, not host latency: just after a recording the drives read more slowly
(most likely while they move the fresh data out of their SLC cache), and a slot limited to
~1.6 GB/s left no headroom to catch up.

#### Single-drive playback deficit on zcu106_hpc0

An open observation with the current design (2026-10-19): one Samsung 980 PRO 1TB on
`zcu106_hpc0` plays a 10 GB file back cleanly at 2250 MB/s and mostly at 3000 MB/s, but almost
never at 2500 or 2750 MB/s. Underflow ticks per run (10 GB recorded at 1000 MB/s, 32 x 8 MB
buffers unless stated; "clean" = 0):

| runs | 2250 MB/s | 2500 MB/s | 2750 MB/s | 3000 MB/s |
|---|---|---|---|---|
| sweeps, 20 s after the recording | clean (6 runs, 32 and 16 buffers) | 16.9 M, recheck 5.05 M; 16 buffers: 18.9 M, recheck clean | | |
| ~0.5 min after a recording | | 12.9 M | | clean |
| ~10.5 min after a recording | | 25.7 M | | clean |
| three interleaved rounds, 0.5-2 min after a recording | clean (3 runs) | 5.16 M, 53 732, 33.6 M | 22.3 M, 25.9 M, 20.9 M | clean, 842 079, 109 811 |
| 16 buffers, three runs | | 28.6 M, 8.6 M, 37.7 M | | |

2250 MB/s was clean in 9 of 9 runs and 3000 MB/s in 3 of 5, but 2500 MB/s in only 1 of 12 runs
(0 of 7 with 32 buffers, 1 of 5 with 16) and 2750 MB/s in 0 of 3. Most failures are millions of
ticks: the 10 GB file took up to ~5 % longer than at the nominal rate, a shortfall over the whole
file rather than one short stall. It does not depend on the idle time before the playback (0.5 or
10.5 min) or on the ring size, and three interleaved rounds (2250, 2500, 2750 and 3000 MB/s in
turn) reproduced it. fio reads the same file at 2845-2856 MB/s (3182 MB/s with hugepage fixed
buffers). It was not seen with the same drive on `vck190_fmcp1` (3000 MB/s clean in 3 of 3 runs)
nor with the Sabrent Rocket 2230 1TB on `zcu106_hpc0` (its 2500 MB/s failures were 0.1-0.37 M
ticks, clean on recheck). The cause is not known. For one 980 PRO 1TB on `zcu106_hpc0`, play back
at 2250 MB/s or less.

### CPU load

Measured with `top` during a transfer, after it had settled:

With 16 x 8 MB buffers:

| transfer | total CPU (4 cores) | transfer process |
|---|---|---|
| `fdrec`, 1000 MB/s to the 970 EVO | about 2 % (user + system); the rest idle or I/O wait | `fdrec` 8 % of one core (3 s samples) |
| `fdplay`, 1000 MB/s from RAID0 | 6 % (user + system + softirq), 17 % I/O wait | `fdplay` 24 % of one core (2 s samples) |

These are `uzev` figures (pre-fix †). On `vck190_fmcp1` (two Cortex-A72 cores) the CPU was measured per
core from `/proc/stat` over 10 GB transfers at 1000 MB/s (two runs each, 32 x 8 MB buffers):

| transfer | per core (busy) | transfer process |
|---|---|---|
| `fdrec`, 1000 MB/s to the 970 EVO | core 0 10–10.4 %, core 1 5.7 % | `fdrec` 15.2 % of one core |
| `fdrec`, 1000 MB/s to RAID0 | core 0 11 %, core 1 9–10 % | `fdrec` 17.6 % of one core |
| `fdplay`, 1000 MB/s from the 970 EVO | runs on one core | `fdplay` 10.3 % of one core |
| `fdplay`, 1000 MB/s from RAID0 | runs on one core | `fdplay` 13.2 % of one core |
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | run 1: core 0 11.4 %, core 1 8.2 %; run 2: core 0 6.8 %, core 1 10.9 % | `fdrec` 16.1–16.3 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent) | core 0 8.8–9.1 %, core 1 9.1–9.5 % | `fdrec` 16.6 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | runs on one core (12.1 / 13.8 %; the other 2.4 / 0.8 %) | `fdplay` 12.4 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent) | run 1: core 0 10.1 %, core 1 3.4 %; run 2: core 0 6.2 %, core 1 7.6 % | `fdplay` 11.9 % of one core |
| `fdrec`, 1000 MB/s to the Samsung 980 PRO 1TB | run 1: core 0 5.9 %, core 1 10.8 %; run 2: core 0 8.2 %, core 1 8.6 % | `fdrec` 15.5 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | core 0 8.7–9.3 %, core 1 8.5–8.7 % | `fdrec` 16.2–16.3 % of one core |
| `fdplay`, 1000 MB/s from the Samsung 980 PRO 1TB | runs on one core (11.4 / 12.9 %; the other 1.8 / 0.7 %) | `fdplay` 11.8 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | runs on one core (10.8 / 12.9 %; the other 3.0 / 1.2 %) | `fdplay` 12.4 % of one core |

Nearly all of it is system time; the core the app runs on shows 81–89 % I/O wait (waiting, not
busy); 62–86 % with the Sabrent drives (2026-10-17, where a `top` cross-check gave the same
per-process figures: `fdrec` 14.1–16.6 %, `fdplay` 10.8–13.5 % of one core) and 68–87 % with
the 980 PROs (2026-10-18; `top`: `fdrec` 13.4–16.2 %, `fdplay` 10.7–13.3 % of one core). The
recorder's CPU follows the rate, not the SSD: the Sabrent and 980 PRO rows cost the same as the
970 EVO rows.

On `zcu106_hpc0` (four Cortex-A53 cores at 1.2 GHz), same method (10 GB at 1000 MB/s, two runs,
32 x 8 MB buffers), the load spreads over two cores at most (the app's thread and the core
taking the DMA / NVMe interrupts):

| transfer | busy, summed over the cores | share of the 4-core total | transfer process |
|---|---|---|---|
| `fdrec`, 1000 MB/s to the 970 EVO † | 25–26 % of one core | about 6 % | `fdrec` 23 % of one core |
| `fdrec`, 1000 MB/s to RAID0 † | 29–31 % of one core | about 7 % | `fdrec` 27.5 % of one core |
| `fdplay`, 1000 MB/s from the 970 EVO † | 17–18 % of one core | about 4 % | `fdplay` 15.4 % of one core |
| `fdplay`, 1000 MB/s from RAID0 † | 23–24 % of one core | about 6 % | `fdplay` 21 % of one core |
| `fdrec`, 1000 MB/s to the 980 PRO 1TB | 25.4–25.5 % of one core | about 6.5 % | `fdrec` 23.5–23.6 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | 26.6–26.8 % of one core | about 6.5 % | `fdrec` 24.9–25 % of one core |
| `fdplay`, 1000 MB/s from the 980 PRO 1TB | 19.4–19.6 % of one core | about 5 % | `fdplay` 16.4–16.6 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | 22.4–24.4 % of one core | about 6 % | `fdplay` 19.9–22 % of one core |
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | 27 % of one core | about 7 % | `fdrec` 24.5 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent Rocket 2230 1TB) | 28–29 % of one core | about 7 % | `fdrec` 25.6–25.7 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | 21.5–22 % of one core | about 5.5 % | `fdplay` 19 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent Rocket 2230 1TB) | 22–23 % of one core | about 5.5 % | `fdplay` 18.6–18.8 % of one core |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

The 980 PRO rows (2026-10-19, current design) were cross-checked with `top` (`fdrec`
23.9–24.6 %, `fdplay` 16–23 % of one core); during `fdplay` the I/O wait sits on one or two
cores (50–76 % on the busiest). With the pre-fix design the same drives cost about the same
(`fdrec` 23–25 %, `fdplay` 16–17 % of one core; RAID0 `fdplay` now 20–22 %, two runs). The
Sabrent rows (2026-10-19, current design): `top` gives `fdrec` 22–25 % and `fdplay`
17.6–18.6 % of one core, and the pre-fix design cost the same (`fdrec` 24–26 %, `fdplay`
17–18 %): the clock fix does not change the CPU cost per MB. At the higher rates the current
design allows, `fdrec` uses 67–68 % of one core at 3000 MB/s (one 980 PRO), 73–74 % at
3000 MB/s (980 PRO RAID0) and ~78 % at 3200 MB/s (Sabrent RAID0), and `fdplay` 41 % at
2250 MB/s (one Sabrent) and 42 % at 2500 MB/s (one 980 PRO); see
[Results: zcu106_hpc0](#results-zcu106_hpc0).

The two methods (`top` on `uzev`, `/proc/stat` per core on the other boards) are not directly comparable;
the [comparison](#comparison-with-fpga-drive-aximm-pcie-dd-method) measures both boards the same
way.

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
* The **Sabrent Rocket 2230 1TB** (DRAM-less, Gen4) writes ~4.5 GB/s for about the first
  75 GB on an empty, trimmed drive, then a flat ~1.8 GB/s (1779-1821 MB/s from 80 to 320 GB).
  On `vck190_fmcp1` its sustained recording rate is set not by the cache but by rare ~0.65 s
  write stalls (1000 MB/s clean over 143 GiB, see
  [Long recordings](#long-recordings-past-the-slc-cache)). On `zcu106_hpc0` the same cache
  shows: ~72 GB at ~2.9 GB/s (the Gen3 x4 link's rate), then a flat ~1.8 GB/s (median
  1798 MB/s), the same post-cache rate as on `vck190_fmcp1`; there it sets the sustained
  single-drive rate (1750 MB/s over 200 GiB). With the pre-fix design the board wrote at most
  ~1.56 GB/s per slot with this drive, below its post-cache rate, so the cache did not show at
  all (a flat ~1554 MB/s over 300 GiB).
* The **Samsung 980 PRO 1TB** caches about 115-120 GB on an empty, trimmed drive (the same on
  both boards). It writes into the cache at ~4.7 GB/s on `vck190_fmcp1` (Gen4 x4; the fio limit
  of that host) and ~2.98 GB/s on `zcu106_hpc0` (the Gen3 x4 link), and a flat **~1.77 GB/s**
  after it on both boards (the pair: ~3.47 GB/s after ~235-250 GB on `vck190_fmcp1`; on
  `zcu106_hpc0` one fio job writes only ~3.4 GB/s to the pair, so only a 5 % knee shows, at
  ~247 GB). One drive records 1750 MB/s cleanly past the cache on both boards, 2000 MB/s only
  until the cache ends. This is the drive's TurboWrite cliff. With the pre-fix design
  `zcu106_hpc0` measured a lower post-cache rate, ~1.52 GB/s, likely because the ~1.59 GB/s
  per-slot ceiling could not make up the drive's pauses after the cache: the drive accepts data
  in bursts faster than its average and pauses while it programs its TLC flash, so with the
  ceiling the average fell below both (an inference from the same drives measured under three
  host limits, not from a trace of the drive).

Measured with one sequential fio write (queue depth 8, 8 MB blocks, `O_DIRECT`) on a freshly
created XFS, 60 s of idle first, bandwidth logged every 2 s:

| SSD | target | layout | written | rate inside the cache | cache size (empty, trimmed) | rate after the cache |
|---|---|---|---|---|---|---|
| Samsung 970 EVO 250GB | `uzev` † | single | 32 GB steps, 40 GB | up to ~1.5 GB/s | ~13-14 GB | ~330 MB/s |
| Samsung 950 PRO 256GB | `uzev` † | single | 32 GB steps, 40 GB | ~955 MB/s | no cliff seen | ~955 MB/s |
| Sabrent Rocket 2230 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.5-4.6 GB/s | **~75 GB** | **~1.8 GB/s**, flat |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.45 GB/s (fio CPU-bound) | **~140 GB** (~70 GB per drive) | **~3.6 GB/s**, flat |
| Samsung 980 PRO 1TB | `zcu106_hpc0` | single | 300 GiB | 2965-2986 MB/s (the Gen3 x4 link) | **~115-120 GB** (full rate to ~113 GB, flat from 127 GB) | **~1.77 GB/s**, flat (1717-1823 MB/s, median 1768) |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3360-3469 MB/s (fio CPU-bound) | **~247 GB** (a 5 % knee) | ~3.26 GB/s (3170-3288 MB/s; partly fio-bound) |
| Samsung 980 PRO 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.7 GB/s (fio CPU-bound: a lower bound for the drive) | **~115-120 GB** (full rate to 113.5 GB, flat from 129 GB) | **~1.77 GB/s**, flat (1729-1798 MB/s) |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.7 GB/s (fio CPU-bound) | **~235-250 GB** (~118 GB per drive) | **~3.47 GB/s**, flat (3407-3504 MB/s) |
| Sabrent Rocket 2230 1TB | `zcu106_hpc0` | single | 300 GiB | 2844-2905 MB/s (the Gen3 x4 link) | **~70-73 GB** | **~1.8 GB/s**, flat (1777-1822 MB/s, median 1798) |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3133-3363 MB/s (fio CPU-bound) | not visible (flat over 537 GB: the pair's ~3.6 GB/s post-cache rate is above what one fio job writes) | same: ~3230 MB/s |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

The 970 EVO and 950 PRO rows summarize the sweeps and fio runs above. The cache sizes and
post-cache rates of the 1 TB drives are the drives', the same on both boards; their in-cache
rates on `zcu106_hpc0` are the Gen3 x4 link's (~2.9 GB/s Sabrent, ~2.98 GB/s 980 PRO), and the
980 PRO's on `vck190_fmcp1` is fio's (~4.7 GB/s). None of the drives throttled (fan on the
cards).

**In-cache and post-cache rates.** A recording shorter than the cache only needs the
in-cache rate; a longer one needs the post-cache rate, and the 32 GB sweep shows only the
first for the 1 TB drives. The cache refills only while the drive is idle (how fast was not
measured), so back-to-back recordings may not each get a full cache. Size the rate for the
longest recording you need: a short burst test, such as a 10 GB recording, a 4 GB `dd`, or
fio over 32 GB (which runs at full speed through the cache of the 250 GB drives and then
slower, and entirely inside the cache of the 1 TB drives), overstates what a drive sustains.

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

### At a glance

All figures in MB/s (10⁶ bytes/s), measured 2026-10-02/03 with the 970 EVO and 950 PRO on all
three targets, and 2026-10-17 to 2026-10-19 with the 1 TB pairs (rows marked † pre-fix, see
[Setups](#setups); the zcu106 1 TB rows with the current design). **b** = burst (the write fits inside
the drive's SLC write cache), **s** = sustained (the recording ran past the cache, or the drive
has no cache cliff). Reads have no cache effect. For the 1 TB drives the 32 GB columns are
inside the cache (**b**), so the "fdrec sustained" cell also gives the rate that held over a
recording past the cache.

| target / config | WRITE: drive ceiling (fio QD8, 4 GB) | WRITE: dd script (4 GB) | WRITE: fdrec highest clean (4 GB) | WRITE: dd (32 GB) | WRITE: fdrec sustained (32 GB) | READ: drive ceiling (fio QD8, 4 GB) | READ: dd script (4 GB) | READ: fdplay highest clean (4 GB) |
|---|---|---|---|---|---|---|---|---|
| uzev: 970 EVO 250GB † | 1535 **b** | 1024 **b** | 1500 **b** | 460 (average across the cache end) | **250 s** | 1574 | 1398 | 1500 |
| uzev: 950 PRO 256GB † | 971 **s** | 948 **s** | 750 **s** (1000: clean in 2 of 3 runs) | 956 **s** | **750 s** | 1568 | 1267 | 1500 |
| uzev: RAID0 (both) † | 1936 **b** | 1302 **b** | 1750 **b** | 1176 (one run) | **500 s** | 2271 | 1705 | 2750 |
| vck190: 970 EVO 250GB | 1535 **b** | 1519 **b** | 1500 **b** | 492 (average across the cache end) | **250 s** | 3217 | 2382 | 3000 (top step) |
| vck190: 950 PRO 256GB | 953 **s** | 940 **s** | 1000 **s** (16 buffers: 750) | 946 **s** | **750 s** | 2264 | 2087 | 2250 |
| vck190: RAID0 (both) | 1911 **b** | 1855 **b** | 2000 **b** (16 buffers: 1750) | 1446 (one run) | **500 s** | 3652 | 2912 | 3000 (top step) |
| vck190: Sabrent Rocket 2230 1TB (Gen4 x4) | 4186 **b** (fio CPU-bound) | 1906 **b** | 3000 **b** (top step) | 1931 **b** (inside the ~75 GB cache) | 1000 **b**; past the cache (143 GiB): **1000 s** | 4186 (fio CPU-bound) | 3647 | 3000 (top step) |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 4352 **b** (fio CPU-bound) | 1711 **b** | 3000 **b** (top step; 16 buffers: 2000) | 2132 **b** (one run) | 2750 **b**; past the cache (240 GiB): **2750 s** | 3958 (fio CPU-bound) | 2689 | 1000 in the first sweep; 3000 (top step) in a repeat, 2 of 3 runs |
| vck190: Samsung 980 PRO 1TB (Gen4 x4) | 4694 **b** (fio CPU-bound) | 2006 **b** | 3000 **b** (top step) | 2073 **b** (inside the ~115 GB cache) | 3200 **b**; past the cache (240 GiB): **1750 s** | 4352 (fio CPU-bound; 6312 with fixed buffers, 10 GB) | 3678 | 3000 (top step; clean 2 of 3 runs, 32 and 16 buffers) |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 4623 **b** (fio CPU-bound) | 2173 **b** | 3000 **b** (top step; 16 buffers: 3000) | 2117 **b** (one run) | 3200 **b**; past the cache (480 GiB): **2000 s** (2250-3200 dropped a few thousand beats, FIFO overflows) | 4356 (fio CPU-bound; 7936 with fixed buffers, 10 GB) | 3920 | 2500 (16 buffers: 3000, top step) |
| zcu106: 970 EVO 250GB † | 1533 **b** | 1006 **b** | 1500 **b** | 463 (average across the cache end) | **250 s** | 1578 | 1322 | 1500 |
| zcu106: 950 PRO 256GB † | 965 **s** | 955 **s** | 1000 **s** (16 buffers: 750) | 960 **s** | **750 s** | 1571 | 1302 | 1500 |
| zcu106: RAID0 (both) † | 1941 **b** | 1263 **b** | 2000 **b** (16 buffers: 1750) | 1129 (one run) | **500 s** | 2453 | 1978 | 3000 (top step, clean 2 of 3) |
| zcu106: Samsung 980 PRO 1TB (Gen3 x4) | 2956 **b** | 1398 **b** | 3000 **b** (top step; 16 buffers: 3000) | 1491 **b** (inside the ~115 GB cache) | 3000 **b**; past the cache (200 GiB): **1750 s** | 2854 (fio CPU-bound; 3182 with fixed buffers, 10 GB) | 2026 | 2500 (clean 2 of 3; 16 buffers: 2000, 2 of 3; 10 GB: 2250) |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 3401 **b** (fio CPU-bound) | 1755 **b** | 3000 **b** (top step; 16 buffers: 3000) | 1749 **b** (one run) | 3000 **b**; past the cache (350 GiB): **2500 s** (2750-3200 dropped 846-14 934 beats, FIFO overflows) | 2824 (fio CPU-bound; 5965 with fixed buffers, 10 GB) | 2397 | 1500 (16 buffers: 2750, clean 1 of 3; 10 GB: 2250, 16 buffers 3200) |
| zcu106: Sabrent Rocket 2230 1TB (Gen3 x4) | 2827 **b** | 1398 **b** | 2000 **b** (16 buffers: 2750) | 1307 **b** (inside the ~72 GB cache) | 2750 **b**; past the cache (200 GiB): **1750 s** | 2879 (fio CPU-bound; 3124 with fixed buffers, 10 GB) | 2208 | 2250 (16 buffers: 2250; 2500 clean 1 of 3) |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 3229 **b** (fio CPU-bound) | 1536 **b** | 3000 **b** (top step; 16 buffers: 1750) | 1527 **b** (one run) | 3200 **b**; past the cache (350 GiB): **2250 s** (2500-3200 dropped 1226-10 150 beats, FIFO overflows) | 2653 (fio CPU-bound; 5138 with fixed buffers, 10 GB) | 2208 | 1750 (16 buffers: 2250; 2500 clean 1 of 3) |

| target / config | dd write: rate / % of one core / MB/s per % core | fdrec: rate / % of one core / MB/s per % core |
|---|---|---|
| uzev (Cortex-A53, 1.1 GHz): 970 EVO 250GB † | 1024 / 55 % / 18 | 1493 / 36 % / 41 |
| uzev: 950 PRO 256GB † | 948 / 53 % / 18 | 748 / 22 % / 35 |
| uzev: RAID0 (both) † | 1302 / 79 % / 16 | 1742 / 51 % / 34 |
| vck190 (Cortex-A72, 1.4 GHz): 970 EVO 250GB | 1519 / 60 % / 25 | 1495 / 24 % / 62 |
| vck190: 950 PRO 256GB | 940 / 38 % / 25 | 955 / 17 % / 55 |
| vck190: RAID0 (both) | 1855 / 79 % / 23 | 1909 / 35 % / 54 |
| vck190: Sabrent Rocket 2230 1TB | 1906 / 77 % / 25 | 2984 / 37 % / 81 |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 1711 / 69 % / 25 | 2984 / 51 % / 59 |
| vck190: Samsung 980 PRO 1TB | 2006 / 79 % / 25 | 2983 / 46 % / 64 |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 2173 / 88 % / 25 | 2985 / 48 % / 62 |
| zcu106 (Cortex-A53, 1.2 GHz): 970 EVO 250GB † | 1006 / 50 % / 20 | 1493 / 35 % / 40 |
| zcu106: 950 PRO 256GB † | 955 / 50 % / 19 | 958 / 27 % / 35 |
| zcu106: RAID0 (both) † | 1263 / 72 % / 17 | 1929 / 55 % / 33 |
| zcu106: Samsung 980 PRO 1TB | 1398 / 74 % / 19 | 2980 / 68 % / 44 |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 1755 / 90 % / 20 | 2982 / 74 % / 40 |
| zcu106: Sabrent Rocket 2230 1TB | 1398 / 67 % / 21 | 1990 / 49 % / 38 |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 1536 / 80 % / 19 | 2980 / 75 % / 37 |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

Selection rule: dd and fio cells are the median of three runs at their own speed (one run where
marked); `fdrec` / `fdplay` cells are the highest 250 MB/s step that was clean over 4000 MiB
(0 drops / 0 underflows) and, in the CPU table, the rate it achieved; "fdrec sustained" is the
highest clean step of the 32 GB [fdbench.sh sweep](#sustained-recording-rate). `uzev` recorder rows
used 16 x 8 MB buffers, `vck190_fmcp1` and `zcu106_hpc0` rows the shipped default of 32 x 8 MB
(the 16-buffer result is given where it differs). The `fdrec` and `fdplay` sweeps stop at
3000 MB/s, the last 250 MB/s step below the 3.2 GB/s generator and sink maximum. The per-%-core
figures of the `vck190` Sabrent and 980 PRO 1TB rows are higher than those of the 970 EVO and
950 PRO on the same board because the rates are higher: a fixed per-run cost is spread over more
data. On `zcu106_hpc0` several 4 GB cells of the 1 TB drives are decided by single rare events
(one FIFO overflow or one short read stall: the Sabrent's `fdrec` and `fdplay`, the 980 PRO
RAID0's `fdplay`), which is why 16 buffers can come out higher than 32; one 980 PRO's `fdplay`
cell is set by its 2500-2750 MB/s playback deficit (see
[Single-drive playback deficit on zcu106_hpc0](#single-drive-playback-deficit-on-zcu106_hpc0)).
The 32 GB and 10-40 GB recordings and the 10 GB playbacks are the better guide there.

How to read it: the "drive ceiling" columns show what the SSD itself delivered under Linux
with 8 requests in flight. The dd and burst columns are short transfers that a consumer drive
absorbs in its write cache; the bold **s** figure in the sustained column is what you can record
for as long as you like (for the 1 TB drives, the figure past the cache). The recorder figures are the strictest of all, because one late write anywhere in the
recording makes a rate fail, and they cost about half the CPU of `dd` for writes. The
[detailed tables](#results-uzev) and [why the figures differ](#why-the-figures-differ) follow,
and [Where the bottlenecks are](#where-the-bottlenecks-are) explains what limits each figure.

**uzev, zcu106 and vck190, same SSDs.** Writes are drive-bound on all three boards (fio 4 GB
writes 1533–1535 MB/s to the 970 EVO, 953–971 to the 950 PRO, 1911–1941 to RAID0), and the
sustained 32 GB rates and the highest clean `fdrec` rates are the same everywhere. Reads are
host-bound on the two Zynq UltraScale+ boards at about 1.3–1.6 GB/s per drive (the former
per-slot ceiling of the pre-fix design †, see [Setups](#setups)), while the
VCK190 reads the same drives 2–3 times faster. On the ZCU106, `fdplay` with its hugepage
buffers reads RAID0 faster than fio does (clean at 3000 MB/s against fio's 2453). The ZCU106
tracks `uzev` closely (same device, Cortex-A53 cores, XDMA Root Ports): `dd` CPU 17–20 MB/s per
% of a core, `fdrec` 33–40, `fdplay` 45–60.

Between `uzev` and the VCK190: Reads are much faster on the VCK190 (970 EVO: `dd` 2382 vs
1398 MB/s, fio 3217 vs 1574; RAID0 fio 3652 vs 2271; the dual `dd` script 4279 vs 2533), so on
`uzev` the host (the former per-slot ceiling), not the SSDs, set the read figures. Writes change much less: fio
writes 1535 MB/s to the 970 EVO on both boards (the drive's limit), and `fdrec`'s highest clean
rate on it is 1500 MB/s on both. RAID0 playback on the VCK190 is clean at 3000 MB/s (2875 MB/s
achieved), the top step below the 3.2 GB/s sink maximum, against 2750 MB/s on `uzev`. Per unit
of CPU, a 1.4 GHz Cortex-A72 core does about 1.4–1.6 times the work of a 1.1 GHz Cortex-A53
core: `fdrec` 54–62 vs 33–41 MB/s per % of a core, `dd` writes 23–25 vs 16–18. With 32 buffers
the ring hides short deficits over 4000 MiB: the 950 PRO is clean at 1000 MB/s while writing
951–955 MB/s, and not with 16 buffers. The sustained 32 GB rates are identical on both boards
(250 / 750 / 500 MB/s): they are set by the SSDs. A single `dd` write stream reaches the
970 EVO's limit on the VCK190 (1519 MB/s, fio 1535), whereas on `uzev` the CPU limited it to
1024 MB/s. With both drives, the dual `dd` read script reaches 4279 MB/s aggregate on the
VCK190. In 10 GB playbacks, RAID0 is clean at the 3.2 GB/s sink maximum.

**The 1 TB pairs.** The Sabrent Rocket 2230 1TB on `vck190_fmcp1` is the first Gen4 x4 link in
this design, and the first drive that writes faster than the recorder can feed it: fio writes
4.2-4.5 GB/s (fio itself CPU-bound), `fdrec` is clean at the 3000 MB/s top step over 4 GB on one
drive, and 10 GB recordings pass at the 3.2 GB/s generator maximum. Here the generator, not the
SSD, sets the burst rate, and a single `dd` write is CPU-bound on one A72 core (1906 MB/s,
77 % of a core). The 980 PRO on `vck190_fmcp1` (Gen4 x4) behaves the same way: fio is CPU-bound
at ~4.4-4.8 GB/s, every 32 GB sweep step is clean up to the 3.2 GB/s generator maximum, and the
drive's post-cache rate (~1.77 GB/s) is visible. On `zcu106_hpc0` (Gen4 drives on Gen3 Root
Ports) both pairs stopped at ~1.6 GB/s per drive, in both directions, with the pre-fix design:
the former per-slot ceiling (see
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed)).
With the current design both run at their Gen3 x4 link's rate inside the cache: the Sabrent
writes 2827-2890 MB/s per slot (fio 4 GB) and reads 2975-3153 MB/s (raw device), the 980 PRO
writes 2956-2962 MB/s and reads 2934-3185 MB/s. One drive records 32 GB at 2750 MB/s (Sabrent)
or 3000 MB/s (980 PRO), RAID0 at 3200 MB/s (Sabrent) or 3000 MB/s (980 PRO; 3200 MB/s lost
430 beats to FIFO overflows), and both drives show the same cache and post-cache rate as on the
VCK190 (Sabrent ~72 GB and ~1.8 GB/s, 980 PRO ~115-120 GB and ~1.77 GB/s). The ~1.6 GB/s limit
was the host's, not the drives'.

### Method

Measured on `uzev` on 2026-10-02 and on `vck190_fmcp1` and `zcu106_hpc0` on 2026-10-03 (see
their results for the differences), with the playback-capable image (register map 1.1),
the 970 EVO 250GB and 950 PRO 256GB described above (the 1 TB pairs on 2026-10-17 and
2026-10-18, same image and method, and both pairs again on `zcu106_hpc0` on 2026-10-19 with the
current design's image, same method; for an identical pair the second drive alone got only a fio 4 GB check), XFS on a freshly created filesystem
with 30 s of idle time per configuration and 20 s between runs, RAID0 = both drives with
512 KB chunks. Figures are medians of 3 runs, with [min–max], unless noted.

* **dd** (`single_write_test.sh`, `single_read_test.sh`, `dual_*_test.sh`, run verbatim):
  one `dd` process moves 1000 blocks of 4 MiB with `O_DIRECT` between a file on the SSD
  filesystem and `/dev/zero`, one block at a time (queue depth 1). The dual scripts run one
  `dd` per SSD in parallel, each on its own filesystem, and report the aggregate.
* **fdrec / fdplay**: recordings and playbacks of the same 4000 MiB at fixed rates in
  250 MB/s steps, queue depth 8. `uzev`: **16 x 8 MB buffers** (the image default when these
  runs were made); `vck190_fmcp1` and `zcu106_hpc0`: the shipped default of 32 x 8 MB, plus
16-buffer runs. The table gives the highest rate that was clean
  (`fdrec`: 0 drops and `fdverify` PASS; `fdplay`: 0 underflows) and the rate it achieved.
* **Units.** The scripts print "MBytes/s" but move 4000 MiB, so their figure is in MiB/s.
  All figures here are MB/s (10⁶ bytes/s), like `fdrec` and `fdplay`: script figure × 1.0486.
* **CPU** is measured the same way for every row, over the whole transfer: the total CPU from
  `/proc/stat` deltas (share of all the target's cores, four on `uzev` and the ZCU106, two on the VCK190:
  user / system / IRQ + softirq / I/O wait),
  and the transfer process's (user + system) / real time from `time -p`, as a share of one
  core. The per-process figure is the stable one. "MB/s per % core" is the rate divided by
  the per-process figure. (The `top` figures in the [CPU load](#cpu-load) section above were
  taken with another method and are not comparable with these.)

### Results: uzev

All figures of this section are pre-fix (†: HP0/HP1 at 99.99 MHz, see [Setups](#setups)); `uzev`
will not be re-measured.

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

### Results: vck190_fmcp1

VCK190 (XCVC1902, two Cortex-A72 cores at 1.4 GHz, 8 GB DDR4), `vck190_fmcp1` image,
measured 2026-10-03 (board time, UTC). Same SSDs as `uzev` (970 EVO 250GB, 950 PRO 256GB);
the QDMA Root Ports are Gen4-capable, but both SSDs are Gen3 drives, so the links are Gen3 x4.
The Sabrent Rocket 2230 1TB rows (two drives on the M.2 M-key Stack FMC, measured 2026-10-17)
linked at **Gen4 x4** (16 GT/s, `LnkSta` of Root Port and SSD), the first Gen4 link in this
design. The Samsung 980 PRO 1TB rows (the same two drives as on `zcu106_hpc0`, on the FPGA
Drive FMC Gen4, measured 2026-10-18) also linked at Gen4 x4. "RAID0" alone is the 970 EVO +
950 PRO pair; "Sabrent" is one Sabrent Rocket 2230 1TB, "980 PRO" one Samsung 980 PRO 1TB.
Same method as above, with 60 s of idle time after each `mkfs`. `fdrec` / `fdplay` used the
shipped default of **32 x 8 MB buffers**; 16-buffer runs were added for comparison with
`uzev`. The board has **two** cores, so the total CPU column is a share of two cores (50 % =
one full core); the per-process column (% of one core) and MB/s per % core are directly
comparable with `uzev`.

| method | config | direction | size | MB/s | total CPU % of 2 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | 970 EVO | write | 4000 MiB | 1519 [1519–1525] | 0.0 / 29.3 / 1.3 / 18.1 | 60 [59–61] | 25 |
| dd (script) | 970 EVO | read | 4000 MiB | 2382 [2316–2741] | 0.3 / 18.5 / 2.7 / 23.2 | 37 [30–49] | 64 |
| dd (script) | 950 PRO | write | 4000 MiB | 940 [940–942] | 0.2 / 19.0 / 0.0 / 29.4 | 38 [36–39] | 25 |
| dd (script) | 950 PRO | read | 4000 MiB | 2087 [1968–2129] | 0.0 / 18.4 / 2.3 / 25.9 | 34 [31–38] | 60 |
| dd (script) | RAID0 | write | 4000 MiB | 1855 [1776–1863] | 0.4 / 37.9 / 3.2 / 7.9 | 79 [76–81] | 23 |
| dd (script) | RAID0 | read | 4000 MiB | 2912 [2912–3356] | 0.4 / 27.7 / 6.3 / 8.9 | 63 [62–79] | 46 |
| dd (dual script) | both drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 1880 [1872–1897] | 0.1 / 38.7 / 1.9 / 39.1 | 80 [78–80] | 24 |
| dd (dual script) | both drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 4279 [4194–4462] | 0.3 / 38.5 / 3.3 / 47.7 | 73 [71–78] | 58 |
| `fdrec`, highest clean: 1500 (32 buffers) | 970 EVO | record | 4000 MiB | 1495 | 0.0 / 12.5 / 0.0 / 41.0 | 24 [24–24] | 62 |
| `fdrec`, highest clean: 1000 (32 buffers) | 950 PRO | record | 4000 MiB | 955 | 0.1 / 9.4 / 0.1 / 43.7 | 17 | 55 |
| `fdrec` at 750 (32 buffers) | 950 PRO | record | 4000 MiB | 749 | 0.0 / 7.2 / 0.0 / 46.0 | 14 | 53 |
| `fdrec` at 750 (32 buffers) | 950 PRO | record | 32 GB | 750 | 0.2 / 6.7 / 0.0 / 46.4 | 13 | 58 |
| `fdrec`, highest clean: 2000 (32 buffers) | RAID0 | record | 4000 MiB | 1909 | 0.2 / 19.3 / 0.4 / 37.5 | 35 | 54 |
| `fdrec` at 1750 (16 buffers) | RAID0 | record | 4000 MiB | 1744 | sys 16.0 | 31 | 56 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | 970 EVO | play | 4000 MiB | 2831 | 0.0 / 15.4 / 2.3 / 29.3 | 33 | 86 |
| `fdplay`, highest clean: 2250 (32 buffers) | 950 PRO | play | 4000 MiB | 2116 | 0.3 / 16.3 / 0.3 / 30.3 | 31 | 68 |
| `fdplay`, highest clean: 3000, top step (32 buffers) | RAID0 | play | 4000 MiB | 2875 | 0.3 / 23.3 / 3.0 / 21.3 | 49 | 59 |
| `fdplay` at 3000 (16 buffers) | RAID0 | play | 4000 MiB | 2933 | sys 20.4 | 39 | 75 |
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
| `fdrec`, highest clean: 3000, top step (32 buffers) | 980 PRO | record | 4000 MiB | 2983 | 0.0 / 23.8 / 0.0 / 30.4 | 46 [46–47] | 64 |
| `fdrec` at 3200 (32 buffers) | 980 PRO | record | 32 GB | 3198 | 0.2 / 24.8 / 0.1 / 28.8 | 48 | 67 |
| `fdrec` at 3000, top step (16 buffers) | 980 PRO | record | 4000 MiB | 2983 | sys 23.5 | 45 | 66 |
| `fdrec`, highest clean: 3000, top step (32 buffers) | 980 PRO RAID0 | record | 4000 MiB | 2985 | 0.0 / 25.4 / 0.3 / 30.7 | 48 [48–49] | 62 |
| `fdrec` at 3200 (32 buffers) | 980 PRO RAID0 | record | 32 GB | 3198 | 0.3 / 24.0 / 0.2 / 28.3 | 46 | 70 |
| `fdrec` at 3000, top step (16 buffers) | 980 PRO RAID0 | record | 4000 MiB | 2985 | sys 24.1 | 47 | 63 |
| `fdplay`, highest clean: 3000, top step (32 buffers; clean 2 of 3) | 980 PRO | play | 4000 MiB | 2907 | 0.3 / 18.5 / 0.0 / 27.6 | 35 | 84 |
| `fdplay`, highest clean: 2500 (32 buffers) | 980 PRO RAID0 | play | 4000 MiB | 2440 | 0.3 / 16.5 / 0.0 / 30.1 | 31 | 79 |
| `fdplay` at 3000, top step (16 buffers) | 980 PRO RAID0 | play | 4000 MiB | 2949 | 0.2 / 18.9 / 0.0 / 26.7 | 36 | 82 |

Notes:

* Raw script output (MiB/s, medians): 970 EVO write 1449, read 2272; 950 PRO write 896, read
  1990; RAID0 write 1769, read 2777; dual write 1793, read 4081 (aggregate). The read runs last
  1.3–2.0 s, so their spread is partly timer granularity.
* `fdrec` with 32 buffers: 970 EVO clean at 1500 MB/s 3/3 (ingest FIFO high-water mark
  838–1348 of 4096), 1750 drops; 950 PRO clean at 1000 3/3 while writing only 951–955 MB/s
  (the 256 MB ring absorbs the deficit over 4 GB), 1250 drops; RAID0 clean at 2000 3/3
  (1909–1915 MB/s achieved), 2250 drops. With 16 buffers: 970 EVO 1500, 950 PRO 750 (1000
  drops: the 128 MB ring is too small for the deficit), RAID0 1750 (2000 drops). 16 and 32
  buffers cost the same CPU at the same rate.
* `fdplay`: the sweep stops at 3000 MB/s, the last 250 MB/s step below the 3.2 GB/s sink
  maximum; the 970 EVO and RAID0 were clean there (3/3, with 32 and with 16 buffers). The
  950 PRO had underflows at 2500 MB/s.
* At 1000 MB/s: `fdrec` 16 % of a core (970 EVO) and 19 % (RAID0); `fdplay` 11 / 14 / 18 %
  (970 EVO / 950 PRO / RAID0). The total CPU shows ~40–48 % I/O wait during `fdrec` and
  `fdplay`: one of the two cores waiting in io_uring, not busy.
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
  layouts (high-water mark 1673–2253); 3200 MB/s over 32 GB clean on both. `fdplay`: single
  3000 in the sweep, one of the two confirmations had 3194 underflow ticks (467 with 16
  buffers); RAID0 with 32 buffers stopped at 2500 (2750: 30 128 ticks, one read stall), with 16
  buffers 3000 3/3.
* At 1000 MB/s: `fdrec` 16 % (980 PRO) and 17 % (980 PRO RAID0) of a core, `fdplay` 13 / 13 %.
  Each 980 PRO got two NVMe I/O queues (one per core).

Variations (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| 970 EVO | dd bs=1M | 1287 | 1864 | 59 / 33 |
| 970 EVO | dd bs=16M | 1520 | 3039 | 54 / 59 |
| 970 EVO | two dd streams on the drive (aggregate) | 1522 | 3264 | 62 / 49 |
| 970 EVO | dd 32 GB (read: 1 run) | 492 | 2617 | 19 / 39 |
| 950 PRO | dd bs=1M | 945 | 1933 | 46 / 38 |
| 950 PRO | dd bs=16M | 934 | 2255 | 35 / 46 |
| 950 PRO | two dd streams on the drive (aggregate) | 942 | 1942 | 39 / 32 |
| 950 PRO | dd 32 GB (read: 1 run) | 946 | 2180 | 38 / 38 |
| RAID0 | dd bs=1M | 1493 | 2589 | 75 / 52 |
| RAID0 | dd bs=16M | 1848 | 3062 | 78 / 61 |
| RAID0 | two dd streams on the array (aggregate) | 1877 | 3830 | 83 / 76 |
| RAID0 | dd 32 GB (1 run) | 1446 | 3499 | 56 / 74 |
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
| 970 EVO | 1535 MB/s, 18 % of a core | 3217 MB/s, 56 % | 484 MB/s, 5 % | 3285 MB/s, 56 % |
| 950 PRO | 953 MB/s, 11 % | 2264 MB/s, 48 % | 949 MB/s, 11 % | 2296 MB/s, 47 % |
| RAID0 | 1911 MB/s, 23 % | 3652 MB/s, 97 % | 1411 MB/s, 17 % | 3917 MB/s, 97 % |
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

AMD ZCU106 (XCZU7EV, four Cortex-A53 cores at 1.2 GHz, 4 GB DDR4), FPGA Drive FMC Gen4 on HPC0,
XDMA Gen3 x4 Root Ports, `zcu106_hpc0` image, measured 2026-10-03 (board time, UTC). Same SSDs
as the other boards; both linked at Gen3 x4. Same method, with 60 s of idle time after each
`mkfs`. `fdrec` / `fdplay` used the shipped default of **32 x 8 MB buffers**; 16-buffer results
are in brackets where they differ. Total CPU is a share of four cores (25 % = one full core).
The Samsung 980 PRO 1TB rows (two drives, measured 2026-10-19 with the current design) are Gen4
drives; they link at Gen3 x4 here (`LnkSta 8GT/s (downgraded)`), and so do the Sabrent Rocket
2230 1TB rows (two drives on the M.2 M-key Stack FMC on HPC0, measured 2026-10-19 with the
current design). "RAID0" alone is the 970 EVO + 950 PRO pair. The 970 EVO and 950 PRO rows are
pre-fix (†: HP0/HP1 at 99.99 MHz, see [Setups](#setups)); the pre-fix figures of both 1 TB pairs
are summarized in
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed).

| method | config | direction | size | MB/s | total CPU % of 4 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | 970 EVO † | write | 4000 MiB | 1006 [1002–1040] | 0.1 / 11.8 / 0.4 / 11.8 | 50 [45–54] | 20 |
| dd (script) | 970 EVO † | read | 4000 MiB | 1322 [1318–1421] | 0.2 / 7.5 / 1.0 / 14.3 | 30 [30–40] | 43 |
| dd (script) | 950 PRO † | write | 4000 MiB | 955 [953–957] | 0.1 / 14.3 / 0.3 / 11.3 | 50 [49–56] | 19 |
| dd (script) | 950 PRO † | read | 4000 MiB | 1302 [1286–1365] | 0.1 / 8.5 / 1.5 / 12.4 | 38 [35–40] | 34 |
| dd (script) | RAID0 † | write | 4000 MiB | 1263 [1197–1278] | 0.2 / 17.7 / 0.8 / 5.3 | 72 [72–74] | 17 |
| dd (script) | RAID0 † | read | 4000 MiB | 1978 [1785–2066] | 0.1 / 12.4 / 4.9 / 4.3 | 68 [63–78] | 28 |
| dd (dual script) | both drives, two filesystems † | write (aggregate) | 2 x 4000 MiB | 1897 [1852–1906] | 0.1 / 23.6 / 0.6 / 21.9 | 100 [98–101] | 19 |
| dd (dual script) | both drives, two filesystems † | read (aggregate) | 2 x 4000 MiB | 2778 [2622–2805] | 0.2 / 18.4 / 2.5 / 22.8 | 80 [74–85] | 34 |
| `fdrec`, highest clean: 1500 (16: 1500) | 970 EVO † | record | 4000 MiB | 1493 | 0.0 / 9.1 / 0.0 / 18.7 | 35 | 40 |
| `fdrec`, highest clean: 1000 (16: 750) | 950 PRO † | record | 4000 MiB | 958 | 0.0 / 6.9 / 0.2 / 20.2 | 27 | 35 |
| `fdrec` at 750 | 950 PRO † | record | 32 GB | 750 | 2.5 / 5.4 / 0.1 / 22.1 | 20 | 38 |
| `fdrec`, highest clean: 2000 (16: 1750) | RAID0 † | record | 4000 MiB | 1929 | 0.1 / 14.4 / 0.4 / 16.7 | 55 | 33 |
| `fdplay`, highest clean: 1500 | 970 EVO † | play | 4000 MiB | 1414 | 0.1 / 5.8 / 0.9 / 16.9 | 24 | 56 |
| `fdplay`, highest clean: 1500 | 950 PRO † | play | 4000 MiB | 1414 | 0.0 / 7.0 / 1.2 / 15.3 | 30 | 46 |
| `fdplay` at 3000, top step (clean 2 of 3; 16: 3 of 3) | RAID0 † | play | 4000 MiB | 2822 | 0.2 / 15.3 / 4.5 / 4.1 | 76–81 | 33–35 |
| dd (script) | 980 PRO 1TB | write | 4000 MiB | 1398 [1394–1427] | 0.2 / 17.6 / 0.5 / 5.6 | 74 [63–75] | 19 |
| dd (script) | 980 PRO 1TB | read | 4000 MiB | 2026 [1915–2292] | 0.3 / 10.8 / 2.3 / 8.2 | 50 [42–70] | 40 |
| dd (script) | RAID0 (2x 980 PRO) | write | 4000 MiB | 1755 [1651–1762] | 0.1 / 22.4 / 0.0 / 1.4 | 90 [89–91] | 20 |
| dd (script) | RAID0 (2x 980 PRO) | read | 4000 MiB | 2397 [2255–2397] | 0.3 / 20.7 / 0.0 / 1.3 | 82 [80–82] | 29 |
| dd (dual script) | both 980 PRO, two filesystems | write (aggregate) | 2 x 4000 MiB | 2741 [2646–2759] | 0.2 / 35.1 / 0.9 / 10.6 | 145 [133–160] | 19 |
| dd (dual script) | both 980 PRO, two filesystems | read (aggregate) | 2 x 4000 MiB | 4033 [3600–4052] | 0.3 / 23.8 / 4.6 / 11.4 | 111 [100–128] | 36 |
| `fdrec`, highest clean: 3000, top step (16: 3000) | 980 PRO 1TB | record | 4000 MiB | 2980 | 0.2 / 17.4 / 0.0 / 10.5 | 68 | 44 |
| `fdrec` at 3000 | 980 PRO 1TB | record | 32 GB | 2998 | 0.2 / 17.5 / 0.1 / 11.3 | 67 | 44 |
| `fdrec`, highest clean: 3000, top step (16: 3000) | RAID0 (2x 980 PRO) | record | 4000 MiB | 2982 | 0.2 / 18.1 / 0.5 / 10.9 | 74 | 40 |
| `fdrec` at 3000 | RAID0 (2x 980 PRO) | record | 32 GB | 2998 | 0.2 / 18.6 / 0.3 / 11.5 | 73 | 41 |
| `fdplay`, highest clean: 2500 (clean 2 of 3; 16: 2000, 2 of 3) | 980 PRO 1TB | play | 4000 MiB | 2376 | 0.0 / 9.1 / 2.2 / 11.2 | 42 | 57 |
| `fdplay`, highest clean: 1500 (16: 2750, clean 1 of 3; 2500 clean) | RAID0 (2x 980 PRO) | play | 4000 MiB | 1472 | 0.2 / 7.5 / 0.7 / 15.5 | 32 | 46 |
| dd (script) | Sabrent Rocket 2230 1TB | write | 4000 MiB | 1398 [1384–1422] | 0.1 / 17.5 / 0.0 / 6.0 | 67 [67–73] | 21 |
| dd (script) | Sabrent Rocket 2230 1TB | read | 4000 MiB | 2208 [1864–2280] | 0.1 / 14.2 / 0.0 / 5.4 | 63 [52–77] | 36 |
| dd (script) | RAID0 (2x Sabrent) | write | 4000 MiB | 1536 [1394–1664] | 0.2 / 19.0 / 1.5 / 3.2 | 80 [75–90] | 19 |
| dd (script) | RAID0 (2x Sabrent) | read | 4000 MiB | 2208 [2066–2231] | 0.1 / 17.7 / 0.0 / 2.0 | 85 [70–85] | 26 |
| dd (dual script) | both Sabrent, two filesystems | write (aggregate) | 2 x 4000 MiB | 2565 [2504–2646] | 0.2 / 33.5 / 1.1 / 10.5 | 136 [122–141] | 19 |
| dd (dual script) | both Sabrent, two filesystems | read (aggregate) | 2 x 4000 MiB | 3663 [3647–4153] | 0.3 / 25.6 / 9.0 / 12.1 | 104 [101–130] | 35 |
| `fdrec`, highest clean: 2000 (16: 2750) | Sabrent Rocket 2230 1TB | record | 4000 MiB | 1990 | 0.0 / 13.0 / 0.1 / 16.8 | 49 | 38 |
| `fdrec` at 2750 | Sabrent Rocket 2230 1TB | record | 32 GB | 2748 | 0.1 / 15.0 / 0.2 / 13.2 | 66 | 41 |
| `fdrec`, highest clean: 3000, top step (16: 1750) | RAID0 (2x Sabrent) | record | 4000 MiB | 2980 | 0.2 / 18.7 / 0.3 / 8.4 | 75 | 37 |
| `fdrec` at 3200 | RAID0 (2x Sabrent) | record | 32 GB | 3197 | 0.1 / 20.1 / 0.7 / 10.0 | 78 | 41 |
| `fdplay`, highest clean: 2250 (16: 2250; 2500 clean 1 of 3) | Sabrent Rocket 2230 1TB | play | 4000 MiB | 2148 | 0.0 / 8.9 / 2.5 / 11.5 | 41 | 49 |
| `fdplay`, highest clean: 1750 (16: 2250; 2500 clean 1 of 3) | RAID0 (2x Sabrent) | play | 4000 MiB | 1696 | 0.0 / 8.2 / 1.2 / 13.6 | 32 | 51 |

Notes:

* Raw script output (MiB/s, medians): 970 EVO write 959, read 1261; 950 PRO write 911, read
  1242; RAID0 write 1204, read 1886; dual write 1809, read 2649 (aggregate).
* `fdrec` with 32 buffers: 970 EVO 1500 3/3 (high-water mark 998–1311), 1750 drops; 950 PRO
  1000 3/3 while writing only 958–959 MB/s (the 256 MB ring absorbs the deficit over 4 GB),
  1250 drops; RAID0 2000 3/3 (1922–1936 MB/s achieved), 2250 drops. With 16 buffers the
  950 PRO drops at 1000 and RAID0 at 2000. 16 and 32 buffers cost the same CPU at the same rate.
* `fdplay`: 970 EVO and 950 PRO clean at 1500, underflows at 1750; RAID0 at 3000 MB/s, the top
  step, sits at the sink ceiling (one confirmation run of three had 1046 underflow ticks).
* At 1000 MB/s: `fdrec` 24 % of a core (970 EVO) and 30 % (RAID0); `fdplay` 16 / 20 / 22 %
  (970 EVO / 950 PRO / RAID0).
* The 970 EVO had one NVMe I/O queue and the 950 PRO four, as on the other boards (a property
  of the 970 EVO, see [Where the bottlenecks are](#3-the-nvme-queue-count)).
* 980 PRO 1TB (current design): raw script output (MiB/s, medians): write 1351, read 1970;
  RAID0 write 1694, read 2325; dual write 2631, read 3883 (aggregate). One `dd` at queue depth 1
  is still CPU- and latency-bound (19-20 MB/s per % of a core writing), but each request
  completes sooner than with the pre-fix design: one `dd` writes 35 % and reads 59 % faster,
  RAID0 20 % / 26 %, the dual script 39 % / 63 %. Four NVMe I/O queues on both slots.
* 980 PRO `fdrec` with 32 and with 16 buffers: clean at the 3000 MB/s top step 3/3 on one drive
  and on RAID0 (high-water mark 2119-3717); 3000 MB/s over 32 GB clean on both (high-water mark
  3785 and 3054).
* 980 PRO `fdplay` (sweeps started 20 s after the recording): single 2500 with 32 buffers in
  2 of 3 (6.23 M ticks once; 2750: 4.87 M), 2000 with 16 buffers in 2 of 3 (19 365 ticks once;
  2250: 29 345); RAID0 1500 with 32 buffers (1750: 4264 ticks), 2750 with 16 buffers in 1 of 3
  (2298 and 3677 ticks; 2500 clean). The RAID0 cells are decided by short read stalls, the
  single-drive ones by the 2500-2750 MB/s deficit (see
  [Single-drive playback deficit on zcu106_hpc0](#single-drive-playback-deficit-on-zcu106_hpc0));
  the 10 GB playbacks are the better guide.
* At 1000 MB/s: `fdrec` 25 % of a core (980 PRO) and 26 % (RAID0); `fdplay` 17 / 20 %, about
  the same as with the pre-fix design (24 / 26 %, 16 / 18 %).
* Sabrent Rocket 2230 1TB (current design): raw script output (MiB/s, medians): write 1346,
  read 2139; RAID0 write 1481, read 2162; dual write 2476, read 3539 (aggregate). One `dd` at
  queue depth 1 is still CPU- and latency-bound on the A53 (19–21 MB/s per % of a core writing),
  but each request completes sooner than with the pre-fix design: one `dd` writes 36 % and reads
  75 % faster, the dual script 36 % / 41 %. Four NVMe I/O queues on both slots.
* Sabrent `fdrec` with 32 buffers: 2000 3/3 (high-water mark 1452–2434); 2250 dropped 1154 beats
  once (one FIFO overflow at a buffer boundary, not bandwidth); with 16 buffers 2750 3/3, 3000
  drops writing 2851 MB/s (above the drive's write rate). RAID0 with 32 buffers 3000 3/3 (the
  sweep's top step; high-water mark 2939–3297); with 16 buffers 1750 3/3, 2000 dropped
  857 232 beats. `fdplay`: single 2250 with 32 buffers (2500: 133 255 ticks), with 16 buffers
  2250 clean and 2500 clean in 1 of 3; RAID0 1750 with 32 buffers (2000: 5565 ticks), with 16
  buffers 2250 clean and 2500 clean in 1 of 3. These 4 GB sweeps are decided by single rare
  events; the 32 GB and 10-40 GB recordings are the better guide.
* At 1000 MB/s: `fdrec` 26 % of a core (Sabrent) and 27 % (RAID0); `fdplay` 19 / 20 %, the same
  as with the pre-fix design (25 / 26 %, 18 / 19 %).

Variations (dd timed like the scripts):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| 970 EVO † | dd bs=1M | 851 | 1089 | 49 / 31 |
| 970 EVO † | dd bs=16M | 1101 | 1520 | 52 / 38 |
| 970 EVO † | two dd streams on the drive (aggregate) | 1514 | 1592 | 77 / 39 |
| 970 EVO † | dd 32 GB (read: 1 run) | 463 | 1429 | 24 / 40 |
| 950 PRO † | dd bs=1M | 876 | 1188 | 53 / 38 |
| 950 PRO † | dd bs=16M | 953 | 1422 | 49 / 39 |
| 950 PRO † | two dd streams on the drive (aggregate) | 954 | 1586 | 51 / 42 |
| 950 PRO † | dd 32 GB (read: 1 run) | 960 | 1476 | 50 / 46 |
| RAID0 † | dd bs=1M | 1098 | 1553 | 68 / 51 |
| RAID0 † | dd bs=16M | 1283 | 1915 | 73 / 68 |
| RAID0 † | two dd streams on the array (aggregate) | 1911 | 2863 | 109 / 96 |
| RAID0 † | dd 32 GB (1 run) | 1129 | 1831 | 62 / 61 |
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
| 970 EVO † | 1533 MB/s, 24 % of a core | 1578 MB/s, 40 % | 486 MB/s, 7 % | 1596 MB/s, 39 % |
| 950 PRO † | 965 MB/s, 15 % | 1571 MB/s, 54 % | 964 MB/s, 15 % | 1591 MB/s, 50 % |
| RAID0 † | 1941 MB/s, 41 % | 2453 MB/s, 92 % | 1427 MB/s, 26 % | 2482 MB/s, 95 % |
| 980 PRO 1TB | 2956 MB/s, 73 % of a core | 2854 MB/s, 98 % | 2984 MB/s, 73 % | 2892 MB/s, 97 % |
| RAID0 (2x 980 PRO) | 3401 MB/s, 96 % | 2824 MB/s, 98 % | 3389 MB/s, 96 % | 2977 MB/s, 96 % |
| Sabrent Rocket 2230 1TB | 2827 MB/s, 70 % of a core | 2879 MB/s, 98 % | 2824 MB/s, 76 % | 2920 MB/s, 98 % |
| RAID0 (2x Sabrent) | 3229 MB/s, 92 % | 2653 MB/s, 94 % | 3311 MB/s, 94 % | 2777 MB/s, 97 % |

† Measured with the pre-fix design (HP0/HP1 at 99.99 MHz); see [Setups](#setups).

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
500 MB/s. The 1 TB drives cache 75-120 GB, so on them even a 32 GB `dd` is a burst (on
`vck190_fmcp1` the Sabrent 1931 MB/s, the 980 PRO 2073 MB/s, both about the same as over 4 GB), and only the
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
slot, and both read ~2.9-3.2 GB/s (raw device), the link's practical rate. With the pre-fix
design the 99.99 MHz HP port behind each Root Port capped a fast drive at ~1.6 GB/s, below the
link's rate (see
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed)). To check the link itself, look at its
negotiated speed and width (`lspci -vv`, see
[Test the design in Linux](linux_test.md#1-check-that-the-pcie-links-are-up)).

The sibling design's own documentation quotes lower `dd` figures for `uzev` (read 790–970,
write ~585 MB/s); those were measured with a Samsung 980 PRO and an older image, and do not
apply to this setup. With this image, a Samsung 980 PRO 1TB on `zcu106_hpc0` gives 1398 MB/s
write and 2026 MB/s read with the same scripts (1035 and 1278 MB/s with the pre-fix design).

For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics. See their
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).

## Where the bottlenecks are

Why don't you get the SSD's rated read and write speed? This section goes through the chain
from the SSD to the fabric, in the order in which the limits usually bite. The numbers are
the `uzev` measurements on this page (four Cortex-A53 cores at 1.1 GHz, PCIe Gen3 x4,
Samsung 970 EVO 250GB and 950 PRO 256GB) unless another target or drive is named; the
reasoning applies to every target.

### 1. The SSD itself

**Writes: the SLC cache, then the flash.** Samsung rates the 970 EVO 250GB at up to
1500 MB/s sequential write, and 300 MB/s once its TurboWrite (SLC) cache is full
([data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung-NVMe-SSD-970-EVO-Data-Sheet_Rev.1.0.pdf)).
That is what was measured: 1024 MB/s with `dd` and 1535 MB/s with fio over 4 GB, then
about 330 MB/s after ~14 GB (a 32 GB `dd` averages 460 MB/s across the cache end). The
950 PRO 256GB, rated at 900 MB/s write
([Samsung](https://www.samsung.com/us/computer/memory-storage/MZ-V5P256BW)), has no such
cliff: its ~955 MB/s is its real write rate, over 4 GB and over 32 GB alike.

The 1 TB drives have much larger caches and faster flash behind them. The Sabrent Rocket 2230
1TB writes ~4.5 GB/s on Gen4 x4 (~2.9 GB/s on the Gen3 x4 link of `zcu106_hpc0`) for ~72-75 GB
and then a flat ~1.8 GB/s, on both boards; the Samsung 980 PRO 1TB writes ~4.7 GB/s on Gen4 x4
(~3.0 GB/s on the Gen3 x4 link) for ~115-120 GB and then a flat ~1.77 GB/s, on both boards (with
the pre-fix design `zcu106_hpc0` measured ~1.52 GB/s after the cache, see
[The SLC cache](#the-slc-cache)). Where nothing else comes first, the post-cache rate sets the
sustained single-drive rate: 1750 MB/s for the 980 PRO on both boards (over 240 GiB on the
VCK190, over 200 and 221 GiB on `zcu106_hpc0`; 2000 MB/s drops when the cache ends) and for the
Sabrent on `zcu106_hpc0` (over 200 GiB; 2000 MB/s drops just past the cache). Elsewhere other
limits come first: the Sabrent's rare write stalls on `vck190_fmcp1` and late DMA restarts in
long RAID0 recordings (section 5); see [The SLC cache](#the-slc-cache).

**Reads: the rating assumes a fast host with many commands outstanding.** The ratings
(3400 MB/s for the 970 EVO, 2200 MB/s for the 950 PRO) are measured with many read commands
in flight on a fast desktop host. With one request at a time (`dd`, queue depth 1) the
950 PRO reads 1267 MB/s; with 8 in flight (fio, `fdplay`) about 1570 MB/s on `uzev` and
`zcu106_hpc0` (†). The rest of the gap is the host, not the drive: the same 950 PRO reads 2264 MB/s
with fio on the VCK190, and the 970 EVO 3217 MB/s there against 1574 (`uzev`) and 1578 MB/s
(`zcu106_hpc0`). On the Zynq UltraScale+ boards ~1.59 GB/s was a per-slot ceiling of the
pre-fix design's clocking (see
[The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed)); with the
current design a Sabrent Rocket 2230 1TB reads ~2.9-3.15 GB/s and a Samsung 980 PRO 1TB
~2.9-3.2 GB/s per slot there (raw device, 1 MB requests at queue depth 8 and 32).

**Reads right after a recording.** With the pre-fix design a 980 PRO 1TB RAID0 on
`zcu106_hpc0` played back at 2500-3000 MB/s underflowed within about three minutes of a 10 GB
recording and was clean after 3-10 minutes of idle. With the current design the same pair shows
no such time dependence: the effect was the former per-slot ceiling, which left no headroom
while the drives read more slowly just after a recording (see
[playback soon after a recording](#playback-soon-after-a-recording)). One 980 PRO 1TB alone on
`zcu106_hpc0` has an unexplained playback deficit at 2500-2750 MB/s (see
[Single-drive playback deficit on zcu106_hpc0](#single-drive-playback-deficit-on-zcu106_hpc0)).

**The recorder's criterion is the drive's worst moment.** A recording passes only if no beat
is dropped over its whole length, so its rate is set by the drive's slowest stretch
(garbage collection, the cache end, a write-latency spike), not by its average. That is why
the sustained recording rates (970 EVO 250, 950 PRO 750, RAID0 500 MB/s over 32 GB) are below
every average on this page.

The Sabrent Rocket 2230 1TB on `vck190_fmcp1` shows that the worst moment need not be a
bandwidth limit. It writes 1.8 GB/s even past its cache, yet in 2 of ~13 long single-drive
recordings no write completed for about 0.65 s (one gap at the 750 and one at the 1250 MB/s
step of the sweep, none at 1000 MB/s in 7 recordings up to 143 GiB). A stall that long drops
beats at any rate above what the ring covers (section 5). On `zcu106_hpc0` the same drives
showed no such stall, neither with the pre-fix design (14 single-drive recordings of 4 GB to
200 GiB at up to 1500 MB/s) nor with the current one (more than 40 single-drive recordings of
4 GB or more at 250-2750 MB/s, where a 0.65 s stall at 2 GB/s or more would have cost at least
80 M beats in one gap); why was not investigated.

### 2. The host I/O path and the CPU

Every write and read goes through the kernel's filesystem, block layer and NVMe driver, and
that path costs CPU time per byte even without a data copy. `fdrec` uses about 2.5–3 % of one
1.1 GHz Cortex-A53 core per 100 MB/s, almost all of it system time, and the cost grows
linearly with the rate, so one core would saturate somewhere in the 3–4 GB/s region. `dd`
additionally has the CPU produce every byte (zero-fill from `/dev/zero`) and runs one request
at a time: about 5.5 % of a core per 100 MB/s, and on RAID0 a single `dd` is CPU-bound at
~1.3 GB/s (80–90 % of a core). The AXI DMA writes DDR through a non-coherent port, so the
driver does a cache-maintenance pass over each buffer (one invalidate after the DMA, one
clean before the buffer goes back); that is part of the system time above.

On the VCK190 (two 1.4 GHz Cortex-A72 cores) the same work costs less: `fdrec` uses about
1.6–1.9 % of one core per 100 MB/s (24 % at 1495 MB/s, 35 % at 1909 MB/s), `fdplay` 1.2–1.7 %,
and a `dd` write about 4 % (60 % of a core at 1519 MB/s). A core goes about 1.4–1.6 times as
far, but there are only two of them, and during a recording one of them spends much of its
time waiting for I/O completions. On that board the host also stops limiting reads: the 970 EVO
reads 3217 MB/s with fio and the 950 PRO 2264 MB/s, close to or above their ratings, against
1574 and 1568 MB/s on `uzev`. With the Gen4 Sabrent Rocket 2230 1TB the VCK190's CPU becomes
the limit of the reference tools: one fio thread reaches 82-98 % of a core at ~4.2-4.5 GB/s,
and one `dd` write stream 72-88 % at ~1.9 GB/s. The Samsung 980 PRO 1TB there gives the same
picture (fio 89-99 % of a core at ~4.4-4.8 GB/s, one `dd` write ~2.0-2.2 GB/s). `fdrec` records
3 GB/s on one drive with 37 % (Sabrent) to 46 % (980 PRO) of a core.

On `zcu106_hpc0` with the current design the reference tools hit the same wall on one A53 core:
fio reads of a file (2.7-2.9 GB/s) and fio writes to a RAID0 pair (~3.2-3.3 GB/s Sabrent,
~3.4 GB/s 980 PRO) keep the fio thread at 92-98 % of a core, so they measure fio, not the storage
(with hugepage fixed buffers fio reads the RAID0 pairs at 5138 and 5965 MB/s). The recorder's cost
per MB is the same as with the pre-fix design: `fdrec` uses ~25 % of one core at 1000 MB/s,
67-74 % at 3000 MB/s and ~78 % at 3200 MB/s (RAID0, 32 GB), `fdplay` 17-19 % at 1000 MB/s and
41-42 % at 2250-2500 MB/s.

#### The former Zynq UltraScale+ per-slot ceiling (fixed)

With the first release of the Zynq UltraScale+ designs, every transfer to or from one fast SSD on
`uzev` and `zcu106_hpc0` stopped at about the same rate, in both directions and whatever the
method or the drive. With a Samsung 980 PRO 1TB: fio wrote 1578-1587 and read 1577-1596 MB/s
(on both slots), two `dd` streams wrote 1574 MB/s, and `fdrec` steps above 1500 MB/s wrote
1582-1588 MB/s and dropped. With a Sabrent Rocket 2230 1TB: writes 1543-1564 MB/s, reads
1570-1597 MB/s. Two drives in RAID0 doubled it (fio 2997-3145 MB/s write). The read figures of
the 970 EVO and 950 PRO on these boards (fio 1568-1596 MB/s) are the same ceiling, not the
drives: the same drives read 2264-3285 MB/s on the VCK190. The 970 EVO's 1533-1535 MB/s and the
950 PRO's ~955-970 MB/s writes are their own limits (the same on all three boards).

**Cause.** In the Zynq UltraScale+ block design (`Vivado/src/bd/bd_zynqmp.tcl`) each XDMA Root
Port's AXI master (`M_AXI_B`), which carries the SSD's DMA reads and writes of DDR, reaches the
PS through an HP port, `S_AXI_HP0_FPD` or `S_AXI_HP1_FPD`. These ports (`saxihp0_fpd_aclk`,
`saxihp1_fpd_aclk`) and the slave side of their AXI interconnects were clocked from `pl_clk0` at
99.99 MHz, so a 128-bit port carried at most 16 bytes x 99.99 MHz = 1.600 GB/s. The measured
reads (1570-1597 MB/s) and the 980 PRO's writes (1574-1588 MB/s) were 98-100 % of that; writes
with the Sabrent stopped a little lower (1543-1564 MB/s). Checked on `zcu106_hpc0` with the
Sabrent drives:

* The clock tree (`/sys/kernel/debug/clk/clk_summary`) showed `pl0_ref` at 99 990 000 Hz (the
  HP0/HP1 path) and `pl1_ref` at 249 975 000 Hz (then used by the recorder's AXI DMA only).
* A raw sequential read of one drive (`fio --filename=/dev/nvme0n1 --readonly --rw=read
  --direct=1 --ioengine=io_uring`) reached 1597 MB/s with 1 MB requests at queue depth 8 and
  1596 MB/s at queue depth 32: four times the bytes in flight changed nothing, the signature of
  a clock-bound stage in the path, not of latency or queue depth.
* PCIe MaxPayload is 128 bytes and MaxReadReq 512 bytes on the Root Ports and the SSDs, as on
  the VCK190, which had no such ceiling: it was not a payload-size limit.
* The link was not it either, nor the CPU (`fdrec` used 36 % of a core at 1500 MB/s).

The clocking was inherited from the base design,
[fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie).

**The fix.** The current design clocks `S_AXI_HP0_FPD`, `S_AXI_HP1_FPD` and the slave side of
their interconnects from `pl_clk1` (250 MHz), the clock of the recorder's AXI DMA and
`S_AXI_HP2_FPD`: 16 bytes x 250 MHz = 4.0 GB/s per port, above what a Gen3 x4 link carries. The
PS-master register paths (`M_AXI_HPM0/1_FPD`) stay on `pl_clk0`. Timing is met on both Zynq
UltraScale+ targets (worst setup slack +0.226 ns on `zcu106_hpc0`, +0.133 ns on `uzev`; no
critical warnings), for 68 (`zcu106_hpc0`) and 107 (`uzev`) more LUTs and no more block RAM. On
the running board `pl1_ref` now has four users instead of one.

Before and after on `zcu106_hpc0` with the same two Sabrent Rocket 2230 1TB, FMC card, image
family and scripts (pre-fix 2026-10-18, current design 2026-10-19; 32 x 8 MB buffers; MB/s):

| measurement | pre-fix (HP0/HP1 at 99.99 MHz) | current design (HP0/HP1 at 250 MHz) |
|---|---|---|
| fio write, 4 GB, 8 MB x QD8: slot 1 / slot 2 | 1543 / 1561 | 2827 / 2890 |
| fio read, 4 GB, 8 MB x QD8: slot 1 / slot 2 | 1573 / 1570 | 2879 / 2875 (fio CPU-bound) |
| raw read of one drive, 1 MB x QD8 / QD32 | 1597 / 1596 | 2975 / 2936 (before the suite); 3153 / 3060 (after it) |
| 32 GB sweep, highest clean step: single / RAID0 | 1500 / 2500 | 2750 / 3200 (the generator maximum) |
| SLC cache, single drive, 300 GiB fio | not visible: flat ~1554 | ~72 GB at ~2.9 GB/s, then a flat 1798 (median) |
| long recording past the cache: single (200 GiB) / RAID0 (350 GiB) | 1500 / 1750 | 1750 / 2250 |
| bursts, single: 10 GB / 40 GB | 1500 / 1500 | 2750 / 2750 |
| bursts, RAID0: 10 GB / 40 GB | 2500 / none clean (2500: 193 beats) | 3200 / 3200 |
| playback 10 GB, single: 32 / 16 buffers | 1500 / 1500 | 2250 / 2250 |
| playback 10 GB, RAID0: 32 / 16 buffers | 2000 / 2250 | 2250 (2 of 3) / 2500 |
| CPU at 1000 MB/s, % of one core: `fdrec` single / RAID0 | 24.3-24.4 / 25.6-25.7 | 24.5 / 25.6-25.7 |
| CPU at 1000 MB/s, % of one core: `fdplay` single / RAID0 | 17.4 / 18.2-18.3 | 19.0 / 18.6-18.8 |

The same with the two Samsung 980 PRO 1TB on the FPGA Drive FMC Gen4 (pre-fix 2026-10-17,
current design 2026-10-19; 32 x 8 MB buffers unless stated; MB/s):

| measurement | pre-fix (HP0/HP1 at 99.99 MHz) | current design (HP0/HP1 at 250 MHz) |
|---|---|---|
| fio write, 4 GB, 8 MB x QD8: slot 1 / slot 2 | 1581 / 1584 | 2956 / 2962 |
| fio read, 4 GB, 8 MB x QD8: slot 1 / slot 2 | 1577 / 1577 | 2854 / 2831 (fio CPU-bound) |
| raw read of one drive, 1 MB x QD8 / QD32 | not measured | 3020 / 3185 (before the suite); 2974 / 2934 (after it) |
| 32 GB sweep, highest clean step: single / RAID0 | 1500 / 3000 | 3000 / 3000 (3200: 430 beats, FIFO overflows) |
| `fdrec` 4 GB, highest clean step: single / RAID0 | 1500 / 2750 | 3000 / 3000 (the sweep's top step) |
| SLC cache, single drive, 300 GiB fio | 1581-1590 to ~115-120 GB, then ~1520 | ~2.98 GB/s to ~115-120 GB, then a flat 1768 (median) |
| long recording past the cache: single (200 GiB) / RAID0 (350 GiB) | 1500 / 2250 | 1750 / 2500 |
| bursts, single: 10 GB / 40 GB | 1500 / 1500 | 3000 / 3000 |
| bursts, RAID0: 10 GB / 40 GB | 2500 / 3000 | 2750 / 3200 (the generator maximum) |
| playback 10 GB, single: 32 / 16 buffers | 1250 / 1250 | 2250 / 2250 |
| playback 10 GB, RAID0: 32 / 16 buffers | 2250 / 1250 | 2250 (2 of 3) / 3200 (2 of 3) |
| RAID0 playback within ~3 min of a recording, 2500-3000 | underflows in 5 of 6 runs (up to 37 M ticks) | no time dependence (at most 0.23 M ticks, at random rates and times) |
| `dd` script, single: write / read | 1035 / 1278 | 1398 / 2026 |
| CPU at 1000 MB/s, % of one core: `fdrec` single / RAID0 | 23.3-23.6 / 24.7-24.8 | 23.5-23.6 / 24.9-25.0 |
| CPU at 1000 MB/s, % of one core: `fdplay` single / RAID0 | 15.7-15.8 / 17.1-17.3 | 16.4-16.6 / 19.9-22.0 |

The rows marked † in the other tables of this page show the old ceiling with the 970 EVO and
950 PRO (their reads).

**What limits a slot now.** The HP port (4.0 GB/s) is no longer it. Inside the SLC cache the
limit is the Gen3 x4 link at 128-byte MaxPayload (unchanged, as is MaxReadReq 512 bytes): the
link carries 3.94 GB/s raw, and each 128-byte payload travels in a TLP with ~20-24 bytes of
header, sequence number, LCRC and framing, plus acknowledgement and flow-control packets, which
leaves ~3.1-3.3 GB/s of payload per direction. Measured: raw reads 2936-3153 MB/s (Sabrent) and
2934-3185 MB/s (980 PRO); writes 2824-2949 MB/s (Sabrent: fio, and the 3000 and 3200 MB/s sweep
steps, which write ~2949 MB/s) and 2956-3037 MB/s (980 PRO: fio, and the 3200 MB/s sweep step);
the same drives write ~4.2-4.7 GB/s in their cache on the VCK190's Gen4 x4 link. So one drive
records 2750 MB/s (Sabrent) or 3000 MB/s (980 PRO), and a rate above the drive's write rate on
the link drops. Past the cache the drive's post-cache rate (~1.8 GB/s Sabrent, ~1.77 GB/s
980 PRO) is the limit (1750 MB/s for both, over 200 GiB). In long RAID0 recordings the rare late
DMA restarts at buffer boundaries (section 5) now set the limit (clean over 350 GiB: 2250 MB/s
with the Sabrent pair, 2500 MB/s with the 980 PRO pair; faster runs lost 846-14 934 beats each);
the fix does not change them, it only uncovers them. The CPU cost per MB is unchanged (see the
tables).

As a cross-check, [fpga-drive-nvme-offload](https://offload.fpgadrive.com), the hardware NVMe
host design (AMD NVMe Host Accelerator) on the same board and Root Ports, with its HP ports
clocked at 250 MHz, reaches ~3.04 GB/s per Gen3 x4 slot, close to the ~2.9-3.2 GB/s the
recorder's slots now reach.

`uzev` has the same block-design change; it was not re-measured. The Versal target
`vck190_fmcp1` never had this ceiling.

### 3. The NVMe queue count

The Samsung 970 EVO 250GB used on the bench is set up by the NVMe driver with a single I/O
queue (`nvme nvme0: 1/0/0 default/read/poll queues` in the kernel log). This is a property of
that drive: it happened on all three boards (`uzev`, `zcu106_hpc0` and the Versal
`vck190_fmcp1`), while the 950 PRO got two to four queues on every board, and the Samsung
980 PRO 1TB and the Sabrent Rocket 2230 1TB one per core: four on `zcu106_hpc0` (`4/0/0`) and
two on `vck190_fmcp1` (`2/0/0`). With one queue, every
command and completion of the drive goes through one queue and one interrupt, on one core: a
limiter for parallel I/O to that drive. Other drives expose more queues; check yours with
`dmesg | grep queues`.

### 4. RAID0 and the filesystem

With 512 KB chunks, md splits every 8 MB request into 16 stripe writes, alternating between
the drives; the array then runs at twice the slower drive's rate (the 970 EVO's, once its cache
is full). The 970 EVO + 950 PRO array topped out at about 1.9 GB/s (twice the 950 PRO's
~955 MB/s), a limit of the drives, not of md: on `zcu106_hpc0` two Sabrent Rocket 2230 1TB
write 3.2-3.3 GB/s and two 980 PRO 1TB 3.4 GB/s through md (fio, CPU-bound), and on `vck190_fmcp1` two Sabrent Rocket 2230
1TB 4.4 GB/s and two 980 PRO 1TB 4.6-4.7 GB/s (fio, CPU-bound). On the filesystem side,
`fdrec` preallocates the whole file (`fallocate`), so XFS does no allocation work during the
recording, and an `fstrim` immediately before a recording can stall the first writes for more
than 100 ms (see [the fstrim finding](#the-fstrim-finding-and-the-ring-size)).

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
* **The 64 KB fabric FIFO** only has to cover the AXI DMA's pause at each buffer boundary
  (~15 µs, the interrupt latency), which it does up to ~4.4 GB/s
  (see [the FIFO budget](apps.md#tuning-the-fifo-budget-at-buffer-boundaries)). The pause is
  occasionally longer. In long RAID0 recordings with the 1 TB pairs, single FIFO overflows
  lost beats while the ring was nearly empty: on `zcu106_hpc0` the Sabrent Rocket 2230 1TB pair
  at 2500-3200 MB/s (1226-10 150 beats in 350 GiB; clean at 2250 MB/s; once also 28 925 beats
  in a 32 GB recording at 1750 MB/s) and the 980 PRO 1TB pair at 2750-3200 MB/s (846-14 934
  beats in 350 GiB; clean at 2500 MB/s; also 430 beats in a 32 GB recording at 3200 MB/s and
  1167 in 10 GB at 3000 MB/s), each gap starting 64 KiB (+112 B with the Sabrent, +4208 B with
  the 980 PRO) after a buffer boundary; on `vck190_fmcp1` the 980 PRO 1TB pair at
  2250-3200 MB/s (3897-16 643 beats in 480 GiB; clean at 2000 MB/s). The 64 KB FIFO lasts 26 µs
  at 2.5 GB/s and 20 µs at 3.2 GB/s, so a DMA restart occasionally took longer than that (once
  about 160 µs, at 2000 MB/s on `zcu106_hpc0` with the pre-fix design, where the Sabrent pair
  was clean over 350 GiB only at 1750 MB/s). The HP-port clock fix does not change this. For
  long RAID0 recordings this interrupt latency, not the SSDs, is the margin.

Both set what "sustainable" means: a rate is sustainable if the drive's worst stall fits in
the ring.

### 6. What is not the bottleneck at these rates

* **The PCIe link**, with one exception. Gen3 x4 carries about 3.1-3.3 GB/s of payload at
  128-byte MaxPayload (Gen4 x4 on the Versal targets about 6.5 GB/s), above almost every figure
  here. The exception: a Gen4 SSD in a Gen3 design is capped at the Gen3 rate. The Samsung
  980 PRO 1TB and the Sabrent Rocket 2230 1TB link at Gen3 x4 (`8GT/s (downgraded)`) on the Zynq
  UltraScale+ Root Ports, where inside their caches both run at the link's rate (~2.95-3.04 GB/s
  write, ~2.9-3.2 GB/s read per slot), and at Gen4 x4 (16 GT/s) on the VCK190's QDMA Root Ports
  (the Sabrent first, on 2026-10-17). With the pre-fix design the 99.99 MHz HP ports behind the
  Zynq UltraScale+ Root Ports, not the link, capped a fast drive at ~1.6 GB/s (see
  [The former Zynq UltraScale+ per-slot ceiling (fixed)](#the-former-zynq-ultrascale-per-slot-ceiling-fixed)). PCIe
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
