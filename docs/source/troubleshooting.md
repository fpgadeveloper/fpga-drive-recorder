# Troubleshooting

## SSDs and PCIe

### No `PCIe Link is UP`, or an SSD is missing

The PCIe part of this design is the one of fpga-drive-aximm-pcie, so its
[troubleshooting guide](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie/blob/master/docs/source/troubleshooting.md)
applies as well. Work through these in order:

1. **Is the mezzanine card on the right connector?** Each target design is built for one
   FMC connector (see the [target designs](build_instructions.md#target-designs)). A design
   built for another connector cannot see the SSDs.
2. **Is the card seated, and the SSD?** Re-seat the mezzanine card on the FMC connector and
   the SSD in its M.2 slot, and tighten the SSD's screw.
3. **Is VADJ on?** The FMC signals that release the SSDs from reset are powered by the
   carrier's VADJ supply. Check the carrier's VADJ setting against the
   [FMC card's requirements](https://docs.opsero.com/op063/datasheet/overview/).
4. **Is the right image running?** The boot log should show this design's driver line
   (`fdrec ... /dev/fdrec0: fdrec_core v1.1 ...`). A card that holds another design's
   image has another bitstream.
5. **Check the link** with `dmesg | grep -i "pcie link"` and
   `lspci -vv | grep -E "LnkCap|LnkSta"` (see [Test the design in Linux](linux_test)).
   A link that trains slower or narrower than the design supports points to a seating or
   signal problem: try the SSD in the other slot, or another SSD.

## The recorder driver

### No `/dev/fdrec0`

The `fdrec` module is loaded at boot. Check what happened:

```
lsmod | grep fdrec
dmesg | grep -iE "fdrec|xilinx-dma|dma"
```

* **The module is not loaded:** load it with `sudo modprobe fdrec` and look at the kernel
  log. The module must match the running kernel; after you rebuild the kernel, rebuild the
  image so that both come from the same build.
* **`unsupported fdrec_core VERSION 0x...`:** the bitstream in `BOOT.BIN` is not this
  design (or not a compatible version), or the device tree describes hardware that is not
  in the bitstream. Rebuild the image from the matching XSA (`./build.sh yocto`), and
  copy the new `BOOT.BIN` to the SD card together with the rest of the image.
* **`cannot get DMA channel "rx"`:** the AXI DMA itself did not probe. The `xilinx_dma`
  driver needs an interrupt on every channel of the AXI DMA in the device tree; a design
  change that removes or renumbers the DMA interrupts makes the whole DMA fail to probe.
  The device-tree node of the AXI DMA comes from the XSA; check `dmesg | grep -i dma`.
* **`no DMA channel "tx" (...): record only`:** the design has no MM2S channel (a
  record-only build); recording works, playback does not.
* **No `fdrec` message at all:** the device tree has no `compatible = "opsero,fdrec"`
  node. It is added by the board's `system-user.dtsi` (`Yocto/bsp/<board>/`); check with
  `find /proc/device-tree -name "*fdrec*"`.

### `fdrec` or `fdplay` cannot allocate its buffers

The buffers come from the 2 MB hugepage pool that the kernel reserves at boot (`hugepages=`
on the kernel command line, 256 = 512 MB by default). The tool prints how many hugepages it
needs and how many are free. Use fewer or smaller buffers (`--buffers`, `--buf-size`), or
add hugepages at run time:

```
echo 512 | sudo tee /proc/sys/vm/nr_hugepages
grep Huge /proc/meminfo
```

### `/dev/fdrec0` is busy

Only one program can use the recorder at a time. `fdrec` and `fdplay` cannot run together;
check for a recording still running in the background (`ps aux | grep -E "fdrec|fdplay"`).

## Recording

### Beats are dropped (`fdrec` exits with code 2)

A drop means the data arrived faster than the DMA could put it into a free buffer, because
the SSD writes were not completing fast enough. In order of likelihood:

1. **The rate is above what the SSDs sustain.** Find the sustained rate with `fdbench.sh`
   (32 GB per step) and record below it. A rate that works for 10 GB may fail for longer
   recordings.
2. **The SLC cache ran out.** If the drops start after a fixed amount of data (on the
   970 EVO 250GB, ~14 GB), the SSD's write cache filled up; see
   [Benchmarks](benchmarks.md#the-slc-cache). Use a lower rate, a larger or faster SSD, or
   RAID0.
3. **`fstrim` just before the recording.** If the drops are near the start of the file,
   the SSDs may still be processing discards: wait a few seconds after `fstrim` (or skip
   it) before recording; see [Benchmarks](benchmarks.md#the-fstrim-finding-and-the-ring-size).
4. **The ring is too small for the SSD's write stalls.** More buffers (`--buffers 48`,
   `--buffers 64`) or larger buffers absorb longer stalls, within the hugepage pool.
5. **The rate exceeds the FIFO budget.** If `fdrec` warns that "the ingest FIFO covers only
   ... of the DMA restart gap", the rate is too high for the design's FIFO, whatever the
   SSD; see [Applications](apps.md#tuning-the-fifo-budget-at-buffer-boundaries).
6. **Other I/O on the same SSDs**, a nearly full filesystem, or a filesystem other than XFS
   or ext4.

`fdverify` shows where the gaps are (file offsets), which tells you whether they are at the
start (trim, ring), after a fixed amount (cache) or spread over the file (rate too high).

### Recording stops with `recording stalled` (exit code 1)

`fdrec` has a stall watchdog (`--timeout`, default 10 s). If no buffer completes for that
long -- for example a custom source stopped producing data, or `--no-tpg` was used with
nothing driving the stream -- `fdrec` stops the recording, writes the file header and exits
with code 1. `fdbench.sh` reports such a step as `ERROR`.

When it stops, the driver first gives the DMA up to `stop_drain_ms` (module parameter,
default 5000 ms) to finish the buffers it holds. If the source has stopped in the middle of
a packet, the AXI DMA cannot halt, so the channel is terminated and the DMA engine is reset.
The kernel log then shows:

```none
fdrec ...: STOP: source stalled, the DMA still owns buffers after 5000 ms; terminating a channel that is mid-packet ...
xilinx-vdma ...: Cannot stop channel ...: 10008
```

This is expected and harmless: the next recording or playback runs normally. The image
carries a small `xilinx_dma` kernel patch (in `meta-fdrec`,
`0001-dmaengine-xilinx_dma-poll-with-a-delay-so-the-timeout-is-real-time.patch`) that bounds
this reset to about 1.5 s; without it, the stock driver spins a CPU for about 7 minutes.
Measured on `uzev` (2026-10-02): `fdrec` exited about 6.6 s after the `recording stalled`
message.

Before you record again, check the source: its clock, its enable (with `--no-tpg`, a source
that waits for `tpg_enable` needs `echo 1 | sudo tee /sys/class/misc/fdrec0/tpg_enable`) and
its `TVALID`. A source that is legitimately slower than one buffer per `--timeout` needs a
larger `--timeout` or smaller buffers; `fdrec` warns about this at start-up when it knows the
rate. If the source is fine, check `dmesg` for NVMe errors or timeouts: an SSD that stops
completing writes stalls the recording too.

The same can happen at the end of a playback whose sink stopped consuming
(`PLAY_STOP: sink stalled ...`); there the driver flushes the egress FIFO first, so it is
rare.

## Playback

### `fdplay` reports underflows (exit code 2)

The sink consumed faster than the SSDs delivered the data.

* **No `--rate`, or a rate above the read rate.** The checker's default rate is one beat
  per clock (3.2 GB/s), faster than the SSDs; give `fdplay --rate` below the read rate.
* **Read stalls.** Isolated underflow bursts near the read rate are read stalls longer than
  the ring lasts at that rate; more buffers absorb them (see
  [Benchmarks](benchmarks.md#playback)).

### `fdplay` stalls and gives up (`--no-check`)

With `--no-check`, `fdplay` does not enable the checker. On the reference design the
checker is the sink, and while it is disabled it holds `TREADY` low, so the stream stalls
and `fdplay` gives up after `--timeout` seconds with exit code 1. Enable the sink by hand
(`echo 1 | sudo tee /sys/class/misc/fdrec0/chk_enable`), or drop `--no-check`. With your
own sink, make sure it is enabled and consuming.

### Kernel warning `egress FIFO did not prime`

At the start of a checked playback the driver waits up to 100 ms for the egress FIFO to fill
before it enables the checker. The warning means the first data arrived late; the playback
continues, but the checker may count start-up underflows. Check for a slow or busy SSD.

## Build failures

1. **Are you using the correct version of Vivado for this version of the repository?**
   The design needs Vivado, Vitis and EDF 2025.2 (see [Requirements](requirements)).
2. **Did you clone the repository with its submodules?** Clone with `--recursive`, or run
   `git submodule update --init`; the Vivado build fails without the board files.
3. **Did you change the RTL?** A module-reference top must be a Verilog (`.v`) or VHDL
   file; Vivado 2025.2 rejects a SystemVerilog top (`[filemgmt 56-195]`).
4. **Yocto on Windows or WSL** is not supported; build the XSA there and the Yocto image
   on a native Linux machine (see [Build instructions](build_instructions)).
5. **A change to the driver or the apps does not show up in the image:** the Yocto stage
   is skipped when the images exist; delete `Yocto/<target>/images/linux/` and build again
   (see [Yocto](yocto.md#how-to-build)).
