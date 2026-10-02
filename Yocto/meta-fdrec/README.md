# meta-fdrec

Yocto layer for the FPGA Drive Recorder. It is layered on top of the AMD EDF build together
with the board's `bsp/<board>/meta-user` layer (priority 6, below `meta-user` at 7, so a
board can override anything here).

Contents:

* `conf/layer.conf` -- the layer definition (scarthgap). It also sets `FDREC_REPO_ROOT`, the
  repository root, from which the recipes take their sources.
* `recipes-kernel/fdrec-mod/` -- the out-of-tree `fdrec` kernel module (`module.bbclass`;
  sources `sw/fdrec-driver/` and `include/`), auto-loaded at boot. It pins the user-space
  hugepage buffers, drives the AXI DMA S2MM (record) and MM2S (playback) channels through
  the `xilinx_dma` dmaengine driver and exposes `/dev/fdrec0` plus sysfs attributes.
* `recipes-apps/fdrec-apps/` -- `fdrec` and `fdplay` (liburing), `fdverify`, `fdbench.sh` and
  `fdsetup-raid0.sh` (sources `sw/fdrec-apps/` and `include/`). The default target name
  written into recording headers is derived from the generated MACHINE (`fdrec-<target>`).
* `recipes-apps/speed-tests/` -- the base FPGA Drive FMC design's dd speed tests
  (`single_read_test.sh`, `single_write_test.sh`, `dual_read_test.sh`, `dual_write_test.sh`,
  copied verbatim from `fpga-drive-aximm-pcie`), installed in `/usr/bin` with `bc` (provides
  `dc`), so the dd figures can be reproduced next to the fdrec/fdplay results.
* `recipes-kernel/linux/` -- kernel config fragment `fdrec.cfg` (`CONFIG_XILINX_DMA`,
  `CONFIG_HUGETLBFS`, `CONFIG_IO_URING`, `CONFIG_MD_RAID0`, `CONFIG_XFS_FS`, ...).
* `recipes-core/images/` -- image additions: the module, the apps, `liburing`, `mdadm`,
  `nvme-cli`, `fio`, `xfsprogs`, `e2fsprogs-mke2fs`, `speed-tests`, and the bench tools (SSH server,
  `devmem2`, `i2c-tools`, `ethtool`, `iproute2`, `iperf3`, `phytool`, `pciutils`).

Board-specific parts stay in the board's bsp, because they depend on the XSA:

* the `opsero,fdrec` device-tree node (`bsp/<board>/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`),
* the hugepage reservation on the kernel command line
  (`FDREC_HUGEPAGES` -> `BSP_EXTRA_BOOTARGS` in `bsp/<board>/conf/local.conf.append`).

`Yocto/scripts/configure-build.sh` adds a board's extra layers from
`bsp/<board>/bblayers-extra.txt` (one repo-root-relative layer path per line), so this layer
is enabled for a target by listing `Yocto/meta-fdrec` there.
