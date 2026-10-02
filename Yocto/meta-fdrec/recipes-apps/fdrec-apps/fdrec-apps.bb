# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Drive Recorder apps: fdrec, fdplay, fdverify, fdbench.sh, fdsetup-raid0.sh"
DESCRIPTION = "fdrec records the fabric data stream to a file on NVMe \
(zero-copy, io_uring + O_DIRECT from the DMA buffers), fdplay plays a \
recording back into the fabric (O_DIRECT reads into the DMA buffers, MM2S, \
hardware checker verdict), fdverify checks a \
recording beat by beat, fdbench.sh sweeps the sustained recording rate and \
fdsetup-raid0.sh prepares a RAID0 (or single-SSD) recording filesystem."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-drive-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "liburing"

# Sources come straight from this repository: sw/fdrec-apps plus the shared
# headers in include/ (FDREC_REPO_ROOT is set by the layer's layer.conf).
FILESEXTRAPATHS:prepend := "${FDREC_REPO_ROOT}:"
SRC_URI = "file://sw/fdrec-apps \
           file://include \
          "
S = "${WORKDIR}/sw/fdrec-apps"

inherit pkgconfig

# Default target name written into recording headers: the generated MACHINE
# is "fdrec-<target>" (Yocto/scripts/configure-build.sh).
FDREC_TARGET ?= "${@d.getVar('MACHINE').replace('fdrec-', '', 1)}"

# CC, CFLAGS and LDFLAGS come from the environment bitbake exports. The
# Makefile's default FDREC_INCLUDE (../../include) resolves to ${WORKDIR}/include;
# keeping it relative keeps build paths out of the debug info.
EXTRA_OEMAKE = "FDREC_TARGET='${FDREC_TARGET}'"

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} PREFIX=${prefix} BINDIR=${bindir}
}

# The machine name is compiled in, so the package is machine specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# fdsetup-raid0.sh: mdadm, mkfs.xfs / mkfs.ext4, wipefs, lsblk, mountpoint
RDEPENDS:${PN} = "liburing mdadm xfsprogs e2fsprogs-mke2fs util-linux-wipefs util-linux-lsblk util-linux-mountpoint"
