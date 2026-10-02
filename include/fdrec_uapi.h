/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * fdrec_uapi.h -- user-space API of the fdrec kernel driver (/dev/fdrecN).
 *
 * Shared by the kernel module (sw/fdrec-driver) and the apps (sw/fdrec-apps).
 * Every structure uses fixed-width types, natural alignment and explicit
 * padding, so the layout is identical for 32-bit and 64-bit user space and for
 * the kernel. User pointers are carried as __u64.
 *
 * Buffer model (see docs/source/driver.md):
 *
 *   1. The app allocates N buffers from 2 MB hugepages (mmap MAP_HUGETLB),
 *      each a multiple of 2 MB, and registers them with FDREC_IOC_REGISTER_BUFS.
 *      The driver pins them and maps them for the AXI DMA. Buffer i is
 *      identified by its index i in the registered array.
 *   2. FDREC_IOC_START queues every registered buffer to the DMA and enables the
 *      packetizer (and optionally the test pattern generator).
 *   3. FDREC_IOC_WAIT_FILLED returns the next buffer the DMA has filled (in fill
 *      order). The buffer now belongs to the app: write it to disk (O_DIRECT).
 *   4. FDREC_IOC_RELEASE gives the buffer back; the driver re-queues it.
 *   5. FDREC_IOC_STOP stops the datapath and the DMA. Buffers can be registered
 *      again (or a new START issued) afterwards. close() cleans up everything.
 *
 * Playback (file -> memory -> MM2S -> fabric sink), FDREC_CAP_MM2S:
 *
 *   1. Register the buffers with fdrec_bufs.flags = FDREC_DIR_PLAY (mapped
 *      DMA_TO_DEVICE). A registered set has one direction: START/WAIT_FILLED/
 *      RELEASE need a RECORD set, the PLAY_* ioctls a PLAY set (-EINVAL).
 *   2. FDREC_IOC_PLAY_START arms the MM2S channel (optionally resets and
 *      enables the hardware checker). Every buffer belongs to the app.
 *   3. The app fills a buffer (O_DIRECT read from the file) and hands it over
 *      with FDREC_IOC_PLAY_SUBMIT(index, bytes); buffers are played in
 *      submission order, each as one AXI-Stream packet (TLAST on its last
 *      beat).
 *   4. FDREC_IOC_PLAY_WAIT_DONE returns the next buffer the DMA has finished
 *      reading (submission order); the app may refill it.
 *   5. FDREC_IOC_PLAY_STOP stops the MM2S channel.
 *
 * API compatibility: FDREC_API_VERSION 1 is unchanged by playback -- every
 * playback addition is new (FDREC_DIR_PLAY in the formerly must-be-zero
 * fdrec_bufs.flags, new ioctl numbers 0x08..0x0C, new caps bits), so Phase-1
 * binaries keep working. Check fdrec_info.caps for FDREC_CAP_MM2S /
 * FDREC_CAP_CHECK before using them.
 */

#ifndef FDREC_UAPI_H
#define FDREC_UAPI_H

#ifdef __KERNEL__
#include <linux/types.h>
#include <linux/ioctl.h>
#else
#include <linux/types.h>
#include <sys/ioctl.h>
#endif

/* Version of this API; FDREC_IOC_GET_INFO reports the driver's value */
#define FDREC_API_VERSION               1

/* Device node name: /dev/fdrec0, /dev/fdrec1, ... */
#define FDREC_DEV_NAME                  "fdrec"

/* Buffer constraints */
#define FDREC_BUF_ALIGN                 (2u * 1024 * 1024)  /* 2 MB: hugepage size */
#define FDREC_MAX_BUFS                  64                  /* per open file */
/* Largest buffer: 62 MB. Every buffer is one AXI-Stream packet of
 * buf_size / 16 beats, and the packetizer accepts PKT_LEN <= 4194303
 * (2^22 - 1) beats; 62 MB is the largest 2 MB multiple below that. */
#define FDREC_MAX_PKT_LEN               4194303u
#define FDREC_MAX_BUF_SIZE              (62ull << 20)

/* struct fdrec_info.caps */
#define FDREC_CAP_TPG                   (1u << 0)   /* test pattern generator present */
#define FDREC_CAP_S2MM                  (1u << 1)   /* record (fabric -> memory) */
#define FDREC_CAP_MM2S                  (1u << 2)   /* playback (memory -> fabric):
						     * DMA channel "tx" present */
#define FDREC_CAP_CHECK                 (1u << 3)   /* fdrec_check sink/checker
						     * registers (VERSION >= 1.1) */

