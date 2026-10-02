# SPDX-License-Identifier: GPL-2.0-only OR MIT
#
# Out-of-tree build of the fdrec kernel module.
#
#   make KERNEL_SRC=<configured kernel tree or kernel build dir>
#   make KERNEL_SRC=... modules_install [INSTALL_MOD_PATH=<rootfs>]
#
# On the board, with the kernel headers/build dir installed:
#   make KERNEL_SRC=/lib/modules/$(uname -r)/build
#
# Yocto (module.bbclass) passes KERNEL_SRC, O, CC, LD, ... itself.

KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
SRC := $(shell pwd)

all: modules

modules:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules

modules_install:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) modules_install

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(SRC) clean

.PHONY: all modules modules_install clean
