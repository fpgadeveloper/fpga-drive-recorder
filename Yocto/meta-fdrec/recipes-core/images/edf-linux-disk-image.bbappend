# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# FPGA Drive Recorder additions to the EDF disk image (on top of the board's
# bsp/<board>/meta-user image bbappend, which carries the base design's
# packages such as nvme-cli and pciutils).

# The recorder: kernel driver (auto-loaded) + apps, and what the apps use.
FDREC_PACKAGES = " \
    fdrec-mod \
    fdrec-apps \
    liburing \
    mdadm \
    nvme-cli \
    fio \
    xfsprogs \
    e2fsprogs-mke2fs \
    util-linux-lsblk \
    util-linux-wipefs \
    speed-tests \
"

# Bench tools for bring-up and the autonomous test loop (register access,
# I2C, Ethernet; the in-kernel packet generator pktgen is built in by the
# base kernel config, CONFIG_NET_PKTGEN=y). sshd comes from the
# ssh-server-openssh image feature. No key or password is installed by this
# layer: provisioning is done over the UART.
FDREC_BENCH_PACKAGES = " \
    devmem2 \
    i2c-tools \
    ethtool \
    iproute2 \
    iperf3 \
    phytool \
    pciutils \
"

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " ${FDREC_PACKAGES} ${FDREC_BENCH_PACKAGES}"
