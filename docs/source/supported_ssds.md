# Supported SSDs

## Compatibility

The [FPGA Drive FMC Gen4] and [M.2 M-key Stack FMC] support M.2 M-key NVMe SSDs of PCIe
Gen1 to Gen4. The recorder uses the SSDs through the standard Linux NVMe driver, so any SSD
that works with the [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
reference design under Linux also works with this design. That design's documentation keeps
the longer [list of tested SSDs](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie/blob/master/docs/source/supported_ssds.md).
An SSD that supports a higher PCIe generation than the design links at the design's speed.

## SSDs tested with the recorder

| SSD (brand and model) | Capacity | Firmware | Used for |
|-----------------------|----------|----------|----------|
| Samsung 970 EVO       | 250 GB   | 1B2QEXE7 | single drive, RAID0, playback |
| Samsung 950 PRO       | 256 GB   | 1B0QBXX7 | single drive, RAID0, playback |

The measured rates of both drives, alone and as a RAID0 pair, are on the
[Benchmarks](benchmarks) page.

## Choosing SSDs for recording

Compatibility is rarely the issue; the **sustained write rate** is. A recorder writes at a
constant rate for as long as the recording lasts, and the SSD must keep up the whole time,
or beats are dropped. The rate printed on an SSD's datasheet is usually not that rate:

* **SLC write cache.** Most consumer SSDs with TLC or QLC flash write into a fast
  pseudo-SLC cache first and fold the data into the slower flash later. While the cache
  lasts, the SSD writes at its datasheet rate; once it is full, the rate drops, sometimes
  to a fraction. The size of the cache depends on the model, the capacity and how full the
  drive is. On the 970 EVO 250GB above, the cache lasts about 14 GB on an empty, trimmed
  drive, then the write rate falls to about 330 MB/s; on the 950 PRO 256GB no comparable
  cliff was seen: it writes at about 955 MB/s throughout.
* **Size your test to your recordings.** A short test (a few GB, such as the `dd` speed
  tests) measures the cache. Use `fdbench.sh` with a recording size at least as long as
  your longest recording (default 32 GB per step) to find the rate you can sustain.
* **Free space and trim.** An SSD with little free space, or one that has not been trimmed,
  has less room for its cache and for garbage collection. Keep the recording filesystem
  empty enough, and trim it between recordings (`fstrim`, see the note on its timing in
  [Benchmarks](benchmarks.md#the-fstrim-finding-and-the-ring-size)).
* **RAID0.** Two SSDs striped as RAID0 add up their rates, but every chunk of the stripe
  goes to both drives in turn, so the array is limited by the slower drive: twice the
  slower drive's sustained rate. Use two identical SSDs.
* **Heat.** Long recordings at high rates heat the SSD controller, and many SSDs throttle
  when they get hot. Give the SSDs airflow, or a heatsink, for long recordings, and check
  the temperature with `nvme smart-log`.

Drives designed for sustained writes (SLC or MLC flash, enterprise and industrial drives,
or simply larger capacities with a bigger cache) give higher sustained rates.

You can help us maintain this list by communicating [your experiences] to us or by
contributing to the documentation on our [Github repo].

[your experiences]: https://opsero.com/contact-us
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[Github repo]: https://github.com/fpgadeveloper/fpga-drive-recorder
