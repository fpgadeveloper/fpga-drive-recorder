# Revision History

## v1.0 (2025.2)

Initial version of the FPGA Drive Recorder, built with Vivado / Vitis 2025.2 and the
Yocto / EDF 2025.2 flow (no PetaLinux flow, no standalone application). First target:
`uzev` (UltraZed-EV Carrier), based on the `uzev` design of
[fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie).

* Hardware: `user_data_source` (test pattern generator) and `user_data_sink` (hardware
  checker) insertion points; `fdrec_core` with the ingest FIFO and drop counter, the
  packetizer, the egress FIFO and the AXI-Lite register block (register map 1.1); AXI DMA
  with S2MM (record) and MM2S (playback) in scatter-gather mode; self-checking testbenches
  for the custom RTL.
* Linux: the `fdrec` kernel driver (user-space hugepage buffers pinned by the driver, one
  active + one pending DMA descriptor, `/dev/fdrec0`, sysfs counters), and the `fdrec`,
  `fdplay`, `fdverify`, `fdbench.sh` and `fdsetup-raid0.sh` tools, in the `meta-fdrec`
  Yocto layer; the `dd` speed-test scripts of fpga-drive-aximm-pcie for comparison.
* `fdrec` and `fdplay` default to 32 x 8 MB buffers and stop with a stall watchdog
  (`--timeout`, default 10 s); `fdsetup-raid0.sh --mount` chooses the mount point and
  creates it.
* Second target: `vck190_fmcp1` (VCK190, FMCP1, Versal, PCIe Gen4 x4 per slot), with the same
  recorder datapath.
* Third target: `zcu106_hpc0` (ZCU106, HPC0, Zynq UltraScale+, PCIe Gen3 x4 per slot).
* vck190_fmcp1: PCIe PIPE pipeline 2 stages (timing closure).
* zcu106_hpc0, uzev (2026-10-18): the HP ports through which the XDMA Root Ports reach the PS
  DDR (`S_AXI_HP0/1_FPD`) and the slave side of their interconnects are clocked from `pl_clk1`
  (250 MHz) instead of `pl_clk0` (99.99 MHz). This raises the per-port limit from 1.6 to
  4.0 GB/s and lifts the ~1.6 GB/s per-slot ceiling of the first release: measured on
  `zcu106_hpc0`, one Gen4 SSD now writes ~2.9-3.0 GB/s and reads ~2.9-3.2 GB/s per Gen3 x4 slot.
  Timing is met on both targets.
* Documentation: this site, with generated block diagrams, the register map, the driver
  and file-format references, and the benchmarks measured on `uzev`.

### Documentation updates

* 2026-10-17: benchmarks of two more SSD pairs: Sabrent Rocket 2230 1TB on `vck190_fmcp1` (the
  first Gen4 x4 link in this design) and Samsung 980 PRO 1TB on `zcu106_hpc0`, single and
  RAID0, in every benchmark table (32 GB sweeps, bursts, playback, CPU, `dd` comparison). New:
  the in-cache vs post-cache distinction for drives whose SLC cache is larger than the 32 GB
  sweep step, long recordings past the cache, measured cache sizes, the ~1.59 GB/s per-slot
  ceiling of the Zynq UltraScale+ Root Ports, the Sabrent's rare write stalls, late DMA restarts
  in long RAID0 recordings on `zcu106_hpc0`, and an observation on playback right after a
  recording. Each drive on the other board is pending.
* 2026-10-18: each 1 TB pair on the other board: Sabrent Rocket 2230 1TB on `zcu106_hpc0`
  (Gen3 x4) and Samsung 980 PRO 1TB on `vck190_fmcp1` (Gen4 x4), in every benchmark table,
  including the 980 PRO's post-cache rate (~1.77 GB/s) and long RAID0 recordings on the VCK190.
  The ~1.6 GB/s per-slot ceiling of the Zynq UltraScale+ targets is now explained: the HP ports
  between the XDMA Root Ports and the PS DDR (`S_AXI_HP0/1_FPD`) are clocked at 99.99 MHz; the
  Zynq UltraScale+ figures are marked as measured with that clock (pre-fix), and a fix is being
  validated. The playback-after-recording observation is limited to the one board and drive
  pair that showed it.
* 2026-10-19: the Sabrent Rocket 2230 1TB pair on `zcu106_hpc0` measured with the HP-port clock
  fix (HP0/HP1 at 250 MHz), in every benchmark table: 32 GB sweeps single 2750 / RAID0 3200 MB/s
  (the generator maximum), the drive's ~72 GB SLC cache and ~1.8 GB/s post-cache rate now
  visible, long recordings past the cache single 1750 / RAID0 2250 MB/s, bursts, playback, CPU
  (unchanged per MB). The ceiling section is now "The former Zynq UltraScale+ per-slot ceiling
  (fixed)", with the cause, the fix, a before/after table and what limits a slot now (the Gen3
  x4 link inside the cache, the drive past it, late DMA restarts in long RAID0 recordings).
  Figures measured with the old clock are marked †; the Samsung 980 PRO 1TB on `zcu106_hpc0`
  with the fix followed in a second update the same day, the `uzev` and 970 EVO / 950 PRO
  figures will not be re-measured.
* 2026-10-19: the Samsung 980 PRO 1TB pair on `zcu106_hpc0` measured with the HP-port clock fix,
  in every benchmark table: ~2.96 GB/s fio writes per slot (the Gen3 x4 link), 32 GB sweeps
  single 3000 / RAID0 3000 MB/s, the drive's ~115-120 GB SLC cache and ~1.77 GB/s post-cache
  rate now visible (as on `vck190_fmcp1`), long recordings past the cache single 1750 / RAID0
  2500 MB/s, bursts single 3000 / RAID0 3200 MB/s (40 GB), playback single 2250 / RAID0
  2250-3200 MB/s, CPU per MB unchanged. The pair's pre-fix figures are in a second before/after
  table of the ceiling section. The "playback soon after a recording" effect is gone with the
  fix (it was the per-slot ceiling); new open observation: one 980 PRO on `zcu106_hpc0`
  under-runs at 2500-2750 MB/s playback. Only the `uzev` and 970 EVO / 950 PRO figures remain
  marked †.
