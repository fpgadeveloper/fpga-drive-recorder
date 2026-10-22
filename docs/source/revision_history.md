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
* zcu106_hpc0, uzev: HP-port clock fix (2026-10-18). In the first release, the XDMA Root Ports
  reached the PS DDR through `S_AXI_HP0_FPD` and `S_AXI_HP1_FPD`, which, with the HP-port side of
  their interconnects, were clocked from `pl_clk0` at 99.99 MHz. A 128-bit port at that clock
  carries at most 1.6 GB/s, so one SSD slot was capped at ~1.57-1.60 GB/s, writing and reading,
  whatever the drive. HP0/HP1 and the HP-port side of their interconnects now run on `pl_clk1`
  (250 MHz), which gives 4.0 GB/s per port, on both `zcu106_hpc0` and `uzev`. Timing is met
  (WNS +0.226 ns on `zcu106_hpc0`, +0.133 ns on `uzev`), at a cost of ~70-110 LUTs and no
  additional block RAM. Measured on `zcu106_hpc0` (2026-10-19), a Gen3 x4 slot now writes
  ~2.95-3.04 GB/s and reads ~2.9-3.2 GB/s, the rate of the PCIe link: for example, one Samsung
  980 PRO 1TB records 32 GB at 3000 MB/s instead of 1500 MB/s, and plays back at 2250 MB/s
  instead of 1250 MB/s. The underflows of fast RAID0 playback within minutes of a recording,
  seen with the first release, disappeared with the fix. The base design
  [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie) has the same
  HP-port clocking; the fix is to follow there.
* Driver: the AXI DMA channel interrupts are pinned at probe to the last online CPU (module
  parameter `dma_irq_cpu`, 2026-10-20). On Zynq UltraScale+ the NVMe completions of the PL
  root ports are all handled on CPU0 in bursts of up to ~0.8 ms, and a DMA restart interrupt on
  the same CPU waited behind them: one 980 PRO 1TB on `zcu106_hpc0` under-ran its playback at
  2500-2750 MB/s in almost every run, and long RAID0 recordings lost beats at buffer
  boundaries from 2750 MB/s. With the fix the same drive plays back at the 3.2 GB/s sink
  maximum (52 of 52 runs, single and RAID0).
* Hardware: ingest FIFO 4096 -> 16384 beats (64 KB -> 256 KB; `FIFO_DEPTH`, 2026-10-20), so the
  FIFO covers 82 µs of DMA restart at 3.2 GB/s instead of 20 µs. The egress FIFO stays at
  4096 beats. Measured over 350 GiB RAID0 recordings: `vck190_fmcp1` (Sabrent Rocket 2230 1TB
  pair) clean at 2750, 3000 and 3200 MB/s (before: 2750); `zcu106_hpc0` (980 PRO pair) clean at
  2750 MB/s (before: 2500), 3000 and 3200 MB/s still lose beats once in a few hundred GB to a
  rare 120-240 µs restart. Cost: 42.5 more block RAM tiles on `zcu106_hpc0` (114 to 156.5 of
  312, WNS +0.253 ns); `uzev` 156.5 of 312 (+0.045 ns), `vck190_fmcp1` 166 of 967 (+0.079 ns). The
  register map stays at 1.1 (`ING_FIFO_DEPTH` reports the depth; no software change). The
  figures measured with these changes and driver 1.1 are in the git history of the
  documentation; the [Benchmarks](benchmarks.md) page now gives driver 1.2 figures (below).
