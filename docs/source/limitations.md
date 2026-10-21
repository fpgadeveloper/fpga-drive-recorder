# Known limitations

## Positioning

The FPGA Drive Recorder is a zero-copy recording solution: Linux owns the SSD and the
filesystem, and the processor only does bookkeeping while the data moves from the fabric to
the SSD without being copied by the CPU. It is not a fabric NVMe host engine: every write
and read goes through the Linux block layer, the NVMe driver and the filesystem, so the
recorder needs a running Linux system, and its rate is bounded by the SSDs and by the Linux
I/O path (see [Where the bottlenecks are](benchmarks.md#where-the-bottlenecks-are)). On the
Zynq UltraScale+ targets the PCIe Root Ports are Gen3 x4, so a fast Gen4 SSD writes at most
~2.95-3.04 GB/s per slot, the rate of the Gen3 x4 link (one drive records up to
2750-3000 MB/s); RAID0 of two SSDs records at the generator's 3.2 GB/s inside the SLC cache.
On the Versal target
`vck190_fmcp1` the Root Ports are Gen4 x4, and one drive records at the generator's 3.2 GB/s
inside its SLC cache.

For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host IP is
available from Missing Link Electronics. See Missing Link Electronics'
[NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/).

## Data path

* **Fixed 128-bit stream.** The source and sink interfaces are 128-bit AXI4-Stream, recorded
  and played back in whole 16-byte beats. Narrower data must be packed into 128-bit beats
  (see [custom data source](custom_source)); a partly filled last beat is not recorded.
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
* **FIFO depth vs. the DMA restart gap.** At every buffer boundary the AXI DMA pauses while
  the driver's interrupt handler starts the next buffer: about 9 µs at every boundary with a
  15-20 µs tail on `zcu106_hpc0` (with the DMA interrupts on their own CPU, the driver's
  default). The 256 KB ingest FIFO covers 82 µs at the 3.2 GB/s source maximum and the 64 KB
  egress FIFO 20 µs. Rarely the restart takes much longer: in RAID0 recordings on
  `zcu106_hpc0` one boundary in a run took 120-415 µs at 2500-3200 MB/s and lost
  8085-54 968 beats (five such events in eleven 350 GiB runs and one in a 32 GB run, with
  either pair of drives); on `vck190_fmcp1` the longest boundary seen was 59 µs and
  2250-3200 MB/s were clean over 350 and 480 GiB (see
  [Benchmarks](benchmarks.md#5-latency-budgets-not-bandwidth)).
  So a long RAID0 recording at 2500 MB/s or more on a Zynq UltraScale+ target may still drop a
  few tens of thousands of beats once in a few hundred GB. Removing the software from the boundary path
  (a descriptor chain that keeps the DMA armed across buffers, with overrun detection) is the
  planned follow-up. A design with a higher stream rate needs deeper FIFOs (`FIFO_DEPTH`,
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
