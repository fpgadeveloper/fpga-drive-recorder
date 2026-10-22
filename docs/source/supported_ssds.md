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
Gen3 x4 link's rate inside its cache: ~2.94-3.04 GB/s writing and ~2.9-3.2 GB/s reading per
slot, measured with both 1 TB drives on `zcu106_hpc0`.

**NVMe I/O queues.** On every board tested, the Linux NVMe driver set the 970 EVO 250GB up with
a single I/O queue (`nvme nvme0: 1/0/0 default/read/poll queues` in `dmesg`), whereas the other
drives got one queue per CPU core: the 950 PRO two to four, and both 1 TB drives four on the
four-core ZCU106 (`4/0/0`, both slots) and two on the two-core VCK190 (`2/0/0`). The cause of
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
  | Sabrent Rocket 2230 1TB | about 70-75 GB on `vck190_fmcp1` at ~4.5 GB/s and ~69-70 GB on `zcu106_hpc0` at ~2.9 GB/s (the Gen3 x4 link's rate); about 136-143 GB for a RAID0 pair on `vck190_fmcp1` | a flat ~1.8 GB/s on both boards (~3.6 GB/s for the pair on `vck190_fmcp1`) |
  | Samsung 980 PRO 1TB | about 115-125 GB on both boards, at ~4.7 GB/s or more on `vck190_fmcp1` and ~3.0 GB/s on `zcu106_hpc0` (the Gen3 x4 link's rate); about 245-250 GB for a RAID0 pair | a flat ~1.77 GB/s per drive on both boards (~3.46 GB/s for the pair on `vck190_fmcp1`; ~3.3 GB/s on `zcu106_hpc0`, partly limited by fio) |

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
  measured here it limited one drive to 1750 MB/s, the post-cache rate (~1.77-1.8 GB/s)
  rounded down to a 250 MB/s step, for both drives on both boards: one Sabrent Rocket 2230 1TB
  over 143 GiB and 200 GiB on `vck190_fmcp1` and over 200 GiB on `zcu106_hpc0`, one Samsung
  980 PRO 1TB over 219 GiB and 240 GiB on `vck190_fmcp1` and over 200 GiB and 222 GiB on
  `zcu106_hpc0` (in every case 2000 MB/s dropped just past the cache). RAID0
  pairs held 3200 MB/s, the generator maximum, on both boards with both drives: over 350 GiB
  (the Sabrent pair on both boards, the 980 PRO pair on `zcu106_hpc0`) and over 480 GiB (the
  980 PRO pair on `vck190_fmcp1`). Inside the cache, on the Gen3 x4 slots of `zcu106_hpc0`, one
  980 PRO records 3000 MB/s and one Sabrent 2750 MB/s; at 3000 MB/s the Sabrent falls behind
  (all writes of its queue in flight, ~2.94 GB/s on the Gen3 x4 link).
  See [Benchmarks](benchmarks.md#long-recordings-past-the-slc-cache).
* **Free space and trim.** An SSD with little free space, or one that has not been trimmed,
  has less room for its cache and for garbage collection. Keep the recording filesystem
  empty enough, and trim it between recordings (`fstrim`, see the note on its timing in
  [Benchmarks](benchmarks.md#the-fstrim-finding-and-the-ring-size)).
* **RAID0.** Two SSDs striped as RAID0 add up their rates, but every chunk of the stripe
  goes to both drives in turn, so the array is limited by the slower drive: twice the
  slower drive's sustained rate. Use two identical SSDs. On `zcu106_hpc0` RAID0 is also the
  way past the ~2.94-3.04 GB/s that one Gen3 x4 slot writes: either pair records 10 GB, 32 GB,
  40 GB and 350 GiB at the generator's 3200 MB/s (see
  [Benchmarks](benchmarks.md#burst-and-40-gb-recordings)).
* **Heat.** Long recordings at high rates heat the SSD controller, and many SSDs throttle
  when they get hot. Give the SSDs airflow, or a heatsink, for long recordings, and check
  the temperature with `nvme smart-log`. With a fan on the cards, the Sabrent Rocket 2230 1TB
  reached at most 66 °C and the 980 PRO 1TB 52 °C (composite, both on `zcu106_hpc0`; 61 °C and
  50 °C on `vck190_fmcp1`), in 300-500 GiB writes, with no throttling.

Drives designed for sustained writes (SLC or MLC flash, enterprise and industrial drives,
or simply larger capacities with a bigger cache) give higher sustained rates.

You can help us maintain this list by communicating [your experiences] to us or by
contributing to the documentation on our [Github repo].

[your experiences]: https://opsero.com/contact-us
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[Github repo]: https://github.com/fpgadeveloper/fpga-drive-recorder
