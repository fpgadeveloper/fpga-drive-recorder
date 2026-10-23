# Known limitations

## Positioning

The FPGA Drive Recorder is a zero-copy recording solution: Linux owns the SSD and the
filesystem, and the processor only does bookkeeping while the data moves from the fabric to
the SSD without being copied by the CPU. It is not a fabric NVMe host engine: every write
and read goes through the Linux block layer, the NVMe driver and the filesystem, so the
recorder needs a running Linux system, and its rate is bounded by the SSDs and by the Linux
I/O path (see [Where the bottlenecks are](benchmarks.md#where-the-bottlenecks-are)). On the
Zynq UltraScale+ targets the PCIe Root Ports are Gen3 x4, so a fast Gen4 SSD writes at most
~2.9-3.0 GB/s per slot, the rate of the Gen3 x4 link (inside its cache one Sabrent Rocket 2230
1TB records 2500 MB/s, one Samsung 980 PRO 1TB 3000 MB/s); RAID0 of two SSDs records 3500 MB/s
(Sabrent) or 4500 MB/s (980 PRO), 4500 / 5000 MB/s with a 512 MB buffer ring. On the Versal
target `vck190_fmcp1` the Root Ports are Gen4 x4: one drive records 4500 MB/s inside its cache
(either drive), a RAID0 pair 6500 MB/s (980 PRO) or 4000 MB/s (Sabrent), 7000 MB/s with a 512 MB
ring (both).

For operation without the CPU in the data path, see Opsero's
[fpga-drive-nvme-offload](https://offload.fpgadrive.com) (a fabric NVMe host design for the same
boards, with a licensed AMD IP) or Missing Link Electronics'
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).

## Rate ceilings

Measured on `zcu106_hpc0` and `vck190_fmcp1`; the figures, what sets each ceiling and how to
get past it are in [Where the bottlenecks are](benchmarks.md#where-the-bottlenecks-are).

* **Zynq UltraScale+** (`zcu106_hpc0`, `uzev`): one PCIe Gen3 x4 slot, ~2.9-3.0 GB/s writing
  and ~3.1-3.2 GB/s reading (~3.55 GB/s at 256-byte MaxPayload); playback from a RAID0 file by
  one `fdplay` thread on a Cortex-A53, 3500-4000 MB/s; the AXI DMA's port into DDR
  (`S_AXI_HP2_FPD`, 128 bits at 322.19 / 327.77 MHz, 5.16 / 5.24 GB/s peak), ~5000 MB/s in
  either direction, reached with SSDs by the 980 PRO pair. The host's own write path is not a
  ceiling below the two slots (fio writes a RAID0 pair at 6.07 GB/s).
* **Versal** (`vck190_fmcp1`): the drives (in their cache one 980 PRO writes ~4.95-4.98 GB/s,
  one Sabrent ~4.6 GB/s and reads ~4.5 GB/s); PCIe Gen4 x4 reads of ~6.36 GB/s per link at the
  default 128-byte MaxPayload (~7.07 GB/s at 256 bytes); the PCIe path into DDR that both Root
  Ports share, ~7.2-7.6 GB/s writing and ~7.9-8.0 GB/s reading; the host I/O path of the two
  Cortex-A72 cores, RAID0 recording up to 7000 MB/s (with 16 MB buffers) and playback from a
  file 5500-6000 MB/s; the fabric datapath, 7750 MB/s recording and 7500 MB/s playback (see
  below).
* On both, a recording that starts after idle time at a high rate can lose data in its first
  writes while the drives wake from NVMe APST power saving, which the image leaves on (the
  kernel's default): use a 512 MB buffer ring or turn APST off (see
  [Start-up stalls](benchmarks.md#start-up-stalls-and-the-ring-size)).

## Data path

* **256-bit stream.** The source and sink interfaces are 256-bit AXI4-Stream (`DATA_WIDTH`
  256; 128 is a build option), recorded and played back in whole 32-byte beats. Narrower data
  must be packed into 256-bit beats (see [custom data source](custom_source)); a partly filled
  last beat is not recorded.
* **No drain headroom at the full rate.** `src_clk` and `dp_clk` are both 250 MHz, so a source
  or a sink at one beat per clock (8000 MB/s) leaves the DMA side no spare cycle to catch up
  after a pause at a buffer boundary. Without an SSD, the fabric records losslessly up to
  7750 MB/s and plays back up to 7500 MB/s on `vck190_fmcp1`; on the Zynq UltraScale+ targets
  the port into DDR limits first (see
  [The fabric datapath](benchmarks.md#8-the-fabric-datapath)). A `dp_clk` faster than
  `src_clk` would give the DMA side that headroom; it is not implemented.
* **No backpressure to the source.** By design, the source is never stalled. When the SSDs
  cannot keep up, beats are dropped at the ingest FIFO and counted; a recording is valid only
  if its drop count is 0. There is no mode that pauses the source instead.
* **No framing or timestamps.** The recorder adds no headers, markers or timestamps to the
  data; only the file header records the start and stop times. Put frame markers or
  timestamps into the data in your source if you need them.
* **One stream, one direction at a time.** The design has one `fdrec_core` and one AXI DMA. `/dev/fdrec0` has one opener at a time, and the
  driver runs record or playback, not both; `fdrec` and `fdplay` cannot run simultaneously.
* **The playback sink shares the source clock.** `user_data_sink` runs on `src_clk`; a sink
  with its own clock needs its own clock-domain crossing inside the hierarchy (see
  [custom data sink](custom_sink)).
* **FIFO depth and buffer boundaries.** The AXI DMA runs from one buffer into the next
  without a software restart: the driver keeps the next two buffers appended to its running
  descriptor chain, through a `xilinx_dma` kernel patch in `meta-fdrec` (see
  [Kernel driver](driver.md)). At a boundary the ingest and egress FIFOs therefore only
  bridge the DMA's own descriptor fetch and short DDR back-pressure; the 256 KB ingest FIFO
  (8192 beats of 32 bytes) lasts 32 µs at the 8 GB/s source maximum and the 128 KB egress FIFO
  16 µs. Two conditions remain. The DMA completion interrupt recycles the buffers and must be
  handled within two buffer periods (2.1 ms at 8 GB/s with 8 MiB buffers), or the chain runs
  out and the DMA
  waits as if no buffer were free. And `xilinx_dma` appends only while its descriptor ring is
  in order (the driver renews the DMA channels after every stop to keep it so); otherwise it
  falls back to restarting the DMA from its interrupt handler, and the pause at each
  boundary is the interrupt latency again, which on a Cortex-A53 target is rarely several
  hundred µs, more than the FIFO covers. A kernel built without the patch behaves like that
  fallback. A design with a higher stream rate needs deeper FIFOs (`FIFO_DEPTH`,
  `EGR_FIFO_DEPTH`; the FIFOs use block RAM, as `xpm_fifo_async` cannot use UltraRAM).

## Software

* **Buffers.** At most 64 buffers per open file, each a multiple of 2 MB and at most 62 MB,
  allocated from the hugepage pool reserved at boot (512 MB by default).
* **Filesystem.** The output file must be on a filesystem that supports `O_DIRECT` (XFS and
  ext4 do; tmpfs does not). Sizes are rounded to 4096 bytes.
* **fdverify checks the test pattern only.** It verifies recordings made with the test
  pattern generator. For your own data source it checks the header, and the drop count tells
  you whether data was lost; checking the content is up to your tools. The same holds for
  playback with your own sink (`fdplay --no-check`).
* **RAID0 needs re-assembly after a reboot.** The image does not assemble or mount the array
  at boot; see [Applications](apps.md#fdsetup-raid0sh).

## Platforms and tools

* **Targets.** The design is available for the targets in the
  [target table](build_instructions.md#target-designs). Further Zynq UltraScale+ and Versal
  targets are being added.
* **Linux only.** There is no standalone (baremetal) application and no PetaLinux flow; the
  Linux image is built with the Yocto / EDF flow, which needs a native Linux build machine.
* **Tool version.** The repository is for Vivado / Vitis / EDF 2025.2.
