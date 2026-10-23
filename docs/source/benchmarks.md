# Benchmarks

This page explains how the recorder is measured and lists the results per target and SSD.
Every figure was measured on hardware with the images of this repository (see
[Setups](#setups)); the date, the target and the SSDs are given with each table.
[Where the bottlenecks are](#where-the-bottlenecks-are) lists every ceiling that was found,
per device family, with its measured figure, what sets it and how to get past it.

## Method

### Recording method

Each measurement is one `fdrec` recording of test-pattern data at a fixed generator rate,
followed by `fdverify` on the file. A rate **passes** when `fdrec` exits 0 (zero dropped
beats) and `fdverify` reports a clean file. Because the generator cannot be stalled, a
pass means the whole chain (DMA, driver, filesystem, SSD) kept up with the rate for the
entire recording. Rates are measured in steps, so a "highest clean step" means that the
limit lies between that step and the next one.

* **Sanity check.** Each layout (one SSD, RAID0) first records 10 GiB at 1000 MB/s, verifies
  the file and plays it back at 500 MB/s (the design's hardware test). Every one of these
  passed. It is the only recording below 2500 MB/s on this page.
* **32 GB sweep.** `fdbench.sh --size 32G`, one step per rate **from 2500 MB/s in 500 MB/s
  steps** towards the 8000 MB/s generator maximum, on a freshly created XFS filesystem per
  layout; before every step the previous file is deleted, the filesystem trimmed and the
  drives left idle for 60 s. The sweep **stops after two consecutive failing steps**. The
  highest clean step and the first failing step are then each run twice more, so both are
  decided by 3 runs. **The sweep floor is 2500 MB/s**: rates below it are not swept. 32 GB
  stays **inside** the SLC cache of the 1 TB drives below (66-125 GB per drive), so the sweep
  gives an *in-cache* rate.
* **Burst and 40 GB recordings**: one 10 GB and one 40 GB recording at the highest clean step
  of the sweep and at its first failing step, `rm` + `fstrim` + 30 s of idle before each.
* **Long recordings past the SLC cache**: single recordings of 1.5 to three times the cache
  (fresh XFS, `rm` + `fstrim` + 300 s of idle before each), for one drive at 1750 MB/s and for
  RAID0 from the top of the sweep down until one rate is clean (the rates run are listed in
  [Long recordings past the SLC cache](#long-recordings-past-the-slc-cache)). They give the
  *sustained* rate.

```
sudo fdsetup-raid0.sh -y --single /dev/nvme0n1    # or: sudo fdsetup-raid0.sh -y  (RAID0)
sudo fdrec --rate 1000MB --size 10G /mnt/rec/t.dat; echo rc=$?
sudo fdverify /mnt/rec/t.dat
sudo fdbench.sh --size 32G --from 2500 --to 2500    # one sweep step; fstrim + 60 s idle between steps
```

Between measurements the previous file is deleted and the filesystem trimmed
(`fstrim /mnt/rec`), and the drives are left idle before the next recording (see
[Start-up stalls and the ring size](#start-up-stalls-and-the-ring-size) for why the idle time
matters, and what it costs at high rates). The filesystem is XFS.

### Fabric-only method

`fdrec --no-write` runs the source, the ingest FIFO, the AXI DMA and the buffer ring in DDR
exactly as a recording does, but writes nothing, so it measures the path from the fabric
into DDR on its own. For the playback direction `fdplay` plays a 256 MiB recording, which
fits whole in the 32 x 8 MiB ring: `fdplay` reads the whole file into the ring before the
first buffer is played, so the stream reads DDR only. Both run at the 8000 MB/s maximum
first, then in 250 MB/s steps around the highest clean rate, with 3 runs at the highest clean
and at the first failing rate.

```
sudo fdrec --no-write --rate 8000MB --size 64G; echo rc=$?
sudo fdrec --rate 1000MB --size 256M /mnt/rec/ring.dat
sudo fdplay --rate 7500MB /mnt/rec/ring.dat; echo rc=$?
```

### Playback method

Each measurement is one `fdplay` of a test-pattern recording at a fixed sink rate
(`--rate`). A rate is **clean** when the hardware checker reports 0 underflows, 0 errors,
and gap beats equal to the recording's drop count; the highest clean rate is the fastest
constant-rate stream that the SSDs deliver into the fabric. `fdplay` fills the whole buffer
ring from the file before the first buffer is played, so the ring absorbs read stalls up to
its length at the sink rate.

The sweep plays a 10 GB recording made at 1000 MB/s (0 drops), from 2500 MB/s in 500 MB/s
steps up to the first step with underflows, with 32 and with 16 buffers; the highest clean
step is run 3 times, the first failing step twice.

```
sudo fdrec --rate 1000MB --size 10G /mnt/rec/t.dat; echo rc=$?
sudo fdplay --rate 2500MB /mnt/rec/t.dat; echo rc=$?
```

### References and CPU load

* **fio** gives a reference for what the filesystem and SSDs can do without a fixed input
  rate: `fio --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8` (writes) and the
  same with `--rw=read` (reads), on the same filesystem. "With hugepage fixed buffers" adds
  `--iomem=mmaphuge --fixedbufs`, which is how `fdrec` and `fdplay` do their I/O.
* The drive-only references (fio, the `dd` scripts, the SLC cache fill) run at their own
  speed; the recorder rows of the
  [dd comparison](#comparison-with-fpga-drive-aximm-pcie-dd-method) run at the top rates only.
* **CPU load** is given as a share of all CPU cores of the target (user + system, and I/O
  wait separately) and as the share of one core used by the transfer process.

## Setups

Two SSD pairs, each on two targets. Units: MB/s = 10⁶ bytes/s, GB = 10⁹ bytes, GiB = 2³⁰
bytes (the `fdrec --size` values); figures are medians of 3 runs unless noted.

| SSDs | target | PCIe link per SSD | measured |
|---|---|---|---|
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` (M.2 M-key Stack FMC on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-22 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` (FPGA Drive FMC Gen4 on FMCP1) | **Gen4 x4** (16 GT/s) | 2026-10-22 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` (FPGA Drive FMC Gen4 on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-22 |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` (M.2 M-key Stack FMC on HPC0) | Gen3 x4 (`8GT/s (downgraded)`: a Gen4 drive on Gen3 Root Ports) | 2026-10-22 |

All were measured with the shipped default of 32 x 8 MB buffers (unless noted) and with a fan
on the cards (no thermal throttling: at most 66 °C on the Sabrent drives on `zcu106_hpc0` and
62 °C on `vck190_fmcp1`, 52 °C on the 980 PROs on `zcu106_hpc0` and 50 °C on `vck190_fmcp1`,
with 0 warning or critical temperature time and no thermal-management transition). The same two
drives of each pair are used on both boards.

Every figure on this page was measured with the images of this repository: register map 1.2
with a 256-bit (32-byte) fabric datapath, `src_clk` = `dp_clk` = 250 MHz (249.975 MHz on
`zcu106_hpc0`, 249.9998 MHz on `vck190_fmcp1`), an ingest FIFO of 8192 beats (256 KB) and an
egress FIFO of 4096 beats (128 KB), and `fdrec` driver 1.3, which pins the AXI DMA interrupts
off CPU0 and keeps the DMA armed across buffer boundaries (`xilinx_dma` patch 0002, see
[Kernel driver](driver.md)). The generator and the sink run at up to 8000 MB/s (250 MHz × 32
bytes). On `zcu106_hpc0` the AXI DMA reaches the PS DDR through `S_AXI_HP2_FPD`, 128 bits at
322.19 MHz (`pl_clk3`). "FIFO high-water" figures are in beats of 32 bytes, of 8192. PCIe
MaxPayload was 128 bytes and MaxReadReq 512 bytes on every Root Port and SSD (the kernel's
default; see [The PCIe links and MaxPayload](#6-the-pcie-links-and-maxpayload) for 256
bytes).

## Results: recording, playback and CPU

Targets `vck190_fmcp1` (Versal, two Cortex-A72 cores at 1.4 GHz) and `zcu106_hpc0` (Zynq
UltraScale+, four Cortex-A53 cores at 1.2 GHz), with the SSD pairs of [Setups](#setups). RAID0 =
both drives of a pair, 512 KB chunks (`fdsetup-raid0.sh` defaults). The recordings used the
shipped default ring of 32 x 8 MB buffers unless noted. "FIFO high-water" is the highest fill
level the ingest FIFO reached during a recording, in 32-byte beats of 8192; "full" means it
overflowed.

### Fabric only (no SSD)

The path from the fabric into DDR and back, with no SSD involved (see the
[fabric-only method](#fabric-only-method)), measured 2026-10-22:

| target | direction | highest clean rate | first failing rate | at the 8000 MB/s maximum | what limits it |
|---|---|---|---|---|---|
| `zcu106_hpc0` | record (`fdrec --no-write`, 64 GiB) | **5000 MB/s** (4 of 4; FIFO high-water 4 beats) | 5250 MB/s (3 of 3) | drops (1 184 831 104 beats in 64 GiB); the DMA delivers a flat 5153-5155 MB/s from 5250 MB/s up | `S_AXI_HP2_FPD`, 128 bits at 322.19 MHz = 5155 MB/s |
| `zcu106_hpc0` | playback (256 MiB held in the ring) | **5000 MB/s** (3 of 3; also with 64 x 4 MiB) | 5250 MB/s (3 of 3: 364 340-370 279 underflow ticks) | underflows (4.95 million ticks); ~5.03 GB/s delivered | `S_AXI_HP2_FPD` |
| `vck190_fmcp1` | record (`fdrec --no-write`, 64 GiB) | **7750 MB/s** (4 of 4; FIFO high-water 10-164 beats) | 8000 MB/s (4 of 4) | drops (57 259 to 2 138 051 beats in 64 GiB) although the DMA delivers 7989-7997 MB/s | `src_clk` = `dp_clk`: no drain headroom (see [The fabric datapath](#8-the-fabric-datapath)) |
| `vck190_fmcp1` | playback (256 MiB held in the ring) | **7500 MB/s** (3 of 3; also with 64 x 4 MiB and 16 x 16 MiB) | 7750 MB/s (3 of 3: 1285-1344 underflow ticks) | underflows (~272 000 ticks, 3 % of the beats played) | `src_clk` = `dp_clk`: the egress FIFO cannot refill |

* On `zcu106_hpc0` the record and playback knees are the same, and above them the DMA moves a
  flat 5155 MB/s = 322.19 MHz × 16 bytes: the 128-bit `S_AXI_HP2_FPD` port at its clock, not
  the 8 GB/s source, the 256-bit ingest FIFO and AXI DMA, or the DDR.
* On `vck190_fmcp1` the DMA's NoC path carries the full rate (7.99 GB/s delivered at
  8000 MB/s), but with a source at one beat per clock every cycle in which the DMA takes no
  beat stays in the ingest FIFO: in the 8000 MB/s runs it filled to 7634 of 8192 beats in the
  first second and then lost ~8 beats per 8 MiB buffer boundary. At 7750 MB/s it drains
  between boundaries. 16 MB buffers and pinning `fdrec` to either core did not change that.
  Playback is the mirror image, one step lower.
* The data was intact in every playback (0 errors, 0 gaps); underflows are cycles in which the
  sink found no data.
* `fdrec --no-write` still takes CPU time for the buffer recycling and the cache maintenance
  of every buffer: 56 % of one A53 core at 4000 MB/s and 70 % at 5000 MB/s on `zcu106_hpc0`,
  71 % of one A72 core at 7750 MB/s and 73 % at 8000 MB/s on `vck190_fmcp1`.

The knees were repeated with the other FMC card and SSD pair fitted on each board (one run per
rate): on `zcu106_hpc0` with the FPGA Drive FMC Gen4 and the 980 PROs, `fdrec --no-write` clean
at 5000 MB/s (FIFO high-water 4 beats) and 39 578 080 beats dropped at 5250 MB/s with the DMA at
5153 MB/s, playback from the ring clean at 5000 MB/s and 363 989 underflow ticks at 5250 MB/s;
on `vck190_fmcp1` with the M.2 M-key Stack FMC and the Sabrent drives, `fdrec --no-write` clean at
7750 MB/s (high-water 10 beats) and 2 022 691 beats dropped at 8000 MB/s with the DMA at
7989 MB/s, playback from the ring clean at 7500 MB/s and 1372 underflow ticks at 7750 MB/s. The
fabric limits do not depend on the FMC card or the drives.

### Sustained recording rate

`fdbench.sh --size 32G` steps as in the [recording method](#recording-method): 500 MB/s steps
from 2500 MB/s, `fdrec` with queue depth 8, each layout on a freshly created XFS filesystem,
`rm` + `fstrim` + 60 s of idle before every step, 32 x 8 MB buffers, early stop after two
consecutive failing steps, 3 runs at the highest clean and at the first failing step.

The last column is the rate that holds **past the SLC cache**. The 32 GB sweep runs inside the
cache of these drives, so the last column comes from the
[long recordings](#long-recordings-past-the-slc-cache).

| target | SSD | layout | 32 GB sweep: highest clean step | fio reference (32 GB) | sustained past the SLC cache |
|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 4500 MB/s, in the cache (3 of 3; 5000 MB/s drops 3 of 3 while writing 4567-4653 MB/s: the drive's in-cache rate on Gen4 x4) | 4463 MB/s, in the cache (fio CPU-bound) | **1750 MB/s** over 200 GiB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4000 MB/s, in the cache (3 of 3; 4500 and 5000 MB/s drop in one gap at 0.27 GB: the drives waking from APST power saving after the idle time; **7000 MB/s clean 3 of 3 with 16 MB buffers**, 4500-6000 MB/s clean with APST off) | 4547 MB/s, in the cache (fio CPU-bound; 7.17-7.33 GB/s with fixed buffers) | **3500 MB/s** over 350 GiB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 4500 MB/s, in the cache (3 of 3; 5000 MB/s clean in 3 of 7 recordings of 32 GB: the drive writes ~4.94-4.98 GB/s in its cache) | 4760 MB/s, in the cache (fio CPU-bound) | **1750 MB/s** over 240 GiB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6500 MB/s, in the cache (3 of 3; 7000 MB/s clean 2 of 3 with 8 MB buffers, 3 of 3 with 16 MB buffers) | 4779 MB/s, in the cache (fio CPU-bound; 7.62 GB/s with fixed buffers) | **3250 MB/s** over 480 GiB (6000 and 6500 MB/s dropped from the cache end, ~240-250 GB) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3000 MB/s, in the cache (3 of 3; 3500 MB/s drops 3 of 3: above the drive's ~3.04 GB/s on Gen3 x4) | 2980 MB/s, in the cache | **1750 MB/s** over 200 GiB (3000 MB/s dropped from 116.78 GB, past the ~118-124 GB cache) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 MB/s, in the cache (3 of 3; 5000 MB/s clean in 5 of 7 recordings of 32 GB with the default ring and **3 of 3 with 64 x 8 MB buffers**; 5500 MB/s and above exceed `S_AXI_HP2_FPD` with any ring) | 3436 MB/s, in the cache (fio CPU-bound; 6.07 GB/s with fixed buffers) | **3250 MB/s** over 350 GiB (4500 and 5000 MB/s dropped from the cache end, ~245 GB) |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2500 MB/s, in the cache (3 of 3; 3000 MB/s drops 3 of 3: above the drive's ~2.94 GB/s on Gen3 x4) | 2895 MB/s, in the cache | **1750 MB/s** over 200 GiB (2500 MB/s dropped from 80.25 GB, past the ~66-69 GB cache) |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3500 MB/s, in the cache (3 of 3; 4000 MB/s clean 1 of 3, 4500 MB/s dropped: write stalls longer than the 256 MB ring; **4500 MB/s clean 3 of 3 with 64 x 8 MB buffers**) | 3379 MB/s, in the cache (fio CPU-bound) | **3000 MB/s** over 350 GiB (3500 MB/s held the rate past the cache but dropped in one ~0.2 s write stall at 285.71 GB) |

`vck190_fmcp1` with two Sabrent Rocket 2230 1TB (Gen4 x4), same method, 32 x 8 MB buffers.
Single drive: clean up to 4500 MB/s (3 of 3, high-water mark 3 beats); 5000 MB/s drops in 3 of 3
runs from 1.07-1.40 GB and 5500 MB/s from 0.81 GB, while writing 4567-4653 MB/s: the drive's
in-cache write rate on Gen4 x4 is ~4.6 GB/s. RAID0: clean up to 4000 MB/s (3 of 3, high-water
mark 2); 4500 MB/s (3 of 3 runs) and 5000 MB/s dropped, each time in a single gap at 0.27 GB,
right after the first pass through the 256 MB ring, and then held the rate to the end
(4988 MB/s on average at 5000 MB/s). That gap is the start of the recording: after the 60 s of
idle time both drives sit in their deepest APST power state, and the first writes take
~63-65 ms, longer than the ring lasts at 4.5 GB/s (see
[Start-up stalls and the ring size](#start-up-stalls-and-the-ring-size)). With a 512 MB ring
(`--buf-size 16M`) the pair was clean at every step from 4500 to 7000 MB/s (7000 MB/s 3 of 3),
and 7500 MB/s drops while writing 7.13-7.14 GB/s, the host's write ceiling with this pair; with
APST disabled, 4500, 5000 and 6000 MB/s were clean with the default ring. These steps run
inside the drives' SLC cache (~70-75 GB per drive). Past the cache one drive holds 1750 MB/s
(200 GiB) and the pair 3500 MB/s (350 GiB); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`vck190_fmcp1` with two Samsung 980 PRO 1TB (Gen4 x4), same method, 32 x 8 MB buffers. Single
drive: clean up to 4500 MB/s (3 of 3, high-water mark 3 beats); 5000 MB/s passed the sweep and
its two confirmations, but only because the 256 MB ring absorbed a small deficit
(4975-4981 MB/s achieved), and four further 32 GB recordings at 5000 MB/s dropped; 5500 and
6000 MB/s drop while writing 4975-4982 MB/s: the drive's in-cache write rate on Gen4 x4 is
~4.95-4.98 GB/s. RAID0: clean up to 7000 MB/s in the sweep; 7000 MB/s then dropped in one of
two confirmations (6737 MB/s), so 6500 MB/s is the highest step clean 3 of 3 (high-water mark
7); 7500 and 8000 MB/s drop at 7329-7356 MB/s, which is ~96 % of the host's write ceiling on
this array (~7.62 GB/s with fio and fixed buffers, see [The paths into DDR](#7-the-paths-into-ddr)).
With 16 MB buffers (`--buf-size 16M`, a 512 MB ring) 7000 MB/s was clean 3 of 3. These steps
run inside the drives' SLC cache (~115-125 GB per drive). Past the cache one drive holds
1750 MB/s (240 GiB) and the pair 3250 MB/s (480 GiB); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`zcu106_hpc0` with two Samsung 980 PRO 1TB (Gen3 x4), same method, 32 x 8 MB buffers. Single
drive: clean up to 3000 MB/s (3 of 3, high-water mark 1 beat); 3500 MB/s drops in 3 of 3 runs
from 1.85-1.94 GB while writing 3034-3037 MB/s, and 4000 MB/s from 1.03 GB: the drive on its
Gen3 x4 link (~3.04 GB/s). RAID0: clean at every step from 2500 to 5000 MB/s (high-water mark 1
to 4 beats) and at 5000 MB/s in 3 of 3 sweep runs; 5500 and 6000 MB/s drop while writing a flat
5118-5147 MB/s, the 5.16 GB/s of `S_AXI_HP2_FPD`: their first gap lies inside the first buffer,
2-5 MB into the file (the path into DDR, not the ring), also with 64 x 8 MB or 32 x 16 MB
buffers. Four further 32 GB recordings at 5000 MB/s with the default ring, outside the sweep,
dropped twice (2582 beats; 8 580 162 beats in a stall in the first second after the idle time),
while 4500 MB/s was clean 3 of 3 and 5000 MB/s with 64 x 8 MB buffers 3 of 3. These steps run
inside the SLC cache (~118-124 GB per drive). Past the cache one drive holds 1750 MB/s
(200 GiB) and the pair 3250 MB/s (350 GiB); see
[Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

`zcu106_hpc0` with two Sabrent Rocket 2230 1TB (Gen3 x4), same method, 32 x 8 MB buffers. Single
drive: clean at 2500 MB/s (3 of 3, high-water mark 1 beat); 3000 MB/s drops in 3 of 3 runs from
9.13-9.50 GB while writing 2879-2948 MB/s, and 3500 MB/s from 1.03 GB at 2943 MB/s: the drive
on its Gen3 x4 link (~2.94 GB/s), a fixed rate deficit. RAID0: clean at 2500, 3000 and
3500 MB/s (3500 in 3 of 3, high-water mark 1); 4000 MB/s was clean in 1 of 3 runs and
4500 MB/s dropped: in two of these runs in a single gap at 0.27 GB, right after the first pass
through the ring (the signature of the start-up stall that `vck190_fmcp1` traced to APST; not
tested on this board), once in 14 gaps from 26.07 GB: stalls longer than the 256 MB ring lasts
at that rate (57-64 ms). With 64 x 8 MB buffers (512 MB) 4500 MB/s was clean in 3 of 3 runs,
while 5000 MB/s drops with either ring (all 8 writes in flight, ~4.8-4.9 GB/s written: the
Sabrent pair; the 980 PRO pair records 5000 MB/s on this board). These steps run inside the
SLC cache (~66-69 GB per drive). Past the cache one drive holds 1750 MB/s (200 GiB), the RAID0 pair
3000 MB/s (350 GiB); see [Long recordings past the SLC cache](#long-recordings-past-the-slc-cache).

fio reference: `fio --name=w --rw=write --bs=8M --direct=1 --ioengine=io_uring --iodepth=8
--size=32G --filename=/mnt/rec/fio.dat` on the freshly created filesystem, before the sweep.
It is an average over 32 GB: fio has no fixed input rate, so it rides the SLC cache at full
speed and does not show the post-cache write rate that limits a constant-rate recording.

Every step of the sweeps ("first gap" is the file offset of the first discontinuity
reported by `fdverify`; "avg MB/s" is the data written divided by the recording time;
"gaps (20)" = the first 20 of many discontinuities); 32 x 8 MB buffers:

| target | SSD | layout | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | avg MB/s | fdverify | first gap |
|---|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 2500 | pass | 0 | 1 | 2498.9 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 3000 | pass | 0 | 1 | 2998.5 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 3500 | pass | 0 | 1 | 3497.9 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 4000 | pass | 0 | 2 | 3997.2 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | **4500** | pass | 0 | 3 | 4496.8 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 5000 | drops | 73 395 150 | full | 4643.8 | gaps | 1.07 GB |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 5500 | drops | 191 484 815 | full | 4634.4 | gaps | 0.81 GB |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 4500 (#2) | pass | 0 | 3 | 4496.8 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 5000 (#2) | drops | 70 989 709 | full | 4653.3 | gaps | 1.11 GB |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 4500 (#3) | pass | 0 | 3 | 4493.2 | pass | - |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 5000 (#3) | drops | 93 549 899 | full | 4567.3 | gaps | 1.40 GB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 1 | 2498.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 1 | 2998.5 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3500 | pass | 0 | 1 | 3497.9 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **4000** | pass | 0 | 2 | 3997.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4500 | drops | 462 600 | full | 4494.4 | gaps | 0.27 GB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 5000 | drops | 1 592 112 | full | 4988.3 | gaps | 0.27 GB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4000 (#2) | pass | 0 | 2 | 3996.7 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4500 (#2) | drops | 492 550 | full | 4494.4 | gaps | 0.27 GB |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4000 (#3) | pass | 0 | 2 | 3997.2 | pass | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4500 (#3) | drops | 540 295 | full | 4494.4 | gaps | 0.27 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 1 | 2498.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3000 | pass | 0 | 1 | 2998.5 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 3500 | pass | 0 | 1 | 3497.9 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 4000 | pass | 0 | 2 | 3997.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | **4500** | pass | 0 | 3 | 4496.2 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5000 | pass | 0 | 4 | 4980.4 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5500 | drops | 104 399 473 | full | 4975.3 | gaps | 2.47 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 6000 | drops | 210 955 816 | full | 4977.5 | gaps | 1.49 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5000 (#2) | pass | 0 | 4 | 4974.6 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5500 (#2) | drops | 102 874 375 | full | 4981.8 | gaps | 2.70 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5000 (#3) | pass | 0 | 4 | 4981.1 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5500 (#3) | drops | 103 619 879 | full | 4978.2 | gaps | 2.76 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 4500 (#2) | pass | 0 | 3 | 4496.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 4500 (#3) | pass | 0 | 3 | 4496.8 | pass | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5000 (#4) | drops | 4 488 976 | full | 4943.1 | gaps | 18.39 GB |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 5000 (#5) | drops | 4 792 910 | full | 4941.0 | gaps | 21.01 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 1 | 2499.1 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 1 | 2998.5 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3500 | pass | 0 | 1 | 3497.9 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4000 | pass | 0 | 2 | 3997.6 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 | pass | 0 | 3 | 4496.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 | pass | 0 | 4 | 4996.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 | pass | 0 | 5 | 5495.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6000 | pass | 0 | 6 | 5994.4 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **6500** | pass | 0 | 7 | 6494.0 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7000 | pass | 0 | 8 | 6990.8 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7500 | drops | 13 491 423 | full | 7356.0 | gaps | 11.79 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 8000 | drops | 89 250 040 | full | 7335.6 | gaps | 0.09 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7000 (#2) | drops | 32 201 712 | full | 6737.2 | gaps | 26.81 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7500 (#2) | drops | 17 368 828 | full | 7329.3 | gaps | 6.22 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7000 (#3) | pass | 0 | 8 | 6992.2 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 7500 (#3) | drops | 14 660 688 | full | 7345.0 | gaps | 13.04 GB |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6500 (#2) | pass | 0 | 7 | 6490.3 | pass | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6500 (#3) | pass | 0 | 7 | 6492.8 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 2500 | pass | 0 | 1 | 2498.3 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | **3000** | pass | 0 | 1 | 2997.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3500 | drops | 154 403 626 | full | 3036.9 | gaps (20) | 1.85 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 4000 | drops | 329 305 806 | full | 3036.9 | gaps (20) | 1.03 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3000 (#2) | pass | 0 | 1 | 2997.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3500 (#2) | drops | 154 448 329 | full | 3036.9 | gaps (20) | 1.85 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3000 (#3) | pass | 0 | 1 | 2997.4 | pass | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 3500 (#3) | drops | 155 334 368 | full | 3033.7 | gaps (20) | 1.94 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 1 | 2498.5 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 1 | 2998.0 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 3500 | pass | 0 | 1 | 3497.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4000 | pass | 0 | 2 | 3996.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | **4500** | pass | 0 | 3 | 4495.6 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 | pass | 0 | 4 | 4993.4 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 | drops | 72 370 984 | full | 5142.9 | gaps (20) | 0.005 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 6000 | drops | 177 603 639 | full | 5117.6 | gaps (20) | 0.002 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#2) | pass | 0 | 2274 | 4994.1 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 (#2) | drops | 72 339 629 | full | 5146.8 | gaps (20) | 0.005 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#3) | pass | 0 | 4 | 4992.7 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5500 (#3) | drops | 72 277 257 | full | 5144.4 | gaps (20) | 0.005 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#4) | drops | 8 580 162 | full | 4954.5 | gaps (160) | 2.20 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 (#2) | pass | 0 | 3 | 4495.6 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 5000 (#5) | pass | 0 | 4 | 4994.2 | pass | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 4500 (#3) | pass | 0 | 3 | 4495.0 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | **2500** | pass | 0 | 1 | 2498.3 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2500 (#2) | pass | 0 | 1 | 2498.3 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 2500 (#3) | pass | 0 | 1 | 2498.3 | pass | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 | drops | 10 695 300 | full | 2947.6 | gaps (20) | 9.13 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 (#2) | drops | 37 257 754 | full | 2879.1 | gaps (20) | 9.20 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3000 (#3) | drops | 12 558 399 | full | 2943.8 | gaps (20) | 9.50 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 3500 | drops | 193 533 571 | full | 2943.0 | gaps (20) | 1.03 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 2500 | pass | 0 | 1 | 2498.3 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3000 | pass | 0 | 1 | 2997.7 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | **3500** | pass | 0 | 1 | 3496.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3500 (#2) | pass | 0 | 1 | 3496.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 3500 (#3) | pass | 0 | 1 | 3496.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4000 | drops | 24 948 580 | full | 3905.0 | gaps (14) | 26.07 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4000 (#2) | drops | 36 879 | full | 3995.8 | gaps (1) | 0.27 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4000 (#3) | pass | 0 | 2 | 3995.8 | pass | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 4500 | drops | 1 059 248 | full | 4490.3 | gaps (1) | 0.27 GB |

"(#2)" to "(#5)" are repeats. On `vck190_fmcp1` the 980 PRO single-drive runs 4500 (#2),
4500 (#3), 5000 (#4) and 5000 (#5) and the RAID0 runs 6500 (#2) and 6500 (#3) ran on a second
freshly created filesystem; two further 32 GB recordings at 5000 MB/s on one 980 PRO, made
outside the sweep (the [dd comparison](#results-vck190_fmcp1) and the [CPU load](#cpu-load)
runs), dropped 5 812 732 and 2 678 151 beats. On `zcu106_hpc0` the 980 PRO RAID0 runs 5000 (#4),
4500 (#2), 5000 (#5) and 4500 (#3) ran on a second freshly created filesystem; two further 32 GB
recordings at 5000 MB/s on that RAID0, made outside the sweep (the
[dd comparison](#results-zcu106_hpc0) and the [CPU load](#cpu-load) runs), dropped 2582 beats
and were clean (high-water mark 5115), respectively.
Every failing step starts its first gap 262 368 bytes (8192 + 7 beats of 32 bytes) after an
8 MiB buffer boundary: the ring ran out behind the drive (see
[Where the bottlenecks are](#5-latency-budgets-not-bandwidth)); the single gaps at 0.27 GB of the
Sabrent pairs are 262 368 bytes after the 32nd boundary, the end of the first pass through the
ring. There are two exceptions. RAID0 at 8000 MB/s on `vck190_fmcp1` has its first gap inside a
buffer, at 0.09 GB: the 8000 MB/s limit of the fabric itself (see
[Fabric only](#fabric-only-no-ssd)). RAID0 at 5500 and 6000 MB/s on `zcu106_hpc0` has its first
gap inside the first buffer (~4.65 MB and ~2.08 MB into the file) and then 1-beat gaps
throughout: the 5.16 GB/s of `S_AXI_HP2_FPD`. In the failing runs the gaps that `fdverify` finds
add up exactly to the drop count in the file header (two 16-byte words per dropped beat).

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`, Gen4 x4): one drive is clean to 4500 MB/s; it
  writes ~4.6 GB/s in its cache (4567-4653 MB/s at 5000 and 5500 MB/s), so 5000 MB/s drops. The
  RAID0 pair is clean to 4000 MB/s with the default ring; at 4500 and 5000 MB/s every failure is
  one gap at 0.27 GB, the drives waking from APST at the start of the recording (see
  [Start-up stalls and the ring size](#start-up-stalls-and-the-ring-size)); with 16 MB buffers
  the pair is clean to 7000 MB/s (3 of 3), and 7500 MB/s exceeds the host's ~7.2-7.3 GB/s write
  path with this pair.
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`, Gen3 x4): one drive is clean to 3000 MB/s; it writes
  ~3.04 GB/s on its Gen3 x4 link, so 3500 MB/s drops (3 of 3). The RAID0 pair records up to
  `S_AXI_HP2_FPD`: 5000 MB/s passed the sweep 3 of 3 but only 2 of 4 later runs with the default
  256 MB ring (a stall in the first second after the idle time outlasted the ring, 51 ms at
  5 GB/s), and 3 of 3 with 64 x 8 MB buffers; 4500 MB/s is clean 3 of 3 with the default ring;
  5500 MB/s and above exceed HP2 with any ring.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`, Gen4 x4): one drive is clean to 4500 MB/s; it
  writes ~4.95-4.98 GB/s in its cache, so 5000 MB/s passes only while the ring covers the
  deficit (3 of 7 over 32 GB) and 5500 MB/s drops. The RAID0 pair is clean to 6500 MB/s (3 of
  3) and 7000 MB/s in 2 of 3 (3 of 3 with 16 MB buffers); 7500 MB/s and above exceed the
  host's ~7.6 GB/s write path (fio 32 GB 4760 / 4779 MB/s without fixed buffers, CPU-bound).
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): the single-drive failures at 3000 and
  3500 MB/s write 2879-2948 MB/s, the drive on its Gen3 x4 link (a fixed rate deficit). On
  RAID0, 4000 MB/s failed in 2 of 3 runs and 4500 MB/s once, each time on stalls longer than
  the 256 MB ring (two of them a single gap at 0.27 GB, the start-up signature); with a 512 MB
  ring 4500 MB/s was clean 3 of 3.

### Burst and 40 GB recordings

Single recordings at a fixed rate: 32 x 8 MB buffers, `rm` + `fstrim` + 30 s idle before each,
10 GB and 40 GB at the highest clean step of the 32 GB sweep and once at its first failing
step (with the 980 PRO pair on `vck190_fmcp1`, where a burst at 6500 MB/s dropped, also at
6000 MB/s, and its RAID0 bursts were run twice; with the 980 PRO pair on `zcu106_hpc0` at
5000 MB/s, the sweep's step clean 3 of 3 when the bursts ran). "Burst" rows are 10 GB
recordings; the 40 GB rows are still inside the SLC caches of these drives.

| target | SSD | layout | recording | rate (MB/s) | result | FIFO high-water (beats) |
|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 10 GB | **4500** | pass, 3 of 4 (one drop from 0.41 GB right after a 500 GiB write to the pair, see below) | 3 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 10 GB | 5000 | drops from 3.81 GB (above the drive's ~4.6 GB/s write rate) | full |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 40 GB | **4500** | pass (in the cache) | 3 |
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 40 GB | 5000 | drops from 1.69 GB | full |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **4000** | pass | 2 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 4500 | drops in one gap at 0.27 GB (the APST start-up stall) | full |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **4000** | pass (in the cache) | 2 |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | 4500 | drops in one gap at 0.27 GB (the APST start-up stall) | full |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 10 GB | **5000** | pass (highest burst; the drive writes ~4.95-4.98 GB/s, the ring covers the rest) | 4 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 10 GB | 5500 | drops from 2.70 GB (above the drive's write rate) | full |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 40 GB | **5000** | pass (in the cache) | 4 |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 40 GB | 5500 | drops from 2.54 GB | full |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **6000** | pass, 2 of 2 | 6 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 6500 | 1 of 2 (one run dropped from 0.86 GB) | 7 / full |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 7000 | pass, 2 of 2 | 293 / 8 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **6000** | pass, 2 of 2 (in the cache) | 6 |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 6500 | 1 of 2 (one run dropped from 41.67 GB) | 7 / full |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 7000 | 1 of 2 (one run dropped from 1.41 GB) | 144 / full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | **3000** | pass, 3 of 4 (one drop from 0.91 GB right after a 500 GiB write to the pair, see below) | 1 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 10 GB | 3500 | drops from 1.85 GB (above the drive's ~3.04 GB/s write rate on Gen3 x4) | full |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | **3000** | pass (in the cache) | 1 |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 40 GB | 3500 | drops from 1.94 GB | full |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | **5000** | pass | 4 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 10 GB | 5500 | drops from 4.65 MB (`S_AXI_HP2_FPD`) | full |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | **5000** | pass (in the cache) | 4 |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 40 GB | 5500 | drops from 4.67 MB (`S_AXI_HP2_FPD`) | full |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | **2500** | pass, 3 of 4 (one drop from 1.00 GB right after a 500 GiB write to the pair, see below) | 1 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 10 GB | 3000 | drops from 10.00 GB (above the drive's ~2.94 GB/s write rate on Gen3 x4) | full |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | **2500** | pass (in the cache) | 1 |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 40 GB | 3000 | drops from 10.07 GB | full |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | 3500 | pass | 1 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 10 GB | **4000** | pass (highest burst tried) | 2 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | **3500** | pass (in the cache) | 1 |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 40 GB | 4000 | drops (one start-up gap at 0.27 GB) | full |

* **Sabrent Rocket 2230 1TB** (`vck190_fmcp1`): one drive bursts 10 and 40 GB at 4500 MB/s
  (5000 MB/s exceeds its ~4.6 GB/s write rate: drops from 1.7-3.8 GB). The first 10 GB run, right
  after a 500 GiB write to the pair, dropped from 0.41 GB (the drive still moving that data out
  of its cache); three repeats were clean. RAID0 records 10 and 40 GB at 4000 MB/s; at
  4500 MB/s both lost the start-up gap at 0.27 GB.
* **Samsung 980 PRO 1TB** (`vck190_fmcp1`): one drive bursts 10 and 40 GB at 5000 MB/s
  (5500 MB/s exceeds its ~4.95-4.98 GB/s write rate: drops from 2.5-2.7 GB). The RAID0 pair
  records 10 and 40 GB at 6000 MB/s in 2 of 2 runs each; at 6500 MB/s one run in two dropped
  (10 and 40 GB), at 7000 MB/s one of the two 40 GB runs (both 10 GB runs were clean): write
  stalls longer than the 256 MB ring lasts (37-39 ms), each with 8 writes in flight. 16 MB
  buffers made 7000 MB/s clean over 32 GB.
* **Samsung 980 PRO 1TB** (`zcu106_hpc0`): one drive records 10 and 40 GB at 3000 MB/s
  (3500 MB/s exceeds its ~3.04 GB/s write rate on Gen3 x4: drops from 1.85 and 1.94 GB). One
  10 GB run at 3000 MB/s dropped once, in a single stall at 0.91 GB, as the first recording after
  a 500 GiB write to the pair; three repeats were clean. The RAID0 pair records 10 and 40 GB at
  5000 MB/s; 5500 MB/s is above `S_AXI_HP2_FPD`.
* **Sabrent Rocket 2230 1TB** (`zcu106_hpc0`): one drive records 10 and 40 GB at 2500 MB/s
  (3000 MB/s exceeds its ~2.94 GB/s write rate on Gen3 x4: drops from 10.00 and 10.07 GB). One
  10 GB run at 2500 MB/s dropped once, in a single stall at 1.00 GB, as the first recording
  after a 500 GiB write to the pair (the drive was likely still moving that data out of its
  cache); three repeats were clean. RAID0 records 10 GB at 4000 MB/s and 40 GB at 3500 MB/s;
  40 GB at 4000 MB/s lost one start-up gap at 0.27 GB.

### Long recordings past the SLC cache

For the 1 TB drives a 32 GB or 40 GB recording stays inside the SLC cache, so the rate that
holds for a long recording was measured with single recordings of 1.5 to three times the
cache (fresh XFS, `rm` + `fstrim` and **300 s** of idle before each, 32 x 8 MB buffers). One
drive: at 1750 MB/s on every combination, and on `zcu106_hpc0` also at the in-cache top of the
sweep, which drops where the cache ends. RAID0: the 980 PRO pairs at the in-cache top and one
step lower (6500 and 6000 MB/s on `vck190_fmcp1`, 5000 and 4500 MB/s on `zcu106_hpc0`), which
are above the pair's post-cache rate and drop at the cache end, then at 3250 MB/s, just below
the pair's ~3.46-3.57 GB/s post-cache rate; the Sabrent pairs at 3500 MB/s (on `zcu106_hpc0`
the in-cache top, followed by 3000 MB/s; on `vck190_fmcp1`, where the in-cache top of 4000 MB/s
lies above the pair's ~3.6 GB/s post-cache rate, directly). Sizes are the `fdrec --size` values
(GiB), with GB (10⁹ bytes) in brackets. The ingest FIFO high-water mark was read and cleared
every second while the recording ran; the table gives the highest of those samples.

| target | SSD | layout | recording | rate (MB/s) | result | drops (beats) | FIFO high-water (beats) | first gap |
|---|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 200 GiB (214.7 GB, ~2.9x the cache) | **1750** | pass, `fdverify` PASS | 0 | 1 | - |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | **3500** | pass, `fdverify` PASS | 0 | 1 | - |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 240 GiB (257.7 GB, ~2.1x the cache) | **1750** | pass, `fdverify` PASS | 0 | 1 | - |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB (515.4 GB, ~2.1x the pair's cache) | 6500 | drops (past the cache, ~3.55 GB/s) | 7 170 804 659 | full | 0.55 GB (an early stall; continuous drops from ~250 GB, the cache end) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | 6000 | drops (past the cache, ~3.55 GB/s) | 5 814 125 535 | full | 0.78 GB (an early stall; continuous drops from ~240 GB) |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 480 GiB | **3250** | pass, `fdverify` PASS | 0 | 1 | - |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB (214.7 GB, ~1.8x the cache) | 3000 | drops (past the cache, ~1.77 GB/s) | 1 978 747 470 | full | 116.78 GB |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 1 | - |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~1.5x the pair's cache) | 5000 | drops (a start-up stall, then past the cache) | 1 706 675 161 | full | 3.05 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | 4500 | drops (past the cache, ~3.54 GB/s) | 1 061 305 139 | full | 247.34 GB |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 350 GiB | **3250** | pass, `fdverify` PASS | 0 | 1 | - |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB (214.7 GB, ~3x the cache) | 2500 | drops (past the cache, ~1.81 GB/s) | 1 600 668 620 | full | 80.25 GB |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 200 GiB | **1750** | pass, `fdverify` PASS | 0 | 1 | - |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB (375.8 GB, ~2.6x the pair's cache) | 3500 | drops (one write stall) | 16 775 917 | full | 285.71 GB |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 350 GiB | **3000** | pass, `fdverify` PASS | 0 | 1 | - |

* **Sabrent Rocket 2230 1TB on `vck190_fmcp1`**: one drive holds 1750 MB/s over 200 GiB
  (post-cache median 1799 MB/s: ~3 % margin) and the RAID0 pair 3500 MB/s over 350 GiB
  (post-cache median 3614 MB/s: ~3 %), one run each, with a FIFO high-water mark of 1 beat in
  every 1 s sample; writes in flight 0-1 (one drive) and 0-6 (RAID0) per 10 s sample.
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, single**: 1750 MB/s holds over 240 GiB (post-cache
  median 1766 MB/s: ~1 % margin); the FIFO high-water mark was 1 beat in every 1 s sample of
  the recording (one more sample, taken while the recording stopped, read 3830 beats; `fdrec`'s
  own figure is 1), with 0-1 writes in flight in most 10 s samples (at most 8).
* **Samsung 980 PRO 1TB on `vck190_fmcp1`, RAID0**: the pair holds 3250 MB/s over 480 GiB
  (high-water mark 1 in all 156 samples). Inside the cache it held 6000 and 6500 MB/s apart
  from one early stall each in the first GB (8192 + 7 beats after a buffer boundary: the ring
  ran out); past the cache end (~240-250 GB) it writes a flat ~3.52-3.57 GB/s, so 6000 and
  6500 MB/s drop there.
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, single**: 1750 MB/s holds over 200 GiB (post-cache
  median 1765 MB/s: ~1 % margin; high-water mark 1 in all 121 one-second samples, 0-2 writes in
  flight in most 10 s samples, 8 once). 3000 MB/s drops from 116.78 GB, where the cache ends and
  the drive falls to 1767-1831 MB/s with all 8 writes in flight.
* **Samsung 980 PRO 1TB on `zcu106_hpc0`, RAID0**: the pair holds 3250 MB/s over 350 GiB
  (high-water mark 1 in all 114 samples, 0-2 writes in flight). At 4500 MB/s it held the rate
  with 2-3 writes in flight up to the cache end at 247.34 GB, then wrote 3537-3573 MB/s; at
  5000 MB/s it lost one stall in the first second after the 300 s of idle time (at 3.05 GB,
  8192 + 7 beats after a buffer boundary), then held 5000 MB/s to the cache end and wrote
  3524-3554 MB/s after it.
* **Sabrent Rocket 2230 1TB on `zcu106_hpc0`, single**: one drive holds 1750 MB/s over 200 GiB
  (high-water mark 1 in every 1 s sample, 0-1 writes in flight per 10 s sample). 2500 MB/s
  drops from 80.25 GB, where the cache ends and the drive falls to 1808-1816 MB/s with all 8
  writes in flight. The margin at 1750 MB/s is about 3 % (post-cache median 1806 MB/s, fio).
* **Sabrent Rocket 2230 1TB on `zcu106_hpc0`, RAID0**: the pair recorded 3000 MB/s cleanly over
  350 GiB (high-water mark 1 in every 1 s sample, 1 write in flight in every 10 s sample). At
  3500 MB/s it held the rate inside and past the ~140 GB cache, but one write stall of ~0.2 s
  at 285.71 GB outlasted the 256 MB ring (16 775 917 beats lost).

### Playback

Register map 1.2 (AXI DMA MM2S, egress FIFO of 4096 beats of 32 bytes, `fdrec_check` sink),
XFS, `fdplay` with queue depth 8. Each run plays a 10 GB test-pattern recording made at
1000 MB/s with 0 drops, in the sweep of the [playback method](#playback-method) (from
2500 MB/s in 500 MB/s steps; the sink maximum is 8000 MB/s). "Runs" lists underflow-free
runs / runs at that rate.

| target | SSD | layout | buffers | highest clean playback rate | runs | first rate with underflows | read fio reference |
|---|---|---|---|---|---|---|---|
| `vck190_fmcp1` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **4500 MB/s** | 3/3 each (every sweep step from 2500 MB/s clean) | 5000 MB/s (27 968 621 and 27 715 554 ticks with 32 buffers, 31 311 063 and 31 408 574 with 16: above the drive's ~4.5 GB/s read; MaxPayload 256 bytes does not change it) | 4417 and 4461 MB/s (fio CPU-bound); 4525 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **5500 MB/s** | 3/3 each (every sweep step from 2500 MB/s clean) | 6000 MB/s (13 328 114 and 13 965 721 ticks with 32 buffers, 16 069 034 and 15 892 092 with 16; ~5.66 GB/s delivered; `fdplay` CPU-bound: one core 96 % busy at 5500 MB/s) | 4317 and 4281 MB/s (fio CPU-bound); 7820 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **6000 MB/s** | 3/3 each (every sweep step from 2500 MB/s clean) | 6500 MB/s (11 308 291 and 11 339 737 ticks with 32 buffers, 14 237 945 and 14 375 939 with 16: above the drive's ~6.3 GB/s read at 128-byte MaxPayload; with MaxPayload 256 bytes 6500 MB/s was clean 3 of 3) | 4426 and 4281 MB/s (fio CPU-bound); 6320 MB/s with hugepage fixed buffers |
| `vck190_fmcp1` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **6000 MB/s** | 3/3 each (every sweep step from 2500 MB/s clean) | 6500 MB/s (32 buffers: 1 782 003 ticks in the sweep, clean in the recheck; 16 buffers: 2 247 203 and 2 832 248; `fdplay` CPU-bound: one core 89 % busy at 6000 MB/s) | 4716 and 4199 MB/s (fio CPU-bound); 7936 MB/s with hugepage fixed buffers (the host's ~8.0 GB/s read ceiling) |
| `zcu106_hpc0` | 2x Samsung 980 PRO 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **4000 MB/s** | 3/3 each (2500, 3000 and 3500 MB/s clean) | 4500 MB/s (23 945 694 and 29 908 752 ticks with 32 buffers, 29 644 662 and 27 951 305 with 16; ~4.1-4.2 GB/s delivered: `fdplay` at 95 % of a core) | 2990 and 2877 MB/s (fio CPU-bound); 5942 MB/s with hugepage fixed buffers (6365-6371 MB/s with two fio jobs) |
| `zcu106_hpc0` | Samsung 980 PRO 1TB | single | 32 x 8 MB and 16 x 8 MB | **3000 MB/s** | 3/3 each (2500 MB/s clean) | 3500 MB/s (25 999 470 and 25 753 071 ticks with 32 buffers, 29 542 345 and 29 540 213 with 16: above the slot's ~3.19 GB/s read rate at 128-byte MaxPayload; with 256 bytes 3500 MB/s was clean 3 of 3) | 2891 and 2902 MB/s (fio CPU-bound); 3183 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | Sabrent Rocket 2230 1TB | single | 32 x 8 MB and 16 x 8 MB | **3000 MB/s** | 3/3 each (2500 MB/s clean) | 3500 MB/s (33 437 108 and 33 253 762 ticks with 32 buffers, 36 835 691 and 37 097 892 with 16: above the slot's ~3.1 GB/s read rate on Gen3 x4) | 2955 and 2979 MB/s (fio CPU-bound); 3124 MB/s with hugepage fixed buffers |
| `zcu106_hpc0` | 2x Sabrent Rocket 2230 1TB | RAID0, 512K chunk | 32 x 8 MB and 16 x 8 MB | **3500 MB/s** | 3/3 each (2500 and 3000 MB/s clean) | 4000 MB/s (28 837 384 and 20 673 529 ticks with 32 buffers, 28 823 862 and 17 048 881 with 16; 3.7-3.8 GB/s delivered) | 2904 and 2768 MB/s (fio CPU-bound); 5113 MB/s with hugepage fixed buffers |

The rows are from 2026-10-22, with 10 GB playbacks; every playback had 0 errors and 0 gaps.

The Sabrent Rocket 2230 1TB pair (Gen4 x4 on `vck190_fmcp1`) plays back at 4500 MB/s from one
drive and at 5500 MB/s from RAID0, with 32 or 16 buffers (every sweep step from 2500 MB/s, then
3 of 3 at the top in each configuration). One drive reads its data at ~4.5 GB/s (fio with
hugepage fixed buffers: 4525 MB/s), well below its Gen4 x4 link (~6.1 GB/s at 128-byte
MaxPayload), so 5000 MB/s underflows and MaxPayload 256 bytes makes no difference. From RAID0
`fdplay` is the limit (one A72 core 96 % busy at 5500 MB/s; 6000 MB/s delivers ~5.66 GB/s)
while fio reads the pair at 7820 MB/s with hugepage fixed buffers.

The Samsung 980 PRO 1TB pair (Gen4 x4 on `vck190_fmcp1`) plays back at 6000 MB/s from one drive
and from RAID0, with 32 or 16 buffers (every sweep step from 2500 MB/s, then 3 of 3 at
6000 MB/s in each configuration). One drive reads ~6.3 GB/s through its Gen4 x4 link at
128-byte MaxPayload (fio with hugepage fixed buffers: 6320 MB/s), so 6500 MB/s underflows; with
MaxPayload 256 bytes it reads 6.85-7.07 GB/s and plays 6500 MB/s cleanly (see
[The PCIe links and MaxPayload](#6-the-pcie-links-and-maxpayload)). From RAID0 `fdplay` itself
becomes the limit (one A72 core 89 % busy at 6000 MB/s); fio reads the pair at 7936 MB/s with
hugepage fixed buffers, the host's read ceiling on this board (two fio jobs read the same
7983-7992 MB/s).

The Samsung 980 PRO 1TB on `zcu106_hpc0` plays back at 3000 MB/s from one drive and at
4000 MB/s from RAID0, with 32 or 16 buffers: all 20 sweep runs at or below those rates were clean
(and 6 of 6 4000 MiB runs at 3000 / 4000 MB/s). One Gen3 x4 slot reads ~3.19 GB/s with fixed
buffers at 128-byte MaxPayload, so 3500 MB/s delivers ~3.22-3.25 GB/s and underflows; with
MaxPayload 256 bytes the slot reads ~3.55 GB/s and one drive plays 3500 MB/s cleanly (see
[The PCIe links and MaxPayload](#6-the-pcie-links-and-maxpayload)). RAID0 at 4500 MB/s
underflows (~4.1-4.2 GB/s delivered) although two fio jobs with fixed buffers read the pair at
6.37 GB/s and the MM2S path alone takes 5000 MB/s: one `fdplay` thread uses 94.5 % of one A53
core at 4000 MB/s.

The Sabrent Rocket 2230 1TB on `zcu106_hpc0` plays back at 3000 MB/s from one drive (3500 MB/s
is above what one Gen3 x4 slot reads, ~3.1 GB/s even with fixed buffers) and at 3500 MB/s from
RAID0, with 32 or 16 buffers: all 18 sweep runs at or below those rates were clean (and 6 of 6
4000 MiB runs at 3000 / 3500 MB/s). RAID0 at 4000 MB/s underflows (3.7-3.8 GB/s delivered)
although fio reads the pair at 5113 MB/s with hugepage fixed buffers and the MM2S path alone
takes 5000 MB/s: at 3500 MB/s `fdplay` already uses 87 % of one A53 core. fio without fixed
buffers is CPU-bound on this board (2.77-2.99 GB/s).

Read fio reference: `fio --name=rd --filename=<the recording> --readonly --rw=read --bs=8M
--direct=1 --ioengine=io_uring --iodepth=8 --size=10G` on the same filesystem; "hugepage fixed
buffers" adds `--iomem=mmaphuge --fixedbufs`, which is how `fdplay` reads (hugepage buffers
registered with io_uring).

Functional checks of `fdplay` (10 GB test-pattern recordings unless stated, one drive):

| measurement | result |
|---|---|
| 10 GB clean recording, `--rate 1000MB` | 10.83 s on `zcu106_hpc0` (both SSDs), 10.78-10.80 s on `vck190_fmcp1`, beats 335 544 320 (32 bytes each), errors 0, gaps 0, gap beats 0, underflows 0, last seq 671 088 638 (word 0 of the last beat), egr_discard 0 |
| 10 GB recording with drops, `--rate 500MB` | one Sabrent on `zcu106_hpc0`, recorded at 4000 MB/s (drop count 113 928 833 beats, 1203 discontinuities in `fdverify`): 21.56 s, beats 335 544 320, errors 0, gaps 1203, gap beats 113 928 833, underflows 0. One 980 PRO on `zcu106_hpc0`, recorded at 3500 MB/s (drop count 42 148 262, 1045 discontinuities): 21.56 s, gaps 1045, gap beats 42 148 262, underflows 0. One 980 PRO on `vck190_fmcp1`, recorded at 5500 MB/s (drop count 28 478 390, 980 discontinuities): 21.52 s, gaps 980, gap beats 28 478 390, underflows 0. One Sabrent on `vck190_fmcp1`, recorded at 5000 MB/s (drop count 13 990 866, 133 discontinuities): 21.54 s, gaps 133, gap beats 13 990 866, underflows 0 |
| `--rate` above what the SSD delivers | underflow ticks counted by the checker; exit code 2 (33 203 605 ticks at 3500 MB/s from one Sabrent and 25 977 473 at 3500 MB/s from one 980 PRO on `zcu106_hpc0`; 13 049 549 at 6500 MB/s from one 980 PRO and 27 673 786 at 5000 MB/s from one Sabrent on `vck190_fmcp1`) |
| 256 MB recording resident in the ring (32 x 8 MB, 64 x 4 MB) | 0 underflows at 5000 MB/s on `zcu106_hpc0` and at 7500 MB/s on `vck190_fmcp1` (also 16 x 16 MB), with either FMC card; see [Fabric only](#fabric-only-no-ssd) |
| 16 buffers | one Sabrent on `zcu106_hpc0`: 10 GB recorded at 2500 MB/s with `--buffers 16` clean, played back at 3000 MB/s with 16 buffers clean. One 980 PRO on `zcu106_hpc0`: 10 GB at 3000 MB/s with 16 buffers clean, played back at 3000 MB/s with 16 buffers clean. One 980 PRO on `vck190_fmcp1`: 10 GB at 5000 MB/s with 16 buffers dropped 12 506 beats in one gap at 10.65 GB (the 128 MB ring against the drive's ~4.98 GB/s), played back at 6000 MB/s with 16 buffers: gaps 1, gap beats = the drop count, 0 underflows. One Sabrent on `vck190_fmcp1`: no usable result (10 GB at 4500 MB/s with 16 buffers recorded with 0 drops, but the drive could not read part of the file back; see below) |
| Ctrl-C (SIGINT) after 4 s at 1000 MB/s | `fdrec`: exit code 0 within 0.11-0.12 s, 3.92 GB, `fdverify` PASS. `fdplay`: exit code 1 within 0.01-0.11 s, 3.83-3.88 GB played, egr_discard 634 455-783 542 beats (the flushed in-flight buffers), no `Cannot stop channel`; the next playback is complete with 0 underflows (every combination) |
| Checker prime wait (driver, at most 100 ms) | never timed out (no `did not prime` message in any playback: about 120 on `zcu106_hpc0` and 155 on `vck190_fmcp1`) |

**A drive read error.** On `vck190_fmcp1` the first Sabrent Rocket 2230 1TB (slot 1) could not
read back part of the 16-buffer recording above: for four read commands around 8.16 GB into the
file it returned an unrecovered read error (NVMe status "media and data integrity error"), and
its SMART media-error count went from 0 to 19, once. The recording itself had completed with 0
drops, and `fdplay` played the 8.15 GB before the error with 0 errors, gaps and underflows. The
drive's error log stayed empty. Afterwards a 200 GiB recording on that drive and a 350 GiB RAID0
recording read back clean with `fdverify`, the count stayed at 19, and the NVMe short self-test
passed on both drives. The drive has 184 unsafe shutdowns in its history (bench power cuts). It
is not a recorder data error; its cause was not established.

### CPU load

Measured per core from `/proc/stat` over 10 GB transfers at 1000 MB/s (two runs each,
32 x 8 MB buffers), and per process. On `vck190_fmcp1` (two Cortex-A72 cores):

| transfer | per core (busy) | transfer process |
|---|---|---|
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | run 1: core 0 10.1 %, core 1 7.7 %; run 2: core 0 7.2 %, core 1 10.2 % | `fdrec` 16.0–16.3 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent) | core 0 10.0–10.2 %, core 1 7.9–8.2 % | `fdrec` 16.6–16.7 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | run 1 on one core (13.9 %, the other 0.6 %); run 2: core 1 9.8 %, core 0 4.2 % | `fdplay` 12.4–12.5 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent) | runs on one core (11.7 / 11.5 %; the other 3.0 / 2.2 %) | `fdplay` 12.0 % of one core |
| `fdrec`, 1000 MB/s to the Samsung 980 PRO 1TB | run 1: core 0 7.7 %, core 1 10.1 %; run 2: core 0 7.7 %, core 1 9.1 % | `fdrec` 15.4–15.5 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | core 0 8.9–9.5 %, core 1 9.1–9.7 % | `fdrec` 16.3 % of one core |
| `fdplay`, 1000 MB/s from the Samsung 980 PRO 1TB | runs on one core (12.2 / 11.7 %; the other 0.9 / 3.6 %) | `fdplay` 11.8–12.0 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | runs on one core (12.3 %, the other 1.5 %; in one run 20.8 / 5.6 % with another process on core 0) | `fdplay` 12.3–12.4 % of one core |

Nearly all of it is system time; the core the app runs on shows 20–87 % I/O wait (waiting, not
busy). A `top` cross-check gave the same per-process figures: `fdrec` 13.8–16.5 %, `fdplay`
10.6–12.8 % of one core. At the top rates (32 GB): `fdrec` uses 98 % of one core at 6500 MB/s
to the 980 PRO RAID0 (clean; both cores ~55 % busy), 72-75 % at 5000 MB/s to one 980 PRO, 70 %
at 4500 MB/s to one Sabrent, 65 % at 4000 MB/s to the Sabrent RAID0, 117-119 % at 7000 MB/s to
the Sabrent RAID0 with 16 MB buffers and ~111 % at ~7.3 GB/s to the 980 PRO RAID0 (with its
io_uring workers on both cores); `fdplay` 91 % at 6000 MB/s from the 980 PRO RAID0 (one core
89 % busy), 94 % at 5500 MB/s from the Sabrent RAID0 (one core 96 % busy), 83 % at 6000 MB/s
from one 980 PRO and 63 % at 4500 MB/s from one Sabrent. `fdrec` costs ~1.5-1.7 % of an A72
core per 100 MB/s at every rate, of which ~0.9 % is the DMA ring itself (`--no-write`: 73 % at
8000 MB/s, the cache maintenance and the ioctls). Pinning `fdrec` to one core (`taskset`) makes
it worse: that core is 99.7 % busy and the 980 PRO RAID0 takes only ~6.1 GB/s.

On `zcu106_hpc0` (four Cortex-A53 cores at 1.2 GHz), same method (10 GB at 1000 MB/s, two runs,
32 x 8 MB buffers), the load spreads mostly over two cores (the app's thread and the core
taking the DMA / NVMe interrupts):

| transfer | busy, summed over the cores | share of the 4-core total | transfer process |
|---|---|---|---|
| `fdrec`, 1000 MB/s to the 980 PRO 1TB | 25.5–26.1 % of one core | about 6.5 % | `fdrec` 23.6 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x 980 PRO 1TB) | 27.2–27.6 % of one core | about 6.9 % | `fdrec` 25.0–25.3 % of one core |
| `fdplay`, 1000 MB/s from the 980 PRO 1TB | 19.4–20.4 % of one core | about 5.0 % | `fdplay` 16.5–16.7 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x 980 PRO 1TB) | 23.6–23.9 % of one core | about 5.9 % | `fdplay` 21.3 % of one core |
| `fdrec`, 1000 MB/s to the Sabrent Rocket 2230 1TB | 26.9–27.3 % of one core | about 6.8 % | `fdrec` 24.7–24.8 % of one core |
| `fdrec`, 1000 MB/s to RAID0 (2x Sabrent Rocket 2230 1TB) | 30.1–31.1 % of one core | about 7.7 % | `fdrec` 25.8–25.9 % of one core |
| `fdplay`, 1000 MB/s from the Sabrent Rocket 2230 1TB | 25.0–25.2 % of one core | about 6.3 % | `fdplay` 19.3–19.4 % of one core |
| `fdplay`, 1000 MB/s from RAID0 (2x Sabrent Rocket 2230 1TB) | 23.0–23.4 % of one core | about 5.8 % | `fdplay` 18.6 % of one core |

The rows were cross-checked with `top` (`fdrec` 23.3–25.1 %, `fdplay` 14.3–22.1 % of one core);
during `fdplay` the I/O wait sits on the app's core (up to 80 %). At higher rates (32 GB) `fdrec`
uses 58 % of one core at 2500 MB/s (one Sabrent), 67 % at 3000 MB/s (one 980 PRO), 88 % at
3500 MB/s (Sabrent RAID0), 100 % at 4500 MB/s (980 PRO RAID0), 113-115 % at 4500 MB/s (Sabrent
RAID0 with 64 buffers) and 116-117 % at 5000 MB/s (980 PRO RAID0), with io_uring workers on
other cores above one core; `fdplay` 60-63 % at 3000 MB/s (one drive), 87 % at 3500 MB/s
(Sabrent RAID0) and 94.5 % at 4000 MB/s (980 PRO RAID0, one core 92 % busy). With no file I/O
at all, `fdrec --no-write` takes 56 % at 4000 and 70 % at 5000 MB/s. See
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

* The **Sabrent Rocket 2230 1TB** (DRAM-less, Gen4) caches ~66-75 GB on an empty, trimmed
  drive (full rate to 64 GB on both boards) and then writes a flat ~1.8 GB/s (median 1806 MB/s
  on `zcu106_hpc0`, 1799 MB/s on `vck190_fmcp1`). Into the cache it writes ~2.9 GB/s on
  `zcu106_hpc0` (2893-2916 MB/s: the Gen3 x4 link) and ~4.6 GB/s on `vck190_fmcp1` (4502-4624
  MB/s, Gen4 x4). This sets its sustained single-drive rate: 1750 MB/s over 200 GiB on both
  boards; 2500 MB/s drops at 80.25 GB on `zcu106_hpc0`, where the cache ends in a recording (see
  [Long recordings](#long-recordings-past-the-slc-cache)). The pair caches ~140 GB and then
  writes ~3.6 GB/s (median 3614 MB/s on `vck190_fmcp1`); it records 3500 MB/s over 350 GiB on
  `vck190_fmcp1` and 3000 MB/s on `zcu106_hpc0`, where one fio job writes only ~3.2 GB/s to the
  pair (CPU-bound), below its post-cache rate, so no knee shows in 535 GB.
* The **Samsung 980 PRO 1TB** caches about 115-125 GB on an empty, trimmed drive (~115-125 GB on
  `vck190_fmcp1`, ~118-124 GB on `zcu106_hpc0`) and writes a flat **~1.77 GB/s** after it
  (median 1766 / 1765 MB/s). Into the cache it writes ~4.94-4.98 GB/s on `vck190_fmcp1` (from
  the 32 GB recordings; fio is CPU-bound at ~4.7 GB/s there) and ~2.98 GB/s on `zcu106_hpc0`
  (the Gen3 x4 link). The pair caches ~245 GB and then writes a flat ~3.46-3.49 GB/s (median
  3463 / 3485 MB/s). One drive records 1750 MB/s cleanly past the cache on both boards
  (240 / 200 GiB), the pair 3250 MB/s (480 / 350 GiB). This is the drive's TurboWrite cliff.

Measured with one sequential fio write (queue depth 8, 8 MB blocks, `O_DIRECT`) on a freshly
created XFS, 60 s of idle first, bandwidth logged every 2 s (the 980 PRO RAID0 row on
`zcu106_hpc0` with hugepage fixed buffers and zero buffers, `--iomem=mmaphuge --fixedbufs
--zero_buffers`: one plain fio job is CPU-bound at ~3.4 GB/s there):

| SSD | target | layout | written | rate inside the cache | cache size (empty, trimmed) | rate after the cache |
|---|---|---|---|---|---|---|
| Sabrent Rocket 2230 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.6 GB/s (4502-4624 MB/s, median 4587) | **~70-75 GB** (full rate to 64 GB, down to the post-cache rate by 75 GB) | **~1.8 GB/s**, flat (1775-1829 MB/s from 75 to 320 GB, median 1799) |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.5 GB/s (4364-4624 MB/s, median 4488; fio CPU-bound) | **~140 GB** (~70 GB per drive; full rate to ~135 GB, down by ~150 GB) | **~3.6 GB/s**, flat (3528-3656 MB/s, median 3614) |
| Sabrent Rocket 2230 1TB | `zcu106_hpc0` | single | 300 GiB | 2893-2916 MB/s (the Gen3 x4 link) | **~66-69 GB** (full rate to 64 GB, down to the post-cache rate by 73 GB) | **~1.8 GB/s**, flat (1776-1834 MB/s from 80 to 320 GB, median 1806) |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 3066-3351 MB/s, median 3181 (fio CPU-bound) | not visible (no knee in 535 GB: one fio job writes below the pair's post-cache rate) | not visible (~3.2 GB/s throughout, fio-bound) |
| Samsung 980 PRO 1TB | `vck190_fmcp1` | single | 300 GiB | ~4.7 GB/s (fio CPU-bound: a lower bound for the drive) | **~115-125 GB** (full rate to 111 GB, down by ~118-128 GB) | **~1.77 GB/s**, flat (1710-1792 MB/s, median 1766) |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 500 GiB | ~4.66 GB/s (fio CPU-bound) | **~245 GB** (~122 GB per drive; full rate to 239 GB, a knee to ~254 GB) | **~3.46 GB/s**, flat (3262-3554 MB/s, median 3463) |
| Samsung 980 PRO 1TB | `zcu106_hpc0` | single | 300 GiB | 2964-2989 MB/s (the Gen3 x4 link) | **~118-124 GB** (full rate to 113 GB, down to the post-cache rate by 127 GB) | **~1.77 GB/s**, flat (1716-1801 MB/s from 127 to 321 GB, median 1765) |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 500 GiB | 6048-6089 MB/s, median 6073 (fio with hugepage fixed buffers; two Gen3 x4 slots) | **~245 GB** (~122 GB per drive; full rate to 241 GB, down by 256 GB) | **~3.49 GB/s**, flat (3423-3575 MB/s from 256 to 536 GB, median 3485) |

The cache size and the post-cache rate are properties of the drive: each drive shows the same
on both boards (the Sabrent ~66-75 GB and ~1.8 GB/s, the 980 PRO ~115-125 GB and ~1.77 GB/s, the
980 PRO pair ~245 GB and ~3.46-3.49 GB/s). The in-cache rate is the Gen3 x4 link's for one drive
on `zcu106_hpc0` (and both links for the fixed-buffer fill of the 980 PRO pair), the drive's own
for one Sabrent on `vck190_fmcp1`, and fio's for the other rows (one fio thread is CPU-bound).
None of the drives throttled (fan on the cards).

**In-cache and post-cache rates.** A recording shorter than the cache only needs the
in-cache rate; a longer one needs the post-cache rate, and the 32 GB sweep shows only the
first for the 1 TB drives. The cache refills only while the drive is idle (how fast was not
measured), so back-to-back recordings may not each get a full cache. Size the rate for the
longest recording you need: a short burst test, such as a 10 GB recording, a 4 GB `dd`, or
fio over 32 GB (entirely inside the cache of these 1 TB drives), overstates what a drive
sustains.

## Start-up stalls and the ring size

**Drives waking from APST.** NVMe SSDs save power when idle with Autonomous Power State
Transitions (APST): after some idle time the drive moves itself into a non-operational power
state, and the first commands after that wait until it is back. The Linux kernel enables APST
by default (`nvme_core.default_ps_max_latency_us` = 100000, which allows the deepest states of
the drives measured here), and the image of this repository keeps that default. After the 60 s
of idle time before each benchmark step, both Sabrent Rocket 2230 1TB drives on `vck190_fmcp1`
reported power state 4 (PS4: 5 mW, specified exit latency 44 ms), and the first writes of a
RAID0 recording took ~63-65 ms (the ring's length plus the data lost), longer than the default
256 MB ring lasts at 4.5 GB/s (57 ms). With the default ring, RAID0 recordings (32 GB steps and
10 / 40 GB bursts) at 4500 and 5000 MB/s were clean in only 2 of 11 runs, and every failure was
one gap at 0.27 GB (32 × 8 MiB + 262 368 bytes: the end of the first pass through the ring),
after which the recording held its rate to the end. With APST disabled on both drives the same
recordings were clean in 5 of 5 runs (4500 MB/s three times, 5000 and 6000 MB/s), and with APST
on a 512 MB ring (`--buf-size 16M`) covered the stall up to 7000 MB/s (3 of 3; see the ring
table below). One drive alone showed no start-up drop at 4500 MB/s.

APST was tested on that combination only. The Sabrent pair on `zcu106_hpc0` loses data with the
same signature (one gap at 0.27 GB, at 4000 and 4500 MB/s, in 32 GB recordings and in a 40 GB
burst), very likely for the same reason (not tested there). The 980 PRO pairs also lost data
early in some recordings after idle time, though not at a fixed offset: on `zcu106_hpc0` one
32 GB recording and the 350 GiB recording at 5000 MB/s in their first second, on `vck190_fmcp1`
the first 10 GB recording on a fresh filesystem at 6500 MB/s (from 0.86 GB) and the 480 GiB
recordings at 6000 and 6500 MB/s in their first GB; whether APST plays a part there was not
tested.

Two ways past the start-up stall:

* a 512 MB ring (`--buffers 64` or `--buf-size 16M`, see the ring size below), which covered it
  at every rate measured with APST on;
* APST off, per controller at run time (until the next reboot), or for every drive on the kernel
  command line:

```
echo 0 | sudo tee /sys/class/nvme/nvme0/power/pm_qos_latency_tolerance_us
echo 0 | sudo tee /sys/class/nvme/nvme1/power/pm_qos_latency_tolerance_us
# or, on the kernel command line: nvme_core.default_ps_max_latency_us=0
```

The measurements used the sysfs setting (the kernel then disables APST on that controller, and
the drives stayed in power state 0 through the idle time); the kernel argument should be
equivalent but was not tested. With APST off the drives stay in an operational power state when
idle (the Sabrent's PS0 is rated at up to 5.0 W, PS4 at 5 mW); their idle power was not
measured.

**The first writes after `fstrim`.** The SSDs also process discards in the background, and a
recording that starts right after `fstrim`, with no idle time, can stall its first writes as
well. Measured with the Samsung 980 PRO 1TB pair on `zcu106_hpc0` (RAID0, 512K chunk), 10 GB
recordings at 1700 MB/s, `fdrec --stats 0.1`. "Trim" is `rm` of the previous file, `sync` and
`fstrim /mnt/rec`; "idle" is the pause between that and `fdrec`:

| filesystem | before the run | buffers | recordings with drops |
|---|---|---|---|
| XFS | trim, no idle | 16 x 8 MB | **2 of 3** (6 527 526 beats in one gap at 128 MiB + 262 368 bytes; 1 027 819 beats in 6 gaps from 248 MiB + 262 368 bytes) |
| XFS | trim, no idle | 32 x 8 MB | 1 of 3 (117 280 beats in one gap at 256 MiB + 262 368 bytes) |
| XFS | trim, idle 15 s | 16 x 8 MB | 0 of 2 |
| XFS | no trim (`rm` + `sync` only) | 16 x 8 MB | 0 of 2 |

Two of the dropping runs wrote nothing for their first ~0.2 s, longer than a 128 MB ring
(79 ms) or a 256 MB ring (158 ms) lasts at 1.7 GB/s; 15 s of idle time removed the stall. This
is why the benchmark steps wait after trimming (60 s before each sweep step, 30 s before each
burst, 300 s before each long recording). The wait lets the drives go to sleep, though, which
brings the APST start-up stall above at high rates: wait a few seconds after `fstrim`, and for
high rates use a 512 MB ring or turn APST off.

* `fdrec` opens the output with `O_TRUNC` and preallocates it with `posix_fallocate`, so
  recording over an existing file starts from freshly allocated (unwritten) extents, the same
  as a new file.
* The `fifo_hwm` and `drop_count` sysfs attributes read 0 once `fdrec` has exited (the driver
  resets the core on close); read them from `fdrec`'s `RESULT` line.

**Ring size.** 32 GB RAID0 recordings (fresh XFS, `rm` + `fstrim` + 60 s idle before each; APST
on unless noted):

| SSD | target | layout | ring | rate (MB/s) | recordings with drops | FIFO high-water (beats) |
|---|---|---|---|---|---|---|
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 32 x 8 MB (default) | 4500 | 2 of 2 (one gap at 0.27 GB; 36 gaps from 0.91 GB) | full |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 64 x 8 MB (512 MB) | 4500 | **0 of 3** | 3 |
| 2x Sabrent Rocket 2230 1TB | `zcu106_hpc0` | RAID0 | 32 x 8 MB and 64 x 8 MB | 5000 | 1 of 1 each (all 8 writes in flight every second: the pair's rate) | full |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 32 x 8 MB (default) | 4500 | 0 of 3 | 3 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 32 x 8 MB (default) | 5000 | 2 of 7 (one in a stall in the first second; one of 2582 beats) | full; 4, 4, 4, 2274 and 5115 in the clean runs |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 64 x 8 MB (512 MB) | 5000 | **0 of 3** | 4 |
| 2x Samsung 980 PRO 1TB | `zcu106_hpc0` | RAID0 | 64 x 8 MB and 32 x 16 MB | 5500 | 1 of 1 each (5139-5147 MB/s written: `S_AXI_HP2_FPD`) | full |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB (default) | 4500 | 4 of 6 (each one gap at 0.27 GB) | full; 3 in the clean runs |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB (default) | 5000 | 3 of 3 (each one gap at 0.27 GB) | full |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB (default) | 6000 / 7000 | 0 of 1 / 1 of 1 (one gap at 0.27 GB, then the queue full for 4 s) | 6 / full |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB, APST off | 4500 / 5000 / 6000 | **0 of 3** / 0 of 1 / 0 of 1 | 3 / 4 / 6 |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB, APST off | 7000 | 1 of 1 (12 gaps from 13.3 GB at 6941 MB/s: the rate, not the start) | full |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 16 MB (512 MB) | 4500 to 6500, in 500 MB/s steps | 0 of 1 each | 3 to 7 |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 16 MB (512 MB) | 7000 | **0 of 3** | 110 / 72 / 8 |
| 2x Sabrent Rocket 2230 1TB | `vck190_fmcp1` | RAID0 | 32 x 16 MB (512 MB) | 7500 | 2 of 2 (7.13-7.14 GB/s written, all 8 writes in flight: the host's write ceiling) | full |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB (default) | 7000 | 1 of 3 | 8 / full / 8 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 32 x 16 MB (512 MB) | 7000 | **0 of 3** | 385 / 8 / 8 |
| 2x Samsung 980 PRO 1TB | `vck190_fmcp1` | RAID0 | 32 x 8 MB and 32 x 16 MB | 7500 | 3 of 3 each (7.27-7.39 GB/s written: the host's write ceiling) | full |

A 512 MB ring removed the drops caused by stalls: 4500 MB/s on the Sabrent pair and 5000 MB/s
on the 980 PRO pair on `zcu106_hpc0`, 7000 MB/s on both pairs on `vck190_fmcp1` (after their
first second those runs kept 1-6 of the 8 writes in flight). It does not help a rate above what
the path sustains: 5000 MB/s with the Sabrent pair on `zcu106_hpc0` (all 8 writes in flight
every second; the pair writes ~4.8-4.9 GB/s there), 5500 MB/s on `zcu106_hpc0` whatever the
drives (above `S_AXI_HP2_FPD`), 7500 MB/s on `vck190_fmcp1` (all 8 writes in flight: the host's
write ceiling). `fdrec` accepts at most 64 buffers, each up to 62 MB; both 512 MB rings use the
whole hugepage pool that the image reserves at boot (256 x 2 MB).

## Comparison with fpga-drive-aximm-pcie (dd method)

The [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
reference design measures SSD throughput with four `dd` scripts, which are also in this
design's image (see [Test the design in Linux](linux_test.md#4-measure-the-ssds-with-the-dd-speed-test-scripts)).
This section compares the two methods on the same board, SSDs and image.

### At a glance

All figures in MB/s (10⁶ bytes/s), measured 2026-10-22 (see [Setups](#setups)).
**b** = burst (the write fits inside the drive's SLC write cache), **s** = sustained (the
recording ran past the cache). Reads have no cache effect. The 32 GB columns are inside the
cache of these drives (**b**), so the "fdrec sustained" cell also gives the rate that held over
a recording past the cache.

| target / config | WRITE: drive ceiling (fio QD8, 4 GB) | WRITE: dd script (4 GB) | WRITE: fdrec at the top rate (4 GB) | WRITE: dd (32 GB) | WRITE: fdrec sustained (32 GB) | READ: drive ceiling (fio QD8, 4 GB) | READ: dd script (4 GB) | READ: fdplay at the top rate (4 GB) |
|---|---|---|---|---|---|---|---|---|
| vck190: Sabrent Rocket 2230 1TB (Gen4 x4) | 4383 **b** (fio CPU-bound) | 1848 **b** | 4500 **b** (top step, 3 of 3 over 4000 MiB) | 2071 **b** (inside the ~70-75 GB cache) | 4500 **b** (5000: 0 of 3); past the cache (200 GiB): **1750 s** | 4352 (fio CPU-bound; 4525 with fixed buffers, 10 GB) | 3745 | 4500 (top step, 3 of 3; 10 GB: 4500 with 32 and 16 buffers, 5000 underflows) |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 4378 **b** (fio CPU-bound; 7.17-7.33 GB/s with fixed buffers) | 2046 **b** | 4000 **b** (top step, 3 of 3) | 2075 **b** (one run) | 4000 **b** (4500: one start-up gap at 0.27 GB, APST; 7000 with 16 MB buffers); past the cache (350 GiB): **3500 s** | 4134 (fio CPU-bound; 7820 with fixed buffers, 10 GB) | 3251 | 5500 (top step, 3 of 3; 10 GB: 5500 with 32 and 16 buffers, 6000 underflows) |
| vck190: Samsung 980 PRO 1TB (Gen4 x4) | 4658 **b** (fio CPU-bound) | 1497 **b** | 5000 **b** (top step, 3 of 3 over 4000 MiB) | 1797 **b** (inside the ~115-125 GB cache) | 4500 **b** (5000: 3 of 7); past the cache (240 GiB): **1750 s** | 4442 (fio CPU-bound; 6320 with fixed buffers, 10 GB) | 2254 | 6000 (top step, 3 of 3; 10 GB: 6000 with 32 and 16 buffers, 6500 underflows) |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 4579 **b** (fio CPU-bound; 7.62 GB/s with fixed buffers) | 2076 **b** | 6500 **b** (top step, 3 of 3) | 2137 **b** (one run) | 6500 **b** (7000: 2 of 3; 3 of 3 with 16 MB buffers); past the cache (480 GiB): **3250 s** | 4098 (fio CPU-bound; 7936 with fixed buffers, 10 GB) | 3616 | 6000 (top step, 3 of 3; 10 GB: 6000 with 32 and 16 buffers) |
| zcu106: Samsung 980 PRO 1TB (Gen3 x4) | 2944 **b** | 1477 **b** | 3000 **b** (the 32 GB sweep top; 3 of 3 over 4000 MiB) | 1387 **b** (inside the ~118-124 GB cache) | 3000 **b**; past the cache (200 GiB): **1750 s** | 2859 (fio CPU-bound; 3183 with fixed buffers, 10 GB) | 1800 | 3000 (3 of 3; 10 GB: 3000 with 32 and 16 buffers, 3500 underflows) |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 3395 **b** (fio CPU-bound; 6.07 GB/s with fixed buffers) | 1619 **b** | 5000 **b** (the 32 GB sweep top at the time; 3 of 3 over 4000 MiB) | 1636 **b** (one run) | 4500 **b** (5000: 5 of 7; 3 of 3 with 64 buffers); past the cache (350 GiB): **3250 s** | 2881 (fio CPU-bound; 5942 with fixed buffers, 10 GB; 6.37 GB/s with two jobs) | 2162 | 4000 (3 of 3; 10 GB: 4000 with 32 and 16 buffers, 4500 underflows) |
| zcu106: Sabrent Rocket 2230 1TB (Gen3 x4) | 2827 **b** | 1327 **b** | 2500 **b** (the 32 GB sweep top; 3 of 3) | 1432 **b** (inside the ~66-69 GB cache) | 2500 **b**; past the cache (200 GiB): **1750 s** | 2912 (fio CPU-bound; 3124 with fixed buffers, 10 GB) | 2007 | 3000 (3 of 3; 10 GB: 3000, 3500 underflows) |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 3191 **b** (fio CPU-bound) | 1441 **b** | 3500 **b** (the 32 GB sweep top; 3 of 3) | 1418 **b** (one run) | 3500 **b** (4500 with 64 buffers); past the cache (350 GiB): **3000 s** | 2676 (fio CPU-bound; 5113 with fixed buffers, 10 GB) | 2267 | 3500 (3 of 3; 10 GB: 3500, 4000 underflows) |

| target / config | dd write: rate / % of one core / MB/s per % core | fdrec: rate / % of one core / MB/s per % core |
|---|---|---|
| vck190 (Cortex-A72, 1.4 GHz): Sabrent Rocket 2230 1TB | 1848 / 71 % / 26 | 4467 / 70 % / 64 |
| vck190: RAID0 (2x Sabrent Rocket 2230 1TB) | 2046 / 86 % / 24 | 3978 / 65 % / 61 |
| vck190: Samsung 980 PRO 1TB | 1497 / 57 % / 26 | 4852 / 72 % / 68 |
| vck190: RAID0 (2x Samsung 980 PRO 1TB) | 2076 / 85 % / 24 | 6448 / 92 % / 70 |
| zcu106 (Cortex-A53, 1.2 GHz): Samsung 980 PRO 1TB | 1477 / 70 % / 21 | 2980 / 68 % / 44 |
| zcu106: RAID0 (2x Samsung 980 PRO 1TB) | 1619 / 90 % / 18 | 4954 / 111 % / 45 |
| zcu106: Sabrent Rocket 2230 1TB | 1327 / 67 % / 20 | 2486 / 61 % / 41 |
| zcu106: RAID0 (2x Sabrent Rocket 2230 1TB) | 1441 / 80 % / 18 | 3475 / 87 % / 40 |

Selection rule: dd and fio cells are the median of three runs at their own speed (one run where
marked). The `fdrec` and `fdplay` cells are 3 runs of 4000 MiB at one rate, all clean (0 drops
/ 0 underflows): `fdrec` at the highest clean step of the 32 GB
[fdbench.sh sweep](#sustained-recording-rate) as it stood when the runs were made, `fdplay` at
the highest clean step of the 10 GB [playback](#playback) sweep; the CPU table gives the rate
they achieved, which includes the start and the drain of the transfer. "fdrec sustained" is the
highest step of the 32 GB sweep that was clean 3 of 3. The recorder rows used the shipped
default of 32 x 8 MB buffers. On one 980 PRO on `vck190_fmcp1` the 4000 MiB runs at 5000 MB/s
were clean, but 5000 MB/s over 32 GB was clean in only 3 of 7 recordings, and on the 980 PRO
RAID0 on `zcu106_hpc0` likewise in 5 of 7 with the default ring, so both 32 GB cells are 4500.

How to read it: the "drive ceiling" columns show what the SSD itself delivered under Linux with
8 requests in flight. The dd and burst columns are short transfers that a consumer drive absorbs
in its write cache; the bold **s** figure in the sustained column is what you can record for as
long as you like (the figure past the cache). The recorder figures are the strictest of all,
because one late write anywhere in the recording makes a rate fail, and they cost half the CPU
of `dd` or less for writes. The detailed tables ([vck190_fmcp1](#results-vck190_fmcp1),
[zcu106_hpc0](#results-zcu106_hpc0)) and [why the figures differ](#why-the-figures-differ)
follow, and [Where the bottlenecks are](#where-the-bottlenecks-are) explains what limits each
figure.

**Gen4 drives on a Gen4 and a Gen3 target.** The Samsung 980 PRO 1TB on `vck190_fmcp1` writes
faster than fio or `dd` can feed it: fio writes 4.5-4.8 GB/s (fio itself CPU-bound) and one
`dd` 1.5 GB/s, while `fdrec` shows the drive's own in-cache rate, ~4.94-4.98 GB/s: one drive
records 4000 MiB at 5000 MB/s and 32 GB at 4500 MB/s, the RAID0 pair 32 GB at 6500 MB/s. The
Sabrent Rocket 2230 1TB on `vck190_fmcp1` writes ~4.6 GB/s in its cache (fio 4383-4535 MB/s at
86-89 % of a core, 4681 MB/s with fixed buffers; 4567-4653 MB/s at the failing 5000 and
5500 MB/s sweep steps) and reads its data at ~4.5 GB/s (4525 MB/s with fixed buffers): one drive
records 4000 MiB and 32 GB at 4500 MB/s and plays back 4500 MB/s, the pair records 32 GB at
4000 MB/s (7000 MB/s with 16 MB buffers) and plays back 5500 MB/s. On `zcu106_hpc0` (Gen4 drives
on Gen3 Root Ports) both drives run at their Gen3 x4 link's rate inside the cache. The Sabrent
Rocket 2230 1TB writes 2827-2896 MB/s (fio 4 GB) and 2879-2948 MB/s at the 3000 and 3500 MB/s
sweep steps, and reads 2802-2991 MB/s (raw device). One drive records 32 GB at 2500 MB/s, the
RAID0 pair at 3500 MB/s (4500 MB/s with 64 buffers), and the drive shows its ~66-69 GB cache and
~1.8 GB/s post-cache rate. The Samsung 980 PRO 1TB writes 2944-2986 MB/s (fio) and
3034-3037 MB/s at the 3500 and 4000 MB/s sweep steps, and reads 3099 MB/s raw (1 MB, queue depth
32) and 3183-3193 MB/s with fixed buffers. One drive records 32 GB at 3000 MB/s, the RAID0 pair
at 4500 MB/s (5000 MB/s with 64 buffers, the HP2 knee), and the drive shows the same
~118-124 GB cache and ~1.77 GB/s post-cache rate as on `vck190_fmcp1`.

### Method

Measured with both pairs, the Samsung 980 PRO 1TB and the Sabrent Rocket 2230 1TB, on both
`vck190_fmcp1` and `zcu106_hpc0` on 2026-10-22, with the images of [Setups](#setups) (register
map 1.2, driver 1.3). For each pair the second drive alone got only a fio 4 GB check. XFS on a
freshly created filesystem with 60 s of idle time per configuration and 20 s between runs,
RAID0 = both drives with 512 KB chunks. Figures are medians of 3 runs, with [min–max], unless
noted.

* **dd** (`single_write_test.sh`, `single_read_test.sh`, `dual_*_test.sh`, run verbatim, 3
  runs each): one `dd` process moves 1000 blocks of 4 MiB with `O_DIRECT` between a file on
  the SSD filesystem and `/dev/zero`, one block at a time (queue depth 1). The dual scripts
  run one `dd` per SSD in parallel, each on its own filesystem, and report the aggregate. A
  `dd` over 32 GB adds the burst-versus-cache view (3 write runs on one drive, one run
  otherwise).
* **fio**: 4 GB (3 runs) and 32 GB (one run), writes and reads, queue depth 8, 8 MB blocks.
* **fdrec / fdplay**: 3 recordings and 3 playbacks of the same 4000 MiB at the top rate (see
  the selection rule above), queue depth 8, 32 x 8 MB buffers, plus one 32 GB recording at
  the top of the sweep (`fdrec`: 0 drops and `fdverify` PASS; `fdplay`: 0 underflows).
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

VCK190 (XCVC1902, two Cortex-A72 cores at 1.4 GHz, 8 GB DDR4), `vck190_fmcp1` image, measured
2026-10-22. The Sabrent Rocket 2230 1TB rows (two drives on the M.2 M-key Stack FMC) and the
Samsung 980 PRO 1TB rows (two drives on the FPGA Drive FMC Gen4) linked at **Gen4 x4** (16 GT/s,
`LnkSta` of Root Port and SSD). "Sabrent" is one Sabrent Rocket 2230 1TB, "980 PRO" one Samsung
980 PRO 1TB. Same method as above, with 60 s of idle time after each `mkfs`. `fdrec` / `fdplay`
used the shipped default of **32 x 8 MB buffers**. The board has **two** cores, so the total CPU
column is a share of two cores (50 % = one full core); the per-process column (% of one core)
and MB/s per % core are directly comparable with `zcu106_hpc0`.

| method | config | direction | size | MB/s | total CPU % of 2 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | Sabrent | write | 4000 MiB | 1848 [1839–2006] | 0.0 / 37.0 / 0.0 / 11.1 | 71 [71–76] | 26 |
| dd (script) | Sabrent | read | 4000 MiB | 3745 [3225–3745] | 0.5 / 32.8 / 2.8 / 10.0 | 61 [53–83] | 61 |
| dd (script) | Sabrent RAID0 | write | 4000 MiB | 2046 [1311–2076] | 0.2 / 43.4 / 0.0 / 4.5 | 86 [54–89] | 24 |
| dd (script) | Sabrent RAID0 | read | 4000 MiB | 3251 [2466–3584] | 0.4 / 36.1 / 0.0 / 5.8 | 70 [51–87] | 47 |
| dd (dual script) | both Sabrent drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 2805 [2654–2853] | 0.3 / 61.7 / 1.9 / 14.4 | 123 [116–124] | 23 |
| dd (dual script) | both Sabrent drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 3616 [3410–4392] | 0.5 / 35.7 / 3.7 / 26.7 | 74 [60–77] | 49 |
| `fdrec` at 4500, top step (32 buffers) | Sabrent | record | 4000 MiB | 4467 [4460–4472] | 0.5 / 37.0 / 0.6 / 15.0 | 70 [48–72] | 64 |
| `fdrec` at 4500 (32 buffers) | Sabrent | record | 32 GB | 4497 | 0.2 / 33.1 / 0.6 / 17.9 | 62 | 73 |
| `fdrec` at 4000, top step (32 buffers) | Sabrent RAID0 | record | 4000 MiB | 3978 [3978–3978] | 0.0 / 35.1 / 0.4 / 17.8 | 65 [65–66] | 61 |
| `fdrec` at 4000 (32 buffers) | Sabrent RAID0 | record | 32 GB | 3997 | 0.2 / 31.2 / 0.7 / 23.6 | 58 | 69 |
| `fdplay` at 4500, top step (32 buffers) | Sabrent | play | 4000 MiB | 4222 [4222–4222] | 0.0 / 30.1 / 1.4 / 15.1 | 59 [58–59] | 72 |
| `fdplay` at 5500, top step (32 buffers) | Sabrent RAID0 | play | 4000 MiB | 5074 [5006–5079] | 1.0 / 29.5 / 1.5 / 6.2 | 73 [54–81] | 70 |
| dd (script) | 980 PRO | write | 4000 MiB | 1497 [1482–1541] | 0.2 / 27.2 / 0.0 / 15.2 | 57 [50–58] | 26 |
| dd (script) | 980 PRO | read | 4000 MiB | 2254 [2151–2526] | 0.3 / 18.9 / 2.4 / 9.5 | 38 [36–47] | 59 |
| dd (script) | 980 PRO RAID0 | write | 4000 MiB | 2076 [1698–2129] | 0.2 / 40.2 / 4.4 / 5.1 | 85 [71–90] | 24 |
| dd (script) | 980 PRO RAID0 | read | 4000 MiB | 3616 [3356–3813] | 0.0 / 28.6 / 9.7 / 6.1 | 74 [67–78] | 49 |
| dd (dual script) | both 980 PRO drives, two filesystems | write (aggregate) | 2 x 4000 MiB | 3410 [3289–3437] | 0.4 / 75.8 / 1.4 / 20.0 | 147 [147–148] | 23 |
| dd (dual script) | both 980 PRO drives, two filesystems | read (aggregate) | 2 x 4000 MiB | 6123 [5377–6260] | 0.4 / 60.8 / 5.2 / 24.6 | 116 [101–124] | 53 |
| `fdrec` at 5000, top step (32 buffers) | 980 PRO | record | 4000 MiB | 4852 [4837–4880] | 0.5 / 37.3 / 0.0 / 14.3 | 72 [70–72] | 68 |
| `fdrec` at 5000 (32 buffers) | 980 PRO | record | 32 GB | 4935 (dropped 5 812 732 beats) | 0.2 / 38.9 / 0.3 / 14.5 | 74 | 67 |
| `fdrec` at 6500, top step (32 buffers) | 980 PRO RAID0 | record | 4000 MiB | 6448 [6447–6448] | 0.7 / 48.7 / 0.7 / 5.3 | 92 [92–92] | 70 |
| `fdrec` at 6500 (32 buffers) | 980 PRO RAID0 | record | 32 GB | 6494 | 0.3 / 51.5 / 1.0 / 3.5 | 97 | 67 |
| `fdplay` at 6000, top step (32 buffers) | 980 PRO | play | 4000 MiB | 5641 [5640–5642] | 0.6 / 38.9 / 0.0 / 7.2 | 79 [77–79] | 71 |
| `fdplay` at 6000, top step (32 buffers) | 980 PRO RAID0 | play | 4000 MiB | 5665 [5665–5666] | 0.6 / 41.5 / 0.0 / 5.9 | 83 [83–83] | 69 |

Notes:

* Sabrent raw script output (MiB/s, medians): write 1762, read 3571; RAID0 write 1951, read
  3100; dual write 2675, read 3448 (aggregate; the dual reads spread from 3252 to 4188). One
  `dd` write to one drive uses 71 % of a core (11 % I/O wait), the RAID0 `dd` write 86 %; the
  third RAID0 `dd` write was slow (1250 MiB/s, after 1951 and 1980).
* Sabrent `fdrec`: clean at the top steps, 3 of 3 (one drive at 4500 MB/s over 4000 MiB,
  4460-4472 MB/s achieved, high-water mark 3; RAID0 at 4000 MB/s, 3978 MB/s, high-water mark 2);
  over 32 GB one drive at 4500 MB/s (4497 MB/s) and the RAID0 at 4000 MB/s (3997 MB/s), both
  clean.
* Sabrent `fdplay`: 4500 MB/s (one drive) and 5500 MB/s (RAID0) 3/3, 0 underflows. The tool's
  own rate (4222 / 5074 MB/s) includes the ring prefill.
* 980 PRO raw script output (MiB/s, medians): write 1428, read 2150; RAID0 write 1980, read
  3448; dual write 3252, read 5839 (aggregate). One `dd` write to one drive is only partly
  CPU-bound (57 % of a core, 15 % I/O wait); the RAID0 `dd` write runs at 85 % of a core. The
  first RAID0 `dd` write after `mkfs` and 60 s of idle was slow (1619 MiB/s, then 2030 and
  1980).
* 980 PRO `fdrec`: clean at the top steps, 3 of 3 (one drive at 5000 MB/s over 4000 MiB,
  4837-4880 MB/s achieved, high-water mark 4; RAID0 at 6500 MB/s, 6447-6448 MB/s, high-water
  mark 7). Over 32 GB one drive is clean at 4500 MB/s (the 32 GB run at 5000 MB/s in this
  table dropped) and the RAID0 at 6500 MB/s (6494 MB/s, high-water mark 7).
* 980 PRO `fdplay`: 6000 MB/s 3/3 on both layouts (0 underflows in every playback at or below
  6000 MB/s). The tool's own rate (5641 / 5665 MB/s) includes the ring prefill.
* At 1000 MB/s: `fdrec` 15 % (980 PRO) and 16 % (980 PRO RAID0) of a core, `fdplay` 12 / 12 %;
  `fdrec` 16 % (Sabrent) and 17 % (Sabrent RAID0), `fdplay` 12 / 12 %. Each drive got two NVMe I/O
  queues (one per core).

dd over 32 GB (timed like the scripts; inside the SLC cache):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| Sabrent | dd 32 GB (write: 3 runs, [1777–2169]; read: 1 run) | 2071 | 3434 | 84 / 56 |
| Sabrent RAID0 | dd 32 GB (1 run) | 2075 | 3217 | 77 / 71 |
| 980 PRO | dd 32 GB (write: 3 runs, [1790–2071]; read: 1 run) | 1797 | 3142 | 72 / 52 |
| 980 PRO RAID0 | dd 32 GB (1 run) | 2137 | 3659 | 89 / 83 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| Sabrent | 4383 MB/s, 86 % of a core | 4352 MB/s, 98 % | 4535 MB/s, 89 % | 4513 MB/s, 99 % |
| Sabrent RAID0 | 4378 MB/s, 90 % | 4134 MB/s, 98 % | 4496 MB/s, 93 % | 4239 MB/s, 98 % |
| 980 PRO | 4658 MB/s, 89 % of a core | 4442 MB/s, 97 % | 4481 MB/s, 83 % | 4601 MB/s, 99 % |
| 980 PRO RAID0 | 4579 MB/s, 91 % | 4098 MB/s, 98 % | 4687 MB/s, 93 % | 4448 MB/s, 99 % |

fio itself is CPU-bound (one fio thread at 83–99 % of a core; reads are almost all system time,
pinning the pages of each 8 MB request), so these are the host's figures, not the drives'. With
hugepage fixed buffers (`--iomem=mmaphuge --fixedbufs`, how `fdplay` reads) fio reads one
980 PRO at 6320 MB/s and its RAID0 at 7936 MB/s, one Sabrent at 4525 MB/s (the drive's own read
rate of its data) and its RAID0 at 7820 MB/s (10 GB). With fixed buffers and zero buffers
(`--zero_buffers`) one fio job writes the 980 PRO RAID0 at 7.60-7.62 GB/s and reads it at
7.99 GB/s, the Sabrent RAID0 at 7.17-7.33 GB/s and 7.88-7.94 GB/s, and two jobs (one per core)
do the same: a host I/O ceiling of this board, not fio (see
[The paths into DDR](#7-the-paths-into-ddr)). The 32 GB writes are inside the SLC cache
(~115-125 GB per 980 PRO, ~70-75 GB per Sabrent). The second 980 PRO alone: 4684 MB/s write,
4502 MB/s read; the second Sabrent alone: 4555 MB/s write, 4146 MB/s read (fio 4 GB, one run
each).

### Results: zcu106_hpc0

AMD ZCU106 (XCZU7EV, four Cortex-A53 cores at 1.2 GHz, 4 GB DDR4), XDMA Gen3 x4 Root Ports,
`zcu106_hpc0` image, measured 2026-10-22. The Sabrent Rocket 2230 1TB rows (two drives on the
M.2 M-key Stack FMC on HPC0) are Gen4 drives; they link at Gen3 x4 here (`LnkSta 8GT/s
(downgraded)`). The Samsung 980 PRO 1TB rows (two drives on the FPGA Drive FMC Gen4 on HPC0)
are Gen4 drives that link at Gen3 x4 here too. Same method, with 60 s of idle time after each
`mkfs`. `fdrec` / `fdplay` used the shipped default of **32 x 8 MB buffers**. Total CPU is a
share of four cores (25 % = one full core).

| method | config | direction | size | MB/s | total CPU % of 4 cores (usr / sys / irq / iowait) | process % of one core | MB/s per % core |
|---|---|---|---|---|---|---|---|
| dd (script) | 980 PRO 1TB | write | 4000 MiB | 1477 [1248–1498] | 0.1 / 17.7 / 0.6 / 6.0 | 70 [67–74] | 21 |
| dd (script) | 980 PRO 1TB | read | 4000 MiB | 1800 [1770–1978] | 0.2 / 11.2 / 1.7 / 8.6 | 48 [47–48] | 38 |
| dd (script) | RAID0 (2x 980 PRO) | write | 4000 MiB | 1619 [1503–1664] | 0.3 / 20.9 / 1.6 / 1.6 | 90 [89–91] | 18 |
| dd (script) | RAID0 (2x 980 PRO) | read | 4000 MiB | 2162 [2140–2208] | 0.3 / 19.7 / 0.0 / 2.9 | 76 [76–79] | 28 |
| dd (dual script) | both 980 PRO, two filesystems | write (aggregate) | 2 x 4000 MiB | 2542 [2467–2573] | 0.3 / 34.2 / 0.4 / 13.2 | 134 [131–137] | 19 |
| dd (dual script) | both 980 PRO, two filesystems | read (aggregate) | 2 x 4000 MiB | 3616 [3554–3976] | 0.4 / 25.9 / 3.1 / 11.7 | 106 [100–120] | 34 |
| `fdrec` at 3000, top step | 980 PRO 1TB | record | 4000 MiB | 2980 | 0.2 / 18.1 / 0.2 / 10.8 | 68 [68–69] | 44 |
| `fdrec` at 3000 | 980 PRO 1TB | record | 32 GB | 2998 | 0.2 / 17.4 / 0.1 / 11.5 | 68 | 44 |
| `fdrec` at 5000, top step at the time | RAID0 (2x 980 PRO) | record | 4000 MiB | 4954 [4937–4954] | 0.3 / 29.5 / 0.5 / 1.8 | 111 [111–112] | 45 |
| `fdrec` at 5000 | RAID0 (2x 980 PRO) | record | 32 GB | 4993 (dropped 2582 beats) | 0.3 / 30.6 / 0.7 / 1.3 | 117 | 43 |
| `fdplay` at 3000, top step | 980 PRO 1TB | play | 4000 MiB | 2824 | 0.2 / 12.5 / 2.7 / 8.5 | 56 [55–58] | 51 |
| `fdplay` at 4000, top step | RAID0 (2x 980 PRO) | play | 4000 MiB | 3814 [3802–3814] | 0.2 / 22.5 / 0.0 / 2.0 | 90 [89–90] | 42 |
| dd (script) | Sabrent Rocket 2230 1TB | write | 4000 MiB | 1327 [1275–1427] | 0.2 / 16.7 / 0.5 / 7.6 | 67 [66–73] | 20 |
| dd (script) | Sabrent Rocket 2230 1TB | read | 4000 MiB | 2007 [1864–2305] | 0.4 / 12.9 / 2.5 / 6.3 | 56 [52–87] | 36 |
| dd (script) | RAID0 (2x Sabrent) | write | 4000 MiB | 1441 [1394–1509] | 0.2 / 20.0 / 1.2 / 3.5 | 80 [78–90] | 18 |
| dd (script) | RAID0 (2x Sabrent) | read | 4000 MiB | 2267 [2087–2330] | 0.1 / 15.1 / 4.9 / 1.5 | 87 [70–88] | 26 |
| dd (dual script) | both Sabrent, two filesystems | write (aggregate) | 2 x 4000 MiB | 2542 [2432–2796] | 0.3 / 32.9 / 1.1 / 11.3 | 132 [131–150] | 19 |
| dd (dual script) | both Sabrent, two filesystems | read (aggregate) | 2 x 4000 MiB | 3779 [3679–3920] | 0.7 / 30.0 / 2.5 / 10.9 | 111 [111–134] | 34 |
| `fdrec` at 2500, top step | Sabrent Rocket 2230 1TB | record | 4000 MiB | 2486 | 0.6 / 13.9 / 0.1 / 14.2 | 61 [60–61] | 41 |
| `fdrec` at 2500 | Sabrent Rocket 2230 1TB | record | 32 GB | 2498 | 0.2 / 12.8 / 0.3 / 15.4 | 58 | 43 |
| `fdrec` at 3500, top step | RAID0 (2x Sabrent) | record | 4000 MiB | 3475 | 0.2 / 23.0 / 0.8 / 7.5 | 87 [86–89] | 40 |
| `fdrec` at 3500 | RAID0 (2x Sabrent) | record | 32 GB | 3497 | 0.2 / 23.2 / 0.8 / 7.6 | 88 | 40 |
| `fdplay` at 3000, top step | Sabrent Rocket 2230 1TB | play | 4000 MiB | 2822 | 0.2 / 16.1 / 0.0 / 7.3 | 62 [62–63] | 45 |
| `fdplay` at 3500, top step | RAID0 (2x Sabrent) | play | 4000 MiB | 3281 | 0.4 / 16.8 / 3.6 / 3.5 | 76 [75–81] | 43 |

Notes:

* 980 PRO raw script output (MiB/s, medians): write 1423, read 1746; RAID0 write 1562, read
  2094; dual write 2446, read 3493 (aggregate); 18-21 MB/s per % of a core writing. Four NVMe I/O
  queues on both slots.
* 980 PRO `fdrec`: clean 3/3 over 4000 MiB at 3000 MB/s on one drive (high-water mark 1) and at
  5000 MB/s on RAID0 (high-water mark 4). Over 32 GB one drive is clean at 3000 MB/s, and the
  RAID0 at 4500 MB/s: the 32 GB run at 5000 MB/s in this table dropped 2582 beats, and 5000 MB/s
  needs 64 buffers to be reliable (see [Sustained recording rate](#sustained-recording-rate)).
  Recording costs 68 % of one A53 core at 3000 MB/s and 111-117 % at 5000 MB/s (io_uring
  workers on other cores).
* 980 PRO `fdplay`: 3/3 at 3000 MB/s on one drive and 4000 MB/s on RAID0, 0 underflows. The
  tool's own rate (2824 / 3814 MB/s) includes the ring prefill. Playback costs 56 % of a core
  at 3000 MB/s and 90 % at 4000 MB/s.
* Sabrent raw script output (MiB/s, medians): write 1277, read 1941; RAID0 write 1388, read
  2209; dual write 2446, read 3652 (aggregate); 18-20 MB/s per % of a core writing. One `dd` at
  queue depth 1 is CPU- and latency-bound. Four NVMe I/O queues on both slots.
* Sabrent `fdrec`: clean 3/3 at the top steps over 4000 MiB, 2500 MB/s on one drive and
  3500 MB/s on RAID0 (high-water mark 1 on both), and over 32 GB at the same rates. Recording
  costs 58-61 % of one A53 core at 2500 MB/s and 87-88 % at 3500 MB/s.
* Sabrent `fdplay`: 3/3 at 3000 MB/s on one drive and 3500 MB/s on RAID0, 0 underflows. The
  tool's own rate (2822 / 3281 MB/s) includes the ring prefill. Playback costs 62 % of a core
  at 3000 MB/s and 76 % at 3500 MB/s.
* At 1000 MB/s: `fdrec` 25 % of a core (Sabrent) and 26 % (Sabrent RAID0), 24 % (980 PRO) and
  25 % (980 PRO RAID0); `fdplay` 19 / 19 % (Sabrent) and 17 / 21 % (980 PRO).

dd over 32 GB (timed like the scripts; inside the SLC cache):

| config | test | write MB/s | read MB/s | process % of one core (write / read) |
|---|---|---|---|---|
| 980 PRO 1TB | dd 32 GB (write: 3 runs, [1318–1536]; read: 1 run) | 1387 | 1870 | 66 / 48 |
| RAID0 (2x 980 PRO) | dd 32 GB (1 run) | 1636 | 2504 | 93 / 79 |
| Sabrent Rocket 2230 1TB | dd 32 GB (write: 3 runs, [1334–1541]; read: 1 run) | 1432 | 2358 | 75 / 85 |
| RAID0 (2x Sabrent) | dd 32 GB (1 run) | 1418 | 2464 | 81 / 88 |

fio reference (io_uring, queue depth 8, 8 MB blocks, `O_DIRECT`):

| config | 4 GB write | 4 GB read | 32 GB write | 32 GB read |
|---|---|---|---|---|
| 980 PRO 1TB | 2944 MB/s, 74 % of a core | 2859 MB/s, 97 % | 2970 MB/s, 75 % | 2882 MB/s, 97 % |
| RAID0 (2x 980 PRO) | 3395 MB/s, 95 % | 2881 MB/s, 97 % | 3366 MB/s, 96 % | 2871 MB/s, 98 % |
| Sabrent Rocket 2230 1TB | 2827 MB/s, 73 % of a core | 2912 MB/s, 98 % | 2885 MB/s, 77 % | 2961 MB/s, 97 % |
| RAID0 (2x Sabrent) | 3191 MB/s, 91 % | 2676 MB/s, 98 % | 3338 MB/s, 95 % | 2875 MB/s, 98 % |

The second Sabrent alone: 2896 MB/s write (74 % of a core), 2877 MB/s read (fio 4 GB, one run):
the same ~2.9 GB/s on both slots, the drive on its Gen3 x4 link. The second 980 PRO alone:
2970 MB/s write (75 % of a core), 2846 MB/s read (fio 4 GB, one run). Every read row and the
RAID0 write rows have the fio thread at 91-98 % of one A53 core, so they measure fio, not the
storage. With hugepage fixed buffers fio reads one Sabrent at 3124 MB/s and its RAID0 at
5113 MB/s, one 980 PRO at 3183 MB/s and its RAID0 at 5942 MB/s (10 GB, one job; 6365-6371 MB/s
with two jobs), and with zero buffers it writes the 980 PRO RAID0 at 6066-6076 MB/s: twice one
slot's rate, so the host is not a ceiling below the PCIe slots on this board. The 32 GB writes
are inside the SLC cache (~66-69 GB per Sabrent, ~118-124 GB per 980 PRO).

### Why the figures differ

The two methods answer different questions, and neither measures the PCIe link (with one
exception, below).

**CPU cost.** A `dd` write is a CPU-bound copy of zeros: every 4 MiB block is first zero-filled
by the kernel from `/dev/zero` into `dd`'s buffer, then written with `O_DIRECT`. That costs
about 50 % of one 1.2 GHz Cortex-A53 core per ~1 GB/s, and on RAID0 a single `dd` becomes
CPU-bound at 80–90 % of a core. `fdrec` never produces or copies the data: the AXI DMA fills the
hugepage buffers and the NVMe controller reads the same buffers, and the CPU only issues
io_uring requests and ioctls and does the cache maintenance. Measured, that is about **2–2.5×
more data per unit of CPU for writes** on `zcu106_hpc0` (`dd` 18–21 MB/s per % of a core,
`fdrec` 40–45) and 2.5–3× on `vck190_fmcp1` (`dd` 23–26, `fdrec` 61–73). For reads the gap is
smaller, **about 1.2–1.7×** (on `zcu106_hpc0` `dd` 26–38, `fdplay` 42–51; on `vck190_fmcp1` `dd`
47–61, `fdplay` 69–72): a `dd` read lands in its buffer by DMA and is handed to `/dev/zero`, which
discards it without a copy, so `dd` pays only the per-I/O work (a system call, pinning 1024
pages of 4 KiB per block, a wake-up per completion). The recorder's remaining cost is the
kernel's I/O path itself and the cache maintenance.

**Queue depth 1 vs 8 in flight.** `dd` has one 4 MiB request in flight; the drive idles
while `dd` prepares the next one. On `zcu106_hpc0` one `dd` writes 1327 MB/s to a Sabrent
Rocket 2230 1TB and fio at queue depth 8 2827 MB/s; on its RAID0 one `dd` (each block spans
both drives) reaches 1441 MB/s write and 2267 MB/s read, against fio's 3191 / 2676 MB/s (both
CPU-bound). On `vck190_fmcp1` one `dd` writes 1497 MB/s to a Samsung 980 PRO 1TB, fio 4658 MB/s
(CPU-bound); on its RAID0 one `dd` reaches 2076 MB/s write and 3616 MB/s read, against fio's
4579 / 4098 MB/s (both CPU-bound). One `dd` writes 1848 MB/s to a Sabrent on `vck190_fmcp1`, fio
4383 MB/s (CPU-bound), and on its RAID0 2046 MB/s write and 3251 MB/s read against fio's 4378 /
4134 MB/s; one `dd` writes 1477 MB/s to a 980 PRO on `zcu106_hpc0`, fio 2944 MB/s (the link),
and on its RAID0 1619 MB/s write and 2162 MB/s read against fio's 3395 / 2881 MB/s (CPU-bound).

**Burst vs sustained.** The 1 TB drives cache 66-125 GB, so on them a 4 GB and even a 32 GB
`dd` is a burst (one Sabrent writes 1432 MB/s over 32 GB and 1327 MB/s over 4 GB on
`zcu106_hpc0`, 2071 and 1848 MB/s on `vck190_fmcp1`; one 980 PRO 1797 and 1497 MB/s on
`vck190_fmcp1`, 1387 and 1477 MB/s on `zcu106_hpc0`). The recorder's "highest clean rate" is
stricter than any average: a recorder must never fall behind, not even briefly, so the drive's
worst moment sets it. The recorder's rates in these
tables are 4000 MiB and 32 GB recordings inside the cache; only the
[long recordings](#long-recordings-past-the-slc-cache) show the sustained rate.

**What else differs.** Both methods bypass the page cache (`O_DIRECT`); no cache effect
was seen. `dd` extends its file block by block, while `fdrec` preallocates the full size
first. And the `dd` data never touches the FPGA, whereas the `fdrec` and `fdplay` figures
include the AXI DMA, the fabric FIFO and the DDR traffic of the DMA and the SSD using the
same buffers.

**The PCIe link.** A PCIe Gen3 x4 link carries 3.94 GB/s raw in each direction, ~3.1-3.3 GB/s
of payload with 128-byte MaxPayload; Gen4 x4 twice that. Most figures here are below that: the
SSDs (and their caches), the filesystem and the Linux I/O path set the limits. The exceptions
are a fast Gen4 drive on the Gen3 x4 Root Ports of `zcu106_hpc0` inside its cache (one Sabrent
Rocket 2230 1TB writes ~2.94 GB/s and reads 2802-2991 MB/s from the raw device, one Samsung
980 PRO 1TB writes ~3.04 GB/s and reads 3099 MB/s: the link's practical rate) and reads on the
Gen4 x4 links of `vck190_fmcp1` (one 980 PRO reads 6362 MB/s at 128-byte MaxPayload, both drives
exactly the same; the Sabrent's link carries ~6.1 GB/s too, but the drive reads its data at
~4.5 GB/s; see [The PCIe links and MaxPayload](#6-the-pcie-links-and-maxpayload)). To
check the link itself, look at its negotiated speed and width (`lspci -vv`, see [Test the
design in Linux](linux_test.md#1-check-that-the-pcie-links-are-up)).

The sibling design's own documentation quotes lower `dd` figures for a Zynq UltraScale+ target
(read 790–970, write ~585 MB/s); those were measured with a Samsung 980 PRO and an older image,
and do not apply to this setup. With this design, a Sabrent Rocket 2230 1TB on `zcu106_hpc0`
gives 1327 MB/s write and 2007 MB/s read with the same scripts, and a Samsung 980 PRO 1TB
1477 MB/s write and 1800 MB/s read.

For CPU-less operation or rates beyond what Linux can sustain, see
[How to get more](#9-how-to-get-more).

## Where the bottlenecks are

Why don't you get the SSD's rated read and write speed, or the fabric's 8 GB/s? The first
part of this section lists every ceiling that was measured, per device family, with what sets
it and how to get past it where there is a way. The numbered sections after it go through the
chain from the SSD to the fabric, in the order in which the limits usually bite. The numbers
are the measurements on this page, on `zcu106_hpc0` (Zynq UltraScale+, Gen3 x4) and
`vck190_fmcp1` (Versal, Gen4 x4); the reasoning applies to every target of the family.

### Ceilings at a glance

#### Zynq UltraScale+ (`zcu106_hpc0`, `uzev`)

| ceiling | measured | what sets it | how to get past it |
|---|---|---|---|
| The SSD after its SLC cache | one drive writes a flat ~1.77-1.8 GB/s after its cache (Sabrent Rocket 2230 1TB after ~66-69 GB, Samsung 980 PRO 1TB after ~118-124 GB): **1750 MB/s** sustained over 200 GiB with either; the RAID0 pairs **3000 MB/s** (Sabrent) and **3250 MB/s** (980 PRO, ~3.49-3.57 GB/s after ~245 GB) over 350 GiB | the drive's TLC flash | drives without an SLC cliff, larger drives, RAID0 ([section 1](#1-the-ssd-itself)) |
| Write stalls against the buffer ring | RAID0, 32 GB: Sabrent pair **3500 MB/s** with the default 256 MB ring, **4500 MB/s** with 64 x 8 MB (3 of 3); 980 PRO pair **4500 MB/s** with the default ring (5000 MB/s 5 of 7), **5000 MB/s** with 64 x 8 MB (3 of 3) | write-latency spikes, and the slow start of a recording after idle time, outlast the ring (57 ms at 4.5 GB/s, 51 ms at 5 GB/s) | `--buffers 64` on RAID0 above ~3.5 GB/s (Sabrent) or ~4.5 GB/s (980 PRO); NVMe APST off against the start-up stalls (tested on `vck190_fmcp1`) ([section 5](#5-latency-budgets-not-bandwidth)) |
| One PCIe Gen3 x4 slot | one Sabrent writes ~2.94 GB/s and reads 2.8-3.1 GB/s, one 980 PRO writes ~3.04 GB/s and reads ~3.19 GB/s: one drive records **2500 MB/s** (Sabrent) or **3000 MB/s** (980 PRO) over 32 GB and plays back **3000 MB/s**; at MaxPayload 256 bytes one 980 PRO reads ~3.55 GB/s and plays back **3500 MB/s** | XDMA Root Ports are Gen3 x4 (a Gen4 drive links at 8 GT/s), 128-byte MaxPayload | RAID0 across both slots; MaxPayload 256 bytes for playback; a Versal target with Gen4 x4 ([section 6](#6-the-pcie-links-and-maxpayload)) |
| Playback from a file: one `fdplay` thread | RAID0 playback **3500 MB/s** (Sabrent pair, `fdplay` 87 % of a core) and **4000 MB/s** (980 PRO pair, 94.5 %; 4500 MB/s delivers ~4.1-4.2 GB/s), although fio reads the 980 PRO pair at 6.37 GB/s with fixed buffers (two jobs) and the playback path from DDR takes 5000 MB/s | `fdplay` reads with one thread, ~1.7-2.4 % of an A53 core per 100 MB/s | a reader with more than one thread (not implemented); a fabric NVMe host design ([section 9](#9-how-to-get-more)) |
| The host's write path (four Cortex-A53 cores) | not a ceiling below the two slots: fio with hugepage fixed buffers writes the 980 PRO pair at **6.07 GB/s** and reads it at **6.37 GB/s** (twice one Gen3 x4 slot), and `fdrec` records 5000 MB/s to it, HP2's knee; the Sabrent pair writes only ~4.8-4.9 GB/s at 5000 MB/s with all 8 writes in flight, a limit of that pair on these links | `fdrec` ~2.3-2.6 % of an A53 core per 100 MB/s, spread over its thread and io_uring workers on other cores (116-117 % at 5000 MB/s) | - |
| `S_AXI_HP2_FPD`, the AXI DMA's port into DDR | **5155 MB/s** peak (128 bits × 322.19 MHz on the ZCU106; 5244 MB/s at 327.77 MHz on the UltraZed-EV); without an SSD, recording and playback clean at **5000 MB/s**, 5250 MB/s fails 3 of 3, above it a flat 5153-5155 MB/s; with SSDs, the 980 PRO pair records **5000 MB/s** (64 x 8 MB, 3 of 3) and drops at 5500 and 6000 MB/s writing a flat 5118-5147 MB/s with any ring | a 128-bit PS-PL port, clocked at most 333 MHz (DS925) | a second AXI DMA on a second HP port (needs a two-channel driver; not implemented), or a Versal target ([section 7](#7-the-paths-into-ddr)) |
| The source and the sink | 8000 MB/s (250 MHz × 32 bytes) | `src_clk` × 256 bits | not reached on these targets: HP2 comes first |
| PS DDR | not reached: RAID0 at 5000 MB/s (10 GB/s of DDR traffic) clean | every byte crosses DDR twice | - |

#### Versal (`vck190_fmcp1`)

| ceiling | measured | what sets it | how to get past it |
|---|---|---|---|
| The SSD | in its cache one Samsung 980 PRO 1TB writes ~4.94-4.98 GB/s and one Sabrent Rocket 2230 1TB ~4.6 GB/s: one drive records **4500 MB/s** over 32 GB with either (the 980 PRO 5000 MB/s for 10 and 40 GB); the Sabrent reads its data at ~4.5 GB/s, so one Sabrent plays back **4500 MB/s**; after the cache (~115-125 GB 980 PRO, ~70-75 GB Sabrent) ~1.77-1.8 GB/s: **1750 MB/s** sustained over 200-240 GiB; the pairs ~3.46-3.57 GB/s after ~245 GB (980 PRO: **3250 MB/s** over 480 GiB) and ~3.6 GB/s after ~140 GB (Sabrent: **3500 MB/s** over 350 GiB) | the drive's in-cache write and read rates, then its TLC flash | RAID0; faster drives; drives without an SLC cliff ([section 1](#1-the-ssd-itself)) |
| Write stalls against the buffer ring | RAID0, 32 GB: 980 PRO pair **6500 MB/s** with the default 256 MB ring (7000 MB/s 2 of 3), **7000 MB/s** with 32 x 16 MB (3 of 3); Sabrent pair **4000 MB/s** with the default ring (4500-5000 MB/s: one gap at 0.27 GB in 9 of 11 recordings), **7000 MB/s** with 32 x 16 MB (3 of 3), 4500-6000 MB/s with the default ring and APST off (5 of 5); 980 PRO bursts of 10 and 40 GB clean 2 of 2 at 6000 MB/s, one run in two dropped at 6500 MB/s and at 7000 MB/s (40 GB) | write stalls longer than the ring (39 ms at 6.5 GB/s); with the Sabrent pair the start of a recording after idle time: both drives wake from APST power state 4 (44 ms specified, ~63-65 ms measured) | `--buf-size 16M` on RAID0 above ~4 GB/s (Sabrent) or ~6.5 GB/s (980 PRO); NVMe APST off ([section 5](#5-latency-budgets-not-bandwidth)) |
| PCIe Gen4 x4 link efficiency on reads | one 980 PRO reads **6362 MB/s** per link at MaxPayload 128 bytes (both drives exactly the same), **7069 MB/s** at 256 bytes: one drive plays back **6000 MB/s**, **6500 MB/s** at 256 bytes; the Sabrent's link reads 6072-6116 MB/s at 128 bytes and 6671-6748 MB/s at 256 bytes (raw device, trimmed blocks), but the drive reads its data at ~4.5 GB/s, so 256 bytes does not change its playback | TLP overhead at the kernel's default 128-byte MaxPayload | MaxPayload 256 bytes on Root Port and SSD with `setpci`, MaxReadReq kept at 512, for drives that read faster than ~6.3 GB/s ([section 6](#6-the-pcie-links-and-maxpayload)) |
| The PCIe path into DDR, shared by both Root Ports | RAID0 with fio, hugepage fixed buffers, no fabric traffic: 980 PRO pair **7602-7624 MB/s** write, **7983-7992 MB/s** read; Sabrent pair **7169-7334 MB/s** write, **7879-7937 MB/s** read; the same with one and with two fio jobs | likely the one NoC port (`S08_AXI`, 256 bits at 250 MHz = 8.0 GB/s, QoS request 7000 MB/s) that both QDMA bridges share; not isolated, nor is the 4-5 % difference between the pairs | one NoC port per PCIe bridge ([section 7](#7-the-paths-into-ddr)) |
| The host I/O path (two Cortex-A72 cores) | RAID0 recording at 7500 MB/s writes 7.27-7.39 GB/s (980 PRO pair) and 7.13-7.14 GB/s (Sabrent pair, 16 MB buffers) with the queue full (`fdrec` 111-123 % of a core); RAID0 playback from a file **6000 MB/s** (980 PRO pair, `fdplay` 91 % of a core; 6500 MB/s 1 of 2) and **5500 MB/s** (Sabrent pair, 94 %; 6000 MB/s delivers ~5.66 GB/s) | `fdrec` ~1.5-1.7 % of an A72 core per 100 MB/s, ~0.9 % of it the DMA ring's cache maintenance; `fdplay` one thread; plus the write ceiling above | 16 MB buffers; do not pin `fdrec` to one core; a playback reader with more than one thread (not implemented); a fabric NVMe host design ([section 9](#9-how-to-get-more)) |
| The fabric datapath (`src_clk` = `dp_clk` = 250 MHz) | **8000 MB/s** instantaneous, but recording without an SSD is lossless only up to **7750 MB/s** (8000 MB/s loses ~8 beats per 8 MiB buffer boundary although the DMA delivers 7.99 GB/s) and playback from the ring up to **7500 MB/s**, with either FMC card | a source or sink at one beat per clock with the DMA side at the same clock: no drain headroom after any DMA pause | a `dp_clk` faster than `src_clk` (timing margin is thin on Versal); 512 bits only once the host path exceeds ~8 GB/s ([section 8](#8-the-fabric-datapath)) |
| The AXI DMA's NoC port (`S09_AXI`) | 7989-7997 MB/s delivered (QoS request 8000 MB/s each way) | - | not a ceiling below the fabric's |
| PS DDR (one 64-bit DDR4 controller) | not reached: RAID0 at 7000 MB/s (14 GB/s of DDR traffic; 16 MB buffers, both pairs) clean | every byte crosses DDR twice; about 10 GB/s of recording would be the DDR-bound rate (an estimate, not measured) | - |

### 1. The SSD itself

**Writes: the SLC cache, then the flash.** Inside its cache a drive writes at its own in-cache
rate or at its link's rate, whichever is lower: on the Gen4 x4 links of `vck190_fmcp1` one
Samsung 980 PRO 1TB writes ~4.94-4.98 GB/s (fio is CPU-bound at ~4.7 GB/s) and one Sabrent
Rocket 2230 1TB ~4.6 GB/s (4567-4653 MB/s); on the Gen3 x4 links of `zcu106_hpc0` both run at the
link's rate (~2.94 GB/s the Sabrent, ~3.04 GB/s the 980 PRO). On an empty, trimmed drive the
980 PRO caches ~115-125 GB and the Sabrent ~66-75 GB, on both boards, and after the cache both
write a flat ~1.77-1.8 GB/s (see [The SLC cache](#the-slc-cache)). Where nothing else comes
first, the post-cache rate sets the sustained single-drive rate: 1750 MB/s for both drives on
both boards, over 200-240 GiB; at the in-cache top a recording drops where the cache ends
(80.25 GB with the Sabrent, 116.78 GB with the 980 PRO on `zcu106_hpc0`). Inside the cache one
drive is clean over 32 GB at 4500 MB/s on `vck190_fmcp1` (either drive) and at 2500 MB/s
(Sabrent) or 3000 MB/s (980 PRO) on `zcu106_hpc0`; one 980 PRO on `vck190_fmcp1` at 5000 MB/s
only while the ring covers its ~20-60 MB/s deficit, which lasts for 10 and 40 GB but not
reliably for 32 GB (3 of 7). Smaller drives show the cliff sooner: Samsung rates the 970 EVO
250GB at up to 1500 MB/s sequential write, and 300 MB/s once its TurboWrite (SLC) cache is full
([data sheet](https://download.semiconductor.samsung.com/resources/data-sheet/Samsung-NVMe-SSD-970-EVO-Data-Sheet_Rev.1.0.pdf)).

**Reads: the rating assumes a fast host with many commands outstanding.** Drive read ratings
are measured with many read commands in flight on a fast desktop host. With one request at a
time (`dd`, queue depth 1) one Samsung 980 PRO 1TB reads 2254 MB/s and one Sabrent Rocket 2230
1TB 3745 MB/s on `vck190_fmcp1` (Gen4 x4); with 8 requests in flight fio reads them at 4442 and
4352 MB/s, CPU-bound. With hugepage fixed buffers, the way `fdplay` reads, one 980 PRO reads
6320-6362 MB/s, the Gen4 x4 link's rate at 128-byte MaxPayload (section 6), and one Sabrent
4519-4525 MB/s: the Sabrent's own read rate of its written data (its link carries more). On
`zcu106_hpc0` the Gen3 x4 link sets the per-slot read rate: one Sabrent reads 2802-2991 MB/s
(raw device, 1 MB requests at queue depth 8 and 32) and 3124 MB/s with fio and fixed buffers,
one 980 PRO 3099 MB/s (raw device, queue depth 32) and 3183-3193 MB/s with fixed buffers.

**The recorder's criterion is the drive's worst moment.** A recording passes only if no beat
is dropped over its whole length, so its rate is set by the drive's slowest stretch
(garbage collection, the cache end, a write-latency spike), not by its average. That is why
the sustained recording rates sit below the drives' average write rates (one 980 PRO 1TB:
1750 MB/s against a post-cache median of 1765-1766 MB/s).

A write-latency spike can cost data even below the drive's bandwidth, if it outlasts the ring,
and so can a slow start of a recording after idle time (section 5). On `zcu106_hpc0` the Sabrent
pair dropped 3 of the 4 sweep recordings of 32 GB at 4000-4500 MB/s (two of them in one gap at
0.27 GB, the start-up signature), one 40 GB burst at 4000 MB/s (at 0.27 GB) and one 350 GiB
recording at 3500 MB/s in a single ~0.2 s stall at 285.71 GB; the 980 PRO pair dropped 2 of 7
recordings of 32 GB at 5000 MB/s (one in a stall in its first second) and the 350 GiB recording
at 5000 MB/s once, in its first second. On `vck190_fmcp1` the Sabrent pair dropped 9 of 11 RAID0
recordings at 4500-5000 MB/s, each in one gap at 0.27 GB (the drives waking from APST); the
980 PRO pair dropped one of two 10 GB bursts at 6500 MB/s, one of two 40 GB bursts at 6500 and
at 7000 MB/s, one of three 32 GB recordings at 7000 MB/s, and the 480 GiB recordings at 6000 and
6500 MB/s once each in their first GB; every burst at 6000 MB/s was clean. On three of the four
combinations one drive dropped the first 10 GB burst after a 500 GiB write to the pair (the drive
still moving that data out of its cache); three repeats each were clean. Each time the ring ran
out (the first gap starts 8192 + 7 beats after a buffer boundary), and a 512 MB ring removed the
drops: 4500 MB/s (Sabrent pair) and 5000 MB/s (980 PRO pair) on `zcu106_hpc0`, 7000 MB/s (both
pairs) on `vck190_fmcp1`.

### 2. The host I/O path and the CPU

Every write and read goes through the kernel's filesystem, block layer and NVMe driver, and
that path costs CPU time per byte even without a data copy. On `zcu106_hpc0` (four 1.2 GHz
Cortex-A53 cores) `fdrec` uses about 2.3–2.6 % of one core per 100 MB/s (23.6–25.9 % at
1000 MB/s), almost all of it system time, and the cost grows almost linearly with the rate:
58 % at 2500 MB/s, 67-68 % at 3000 MB/s and 87-88 % at 3500 MB/s. Above ~4.3 GB/s `fdrec` passes
100 % of a core (100-115 % at 4500 MB/s, 116-117 % at 5000 MB/s): with io_uring part of the
kernel's write work runs in worker threads on other cores, so one core is not a wall for
recording. The A53s' write path is not the limit below the two PCIe slots: fio with hugepage
fixed buffers and zero buffers writes the 980 PRO pair at 6.07 GB/s, twice one Gen3 x4 slot,
and `fdrec` records 5000 MB/s to it with 64 buffers, the knee of HP2 (section 7). With the
Sabrent pair 5000 MB/s drops with either ring, all 8 writes in flight and ~4.8-4.9 GB/s written,
while the 980 PRO pair keeps 3-4 writes in flight at that rate on the same board: a limit of the
Sabrent pair on these links, not of the host.

Playback is different: `fdplay` reads with one thread and uses 16.5-21.3 % of a core at
1000 MB/s, 56-63 % at 3000 MB/s, 76-87 % at 3500 MB/s and 89-94.5 % at 4000 MB/s. Playback from
a RAID0 pair tops out at 3500 MB/s (Sabrent) and 4000 MB/s (980 PRO), although fio reads the
pairs at 5113 and 5942 MB/s with one job and hugepage fixed buffers (6365-6371 MB/s with two
jobs, 980 PRO) and the playback path from DDR takes 5000 MB/s: the one `fdplay` thread is the
limit (94.5 % of a core at 4000 MB/s, its core 92 % busy). A reader with more than one thread
would be the way past it; it is not implemented. `dd` additionally has the CPU produce every
byte (zero-fill from `/dev/zero`) and runs one request at a time: about 5 % of a core per
100 MB/s, and on RAID0 a single `dd` is CPU-bound at ~1.4-1.6 GB/s (80-90 % of a core). The AXI
DMA writes DDR through a non-coherent port, so the driver does a cache-maintenance pass over
each buffer (one invalidate after the DMA, one clean before the buffer goes back); that is part
of the system time above, and a large part of it: `fdrec --no-write`, with no file I/O at all,
takes 56 % of a core at 4000 MB/s and 70 % at 5000 MB/s.

On the VCK190 (two 1.4 GHz Cortex-A72 cores) the same work costs less: `fdrec` uses about
1.5-1.7 % of one core per 100 MB/s at every rate (15.4-16.7 % at 1000 MB/s, 65-70 % at
4000-4500 MB/s, 72-75 % at 5000 MB/s, 92-98 % at 6500 MB/s, 117-119 % at 7000 MB/s with 16 MB
buffers), ~0.9 % of it for the DMA ring alone (`--no-write`: 73 % at 8000 MB/s); `fdplay`
about 1.2-1.7 % (12-12.5 % at 1000 MB/s, 63 % at 4500 MB/s, 83-91 % at 6000 MB/s, 94 % at
5500 MB/s from the Sabrent RAID0). A core goes about 1.6 times as far as a ZCU106 core, but
there are only two of them. At 7500 MB/s to a RAID0 pair `fdrec` needs 111-123 % of a core,
spread over both cores, and the recording writes 7.27-7.39 GB/s (980 PRO pair) or 7.13-7.14 GB/s
(Sabrent pair, 16 MB buffers) with the queue full: the host, close to the write ceiling of
section 7. Pinning `fdrec` to one core (`taskset`) makes it worse (that core 99.7 % busy,
~6.1 GB/s); 16 MB buffers help (half the buffer boundaries; 7000 MB/s clean 3 of 3 with either
pair). RAID0 playback from a file stops at 6000 MB/s with the 980 PRO pair (6500 MB/s 1 of 2,
one core 89 % busy) and at 5500 MB/s with the Sabrent pair (one core 96 % busy; 6000 MB/s
delivers ~5.66 GB/s), below the pairs' 7936 and 7820 MB/s fixed-buffer reads: the single
`fdplay` thread. With the Gen4 drives the VCK190's CPU is also the limit of the reference tools:
one fio thread without fixed buffers reaches 83-99 % of a core at ~4.1-4.8 GB/s, and one `dd`
write stream runs at 57-86 % of a core.

On `zcu106_hpc0` the reference tools hit the same wall on one A53 core: fio reads of a file
(2.7-3.0 GB/s) and fio writes to a RAID0 pair (~3.2-3.4 GB/s) keep the fio thread at 91-98 % of
a core, so they measure fio, not the storage (with hugepage fixed buffers fio reads the Sabrent
pair at 5113 MB/s and the 980 PRO pair at 5942 MB/s).

### 3. The NVMe queue count

The Linux NVMe driver gives a drive one I/O queue per CPU core if the drive supports it: both
the Sabrent Rocket 2230 1TB and the Samsung 980 PRO 1TB got four on `zcu106_hpc0` (`4/0/0
default/read/poll queues` in the kernel log, both slots) and two on `vck190_fmcp1` (`2/0/0`).
Some drives get a single I/O queue whatever the board; the Samsung 970 EVO 250GB, an older drive
also tried with this design, is one (`1/0/0`). With one queue, every command and completion of
the drive goes through one queue and one interrupt, on one core: a limiter for parallel I/O to
that drive. Check yours with `dmesg | grep queues`.

### 4. RAID0 and the filesystem

With 512 KB chunks, md splits every 8 MB request into 16 stripe writes, alternating between the
drives; the array then runs at up to twice the slower drive's rate. md itself is not the
limit: `fdrec` records 4500 MB/s to the Sabrent pair and 5000 MB/s to the 980 PRO pair on
`zcu106_hpc0` (64 buffers) and 7000 MB/s to both pairs on `vck190_fmcp1` (16 MB buffers) through
md, and fio with fixed buffers writes 6.07 GB/s and reads 6.37 GB/s through md on `zcu106_hpc0`
(twice one Gen3 x4 slot) and 7.2-7.6 GB/s and 7.9-8.0 GB/s on `vck190_fmcp1` (the PCIe path's
ceiling, section 7). On the filesystem side, `fdrec` preallocates the whole file
(`fallocate`), so XFS does no allocation work during the recording; the first writes of a
recording can be slow after `fstrim` or after idle time (see
[Start-up stalls and the ring size](#start-up-stalls-and-the-ring-size)).

### 5. Latency budgets, not bandwidth

Two buffers decide whether a short stall costs data, although neither limits throughput:

* **The buffer ring** (buffers × buffer size) must cover the longest write stall of the drives
  at the recording rate. The default 32 × 8 MB = 256 MB lasts 128 ms at 2 GB/s, 73 ms at
  3.5 GB/s, 57 ms at 4.5 GB/s, 51 ms at 5 GB/s and 39 ms at 6.5 GB/s; a 512 MB ring
  (`--buffers 64`, or `--buf-size 16M` with 32 buffers, each the whole default hugepage pool)
  lasts twice as long. Two kinds of stall were seen: write-latency spikes anywhere in a
  recording (garbage collection, the cache end, a drive still folding an earlier write), and
  a stall at the start of a recording after idle time, when the drives wake from their deepest
  NVMe APST power state (~63-65 ms with the Sabrent pair on `vck190_fmcp1`; with the default ring
  the loss then shows as one gap at 0.27 GB, the end of the first pass through the ring; see
  [Start-up stalls and the ring size](#start-up-stalls-and-the-ring-size)). Measured: on
  `zcu106_hpc0` the Sabrent pair at 4500 MB/s dropped with 256 MB and was clean 3 of 3 with
  64 x 8 MB, the 980 PRO pair at 5000 MB/s was clean 5 of 7 with 256 MB and 3 of 3 with
  64 x 8 MB; on `vck190_fmcp1` the 980 PRO pair at 7000 MB/s was clean 2 of 3 with 256 MB and 3 of
  3 with 32 x 16 MB, the Sabrent pair clean to 4000 MB/s with 256 MB and to 7000 MB/s (3 of 3)
  with 32 x 16 MB, and with APST off clean at 4500-6000 MB/s with 256 MB. `fdrec` accepts up to
  64 buffers of up to 62 MB; a ring larger than the 512 MB hugepage pool needs more hugepages
  reserved at boot (not tested).
* **The fabric FIFO** must cover the AXI DMA's pauses. Driver 1.3 keeps the DMA armed across
  buffer boundaries, with the next two buffers appended to its running descriptor chain
  (`xilinx_dma` patch 0002, see [Kernel driver](driver.md)), so the DMA does not wait for
  software at a boundary. The ingest FIFO's high-water mark is then a floor set by the rate:
  1 beat up to 3500 MB/s, then one more beat per 500 MB/s, 2 at 4000 MB/s up to 8 at
  7000 MB/s on `vck190_fmcp1` (both pairs), and the same on `zcu106_hpc0` up to 4 at 5000 MB/s.
  Close to HP2's peak (5000 MB/s is 97 % of it) two clean 980 PRO RAID0 recordings reached 2274
  and 5115 of 8192 beats: back-pressure on the DMA side, which the FIFO absorbed. A start-up
  stall that the ring covers raises the mark in the first second (up to 385 beats at 7000 MB/s
  with 16 MB buffers). In every 1 s sample taken while the clean long recordings ran (200-480 GiB,
  inside and past the SLC cache) it was 1 beat. The 256 KB ingest FIFO (8192 beats of 32 bytes)
  lasts 32 µs at 8 GB/s (51 µs at the 5.16 GB/s of HP2 on `zcu106_hpc0`) and is therefore margin
  against DDR and interconnect back-pressure, not against software; the 128 KB egress FIFO lasts
  16 µs at 8 GB/s (see
  [the FIFO budget](apps.md#tuning-the-fifo-budget-at-buffer-boundaries)). The DMA stops at a
  boundary only when the chain is empty, which in practice means that the ring has run out
  behind a slow drive. The overflow then starts 8192 + 7 beats (262 368 bytes) after the
  boundary, so a gap at that offset means that the ring ran out behind the drive. The
  statistics of `fdrec --stats` show it: the io_uring queue is full (`inflight` at `--qd`) and
  the write rate is below the recording rate, as with one Sabrent Rocket 2230 1TB at 3000 MB/s
  on `zcu106_hpc0`. A gap that starts elsewhere inside a buffer comes from the path into DDR or
  the fabric itself (HP2 on `zcu106_hpc0`, section 7; the 8000 MB/s limit of section 8).

Both set what "sustainable" means: a rate is sustainable if the drive's worst stall fits in
the ring.

### 6. The PCIe links and MaxPayload

**Zynq UltraScale+.** The XDMA Root Ports are Gen3 x4, so a Gen4 SSD links at 8 GT/s
(`(downgraded)`). At 128-byte MaxPayload (MaxReadReq 512 bytes) the link carries 3.94 GB/s
raw, and each 128-byte payload travels in a TLP with ~20-24 bytes of header, sequence number,
LCRC and framing, plus acknowledgement and flow-control packets, which leaves ~3.1-3.3 GB/s of
payload per direction. Measured on `zcu106_hpc0`: one slot writes ~2.94 GB/s with the Sabrent
(2879-2948 MB/s at the 3000 and 3500 MB/s sweep steps; fio 2827-2896 MB/s) and ~3.04 GB/s with
the 980 PRO (3034-3037 MB/s at the 3500 and 4000 MB/s steps; fio 2944-2986 MB/s), and reads
2802-2991 MB/s (Sabrent, raw device) and 3099 MB/s raw, 3183-3193 MB/s with fixed buffers
(980 PRO). So one Sabrent records 2500 MB/s and one 980 PRO 3000 MB/s (the next step is above
the link), both play back 3000 MB/s, and RAID0 across both slots is the way past that. The
per-slot figure is consistent with [fpga-drive-nvme-offload](https://offload.fpgadrive.com),
the hardware NVMe host design (AMD NVMe Host Accelerator) on the same board and Root Ports,
which reaches ~3.04 GB/s per Gen3 x4 slot.

**Versal.** The QDMA Root Ports of `vck190_fmcp1` link at Gen4 x4 (16 GT/s, both drives of
both pairs). For writes the drive, not the link, is the limit (~4.94-4.98 GB/s the 980 PRO,
~4.6 GB/s the Sabrent). For reads the link is the limit with the 980 PRO: one 980 PRO reads
6362 MB/s (fio, raw device, hugepage fixed buffers, 8 MB at queue depth 8), both drives exactly
the same, at the 128-byte MaxPayload that the kernel sets, so one drive plays back 6000 MB/s and
underflows at 6500 MB/s. The Sabrent's link reads 6072-6116 MB/s from the raw device (its
trimmed blocks are returned without reading the flash), but the drive reads its written data at
~4.5 GB/s, so one Sabrent plays back 4500 MB/s and the drive is its limit.

**MaxPayload 256 bytes.** The kernel leaves MaxPayload at 128 bytes (MaxReadReq 512 bytes) on
both targets, although the Root Ports support 1024 bytes (QDMA and XDMA), the Samsung 980 PRO
256 bytes and the Sabrent Rocket 2230 512 bytes. Setting 256 bytes on the Root Port and on the
SSD behind it, Root Port first, with the drives idle and nothing mounted, was clean on both
targets (no AER message). What it changes depends on the drive:

| drive, target | read per drive (fio, raw device, hugepage fixed buffers) | one-drive playback from a file | writes |
|---|---|---|---|
| Samsung 980 PRO 1TB, `vck190_fmcp1` | 6362 -> **7069 MB/s** (+11 %); 6346-6350 -> 6848-6892 MB/s from a file | 6000 -> **6500 MB/s** (3 of 3; 7000 MB/s underflows) | unchanged (fio 4753 -> 4780 MB/s; RAID0 within 1 %) |
| Samsung 980 PRO 1TB, `zcu106_hpc0` | 3193 -> **3546 MB/s** (+11 %) | 3000 -> **3500 MB/s** (3 of 3; 4000 MB/s underflows) | fio 2978 -> 3185 MB/s (+7 %); `fdrec` at 3500 MB/s still drops (~3.37 GB/s written instead of ~3.04) |
| Sabrent Rocket 2230 1TB, `vck190_fmcp1` | 6072-6116 -> 6671-6748 MB/s (+10 %, trimmed blocks: the link) | 4500 MB/s either way (5000 MB/s underflows): the drive reads its data at ~4.5 GB/s (4525-4527 MB/s from a file at both settings) | not measured |

So 256 bytes helps playback from a drive that reads faster than its link carries at 128 bytes,
and it gained no recording step: on `vck190_fmcp1` the drives limit the writes, and on
`zcu106_hpc0` one 980 PRO writes ~7-11 % faster but 3500 MB/s still drops (3250 MB/s was not
tried). The RAID0 read with fixed buffers on `vck190_fmcp1` does not change (7983 -> 7989 MB/s,
the ceiling of section 7). The setting does not survive a reboot:

```
# bits 7:5 of the PCIe Device Control register: 000 = 128 bytes, 001 = 256 bytes
sudo setpci -s <root-port> CAP_EXP+8.w=0020:00e0
sudo setpci -s <ssd> CAP_EXP+8.w=0020:00e0
sudo lspci -vv -s <ssd> | grep -A1 DevCtl:      # MaxPayload 256 bytes, MaxReadReq 512 bytes
```

The kernel argument `pci=pcie_bus_perf` also sets 256 bytes on the SSDs, but lowers their
MaxReadReq to 256 bytes as well, which cost ~11 % of a single 980 PRO's write rate on
`vck190_fmcp1` (fio 4325-4327 against 4867-4881 MB/s; not tried on `zcu106_hpc0`): use `setpci`
and keep MaxReadReq at 512. Every other figure on this page was measured at the default
128 bytes.

### 7. The paths into DDR

**Zynq UltraScale+.** Each XDMA Root Port reaches the PS DDR through its own HP port
(`S_AXI_HP0_FPD`, `S_AXI_HP1_FPD`), 128 bits at 250 MHz = 4.0 GB/s each, above what a Gen3 x4
link carries: fio with hugepage fixed buffers writes the 980 PRO RAID0 at 6.07 GB/s and reads it
at 6.37 GB/s (two jobs), twice one slot's rate, so this path is not a ceiling. The recorder's own
AXI DMA runs 256 bits at 250 MHz (8.0 GB/s) into a SmartConnect that converts it to
`S_AXI_HP2_FPD`, a 128-bit port on its own clock, `pl_clk3`, which the PS can run at up to
333 MHz (DS925): 322.19 MHz on the ZCU106 and 327.77 MHz on the UltraZed-EV, a peak of 5155 /
5244 MB/s (see [Architecture](architecture.md)). Measured on `zcu106_hpc0` without an SSD,
recording and playback are clean at 5000 MB/s and fail at 5250 MB/s (3 of 3 each), and above
that the DMA moves a flat 5153-5155 MB/s: **HP2 is the ceiling of the recorder on Zynq
UltraScale+**, however fast the SSDs. The 980 PRO pair reaches it: it records 5000 MB/s with
64 buffers (3 of 3), and 5500 and 6000 MB/s drop while writing a flat 5118-5147 MB/s, with any
ring, their first gap inside the first buffer. With the Sabrent pair the drives come first
(~4.8-4.9 GB/s at 5000 MB/s, all 8 writes in flight). The way past HP2 is a second AXI DMA on a
second HP port (`S_AXI_HP3_FPD`), each carrying half of the stream, which needs a two-channel
driver and is not implemented; or a Versal target. Even at 333 MHz one 128-bit port would carry
only 5.33 GB/s.

**Versal.** The AXI DMA has its own NoC port, `S09_AXI` (256 bits at `dp_clk`, QoS request
8000 MB/s each way), routed straight to the DDR memory controller: it delivered 7989-7997 MB/s
in `fdrec --no-write`, so it is not a ceiling below the fabric's. Both QDMA bridges, however,
reach DDR through one shared NoC port, `S08_AXI` (256 bits at 250 MHz = 8.0 GB/s per direction,
QoS request 7000 MB/s). Measured on the RAID0 with fio, hugepage fixed buffers and no fabric
traffic at all, the 980 PRO pair writes at most 7602-7624 MB/s (the SSDs read host memory) and
reads 7983-7992 MB/s (the SSDs write host memory), and the Sabrent pair 7169-7334 and
7879-7937 MB/s, the same with one fio job (34-39 % of a core writing, 79-98 % reading) and with
two jobs, one per core: a hard ceiling, not fio, and below what the two drives and links carry
(the 980 PRO pair 2 x ~4.98 GB/s write and 2 x ~6.36 GB/s read; the Sabrent pair 2 x ~4.6 and
2 x ~4.5 GB/s). It is **likely the shared `S08_AXI` port**, whose raw rate the read figures
approach, but this was not isolated: the NoC arbitration, the NMU or the DDR controller with the
DMA's traffic could also play a part, and why the Sabrent pair stays 4-5 % below the 980 PRO
pair is not explained. For the recorder it caps RAID0 recording below ~7.2-7.6 GB/s whatever
the CPU does (`fdrec` wrote 7.27-7.39 GB/s at 7500 MB/s with the 980 PRO pair, 95-97 % of its
ceiling, and 7.13-7.14 GB/s with the Sabrent pair, 98 %). The potential way past it is one NoC
port per PCIe bridge, each with its own QoS request, in the block design (not implemented).

**The PS DDR memory.** A recording moves every byte through DDR twice (the AXI DMA writes it,
the SSD reads it), and a playback the other way round. RAID0 recordings at 5000 MB/s on
`zcu106_hpc0` (10 GB/s of DDR traffic) and at 7000 MB/s on `vck190_fmcp1` (14 GB/s, 16 MB
buffers, both pairs) were clean, so DDR is not the limit at these rates. On the VCK190 (one
64-bit DDR4 controller, 25.6 GB/s) about 10 GB/s of recording would be the DDR-bound rate (an
estimate, not measured).

### 8. The fabric datapath

The datapath is 256 bits wide at 250 MHz: the test pattern generator and the checker move one
32-byte beat per `src_clk` cycle at most, 8000 MB/s (7 999 992 192 B/s on `vck190_fmcp1`), and
the AXI DMA side runs at the same 8.0 GB/s (`dp_clk` × 32 bytes). That is above what a PCIe
Gen4 x4 SSD writes, and on `zcu106_hpc0` HP2 (5.16 GB/s, section 7) limits first.

On `vck190_fmcp1`, where the path into DDR carries the full rate, the fabric itself is the
next ceiling: `src_clk` and `dp_clk` are the same frequency, so at 8000 MB/s the source offers a
beat on every `dp_clk` cycle and the DMA side has no spare cycle to catch up. Every cycle in
which the DMA takes no beat (its descriptor fetch at a buffer boundary, NoC or DDR
back-pressure) leaves a beat in the ingest FIFO for the rest of the recording. Measured
without an SSD: at 8000 MB/s the FIFO filled to 7634 of 8192 beats in the first second and
then lost ~8 beats at every 8 MiB buffer boundary, although the DMA delivered 7.99 GB/s; at
7750 MB/s (97 % of a beat per clock) it drains between boundaries (high-water mark 10-164
beats), and recording is lossless. Playback is the mirror image: a sink at one beat per clock
cannot let the 4096-beat egress FIFO refill after an MM2S pause, so playback from the ring is
clean at 7500 MB/s and counts a few underflow ticks from 7750 MB/s (1285-1372 per 256 MiB).
**The sustainable fabric rates on Versal are therefore 7750 MB/s for recording and 7500 MB/s
for playback**, while the 8000 MB/s maximum is an instantaneous rate.

Ways past it:

* A `dp_clk` faster than `src_clk` (for example 300 MHz on the DMA side with the source and
  sink at 250 MHz) gives the DMA side drain headroom, so a source at one beat per clock no
  longer loses beats after a pause. The timing margin of the recorder on Versal is thin at
  250 MHz (`dp_clk` WNS +0.198 ns, `src_clk` +0.122 ns; the critical paths are the ingest
  FIFO's block-RAM address lines, see [Architecture](architecture.md#versal-designs)), so this
  needs work on those paths. It is not implemented.
* A 512-bit datapath raises the instantaneous maximum to 16 GB/s, but it only pays once the
  host's path into DDR carries more than ~8 GB/s; today it carries ~7.2-7.6 GB/s of writes
  (section 7), below the 7750 MB/s the fabric already sustains.

### 9. How to get more

On every target:

* SSDs without an SLC cliff: drives designed for sustained writes (enterprise, industrial,
  MLC or SLC flash), or larger capacities with a bigger cache. See
  [supported SSDs](supported_ssds.md#choosing-ssds-for-recording).
* RAID0 of two good, identical drives.
* A larger ring for the drives' write stalls at high rates: `--buffers 64` (64 x 8 MB) or
  `--buf-size 16M` (32 x 16 MB), both 512 MB, the whole default hugepage pool; more needs a
  larger pool reserved at boot (`hugepages=` on the kernel command line).
* NVMe APST off against the stall at the start of a recording after idle time (see
  [Start-up stalls and the ring size](#start-up-stalls-and-the-ring-size); measured on
  `vck190_fmcp1` with the Sabrent pair). The image keeps the kernel's default, APST on.
* SSDs that expose several NVMe I/O queues.

Zynq UltraScale+:

* RAID0 is the way past the ~2.94-3.04 GB/s that one Gen3 x4 slot writes.
* `--buffers 64` on RAID0 above ~3.5 GB/s with the Sabrent pair and above ~4.5 GB/s with the
  980 PRO pair (4500 and 5000 MB/s clean on `zcu106_hpc0`, against 3500 and 4500 MB/s with the
  default ring).
* MaxPayload 256 bytes (section 6) for single-drive playback above ~3 GB/s (one 980 PRO:
  3500 MB/s).
* Playback from a RAID0 pair above ~4 GB/s: a reader with more than one thread (not
  implemented).
* Past HP2 (~5.0 GB/s): a second AXI DMA on a second HP port with a two-channel driver (not
  implemented), or a Versal target.

Versal:

* MaxPayload 256 bytes (section 6) for single-drive playback above ~6 GB/s, with drives that
  read faster than the link carries at 128 bytes (one 980 PRO: 6500 MB/s; not the Sabrent).
* `--buf-size 16M` on RAID0 above ~4 GB/s with the Sabrent pair (or APST off) and above
  ~6.5 GB/s with the 980 PRO pair (7000 MB/s clean with both).
* Playback from a RAID0 pair above ~5.5-6 GB/s: a reader with more than one thread (not
  implemented).
* Past the shared PCIe NoC port (~7.2-7.6 GB/s write, ~7.9-8.0 GB/s read): one NoC port per
  PCIe bridge (not implemented).
* Past the fabric's 7750 / 7500 MB/s: a faster `dp_clk` than `src_clk`; 512 bits only once the
  host path exceeds ~8 GB/s (section 8).

**Beyond the Linux I/O path.** The CPU and the kernel's I/O path are in the data path of every
recording here (sections 2 and 7). Without them: Opsero's
[fpga-drive-nvme-offload](https://offload.fpgadrive.com) builds and issues the NVMe commands
in fabric logic, through the AMD NVMe Host Accelerator IP (which needs a license), with no CPU
in the data path, on the same boards, FMC cards and source / sink insertion points; its own
datapath and its measured limits are on its documentation site. Hardware NVMe host IP is also
available from Missing Link Electronics: see their
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).