/* FDREC_IOC_GET_INFO: static information about the device */
struct fdrec_info {
	__u32 api_version;      /* FDREC_API_VERSION of the driver */
	__u32 hw_version;       /* VERSION register: [31:16] major, [15:0] minor */
	__u64 src_clk_hz;       /* SRC_CLK_HZ register */
	__u64 dp_clk_hz;        /* DP_CLK_HZ register */
	__u32 beat_bytes;       /* bytes per AXI-Stream beat (16) */
	__u32 fifo_depth;       /* ingest FIFO depth in beats */
	__u32 max_bufs;         /* FDREC_MAX_BUFS */
	__u32 caps;             /* FDREC_CAP_* */
	__u64 buf_align;        /* required buffer size multiple / alignment */
	__u64 max_buf_size;     /* largest buffer size accepted */
	__u32 max_sg_len;       /* largest DMA segment (bytes) of the AXI DMA */
	__u32 reserved0;
	__u64 reserved[4];
};

/*
 * FDREC_IOC_REGISTER_BUFS: pin and DMA-map count buffers of buf_size bytes.
 * addrs points to an array of count __u64 user virtual addresses, each aligned
 * to FDREC_BUF_ALIGN. Only allowed while stopped. Registering replaces any
 * previously registered set; count = 0 just unregisters.
 *
 * flags selects the direction of the whole set: FDREC_DIR_RECORD (0, the
 * Phase-1 value) maps the buffers DMA_FROM_DEVICE for the S2MM channel,
 * FDREC_DIR_PLAY maps them DMA_TO_DEVICE for the MM2S channel (-EOPNOTSUPP
 * without FDREC_CAP_MM2S). Other bits must be 0.
 */
#define FDREC_DIR_RECORD                0u          /* fabric -> memory (S2MM) */
#define FDREC_DIR_PLAY                  1u          /* memory -> fabric (MM2S) */
#define FDREC_BUFS_DIR_MASK             1u

struct fdrec_bufs {
	__u64 addrs;            /* user pointer to __u64[count] */
	__u64 buf_size;         /* bytes per buffer, multiple of FDREC_BUF_ALIGN */
	__u32 count;            /* number of buffers, 0..FDREC_MAX_BUFS */
	__u32 flags;            /* FDREC_DIR_RECORD or FDREC_DIR_PLAY */
};

/* struct fdrec_start.flags */
/* Reset the TPG sequence counter and enable the TPG once the datapath is
 * running (fdrec without --no-tpg). Without it, the TPG enable state from
 * before START is restored unchanged ("do not touch the generator"). */
#define FDREC_START_TPG                 (1u << 0)

/*
 * FDREC_IOC_START: GLOBAL_CTRL.SOFT_RST (flush FIFO, clear counters), set
 * PKT_LEN = buf_size / 16, queue every registered buffer to the DMA, enable
 * the packetizer, then the TPG as selected by flags.
 */
struct fdrec_start {
	__u32 flags;            /* in: FDREC_START_* */
	__u32 pkt_len;          /* out: PKT_LEN programmed (beats per buffer) */
	__u64 first_seq;        /* out: TPG sequence number of the first beat
				 *      recorded when the TPG is the source (0:
				 *      SOFT_RST clears the sequence counter) */
	__u64 start_time_ns;    /* out: CLOCK_REALTIME when the packetizer was enabled */
	__u64 reserved[3];
};

/* struct fdrec_filled.flags */
#define FDREC_FILLED_ERROR              (1u << 0)   /* DMA reported an error */
#define FDREC_FILLED_SHORT              (1u << 1)   /* bytes < buf_size (TLAST early) */

/*
 * FDREC_IOC_WAIT_FILLED: wait for the next filled buffer (fill order).
 * Returns 0 and fills in index/bytes; -ETIMEDOUT when timeout_ms expired;
 * -EINTR on a signal; -ENODATA when stopped and nothing is left; -EIO when
 * the DMA channel reported an error.
 * The driver has already done dma_sync_sgtable_for_cpu() on the buffer.
 */
struct fdrec_filled {
	__s32 timeout_ms;       /* in: <0 = wait forever, 0 = poll */
	__u32 index;            /* out: buffer index */
	__u64 bytes;            /* out: bytes written by the DMA (buf_size unless SHORT) */
	__u64 seq;              /* out: fill sequence number (0, 1, 2, ... since START) */
	__u64 drop_count;       /* out: ING_DROP_COUNT read when the buffer completed */
	__u32 flags;            /* out: FDREC_FILLED_* */
	__u32 reserved0;
	__u64 reserved[2];
};

/* FDREC_IOC_RELEASE: give buffer index back to the driver; it is re-queued
 * to the DMA (after dma_sync_sgtable_for_device()) while running. */
struct fdrec_release {
	__u32 index;
	__u32 flags;            /* must be 0 */
};

