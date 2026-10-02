# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "Scripts for Opsero NVMe speed tests"
DESCRIPTION = "The dd-based SSD speed tests of the FPGA Drive FMC reference \
design (fpga-drive-aximm-pcie): single_{read,write}_test.sh <mount> and \
dual_{read,write}_test.sh <mount1> <mount2> (4 GB, bs=4M, O_DIRECT). \
Installed verbatim so that the recorder images can reproduce the base \
design's dd figures next to the fdrec/fdplay results."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-drive-aximm-pcie"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://single_read_test.sh \
           file://single_write_test.sh \
           file://dual_read_test.sh \
           file://dual_write_test.sh \
          "

S = "${WORKDIR}"

do_install() {
    install -d ${D}${bindir}
    for f in single_read_test.sh single_write_test.sh dual_read_test.sh dual_write_test.sh; do
        install -m 0755 ${WORKDIR}/$f ${D}${bindir}/
    done
}

# bash scripts (bash's time keyword); the speed is computed with dc, which
# the bc package provides (GNU bc 1.07, update-alternatives "dc").
RDEPENDS:${PN} = "bash bc"
