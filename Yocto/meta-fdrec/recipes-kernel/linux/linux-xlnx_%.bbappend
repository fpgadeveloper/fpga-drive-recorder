# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Kernel options the FPGA Drive Recorder needs on top of the board's bsp.cfg
# (which keeps the NVMe + PL PCIe root port options of the base design).
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://fdrec.cfg"
KERNEL_FEATURES:append = " fdrec.cfg"

# xilinx_dma: the HALTED/IDLE/RESET register polls use a zero delay, which makes
# their 1 s timeout 1e9 register reads (~7 min with the CPU stuck). The recorder
# hits this when it stops a channel whose stream source has stalled mid-packet.
# Applies to every target (generic driver code, no machine override).
SRC_URI:append = " file://0001-dmaengine-xilinx_dma-poll-with-a-delay-so-the-timeout-is-real-time.patch"