* Driver 1.2 and `xilinx_dma` kernel patch
  `0002-dmaengine-xilinx_dma-append-descriptors-to-a-running-SG-chain.patch` (2026-10-21): the AXI DMA
  now runs across buffer boundaries without a software restart. Until driver 1.1 the driver
  kept one active and one pending descriptor in `xilinx_dma`, and the stock `xilinx_dma`
  started the pending one from its interrupt handler when the active one completed, so the
  DMA paused at every boundary for the interrupt latency plus the restart: about 9 µs, with a
  15-20 µs tail, but on `zcu106_hpc0` (Cortex-A53) rarely 120-415 µs, more than the
  16384-beat ingest FIFO covers (82 µs at 3.2 GB/s): long RAID0 recordings at 2500-3200 MB/s
  lost 8085-54 968 beats at one boundary once in a few hundred GB (five events in eleven
  350 GiB runs and one in a 32 GB run). A kernel trace of the S2MM interrupt showed these to
  be late interrupt delivery, not a slow handler: the CPU that owns the DMA interrupts runs
  ordinary kernel code with interrupts disabled for 90-660 µs (bulk page frees from the block
  softirq, the periodic memory-cgroup statistics flush). The kernel patch appends a descriptor issued while
  the channel runs to the running scatter-gather chain by moving `TAILDESC`, as AMD's
  bare-metal driver does, and the driver keeps three descriptors in the chain
  (`FDREC_DMA_DEPTH` 2 -> 3), which gives the buffer recycling two buffer periods of slack.
  The register map and the hardware are unchanged (same `BOOT.BIN`). Re-measured with
  driver 1.2 on 2026-10-21: the full benchmark matrix of both pairs, the Sabrent Rocket 2230 1TB
  and the Samsung 980 PRO 1TB, on both `vck190_fmcp1` and `zcu106_hpc0`. The ingest FIFO high-water mark is now a rate floor of
  1-7 beats (7 at 3000-3200 MB/s) in every clean recording from 4 GiB to 480 GiB, where it was
  700-16 363 beats before. Past the SLC cache every RAID0 pair records 3200 MB/s, the
  generator maximum: 350 GiB at 2500-3200 MB/s with the Sabrent pair on both boards (on
  `zcu106_hpc0` 2500 and 2750 MB/s lost beats before) and the 980 PRO pair on `zcu106_hpc0`
  (before: 2750 MB/s; 3000 and 3200 MB/s lost beats), and 480 GiB at 3000 and 3200 MB/s with
  the 980 PRO pair on `vck190_fmcp1` (high-water mark 7 beats throughout; before: 7112 and
  8896). One Sabrent on `vck190_fmcp1` is now clean at every 32 GB step up to 3200 MB/s and
  holds 1750 MB/s past its cache (before: 1000 MB/s, limited by rare ~0.65 s write stalls that
  did not recur in 54 recordings); its RAID0 pair is clean at every step (before: up to
  2750 MB/s in the 2026-10-17 sweep). The single-drive limits are the drives' and unchanged:
  1750 MB/s past the cache, and inside it on the Gen3 x4 slots of `zcu106_hpc0` 3000 MB/s
  (980 PRO) and 2750 MB/s (Sabrent). Playback reaches the 3.2 GB/s sink maximum in every
  configuration except one Sabrent on `zcu106_hpc0` (3000 MB/s, its slot's read rate); the
  isolated read stalls of one 980 PRO on `zcu106_hpc0` (2 of 17 runs on 2026-10-20) did not
  recur (17 of 17). In the four sessions no beat was lost at a buffer boundary for any reason
  other than the ring running out behind the drive.
* Documentation: this site, with generated block diagrams, the register map, the driver
  and file-format references, and the benchmarks.

### Documentation updates

* 2026-10-17 to 2026-10-19: benchmarks of two SSD pairs, the Sabrent Rocket 2230 1TB and the
  Samsung 980 PRO 1TB, each on `vck190_fmcp1` (Gen4 x4) and on `zcu106_hpc0` (Gen3 x4, measured
  with the HP-port clock fix), single drive and RAID0, in every benchmark table: 32 GB sweeps,
  burst and 40 GB recordings, long recordings past the SLC cache, playback, CPU load and the
  `dd` comparison. New: the in-cache vs post-cache distinction for drives whose SLC cache is
  larger than the 32 GB sweep step, the measured cache sizes and post-cache rates, the
  Sabrent's rare write stalls on `vck190_fmcp1`, late DMA restarts in long RAID0 recordings, and
  the open single-drive playback deficit of the 980 PRO 1TB on `zcu106_hpc0` at
  2500-2750 MB/s.
* 2026-10-19: the benchmarks now cover the two 1 TB pairs only, on both `vck190_fmcp1` and
  `zcu106_hpc0`. The figures of the older Samsung 970 EVO 250GB and 950 PRO 256GB drives, all
  `uzev` figures, and the `zcu106_hpc0` figures measured with the first-release HP-port
  clocking (with their comparison against the fix) were removed; they remain in the git
  history. What the older drives showed about themselves is kept as drive facts on
  [Supported SSDs](supported_ssds) and [Benchmarks](benchmarks): the 970 EVO's single NVMe I/O
  queue, its ~14 GB SLC cache and ~330 MB/s after it, and the 950 PRO's lack of a cache cliff.
* 2026-10-21: the benchmarks show only measurements made with driver 1.2. The earlier
  figures, including the measured cache figures of the Samsung 970 EVO 250GB and 950 PRO
  256GB, remain in the git history. The full four-combination matrix (the Sabrent Rocket 2230
  1TB and Samsung 980 PRO 1TB pairs, each on `vck190_fmcp1` and `zcu106_hpc0`, single drive
  and RAID0) is measured with driver 1.2 in every benchmark table: 32 GB sweeps, burst and
  40 GB recordings, long recordings past the SLC cache, playback, CPU load, the SLC cache and
  the `dd` comparison.
