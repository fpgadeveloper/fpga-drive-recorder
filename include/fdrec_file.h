/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * fdrec_file.h -- on-disk format of an FPGA Drive Recorder file.
 *
 * A recording is a 4096-byte header followed by the raw 128-bit beats exactly
 * as the AXI DMA wrote them to memory (16 bytes per beat, little-endian):
 *
 *     offset 0      struct fdrec_file_header (4096 bytes, zero-padded)
 *     offset 4096   beat 0, beat 1, ... (data_bytes bytes)
 *
 * The 4 KB header keeps the data O_DIRECT-aligned. fdrec writes the header
 * once at the start (flags without COMPLETE) and rewrites it at the end with
 * the final counts and FDREC_FILE_FLAG_COMPLETE.
 *
 * With the test pattern generator as the source, beat n of the data carries
 * lower = first_seq + n + (beats dropped before it), upper = ~lower.
 *
 * All multi-byte fields are little-endian. The structure is packed and its
 * size is checked at compile time.
 */

#ifndef FDREC_FILE_H
#define FDREC_FILE_H

#include <stdint.h>

#define FDREC_FILE_MAGIC                "FDREC\0\0\0"   /* 8 bytes incl. NULs */
#define FDREC_FILE_MAGIC_LEN            8
#define FDREC_FILE_HEADER_VERSION       1
#define FDREC_FILE_HEADER_SIZE          4096

/* flags */
#define FDREC_FILE_FLAG_TPG             (1u << 0)   /* source was the test pattern generator */
#define FDREC_FILE_FLAG_COMPLETE        (1u << 1)   /* header rewritten at stop */

struct fdrec_file_header {
	char     magic[8];          /* "FDREC\0\0\0" */
	uint32_t header_version;    /* FDREC_FILE_HEADER_VERSION */
	uint32_t header_size;       /* 4096 */
	uint32_t beat_bytes;        /* 16 */
	uint32_t flags;             /* FDREC_FILE_FLAG_* */
	uint32_t design_version;    /* VERSION register */
	uint64_t src_clk_hz;
	uint64_t rate_bps;          /* 0 if not set by fdrec */
	uint64_t start_time_ns;     /* CLOCK_REALTIME at start */
	uint64_t stop_time_ns;      /* written at stop */
	uint64_t data_bytes;        /* written at stop */
	uint64_t drop_count;        /* written at stop */
	uint64_t first_seq;         /* first sequence number captured, if TPG */
	char     target[32];        /* e.g. "uzev", NUL-padded */
	char     hostname[64];      /* NUL-padded */
	uint8_t  reserved[FDREC_FILE_HEADER_SIZE - 8 - 5 * 4 - 7 * 8 - 32 - 64];
} __attribute__((packed));

#ifdef __cplusplus
static_assert(sizeof(struct fdrec_file_header) == FDREC_FILE_HEADER_SIZE,
	      "fdrec_file_header must be 4096 bytes");
#else
_Static_assert(sizeof(struct fdrec_file_header) == FDREC_FILE_HEADER_SIZE,
	       "fdrec_file_header must be 4096 bytes");
#endif

#endif /* FDREC_FILE_H */
