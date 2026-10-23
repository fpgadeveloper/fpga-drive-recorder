# Supported SSDs

## Compatibility

The [FPGA Drive FMC Gen4] and [M.2 M-key Stack FMC] support M.2 M-key NVMe SSDs of PCIe
Gen1 to Gen4. The recorder uses the SSDs through the standard Linux NVMe driver, so any SSD
that works with the [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
reference design under Linux also works with this design. That design's documentation keeps
the longer [list of tested SSDs](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie/blob/master/docs/source/supported_ssds.md).
An SSD that supports a higher PCIe generation than the design links at the design's speed:
the Zynq UltraScale+ targets (`uzev`, `zcu106_hpc0`) have Gen3 x4 Root Ports, the Versal target
`vck190_fmcp1` has Gen4 x4 Root Ports.

## SSDs tested with the recorder

| SSD (brand and model) | Capacity | Firmware | Used for | Tested on (PCIe link) |
|-----------------------|----------|----------|----------|-----------------------|
| Samsung 970 EVO       | 250 GB   | 1B2QEXE7 | single drive, RAID0, playback | `uzev`, `vck190_fmcp1`, `zcu106_hpc0` (Gen3 x4) |
| Samsung 950 PRO       | 256 GB   | 1B0QBXX7 | single drive, RAID0, playback | `uzev`, `vck190_fmcp1`, `zcu106_hpc0` (Gen3 x4) |
| Sabrent Rocket 2230   | 1 TB     | R21B47.1 | single drive, RAID0 (two drives), playback | `vck190_fmcp1` (Gen4 x4); `zcu106_hpc0` (Gen3 x4, a Gen4 drive) |
| Samsung 980 PRO       | 1 TB     | 5B2QGXA7 | single drive, RAID0 (two drives), playback | `zcu106_hpc0` (Gen3 x4, a Gen4 drive); `vck190_fmcp1` (Gen4 x4) |

The Sabrent Rocket 2230 1TB (`nvme id-ctrl`: `Sabrent SB-2130-1TB`; Phison PS5021-E21T
controller, DRAM-less, with a 64 MiB host memory buffer from the driver) is an M.2 2230 drive;
it was measured on the M.2 M-key Stack FMC. The Samsung 980 PRO 1TB was measured on the FPGA
Drive FMC Gen4. Each pair was measured on both `vck190_fmcp1` and `zcu106_hpc0`.

**PCIe generation.** Both 1 TB drives are Gen4 drives. On the VCK190's Gen4-capable QDMA Root
Ports they link at **Gen4 x4** (16 GT/s, `LnkSta` of both the Root Port and the SSD). On the
Zynq UltraScale+ Root Ports both link at Gen3 x4 (`lspci`:
`Speed 8GT/s (downgraded), Width x4`), as expected. The 970 EVO and 950 PRO are Gen3 drives and
link at Gen3 x4 on every target. On the Zynq UltraScale+ targets a fast Gen4 drive runs at the
Gen3 x4 link's rate inside its cache: measured on `zcu106_hpc0`, ~2.94 GB/s writing and
2.8-3.1 GB/s reading per slot with the Sabrent Rocket 2230 1TB, ~3.04 GB/s writing and
~3.1-3.2 GB/s reading with the Samsung 980 PRO 1TB (~3.55 GB/s reading at 256-byte PCIe
MaxPayload). On the Gen4 x4 Root Ports of `vck190_fmcp1` one Samsung 980 PRO 1TB writes
~4.95-4.98 GB/s inside its cache and reads ~6.36 GB/s at the default 128-byte MaxPayload
(~7.07 GB/s at 256 bytes, see [Benchmarks](benchmarks.md#6-the-pcie-links-and-maxpayload)); one
Sabrent Rocket 2230 1TB writes ~4.6 GB/s inside its cache and reads its data at ~4.5 GB/s, below
what its link carries, so MaxPayload 256 bytes does not change it.

**NVMe I/O queues.** On every board tested, the Linux NVMe driver set the 970 EVO 250GB up with
a single I/O queue (`nvme nvme0: 1/0/0 default/read/poll queues` in `dmesg`), whereas the other
drives got one queue per CPU core: the 950 PRO two to four, and both the Sabrent Rocket 2230
1TB and the Samsung 980 PRO 1TB four on the four-core ZCU106 (`4/0/0`, both slots) and two on
the two-core VCK190 (`2/0/0`). The cause of
the 970 EVO's single queue was not investigated; it is behaviour of this drive's firmware or
controller, not of the design. With one queue, all of
the drive's completions are handled on one CPU core (see
[Where the bottlenecks are](benchmarks.md#3-the-nvme-queue-count)).

The measured rates of the two 1 TB drives, alone and as RAID0 pairs, on `vck190_fmcp1` and
`zcu106_hpc0`, are on the [Benchmarks](benchmarks) page.

## Choosing SSDs for recording

Compatibility is rarely the issue; the **sustained write rate** is. A recorder writes at a
constant rate for as long as the recording lasts, and the SSD must keep up the whole time,
or beats are dropped. The rate printed on an SSD's datasheet is usually not that rate:

* **SLC write cache.** Most consumer SSDs with TLC or QLC flash write into a fast
  pseudo-SLC cache first and fold the data into the slower flash later. While the cache
  lasts, the SSD writes at its datasheet rate; once it is full, the rate drops, sometimes
  to a fraction. The size of the cache depends on the model, the capacity and how full the
  drive is. Measured on an empty, trimmed drive:

  | SSD | cache | write rate after the cache |
  |---|---|---|
  | Sabrent Rocket 2230 1TB | about 66-75 GB (on both boards), written at ~4.6 GB/s on `vck190_fmcp1` (Gen4 x4) and ~2.9 GB/s on `zcu106_hpc0` (the Gen3 x4 link's rate); about 140 GB for a RAID0 pair | a flat ~1.8 GB/s per drive (median 1799-1806 MB/s; ~3.6 GB/s for the pair) |
  | Samsung 980 PRO 1TB | about 115-125 GB (on both boards), written at ~4.95-4.98 GB/s on `vck190_fmcp1` (Gen4 x4) and ~3.0 GB/s on `zcu106_hpc0` (the Gen3 x4 link's rate); about 245 GB for a RAID0 pair | a flat ~1.77 GB/s per drive (~3.46-3.49 GB/s for the pair) |

  On smaller drives the cliff can be steep: Samsung rates the 970 EVO 250GB at 300 MB/s once
  its TurboWrite cache is full.

* **Size your test to your recordings.** A short test (a few GB, such as the `dd` speed
  tests) measures the cache. Use `fdbench.sh` with a recording size at least as long as
  your longest recording (default 32 GB per step) to find the rate you can sustain. 32 GB
  runs past the cache of many smaller drives, but stays inside the cache of the 1 TB
  drives: there it gives an in-cache rate. To find a rate that holds past the cache,
  confirm it with one recording of about twice the cache (`fdrec --size`), after
  `fstrim` and a few minutes of idle.
* **What "sustained" means for a large drive.** If your recordings are shorter than the cache,
  the in-cache rate applies, but only when the cache is empty at the start: it empties while
  the drive is idle, at a rate that was not measured, so do not count on it between
  back-to-back recordings. If they are longer, the post-cache rate applies. On the 1 TB drives
  measured here it limited one drive to 1750 MB/s, just below the post-cache rate
  (~1.77-1.8 GB/s), with either drive on either board, over 200-240 GiB (at the in-cache top the
  recording drops at the cache end: 80.25 GB with one Sabrent Rocket 2230 1TB, 116.78 GB with
  one Samsung 980 PRO 1TB on `zcu106_hpc0`). RAID0 pairs held 3000-3500 MB/s over 350-480 GiB:
  the Sabrent pair 3500 MB/s on `vck190_fmcp1` and 3000 MB/s on `zcu106_hpc0`, the 980 PRO pair
  3250 MB/s on both boards. Inside the cache one drive records 4500 MB/s over 32 GB on the
  Gen4 x4 slots of `vck190_fmcp1` (the 980 PRO writes ~4.95-4.98 GB/s, the Sabrent ~4.6 GB/s),
  and on the Gen3 x4 slots of `zcu106_hpc0` one Sabrent 2500 MB/s and one 980 PRO 3000 MB/s
  (the link carries ~2.94 / ~3.04 GB/s).
  See [Benchmarks](benchmarks.md#long-recordings-past-the-slc-cache).
* **Free space and trim.** An SSD with little free space, or one that has not been trimmed,
  has less room for its cache and for garbage collection. Keep the recording filesystem
  empty enough, and trim it between recordings (`fstrim`, see the note on its timing in
  [Benchmarks](benchmarks.md#start-up-stalls-and-the-ring-size)).
* **Power saving.** NVMe drives with APST power saving (on by default in Linux) may sleep
  deeply after idle time, and the first writes of a recording then complete late. With two
  Sabrent Rocket 2230 1TB in RAID0 on `vck190_fmcp1` that cost data at 4500-5000 MB/s with the
  default buffer ring; a 512 MB ring or APST off removed it (see
  [Benchmarks](benchmarks.md#start-up-stalls-and-the-ring-size)).
* **RAID0.** Two SSDs striped as RAID0 add up their rates, but every chunk of the stripe
  goes to both drives in turn, so the array is limited by the slower drive: twice the
  slower drive's sustained rate. Use two identical SSDs. On `zcu106_hpc0` RAID0 is also the
  way past the ~2.94-3.04 GB/s that one Gen3 x4 slot writes: the Sabrent pair records 32 GB at
  3500 MB/s (4500 MB/s with 64 buffers), 10 GB at 4000 MB/s and 350 GiB at 3000 MB/s, where one
  drive records 2500 MB/s; the 980 PRO pair records 32 GB at 4500 MB/s (5000 MB/s with 64
  buffers), 10 and 40 GB at 5000 MB/s and 350 GiB at 3250 MB/s, where one drive records
  3000 MB/s (see [Benchmarks](benchmarks.md#burst-and-40-gb-recordings)).
* **Heat.** Long recordings at high rates heat the SSD controller, and many SSDs throttle
  when they get hot. Give the SSDs airflow, or a heatsink, for long recordings, and check
  the temperature with `nvme smart-log`. With a fan on the cards, the Sabrent Rocket 2230 1TB
  reached at most 66 °C on `zcu106_hpc0` and 62 °C on `vck190_fmcp1`, the 980 PRO 1TB 52 °C on
  `zcu106_hpc0` and 50 °C on `vck190_fmcp1` (composite), in 300-500 GiB writes, with no
  throttling.

Drives designed for sustained writes (SLC or MLC flash, enterprise and industrial drives,
or simply larger capacities with a bigger cache) give higher sustained rates.

You can help us maintain this list by communicating [your experiences] to us or by
contributing to the documentation on our [Github repo].

[your experiences]: https://opsero.com/contact-us
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[Github repo]: https://github.com/fpgadeveloper/fpga-drive-recorder
