# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Drive Recorder kernel driver (fdrec.ko)"
DESCRIPTION = "Out-of-tree platform driver for the fdrec_core register block \
and the AXI DMA S2MM/MM2S channels: pins user-space hugepage buffers and \
streams fabric data into them for zero-copy O_DIRECT recording to NVMe, and \
back out of them for playback."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-drive-recorder"
LICENSE = "GPL-2.0-only | MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6 \
                    file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit module

# Sources come straight from this repository (no fetch): sw/fdrec-driver and
# the shared headers in include/. FDREC_REPO_ROOT is set by the layer's
# layer.conf. Both directories unpack under ${WORKDIR} with their repo-relative
# paths, so the module's Kbuild finds ../../include exactly as in the repo.
FILESEXTRAPATHS:prepend := "${FDREC_REPO_ROOT}:"
SRC_URI = "file://sw/fdrec-driver \
           file://include \
          "
S = "${WORKDIR}/sw/fdrec-driver"

# Load at boot; the driver binds to the "opsero,fdrec" device-tree node.
KERNEL_MODULE_AUTOLOAD += "fdrec"

RPROVIDES:${PN} += "kernel-module-fdrec"
