# Copyright (C) 2025-2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Replace the stock EDF boot.cmd with our own. The stock edf-linux-mmc-boot.cmd
# ext4loads the kernel from partition 2 and boots with U-Boot's control FDT --
# neither matches our Versal layout (esp/storage/root) nor our need to use the
# cortexa72-linux.dtb the PLM loaded to 0x1000. We swap in fpgadrv-boot.cmd
# (loads Image from the esp FAT, boots with the dtb at 0x1000). The recipe's
# do_compile mkimages ${WORKDIR}/edf-linux-mmc-boot.cmd -> boot.scr, so we just
# overwrite that file before it runs (mirrors the recipe's own :zynq prepend).
#
# := captures the bbappend dir at parse time (${THISDIR} is unreliable at task
# time inside a bbappend).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://fpgadrv-boot.cmd"

# FPGA Drive Recorder: BSP_EXTRA_BOOTARGS (conf/local.conf.append: the hugepage
# reservation) is appended inside the closing quote of the script's single
# `setenv bootargs '...'` line. The variable is referenced by the task, so
# changing it changes do_compile's signature and rebuilds boot.scr.
BSP_EXTRA_BOOTARGS ??= ""

do_compile:prepend() {
    cp ${WORKDIR}/fpgadrv-boot.cmd ${WORKDIR}/edf-linux-mmc-boot.cmd
    if [ -n "${BSP_EXTRA_BOOTARGS}" ]; then
        sed -i -e "/^setenv bootargs '/s|'\$| ${BSP_EXTRA_BOOTARGS}'|" ${WORKDIR}/edf-linux-mmc-boot.cmd
        grep -qF -- " ${BSP_EXTRA_BOOTARGS}'" ${WORKDIR}/edf-linux-mmc-boot.cmd || \
            bbfatal "BSP_EXTRA_BOOTARGS: no 'setenv bootargs' line patched in fpgadrv-boot.cmd"
    fi
}