/* FDREC_IOC_GET_STATS / FDREC_IOC_STOP: counters (STOP returns the final values) */
struct fdrec_stats {
	__u64 drop_count;       /* ING_DROP_COUNT: beats dropped at the ingest FIFO */
	__u64 beats_in;         /* ING_BEATS_IN: beats offered by the source */
	__u64 beats_out;        /* PKT_BEATS_OUT: beats delivered to the DMA */
	__u64 seq_next;         /* TPG_SEQ_NEXT */
	__u32 fifo_hwm;         /* ING_FIFO_HWM (beats) */
	__u32 fifo_depth;       /* ING_FIFO_DEPTH (beats) */
	__u32 overflow;         /* ING_STATUS.OVERFLOW (sticky) */
	__u32 running;          /* 1 between START and STOP */
	__u64 bufs_filled;      /* buffers completed by the DMA since START */
	__u64 bytes_filled;     /* bytes completed by the DMA since START */
	__u32 bufs_dma;         /* buffers currently owned by the DMA */
	__u32 bufs_ready;       /* filled buffers waiting for WAIT_FILLED */
	__u32 bufs_user;        /* buffers owned by the app (returned, not released) */
	__u32 dma_errors;       /* completions with an error */
	__u64 reserved[4];
};

/* FDREC_IOC_SET_RATE: program TPG_RATE_INC for rate_bps bytes/s (0 = stop
 * emitting); returns the rate actually programmed (rounded). Equivalent to
 * writing the rate_bps sysfs attribute. Does not change TPG_CTRL.ENABLE. */
struct fdrec_rate {
	__u64 rate_bps;         /* in: requested; out: programmed */
};

/* ---------------------------------------------------------------------- */
/* Playback                                                               */

/* struct fdrec_play_start.flags */
/* Reset the checker (counters cleared, expected sequence := first beat) and
 * enable it before any data reaches it (fdplay without --no-check). Without
 * it the checker is left as it is ("do not touch the sink"). PLAY_STOP
 * disables a checker that PLAY_START enabled (its counters keep their values). */
#define FDREC_PLAY_CHECK                (1u << 0)

/* FDREC_IOC_PLAY_START: arm the MM2S channel. Needs a FDREC_DIR_PLAY buffer
 * set; every buffer belongs to the app afterwards. With FDREC_PLAY_CHECK the
 * driver first issues GLOBAL_CTRL.SOFT_RST (empties the egress FIFO of any
 * beats left from an aborted playback, clears all counters; CHK_RATE_INC is
 * kept) and resets the checker (ENABLE = 0); the first PLAY_SUBMIT enables
 * it once the stream has primed the egress FIFO (31/32 of EGR_FIFO_DEPTH, or
 * the whole first buffer), so the sink does not count start-up underflows.
 * Without it nothing in the fabric is touched. */
struct fdrec_play_start {
	__u32 flags;            /* in: FDREC_PLAY_* */
	__u32 reserved0;
	__u64 start_time_ns;    /* out: CLOCK_REALTIME at start */
	__u64 reserved[4];
};

/*
 * FDREC_IOC_PLAY_SUBMIT: the app has filled buffer index with bytes bytes of
 * beats (multiple of 16, 1..buf_size); the driver cleans the cache over the
 * buffer (dma_sync_sgtable_for_device(DMA_TO_DEVICE)) and queues it to the
 * MM2S channel as one packet, TLAST on its last beat. Buffers are played in
 * submission order. The buffer belongs to the driver until PLAY_WAIT_DONE
 * returns it. -EINVAL: bad index/bytes or buffer not owned by the app.
 */
struct fdrec_play_submit {
	__u32 index;
	__u32 flags;            /* must be 0 */
	__u64 bytes;
};

/* struct fdrec_play_done.flags */
#define FDREC_DONE_ERROR                (1u << 0)   /* DMA reported an error */

/*
 * FDREC_IOC_PLAY_WAIT_DONE: wait for the next buffer the DMA has finished
 * reading (submission order). Returns 0 and index/bytes; -ETIMEDOUT,
 * -EINTR, -ENODATA (stopped, nothing left), -EIO (DMA error) as WAIT_FILLED.
 * Done means the DMA has read the buffer; its last beats may still be on
 * their way through the egress FIFO to the sink.
 */
struct fdrec_play_done {
	__s32 timeout_ms;       /* in: <0 = wait forever, 0 = poll */
	__u32 index;            /* out: buffer index */
	__u64 bytes;            /* out: bytes the DMA read (as submitted unless ERROR) */
	__u64 seq;              /* out: completion sequence number (0, 1, ... since PLAY_START) */
	__u32 flags;            /* out: FDREC_DONE_* */
	__u32 reserved0;
	__u64 reserved[2];
};

