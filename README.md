# FPGA Drive Recorder

## Description

This reference design records data generated in the FPGA fabric to a file on an NVMe SSD
connected through Opsero's [FPGA Drive FMC Gen4] (OP063) or [M.2 M-key Stack FMC] (OP073).

Linux owns the SSD and the filesystem, and the recording is **zero-copy**: a fabric DMA writes
the samples into DDR buffers, and the NVMe controller reads those same buffers directly
(`O_DIRECT` writes) when the file is written. The CPU never copies the sample data; it only does
the bookkeeping. The data source in the design is a test pattern generator that models an ADC
and that you can replace with your own logic. Every recording reports the number of beats
dropped (zero for a valid recording), and the `fdverify` tool checks a recorded file beat by beat.
Recordings can also be played back into the fabric, where a hardware checker (or your own
data sink, such as a DAC) consumes them at a set rate.

This is a zero-copy recorder in which Linux keeps control of the SSDs; it is not a fabric NVMe
host engine. For CPU-less operation or rates beyond what Linux can sustain, hardware NVMe host
IP is available from Missing Link Electronics
([NVMe Streamer](https://www.missinglinkelectronics.com/ip-cores/nvme-streamer/)).

If you only need the SSD as a Linux block device (or a standalone PCIe enumeration test), use
the [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie) reference
designs instead.

Important links:

* Datasheet for the [FPGA Drive FMC Gen4]
* Datasheet for the [M.2 M-key Stack FMC]
* The user guide for this reference design is hosted here: [FPGA Drive Recorder docs](https://recorder.fpgadrive.com "FPGA Drive Recorder docs")
  (the sources are in [`docs/`](docs/source))
* To report a bug: [Report an issue](https://github.com/fpgadeveloper/fpga-drive-recorder/issues "Report an issue").
* For technical support: [Contact Opsero](https://opsero.com/contact-us "Contact Opsero").

## Architecture

![Block diagram](docs/source/images/fdrec-block-zynqmp.png)

* 128-bit AXI-Stream datapath at 250 MHz; the AMD AXI DMA (scatter-gather, S2MM for recording,
  MM2S for playback) moves the data between the fabric and a ring of 2 MB-hugepage buffers in
  PS DDR, allocated by the recorder app and pinned by the `fdrec` kernel driver. The NVMe SSDs
  read and write the same buffers (`O_DIRECT`).
* The source is never stalled: if the ingest FIFO is full, beats are dropped and counted.
* `user_data_source` and `user_data_sink` are the block-design hierarchies to replace with your
  own logic ([custom data source](https://recorder.fpgadrive.com/en/latest/custom_source.html),
  [custom data sink](https://recorder.fpgadrive.com/en/latest/custom_sink.html)).
* The register map is in [`include/fdrec_regs.h`](include/fdrec_regs.h) and
  [`docs/source/register_map.md`](docs/source/register_map.md).

## Requirements

This project is designed for version 2025.2 of the AMD tools (Vivado / Vitis) and the
AMD Yocto / Embedded Development Framework (EDF) 2025.2. There is no PetaLinux flow (PetaLinux
is being retired) and no standalone (baremetal) flow.

To build and test the design you will need:

* Vivado 2025.2
* Vitis 2025.2 (provides `sdtgen`/`xsct` for the Yocto flow)
* A Linux build machine for the Yocto flow (see [Yocto/README.md](Yocto/README.md))
* [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC]
* One or two M.2 NVMe PCIe SSDs
* One of the supported carriers listed below

## Target designs

<!-- updater start -->
### Zynq UltraScale+ designs

| Target board          | Target design   | M2 Slot 1<br> PCIe Lanes | M2 Slot 2<br> PCIe Lanes | FMC Slot    | Standalone | PetaLinux | Yocto | Vivado<br> Edition | IP<br>License |
|-----------------------|-----------------|--------------------------|--------------------------|-------------|-------|-------|-------|-------|-------|
| [UltraZed-EV Carrier] | `uzev`          | 4     | 4     | HPC         | :x:         | :x:         | :white_check_mark: | Standard :free: | -     |

### Versal designs

| Target board          | Target design   | M2 Slot 1<br> PCIe Lanes | M2 Slot 2<br> PCIe Lanes | FMC Slot    | Standalone | PetaLinux | Yocto | Vivado<br> Edition | IP<br>License |
|-----------------------|-----------------|--------------------------|--------------------------|-------------|-------|-------|-------|-------|-------|
| [VCK190]              | `vck190_fmcp1`  | 4     | 4     | FMCP1       | :x:         | :x:         | :white_check_mark: | Enterprise | -     |

[UltraZed-EV Carrier]: https://www.xilinx.com/products/boards-and-kits/1-1s78dxb.html
[VCK190]: https://www.xilinx.com/vck190
<!-- updater end -->

Notes:

1. The Vivado Edition column indicates which designs are supported by the Vivado *Standard* Edition, the
   FREE edition which can be used without a license. Designs marked "Enterprise" target a device that the
   Standard Edition does not support (for example the XCVC1902 of the VCK190) and need a Vivado Enterprise
   license for that device. No design needs an IP license (IP License column).
2. Further Linux-capable targets of [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
   (Zynq UltraScale+ and Versal boards) are being added.

## Build instructions

Clone the repo and change into its directory:
```
git clone --recursive https://github.com/fpgadeveloper/fpga-drive-recorder.git
cd fpga-drive-recorder
```

To build everything for the `uzev` target (Vivado XSA, then the Yocto image, then the boot
image zip in `bootimages/`), on a Linux machine:
```
./build.sh all --target uzev
```

### Cross-platform build runner

All builds are driven by `build.py` at the repo root, on both Windows
(git bash) and Linux. The `build.sh` / `build.bat` shim finds a suitable
Python 3 automatically (including the one bundled with the AMD tools).
Pick a target design label from the tables above (or run `./build.sh
list`), then run the build command for the stage(s) you want — each
command builds whatever it depends on automatically and skips anything
already built. On Windows without git bash, run the same commands from
Command Prompt or PowerShell using `build.bat` (e.g. `build.bat xsa
--target <target>`).

You don't need to source the AMD tools first — the build runner finds
Vivado and Vitis automatically in their standard install
locations and sets up the environment each stage needs. If your tools
are installed somewhere non-standard and the runner can't find them,
source the tool settings yourself before running the build.

This repository uses git submodules. Clone it with `--recursive`, or run
`git submodule update --init` in an existing clone, before building —
the Vivado build fails without the submodule sources.

#### Build the Vivado project (bitstream + XSA)

```
./build.sh xsa --target <target>
```

#### Build Yocto (Linux only)

```
./build.sh yocto --target <target>
```

#### Build everything

Builds all of the above that the target supports, then gathers the boot
images into `bootimages/*.zip`:

```
./build.sh all --target <target>
./build.sh all --target all          # every target in the repo
```

Also available: `status`, `clean`, `project` — see
`./build.sh --help`. On Windows, the Yocto stage requires a Linux machine;
the runner says so and prints the hand-off command.

### Simulating the custom RTL

The custom RTL in `Vivado/src/hdl` has self-checking testbenches in `Vivado/src/sim`, run in
the Vivado simulator by `Vivado/scripts/sim.tcl`:
```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
```

## Quick start

Flash `Yocto/<target>/images/linux/rootfs.wic.xz` to an SD card and copy `BOOT.BIN` onto its
first (FAT) partition (see the [Yocto](https://recorder.fpgadrive.com/en/latest/yocto.html) page),
boot the board with one or two NVMe SSDs on the mezzanine card, log in as `amd-edf` (you choose
the password on the first login), then:

```
# 1. Make a filesystem on the SSD(s) and mount it at /mnt/rec (created if missing;
#    --mount <dir> to choose another directory) -- ERASES THE DRIVES.
#    Both M.2 slots populated: RAID0 across the two SSDs (XFS, 512 KB chunks):
sudo fdsetup-raid0.sh
#    One SSD:
sudo fdsetup-raid0.sh --single /dev/nvme0n1

# 2. Record 10 GB of the test pattern at 1 GB/s (32 x 8 MB buffers by default).
#    Exit code 0 = no dropped beats, 2 = drops, 1 = error or stall (nothing completed
#    for --timeout seconds, default 10)
sudo fdrec --rate 1000MB --size 10G /mnt/rec/test.dat

# 3. Verify every beat of the recording
sudo fdverify /mnt/rec/test.dat

# 4. Play it back into the fabric: the hardware checker consumes it at 1 GB/s and checks
#    every beat (exit code 0 = no errors, no underflows, gaps = the recording's drops)
sudo fdplay --rate 1000MB /mnt/rec/test.dat

# Find the sustained recording rate of your SSD(s): sweep the rate, 32 GB per step
sudo fdbench.sh

# For comparison, the dd speed tests of fpga-drive-aximm-pcie (on a single-SSD mount)
single_write_test.sh /mnt/rec && single_read_test.sh /mnt/rec
```

The `fdrec` kernel driver is loaded at boot (`/dev/fdrec0`, sysfs counters in
`/sys/class/misc/fdrec0/`), and the image reserves 256 × 2 MB hugepages for the recording
buffers. The [user guide](https://recorder.fpgadrive.com) describes the
[tools](https://recorder.fpgadrive.com/en/latest/apps.html), the
[test procedure with expected output](https://recorder.fpgadrive.com/en/latest/linux_test.html),
the [driver](https://recorder.fpgadrive.com/en/latest/driver.html), the
[file format](https://recorder.fpgadrive.com/en/latest/file_format.html) and the
[measured rates](https://recorder.fpgadrive.com/en/latest/benchmarks.html).

## Contribute

We strongly encourage community contribution to these projects. Please make a pull request if you
would like to share your work:
* if you've spotted and fixed any issues
* if you've added designs for other target platforms
* if you've added software support for other devices

Thank you to everyone who supports us!

## About us

[Opsero Inc.](https://opsero.com "Opsero Inc.") is a team of FPGA developers delivering FPGA products and 
design services to start-ups and tech companies. Follow our blog, 
[FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
