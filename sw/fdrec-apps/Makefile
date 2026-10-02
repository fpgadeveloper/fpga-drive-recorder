# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# FPGA Drive Recorder apps: fdrec, fdplay, fdverify, fdbench.sh, fdsetup-raid0.sh.
#
#   make                         build with the system compiler + liburing
#   make CC=aarch64-linux-gnu-gcc LIBURING_CFLAGS=... LIBURING_LIBS=...
#   make install DESTDIR=<root> [PREFIX=/usr]
#
# fdrec and fdplay need liburing (>= 2.2); fdverify has no dependencies.
# FDREC_TARGET sets the default target name written into recording headers.

CC ?= gcc
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
FDREC_INCLUDE ?= ../../include
FDREC_TARGET ?= unknown

CFLAGS ?= -O2 -g
# Kept apart from CFLAGS, so that a CFLAGS given on the command line or by a
# build system (Yocto) does not drop the include path.
FDREC_CFLAGS = -Wall -Wextra -std=gnu11 -I$(FDREC_INCLUDE) -DFDREC_TARGET='"$(FDREC_TARGET)"'
LIBURING_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags liburing 2>/dev/null)
LIBURING_LIBS ?= $(shell $(PKG_CONFIG) --libs liburing 2>/dev/null || echo -luring)

PROGS = fdrec fdplay fdverify
SCRIPTS = fdbench.sh fdsetup-raid0.sh
HEADERS = fdrec_common.h $(FDREC_INCLUDE)/fdrec_uapi.h $(FDREC_INCLUDE)/fdrec_file.h

all: $(PROGS)

fdrec: fdrec.c $(HEADERS)
	$(CC) $(CPPFLAGS) $(FDREC_CFLAGS) $(CFLAGS) $(LIBURING_CFLAGS) -o $@ $< $(LDFLAGS) $(LIBURING_LIBS)

fdplay: fdplay.c $(HEADERS)
	$(CC) $(CPPFLAGS) $(FDREC_CFLAGS) $(CFLAGS) $(LIBURING_CFLAGS) -o $@ $< $(LDFLAGS) $(LIBURING_LIBS)

fdverify: fdverify.c $(HEADERS)
	$(CC) $(CPPFLAGS) $(FDREC_CFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: all
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(PROGS) $(DESTDIR)$(BINDIR)/
	install -m 0755 $(SCRIPTS) $(DESTDIR)$(BINDIR)/

clean:
	rm -f $(PROGS)

.PHONY: all install clean