/* Checker (fdrec_check) counters, FDREC_CAP_CHECK. All 0 without the checker. */
struct fdrec_chk_stats {
	__u64 beats;            /* CHK_BEATS: beats accepted by the sink */
	__u64 errors;           /* CHK_ERRORS: beats with upper != ~lower */
	__u64 gaps;             /* CHK_GAPS: sequence discontinuities */
	__u64 gap_beats;        /* CHK_GAP_BEATS: missing sequence numbers in total */
	__u64 underflows;       /* CHK_UNDERFLOWS: sink ticks with no data (after the first beat) */
	__u64 last_seq;         /* CHK_LAST_SEQ: sequence number of the last beat */
	__u64 rate_bps;         /* sink throttle (CHK_RATE_INC) in bytes/s */
	__u32 enabled;          /* CHK_CTRL.ENABLE */
	__u32 reserved0;
	__u64 reserved[2];
};

/* FDREC_IOC_PLAY_STOP / FDREC_IOC_GET_PLAY_STATS. PLAY_STOP returns the values
 * read after the stop: the checker it started is frozen by then, so the
 * counters are one coherent set, and egr_discard includes the flushed beats.
 * After a complete playback (sink drained) they equal the values read just
 * before PLAY_STOP. PLAY_STOP sets EGR_CTRL.FLUSH so the (at most
 * two) buffers still owned by the DMA drain at once into the discard path
 * whatever the sink does, terminates the then idle MM2S channel and clears
 * FLUSH again. Beats already in the egress FIFO stay there for the sink. */
struct fdrec_play_stats {
	__u64 bufs_done;        /* buffers the DMA has finished since PLAY_START */
	__u64 bytes_done;       /* bytes the DMA has read since PLAY_START */
	__u32 bufs_dma;         /* buffers currently owned by the DMA (queued or active) */
	__u32 bufs_ready;       /* finished buffers waiting for PLAY_WAIT_DONE */
	__u32 running;          /* 1 between PLAY_START and PLAY_STOP */
	__u32 dma_errors;       /* completions with an error */
	struct fdrec_chk_stats chk;
	__u64 egr_beats_in;     /* EGR_BEATS_IN: beats written into the egress FIFO */
	__u64 egr_discard;      /* EGR_DISCARD: beats discarded by EGR_CTRL.FLUSH */
	__u32 egr_level;        /* EGR_FIFO_LEVEL: egress FIFO occupancy (beats) */
	__u32 egr_depth;        /* EGR_FIFO_DEPTH (beats) */
	__u64 reserved[4];
};

#define FDREC_IOC_MAGIC                 0xBD

#define FDREC_IOC_GET_INFO      _IOR(FDREC_IOC_MAGIC, 0x00, struct fdrec_info)
#define FDREC_IOC_REGISTER_BUFS _IOW(FDREC_IOC_MAGIC, 0x01, struct fdrec_bufs)
#define FDREC_IOC_START         _IOWR(FDREC_IOC_MAGIC, 0x02, struct fdrec_start)
#define FDREC_IOC_WAIT_FILLED   _IOWR(FDREC_IOC_MAGIC, 0x03, struct fdrec_filled)
#define FDREC_IOC_RELEASE       _IOW(FDREC_IOC_MAGIC, 0x04, struct fdrec_release)
#define FDREC_IOC_STOP          _IOR(FDREC_IOC_MAGIC, 0x05, struct fdrec_stats)
#define FDREC_IOC_GET_STATS     _IOR(FDREC_IOC_MAGIC, 0x06, struct fdrec_stats)
#define FDREC_IOC_SET_RATE      _IOWR(FDREC_IOC_MAGIC, 0x07, struct fdrec_rate)
/* Playback (FDREC_CAP_MM2S) */
#define FDREC_IOC_PLAY_START    _IOWR(FDREC_IOC_MAGIC, 0x08, struct fdrec_play_start)
#define FDREC_IOC_PLAY_SUBMIT   _IOW(FDREC_IOC_MAGIC, 0x09, struct fdrec_play_submit)
#define FDREC_IOC_PLAY_WAIT_DONE _IOWR(FDREC_IOC_MAGIC, 0x0A, struct fdrec_play_done)
#define FDREC_IOC_PLAY_STOP     _IOR(FDREC_IOC_MAGIC, 0x0B, struct fdrec_play_stats)
#define FDREC_IOC_GET_PLAY_STATS _IOR(FDREC_IOC_MAGIC, 0x0C, struct fdrec_play_stats)
/* FDREC_IOC_SET_SINK_RATE: program the checker's TREADY throttle
 * (CHK_RATE_INC, same Q1.31 scheme as the TPG) for rate_bps bytes/s; 0 is
 * refused (-EINVAL: a sink that never accepts would wedge the MM2S channel).
 * Returns the rate programmed. FDREC_CAP_CHECK. */
#define FDREC_IOC_SET_SINK_RATE _IOWR(FDREC_IOC_MAGIC, 0x0D, struct fdrec_rate)

#endif /* FDREC_UAPI_H */
