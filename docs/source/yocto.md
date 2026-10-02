# Yocto

The Linux image of this design is built with the AMD Yocto / Embedded Development Framework
(EDF) flow, the announced successor to PetaLinux. There is no PetaLinux flow. The build is
driven by the cross-platform `build.py` runner at the root of the repository.

## Requirements

To build the Yocto image you need a physical or virtual machine running one of the
[supported Linux distributions], with Vivado and Vitis 2025.2 installed — the flow uses
`xsct`/`sdtgen` (which ship with Vitis) to generate a System Device Tree from the Vivado XSA.
You also need [Google's repo tool](https://gerrit.googlesource.com/git-repo/) on your `PATH`.
The host packages are listed in `Yocto/README.md`.

Plan for the disk space and time of a full Yocto build: the first build downloads several GB
of sources and runs bitbake from scratch, and the workspace occupies 40–60 GB.

```{attention}
You cannot build the Yocto image in the Windows operating system. Windows users are advised
to use a Linux virtual machine. On Windows the build runner can still build the Vivado
project and XSA, and prints the command to run on the Linux machine.
```

To test the image you need:

* the target board, with its USB-UART cable and a micro-SD card (8 GB or larger),
* the [FPGA Drive FMC Gen4] or [M.2 M-key Stack FMC] and one or two M.2 NVMe SSDs,
* optionally, an Ethernet cable from the board's RJ45 port to your network (DHCP).

## How to build

The build runner locates and sources the Vivado and Vitis settings itself, so there is no
need to source them by hand.

1. Clone the repository (with its submodules) and `cd` into it:
   ```
   git clone --recursive https://github.com/fpgadeveloper/fpga-drive-recorder.git
   cd fpga-drive-recorder
   ```
2. Build the Yocto image for your target, replacing `<target>` with one of the target
   design labels listed in the [build instructions](build_instructions.md#build-yocto):
   ```
   ./build.sh yocto --target <target>
   ```

This builds the Vivado project and XSA first if they do not exist yet. Subsequent builds are
incremental. See [build instructions](build_instructions.md#yocto-offline-build) to build
against a local sstate-cache mirror. The output products are gathered into
`Yocto/<target>/images/linux/`:

| File | Description |
| --- | --- |
| `rootfs.wic.xz` + `rootfs.wic.bmap` | Full SD-card disk image — this is what you flash |
| `BOOT.BIN` | Boot image (FSBL + PMU firmware + bitstream + ATF + U-Boot) |
| `boot.scr` | U-Boot boot script |
| `Image` | Linux kernel |
| `system.dtb` | Linux device tree |
| `rootfs.tar.gz` | Root filesystem tarball |

`./build.sh all --target <target>` (or `./build.sh package --target <target>` after the Yocto
stage) also packs the flashable files into
`bootimages/fpga-drive-recorder_<target>_yocto-2025-2.zip`.

```{note}
The Yocto stage is skipped when the gathered images already exist. After you change the
driver or the apps in `sw/`, delete `Yocto/<target>/images/linux/` so that the next
`./build.sh yocto` rebuilds the image with your change (incrementally: the workspace is
kept).
```

## How the image is put together

The flow generates a custom Yocto MACHINE (`fdrec-<target>`) directly from the Vivado XSA
(`sdtgen` → System Device Tree → `gen-machineconf parse-sdt`), so the PS configuration and
the PL hardware in the device tree — the XDMA PCIe root ports, the AXI DMA and the fdrec
register block — come from the design itself. The bitstream is embedded in `BOOT.BIN` and
programmed by the FSBL at boot.

On top of the EDF defaults, two layers are added:

* **`Yocto/bsp/<board>/meta-user`** — board-specific: the `system-user.dtsi` device-tree
  fixups (board clocks, Ethernet PHY, SD card, UARTs) and the **`fdrec` device-tree node**
  (`compatible = "opsero,fdrec"`, `dmas = <&axi_dma_0 1>, <&axi_dma_0 0>`,
  `dma-names = "rx", "tx"`: S2MM for recording, MM2S for playback),
  the kernel options of the base design (NVMe, PL PCIe root port), the base design's
  packages, and the kernel command line (`BSP_EXTRA_BOOTARGS`).
* **`Yocto/meta-fdrec`** — the recorder layer, enabled for a board by listing it in
  `Yocto/bsp/<board>/bblayers-extra.txt`:

  | Recipe / file | What it adds |
  |---------------|--------------|
  | `recipes-kernel/fdrec-mod` | the `fdrec.ko` kernel module, built from `sw/fdrec-driver` and `include/` of this repository, loaded at boot |
  | `recipes-apps/fdrec-apps` | `fdrec`, `fdplay`, `fdverify`, `fdbench.sh`, `fdsetup-raid0.sh`, built from `sw/fdrec-apps` (depends on `liburing`) |
  | `recipes-kernel/linux/linux-xlnx_%.bbappend` + `fdrec.cfg` | kernel options: `CONFIG_XILINX_DMA`, `CONFIG_HUGETLBFS`, `CONFIG_IO_URING`, `CONFIG_MD_RAID0` (+ `CONFIG_BLK_DEV_MD`), `CONFIG_XFS_FS` |
  | `recipes-core/images/edf-linux-disk-image.bbappend` | image packages: the module and apps, `liburing`, `mdadm`, `nvme-cli`, `fio`, `xfsprogs`, `e2fsprogs-mke2fs`, and bench tools (`devmem2`, `i2c-tools`, `ethtool`, `iproute2`, `iperf3`, `phytool`, `pciutils`, SSH server) |

  The recipes take their sources straight from the repository (`file://sw/...` and
  `file://include` relative to the repository root), so a change to the driver or the apps
  is picked up by the next `./build.sh yocto`.

### Kernel command line

The kernel command line is built by the EDF `boot.scr`. On the `uzev` target it is:

```
earlycon console=ttyPS0,115200 clk_ignore_unused init_fatal_sh=1 root=/dev/mmcblk1p3 ro rootwait
uio_pdrv_genirq.of_id=generic-uio cma=1000M hugepagesz=2M hugepages=256
```

The board-specific arguments come from `BSP_EXTRA_BOOTARGS` in
`Yocto/bsp/<board>/conf/local.conf.append`. `hugepages=` reserves the 2 MB hugepages that
`fdrec` and `fdplay` allocate their buffers from; the number is the variable
`FDREC_HUGEPAGES` (default 256 = 512 MB; the default ring of 32 × 8 MB needs 128). To change
it, edit `local.conf.append` and rebuild, or at run time:

```
echo 512 | sudo tee /proc/sys/vm/nr_hugepages
grep Huge /proc/meminfo
```

## Boot from SD card

The build produces a **full SD-card disk image** (`rootfs.wic.xz`) with all partitions:
`esp` (FAT, for `BOOT.BIN`), `boot` (ext4: `boot.scr`, kernel, device tree) and `root`
(ext4).

```{warning}
Flashing writes directly to a raw block device and cannot be undone. Be absolutely certain
you have identified the SD card's device node before running the commands below.
```

1. Identify the SD card device: run `lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT` with the card
   unplugged and again with it plugged in; the new entry (`/dev/sdX`, `RM=1`) is the card.
2. Unmount anything the desktop auto-mounted:
   ```
   for p in /dev/sdX?*; do sudo umount "$p" 2>/dev/null; done
   ```
3. Flash the image:
   ```
   sudo bmaptool copy --bmap Yocto/<target>/images/linux/rootfs.wic.bmap \
                            Yocto/<target>/images/linux/rootfs.wic.xz /dev/sdX
   ```
   or, slower: `xzcat Yocto/<target>/images/linux/rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`
4. Copy `BOOT.BIN` onto the `esp` partition (the EDF image leaves it empty, and the BootROM
   loads `BOOT.BIN` from the first FAT partition):
   ```
   sudo partprobe /dev/sdX
   sudo mkdir -p /mnt/sd_esp && sudo mount /dev/sdX1 /mnt/sd_esp
   sudo cp Yocto/<target>/images/linux/BOOT.BIN /mnt/sd_esp/ && sync
   sudo umount /mnt/sd_esp && sudo rmdir /mnt/sd_esp
   ```
5. Eject the card: `sudo eject /dev/sdX`.

Then boot:

1. Plug the SD card into the carrier and set the board's boot mode to SD (see the
   [board specific notes](supported_carriers.md#board-specific-notes) for the switch
   settings).
2. Connect one or two M.2 NVMe SSDs to the mezzanine card, and the card to the FMC
   connector of the carrier that the target design is built for (see the
   [target designs](build_instructions.md#target-designs)).
3. Connect the USB-UART to your PC and open a terminal at 115200 baud (8N1).
4. Optionally connect the board's Ethernet port to your network.
5. Power up the board.

During boot, look for the PCIe links and the recorder driver (here on the `uzev` target):

```none
xilinx-xdma-pcie 400000000.axi-pcie: PCIe Link is UP
xilinx-xdma-pcie 500000000.axi-pcie: PCIe Link is UP
fdrec 420010000.fdrec_core: /dev/fdrec0: fdrec_core v1.1, src_clk 199998001 Hz, dp_clk 249997498 Hz, FIFO 4096 beats, DMA rx dma0chan1 tx dma0chan0 (max segment 67108863 bytes), checker
```

(the clock frequencies are the actual PS PL-clock outputs, read from the design; `tx` is the
playback channel, `checker` means the register map has the playback checker).

## Log in

The console shows a login prompt with the hostname `<target>-fdrec-2025-2` (for example
`uzev-fdrec-2025-2`). Log in as
**`amd-edf`**; on the first login you must choose a password. The `amd-edf` user can run
commands as root with `sudo`. The image includes an SSH server, and the board's Ethernet
port comes up with DHCP, so once the password is set you can also log in over the network
(`ip -br addr` on the board shows the address).

## Next steps

Follow [Test the design in Linux](linux_test): check the SSDs and the driver, measure the
SSDs, then record, verify and play back.

[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
[M.2 M-key Stack FMC]: https://docs.opsero.com/op073/datasheet/overview/
[supported Linux distributions]: https://docs.amd.com/r/en-US/ug1144-petalinux-tools-reference-guide/Setting-Up-Your-Environment
