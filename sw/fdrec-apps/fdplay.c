// SPDX-License-Identifier: MIT
/*
 * fdplay -- FPGA Drive Recorder: play a recording back into the fabric.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Zero-copy, the mirror image of fdrec: the NVMe controller reads the file
 * straight into hugepage buffers (io_uring O_DIRECT reads), and the AXI DMA
 * MM2S channel streams the very same buffers to the fabric data sink. The CPU
 * only does the bookkeeping.
 *
 *   O_DIRECT read of chunk k into buffer k % N -> PLAY_SUBMIT (in file order)
 *   -> PLAY_WAIT_DONE -> the buffer takes the next chunk. Up to --qd reads in
 *   flight. The ring is filled completely before the first PLAY_SUBMIT, so
 *   the stream starts with N buffers of headroom.
 *
 * With the reference design's checker (fdrec_check) as the sink, the beats
 * are verified in hardware: pattern errors, sequence gaps and underflows
 * (sink ready, no data -- the SSD could not keep up with the sink rate).
 *
 * Exit codes: 0 = complete; with the checker also ERRORS = 0, UNDERFLOWS = 0
 *                 and GAP_BEATS = the recording's drop_count,
 *             2 = complete, but the checker found a problem,
 *             1 = error (incl. an incomplete playback).
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <endian.h>
#include <liburing.h>

#include "fdrec_uapi.h"
#include "fdrec_file.h"
#include "fdrec_common.h"

#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB    (21 << 26)      /* MAP_HUGE_SHIFT = 26 */
#endif

#define DEF_DEVICE      "/dev/fdrec0"
#define DEF_BUFFERS     32
#define DEF_BUF_SIZE    (8ull << 20)
#define DEF_QD          8
#define DEF_TIMEOUT     10.0            /* s without DMA progress = stalled */
#define HDR_SIZE        FDREC_FILE_HEADER_SIZE
/* DMA restart gap at every buffer boundary (xilinx_dma idles at the tail of
 * the current descriptor until its IRQ handler starts the next one): ~15 us
 * worst case measured on uzev. The egress FIFO must cover it at the sink rate. */
#define RESTART_GAP_US  15.0
#define BEAT_BYTES      16              /* bytes per 128-bit beat */

/* io_uring user_data: the poll request on the device, else a chunk number */
#define UD_POLL         ((uint64_t)-1)

const char *prog_name = "fdplay";

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

struct opts {
	const char *device;
	const char *input;
	uint64_t rate;          /* sink rate, 0 = leave as is */
	bool rate_set;
	unsigned buffers;
	uint64_t buf_size;
	unsigned qd;
	bool no_check;
	double stats;
	double timeout;
	bool quiet;
};

static void usage(FILE *f)
{
	fprintf(f,
"Usage: fdplay [options] <file>\n"
"\n"
"Play a recording made with fdrec back into the FPGA fabric (zero-copy: O_DIRECT\n"
"reads into hugepage buffers, the AXI DMA MM2S streams the same buffers to the\n"
"data sink, one AXI-Stream packet per buffer).\n"
"\n"
"Options:\n"
"  --rate <bytes/s>      program the sink's consumption rate (the checker's\n"
"                        TREADY throttle; suffixes K/M/G/T, powers of 1024;\n"
"                        KB/MB/GB/TB, powers of 1000; default: leave as is)\n"
"  --buffers <n>         number of buffers (default %d)\n"
"  --buf-size <bytes>    buffer size, multiple of 2 MB (default 8M)\n"
"  --qd <n>              io_uring queue depth: reads in flight (default %d)\n"
"  --no-check            do not touch the checker (your own data sink). On the\n"
"                        reference design the checker IS the sink: without it\n"
"                        enabled (sysfs chk_enable) the stream stalls\n"
"  --timeout <sec>       stall watchdog: abort cleanly when no buffer completes\n"
"                        for this long (default %.0f)\n"
"  --stats <sec>         live stats interval, 0 = off (default 1)\n"
"  --device <path>       recorder device (default %s)\n"
"  -q, --quiet           no live stats line\n"
"  -h, --help            this help\n"
"\n"
"With the checker (default) the file must be a test-pattern recording. fdplay\n"
"resets the checker before the first beat (the driver enables it once the\n"
"egress FIFO has primed) and reads its counters\n"
"once the last beat has reached the sink. An underflow is a sink cycle that\n"
"found no data: the SSD (or the ring) could not keep up with --rate.\n"
"\n"
"Needs (buffers x buf-size) of free 2 MB hugepages (see fdrec --help).\n"
"\n"
"Exit code: 0 = complete (with the checker: ERRORS = 0, UNDERFLOWS = 0 and\n"
"GAP_BEATS = the recording's drop_count), 2 = complete but the checker found\n"
"a problem, 1 = error or incomplete playback.\n",
		DEF_BUFFERS, DEF_QD, DEF_TIMEOUT, DEF_DEVICE);
}

static int parse_args(int argc, char **argv, struct opts *o)
{
	static const struct option lo[] = {
		{ "rate", required_argument, NULL, 'r' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "buf-size", required_argument, NULL, 'B' },
		{ "qd", required_argument, NULL, 'Q' },
		{ "no-check", no_argument, NULL, 'N' },
		{ "timeout", required_argument, NULL, 't' },
		{ "stats", required_argument, NULL, 'S' },
		{ "device", required_argument, NULL, 'D' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int c;

	memset(o, 0, sizeof(*o));
	o->device = DEF_DEVICE;
	o->buffers = DEF_BUFFERS;
	o->buf_size = DEF_BUF_SIZE;
	o->qd = DEF_QD;
	o->stats = 1.0;
	o->timeout = DEF_TIMEOUT;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		uint64_t v;

		switch (c) {
		case 'r':
			if (parse_size(optarg, &o->rate) || !o->rate)
				return die_usage("invalid --rate '%s' (must be > 0)", optarg);
			o->rate_set = true;
			break;
		case 'b':
			if (parse_size(optarg, &v) || v < 2 || v > FDREC_MAX_BUFS)
				return die_usage("--buffers must be 2..%d", FDREC_MAX_BUFS);
			o->buffers = (unsigned)v;
			break;
		case 'B':
			if (parse_size(optarg, &o->buf_size) || !o->buf_size ||
			    o->buf_size % FDREC_BUF_ALIGN ||
			    o->buf_size > FDREC_MAX_BUF_SIZE)
				return die_usage("--buf-size must be a non-zero multiple of 2 MB, at most 62 MB");
			break;
		case 'Q':
			if (parse_size(optarg, &v) || v < 1 || v > 256)
				return die_usage("--qd must be 1..256");
			o->qd = (unsigned)v;
			break;
		case 'N':
			o->no_check = true;
			break;
		case 't':
			if (parse_double(optarg, &o->timeout) || o->timeout <= 0)
				return die_usage("invalid --timeout '%s'", optarg);
			break;
		case 'S':
			if (parse_double(optarg, &o->stats) || o->stats < 0)
				return die_usage("invalid --stats '%s'", optarg);
			break;
		case 'D':
			o->device = optarg;
			break;
		case 'q':
			o->quiet = true;
			break;
		case 'h':
			usage(stdout);
			exit(0);
		default:
			usage(stderr);
			return -1;
		}
	}
	if (optind != argc - 1)
		return die_usage("exactly one <file> is required");
	o->input = argv[optind];
	if (o->no_check && o->rate_set)
		return die_usage("--rate programs the checker's throttle; it cannot be combined with --no-check");
	if (o->qd > o->buffers)
		o->qd = o->buffers;
	return 0;
}

/* ------------------------------------------------------------------------ */

enum bstate { B_EMPTY, B_READING, B_FILLED, B_DMA };

struct play {
	struct opts o;
	int dev;
	int in;
	struct fdrec_info info;
	struct fdrec_file_header *hdr;
	uint64_t data_bytes;    /* bytes to play (multiple of 16) */
	uint64_t nchunks;
	uint8_t *mem;
	size_t mem_len;
	enum bstate *st;
	struct io_uring ring;
	bool ring_ok;
	bool fixed;

	uint64_t next_read;     /* next chunk to read */
	uint64_t next_submit;   /* next chunk to PLAY_SUBMIT (file order) */
	uint64_t chunks_done;   /* chunks the DMA has finished */
	uint64_t prefill;       /* chunks to have read before the first submit */
	unsigned reads_inflight;
	unsigned max_reads_inflight;
	bool poll_armed;
	bool started;
	bool stopped;
	bool abort;             /* stop feeding (error or signal) */
	int error;

	uint64_t bytes_read;
	uint64_t bytes_done;
	double t0, t_last, t_progress;
	uint64_t bytes_last;
	struct fdrec_play_stats final;
};

static void set_error(struct play *p, int err)
{
	if (!p->error)
		p->error = err;
}

static uint64_t chunk_len(struct play *p, uint64_t k)
{
	uint64_t off = k * p->o.buf_size;
	uint64_t left = p->data_bytes - off;

	return left < p->o.buf_size ? left : p->o.buf_size;
}

static int read_header(struct play *p)
{
	struct stat sb;
	ssize_t n;
	uint64_t avail;
	uint32_t flags;

	if (posix_memalign((void **)&p->hdr, 4096, HDR_SIZE)) {
		err_msg("out of memory");
		return -1;
	}
	n = pread(p->in, p->hdr, HDR_SIZE, 0);
	if (n != HDR_SIZE) {
		if (n < 0)
			perr("read header of %s", p->o.input);
		else
			err_msg("%s: too short for a recording header", p->o.input);
		return -1;
	}
	if (memcmp(p->hdr->magic, FDREC_FILE_MAGIC, FDREC_FILE_MAGIC_LEN)) {
		err_msg("%s: not an fdrec recording (bad magic)", p->o.input);
		return -1;
	}
	if (le32toh(p->hdr->header_size) != HDR_SIZE ||
	    le32toh(p->hdr->beat_bytes) != BEAT_BYTES) {
		err_msg("%s: unsupported header (header_size %u, beat_bytes %u)",
			p->o.input, le32toh(p->hdr->header_size),
			le32toh(p->hdr->beat_bytes));
		return -1;
	}
	if (fstat(p->in, &sb) < 0) {
		perr("stat %s", p->o.input);
		return -1;
	}
	avail = (uint64_t)sb.st_size > HDR_SIZE ? (uint64_t)sb.st_size - HDR_SIZE : 0;
	flags = le32toh(p->hdr->flags);
	if (flags & FDREC_FILE_FLAG_COMPLETE) {
		p->data_bytes = le64toh(p->hdr->data_bytes);
		if (p->data_bytes > avail) {
			err_msg("%s: header says %" PRIu64 " data bytes, the file holds %" PRIu64
				" (truncated?)", p->o.input, p->data_bytes, avail);
			return -1;
		}
	} else {
		p->data_bytes = avail;
		fprintf(stderr, "fdplay: note: %s is an incomplete recording (no COMPLETE flag); playing all %" PRIu64
			" bytes after the header, drop_count unknown\n", p->o.input, avail);
	}
	if (p->data_bytes % BEAT_BYTES) {
		fprintf(stderr, "fdplay: note: ignoring %" PRIu64 " trailing bytes (not a whole beat)\n",
			p->data_bytes % BEAT_BYTES);
		p->data_bytes -= p->data_bytes % BEAT_BYTES;
	}
	if (!p->data_bytes) {
		err_msg("%s: no data to play", p->o.input);
		return -1;
	}
	if (!p->o.no_check && !(flags & FDREC_FILE_FLAG_TPG)) {
		err_msg("%s was not recorded from the test pattern generator: the checker would flag every beat; use --no-check",
			p->o.input);
		return -1;
	}
	return 0;
}

static int alloc_buffers(struct play *p)
{
	p->mem_len = (size_t)p->o.buffers * p->o.buf_size;
	p->mem = mmap(NULL, p->mem_len, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB |
		      MAP_POPULATE, -1, 0);
	if (p->mem == MAP_FAILED) {
		int e = errno;

		p->mem = NULL;
		err_msg("cannot allocate %u x %" PRIu64 " MB from 2 MB hugepages: %s",
			p->o.buffers, p->o.buf_size >> 20, strerror(e));
		err_msg("need %lu free hugepages, %lu free (HugePages_Free in /proc/meminfo); "
			"raise with: echo <N> > /proc/sys/vm/nr_hugepages",
			(unsigned long)(p->mem_len / FDREC_BUF_ALIGN), hugepages_free());
		return -1;
	}
	return 0;
}

static int get_stats(struct play *p, struct fdrec_play_stats *st)
{
	if (ioctl(p->dev, FDREC_IOC_GET_PLAY_STATS, st) < 0) {
		memset(st, 0, sizeof(*st));
		return -errno;
	}
	return 0;
}

static int do_stop(struct play *p)
{
	if (p->stopped || !p->started)
		return 0;
	p->stopped = true;
	if (ioctl(p->dev, FDREC_IOC_PLAY_STOP, &p->final) < 0) {
		int e = -errno;

		perr("FDREC_IOC_PLAY_STOP");
		return e;
	}
	return 0;
}

/* Queue O_DIRECT reads for the chunks whose buffers are free */
static void issue_reads(struct play *p)
{
	while (!p->abort && p->reads_inflight < p->o.qd &&
	       p->next_read < p->nchunks) {
		uint64_t k = p->next_read;
		unsigned idx = (unsigned)(k % p->o.buffers);
		uint64_t len = chunk_len(p, k);
		/* O_DIRECT: whole 4 KB blocks; a short read at EOF is fine */
		uint64_t rlen = (len + 4095) & ~4095ull;
		uint8_t *buf = p->mem + (size_t)idx * p->o.buf_size;
		struct io_uring_sqe *sqe;

		if (p->st[idx] != B_EMPTY)
			break;  /* the DMA still owns chunk k - N's buffer */
		sqe = io_uring_get_sqe(&p->ring);
		if (!sqe) {
			io_uring_submit(&p->ring);
			sqe = io_uring_get_sqe(&p->ring);
		}
		if (!sqe)
			break;
		if (p->fixed)
			io_uring_prep_read_fixed(sqe, p->in, buf, (unsigned)rlen,
						 HDR_SIZE + k * p->o.buf_size, (int)idx);
		else
			io_uring_prep_read(sqe, p->in, buf, (unsigned)rlen,
					   HDR_SIZE + k * p->o.buf_size);
		io_uring_sqe_set_data64(sqe, k);
		p->st[idx] = B_READING;
		p->next_read++;
		p->reads_inflight++;
		if (p->reads_inflight > p->max_reads_inflight)
			p->max_reads_inflight = p->reads_inflight;
	}
}

/* Hand the filled chunks to the DMA, strictly in file order */
static void submit_filled(struct play *p)
{
	if (!p->started || p->abort)
		return;
	/* prefill: start the stream only with a full ring of headroom */
	if (p->next_submit == 0) {
		uint64_t k;

		for (k = 0; k < p->prefill; k++)
			if (p->st[k % p->o.buffers] != B_FILLED)
				return;
	}
	while (p->next_submit < p->nchunks) {
		uint64_t k = p->next_submit;
		unsigned idx = (unsigned)(k % p->o.buffers);
		struct fdrec_play_submit s = { .index = idx, .bytes = chunk_len(p, k) };

		if (p->st[idx] != B_FILLED)
			break;
		if (ioctl(p->dev, FDREC_IOC_PLAY_SUBMIT, &s) < 0) {
			perr("FDREC_IOC_PLAY_SUBMIT (buffer %u, chunk %" PRIu64 ")", idx, k);
			set_error(p, -errno);
			p->abort = true;
			return;
		}
		p->st[idx] = B_DMA;
		p->next_submit++;
	}
}

/* Collect every buffer the DMA has finished (non-blocking) */
static void collect_done(struct play *p)
{
	for (;;) {
		struct fdrec_play_done d = { .timeout_ms = 0 };

		if (ioctl(p->dev, FDREC_IOC_PLAY_WAIT_DONE, &d) < 0) {
			if (errno == ETIMEDOUT || errno == EINTR || errno == ENODATA)
				return;
			if (errno == EIO)
				err_msg("DMA error reported for buffer %u", d.index);
			else
				perr("FDREC_IOC_PLAY_WAIT_DONE");
			set_error(p, -errno);
			p->abort = true;
			return;
		}
		if (d.seq != p->chunks_done) {
			err_msg("completion sequence jumped from %" PRIu64 " to %" PRIu64,
				p->chunks_done, (uint64_t)d.seq);
			set_error(p, -EPROTO);
			p->abort = true;
		}
		if (d.index != p->chunks_done % p->o.buffers ||
		    d.bytes != chunk_len(p, p->chunks_done)) {
			err_msg("buffer %u completed with %" PRIu64 " bytes, expected buffer %u with %" PRIu64,
				d.index, (uint64_t)d.bytes,
				(unsigned)(p->chunks_done % p->o.buffers),
				chunk_len(p, p->chunks_done));
			set_error(p, -EPROTO);
			p->abort = true;
		}
		p->st[d.index] = B_EMPTY;
		p->bytes_done += d.bytes;
		p->chunks_done++;
		p->t_progress = now_s();
	}
}

static void handle_cqe(struct play *p, struct io_uring_cqe *cqe)
{
	uint64_t ud = io_uring_cqe_get_data64(cqe);
	uint64_t k, len;
	unsigned idx;

	if (ud == UD_POLL) {
		p->poll_armed = false;
		if (cqe->res < 0 && cqe->res != -ECANCELED) {
			errno = -cqe->res;
			perr("poll on the recorder device");
			set_error(p, cqe->res);
			p->abort = true;
		}
		return;
	}
	k = ud;
	idx = (unsigned)(k % p->o.buffers);
	len = chunk_len(p, k);
	p->reads_inflight--;
	if (cqe->res < 0 || (uint64_t)cqe->res < len) {
		if (cqe->res < 0) {
			errno = -cqe->res;
			perr("read %s at offset %" PRIu64, p->o.input,
			     (uint64_t)HDR_SIZE + k * p->o.buf_size);
			set_error(p, cqe->res);
		} else {
			err_msg("short read from %s (%d of %" PRIu64 " bytes at offset %" PRIu64 ")",
				p->o.input, cqe->res, len,
				(uint64_t)HDR_SIZE + k * p->o.buf_size);
			set_error(p, -EIO);
		}
		p->st[idx] = B_EMPTY;
		p->abort = true;
		return;
	}
	p->st[idx] = B_FILLED;
	p->bytes_read += len;
}

static int arm_poll(struct play *p)
{
	struct io_uring_sqe *sqe;

	if (p->poll_armed)
		return 0;
	sqe = io_uring_get_sqe(&p->ring);
	if (!sqe)
		return -EBUSY;
	io_uring_prep_poll_add(sqe, p->dev, POLLIN);
	io_uring_sqe_set_data64(sqe, UD_POLL);
	p->poll_armed = true;
	return 0;
}

static unsigned bufs_in_dma(struct play *p)
{
	unsigned i, n = 0;

	for (i = 0; i < p->o.buffers; i++)
		if (p->st[i] == B_DMA)
			n++;
	return n;
}

static void print_stats(struct play *p, bool final)
{
	struct fdrec_play_stats st;
	double now = now_s();
	double el = now - p->t0;
	double dt = now - p->t_last;
	double inst = dt > 0 ? (p->bytes_done - p->bytes_last) / dt / 1e6 : 0;
	double avg = el > 0 ? p->bytes_done / el / 1e6 : 0;

	get_stats(p, &st);
	fprintf(stderr,
		"%s%8.1fs %8.1f MB/s (avg %7.1f) %12.3f GB  reads %2u  in DMA %2u  underflows %" PRIu64 "%s",
		isatty(2) ? "\r" : "", el, inst, avg, p->bytes_done / 1e9,
		p->reads_inflight, bufs_in_dma(p), (uint64_t)st.chk.underflows,
		(isatty(2) && !final) ? "   " : "\n");
	fflush(stderr);
	p->t_last = now;
	p->bytes_last = p->bytes_done;
}

/*
 * The DMA is done when it has read the last buffer; the last beats may still
 * sit in the egress FIFO. Wait until the sink has them all (checker: BEATS
 * reaches the beats played; otherwise: the egress FIFO is empty).
 */
static void wait_sink_drained(struct play *p)
{
	uint64_t want = p->data_bytes / BEAT_BYTES;
	double deadline = now_s() + p->o.timeout;
	struct fdrec_play_stats st;

	if (!(p->info.caps & FDREC_CAP_CHECK))
		return;
	while (now_s() < deadline) {
		if (get_stats(p, &st))
			return;
		if (p->o.no_check ? st.egr_level == 0 : st.chk.beats >= want)
			return;
		usleep(1000);
	}
	err_msg("the sink did not take the last beats within %.0f s (egress FIFO level %u)",
		p->o.timeout, st.egr_level);
}

int main(int argc, char **argv)
{
	struct play pp, *p = &pp;
	struct fdrec_bufs reg;
	struct fdrec_play_start start;
	struct fdrec_play_stats st;
	struct sigaction sa;
	uint64_t *addrs = NULL;
	struct iovec *iov = NULL;
	double next_stats;
	uint64_t want_beats, hdr_drops = 0, first_seq;
	bool complete, check_ok = true, hdr_complete;
	int ret = 1, e;
	unsigned i;

	memset(p, 0, sizeof(*p));
	p->dev = p->in = -1;
	if (parse_args(argc, argv, &p->o))
		return 1;

	p->in = open(p->o.input, O_RDONLY | O_DIRECT | O_CLOEXEC);
	if (p->in < 0) {
		perr("open %s with O_DIRECT", p->o.input);
		goto out;
	}
	if (read_header(p))
		goto out;
	hdr_complete = le32toh(p->hdr->flags) & FDREC_FILE_FLAG_COMPLETE;
	hdr_drops = le64toh(p->hdr->drop_count);
	first_seq = le64toh(p->hdr->first_seq);
	p->nchunks = (p->data_bytes + p->o.buf_size - 1) / p->o.buf_size;
	p->prefill = p->nchunks < p->o.buffers ? p->nchunks : p->o.buffers;

	p->dev = open(p->o.device, O_RDWR | O_CLOEXEC);
	if (p->dev < 0) {
		perr("open %s (is the fdrec module loaded?)", p->o.device);
		goto out;
	}
	if (ioctl(p->dev, FDREC_IOC_GET_INFO, &p->info) < 0) {
		perr("FDREC_IOC_GET_INFO");
		goto out;
	}
	if (p->info.api_version != FDREC_API_VERSION) {
		err_msg("driver API version %u, this fdplay expects %u",
			p->info.api_version, FDREC_API_VERSION);
		goto out;
	}
	if (!(p->info.caps & FDREC_CAP_MM2S)) {
		err_msg("%s has no playback channel (needs a design with the AXI DMA MM2S, fdrec_core 1.1, and dma-names \"tx\" in the device tree)",
			p->o.device);
		goto out;
	}
	if (!p->o.no_check && !(p->info.caps & FDREC_CAP_CHECK)) {
		err_msg("%s has no checker (fdrec_core %u.%u); use --no-check",
			p->o.device, p->info.hw_version >> 16, p->info.hw_version & 0xffff);
		goto out;
	}

	if (p->o.rate_set) {
		struct fdrec_rate rt = { .rate_bps = p->o.rate };

		if (ioctl(p->dev, FDREC_IOC_SET_SINK_RATE, &rt) < 0) {
			perr("FDREC_IOC_SET_SINK_RATE");
			goto out;
		}
		p->o.rate = rt.rate_bps;
	}
	/* Underflow budget: FIFO bytes / sink rate must exceed the restart gap */
	if (!p->o.no_check && get_stats(p, &st) == 0 && st.egr_depth &&
	    st.chk.rate_bps * RESTART_GAP_US / 1e6 > (double)st.egr_depth * BEAT_BYTES)
		fprintf(stderr, "fdplay: warning: at %.1f MB/s the %u-beat egress FIFO covers only %.1f us of the ~%.0f us DMA restart gap at each buffer boundary: expect underflows (lower --rate, or a deeper EGR FIFO in the design)\n",
			st.chk.rate_bps / 1e6, st.egr_depth,
			(double)st.egr_depth * BEAT_BYTES / st.chk.rate_bps * 1e6, RESTART_GAP_US);
	if (p->o.no_check && (p->info.caps & FDREC_CAP_CHECK) &&
	    get_stats(p, &st) == 0 && !st.chk.enabled)
		fprintf(stderr, "fdplay: note: the checker is disabled; if it is still the data sink in this design, the stream will stall (enable it: echo 1 > /sys/class/misc/fdrec0/chk_enable)\n");

	if (alloc_buffers(p))
		goto out;
	addrs = calloc(p->o.buffers, sizeof(*addrs));
	iov = calloc(p->o.buffers, sizeof(*iov));
	p->st = calloc(p->o.buffers, sizeof(*p->st));
	if (!addrs || !iov || !p->st) {
		err_msg("out of memory");
		goto out;
	}
	for (i = 0; i < p->o.buffers; i++) {
		addrs[i] = (uintptr_t)(p->mem + (size_t)i * p->o.buf_size);
		iov[i].iov_base = p->mem + (size_t)i * p->o.buf_size;
		iov[i].iov_len = p->o.buf_size;
		p->st[i] = B_EMPTY;
	}
	memset(&reg, 0, sizeof(reg));
	reg.addrs = (uintptr_t)addrs;
	reg.buf_size = p->o.buf_size;
	reg.count = p->o.buffers;
	reg.flags = FDREC_DIR_PLAY;
	if (ioctl(p->dev, FDREC_IOC_REGISTER_BUFS, &reg) < 0) {
		perr("FDREC_IOC_REGISTER_BUFS (%u x %" PRIu64 " MB, playback)",
		     p->o.buffers, p->o.buf_size >> 20);
		goto out;
	}

	if (io_uring_queue_init(p->o.qd + 2, &p->ring, 0) < 0) {
		err_msg("io_uring_queue_init failed (CONFIG_IO_URING?)");
		goto out;
	}
	p->ring_ok = true;
	p->fixed = io_uring_register_buffers(&p->ring, iov, p->o.buffers) == 0;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;      /* no SA_RESTART: interrupt the wait */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	/* Checker reset before any data can reach it; the driver enables it once
	 * the first buffer has primed the egress FIFO */
	memset(&start, 0, sizeof(start));
	start.flags = p->o.no_check ? 0 : FDREC_PLAY_CHECK;
	if (ioctl(p->dev, FDREC_IOC_PLAY_START, &start) < 0) {
		perr("FDREC_IOC_PLAY_START");
		goto out;
	}
	p->started = true;
	p->t0 = p->t_last = p->t_progress = now_s();

	if (!p->o.quiet && isatty(2)) {
		struct fdrec_play_stats s0;

		get_stats(p, &s0);
		fprintf(stderr, "fdplay: playing %s, %.3f GB (%u x %" PRIu64 " MB buffers, qd %u%s), sink %s at %.1f MB/s -- Ctrl-C to stop\n",
			p->o.input, p->data_bytes / 1e9, p->o.buffers,
			p->o.buf_size >> 20, p->o.qd, p->fixed ? ", fixed buffers" : "",
			p->o.no_check ? "(own)" : "checker", s0.chk.rate_bps / 1e6);
	}
	next_stats = p->t0 + (p->o.stats > 0 ? p->o.stats : 1e30);

	/* ---- main loop ---- */
	for (;;) {
		struct io_uring_cqe *cqe;
		struct __kernel_timespec ts;
		double now = now_s(), wait_s;
		unsigned head, seen;

		if (g_stop && !p->abort) {
			fprintf(stderr, "\nfdplay: interrupted\n");
			p->abort = true;
		}
		collect_done(p);
		issue_reads(p);
		submit_filled(p);
		if (p->chunks_done == p->nchunks)
			break;
		if (p->abort && p->reads_inflight == 0)
			break;
		if (!p->abort && p->next_submit > p->chunks_done)
			arm_poll(p);
		io_uring_submit(&p->ring);

		/* Stall watchdog: buffers in the DMA, no completion for too long */
		if (!p->abort && p->next_submit > p->chunks_done &&
		    now - p->t_progress > p->o.timeout) {
			get_stats(p, &st);
			err_msg("playback stalled: no buffer completed for %.0f s (sink not accepting? checker %s, egress FIFO %u/%u)",
				p->o.timeout, st.chk.enabled ? "enabled" : "DISABLED",
				st.egr_level, st.egr_depth);
			set_error(p, -ETIMEDOUT);
			p->abort = true;
		}

		if (!p->o.quiet && p->o.stats > 0 && now >= next_stats) {
			print_stats(p, false);
			while (next_stats <= now)
				next_stats += p->o.stats;
		}
		wait_s = (p->o.stats > 0 ? next_stats : now + 0.5) - now;
		if (wait_s < 0.001)
			wait_s = 0.001;
		if (wait_s > 0.5)
			wait_s = 0.5;
		ts.tv_sec = (long long)wait_s;
		ts.tv_nsec = (long long)((wait_s - (double)ts.tv_sec) * 1e9);
		e = io_uring_wait_cqe_timeout(&p->ring, &cqe, &ts);
		if (e < 0 && e != -ETIME && e != -EINTR) {
			errno = -e;
			perr("io_uring_wait_cqe");
			set_error(p, e);
			p->abort = true;
		}
		seen = 0;
		io_uring_for_each_cqe(&p->ring, head, cqe) {
			handle_cqe(p, cqe);
			seen++;
		}
		io_uring_cq_advance(&p->ring, seen);
	}

	if (p->poll_armed) {
		struct io_uring_sqe *sqe = io_uring_get_sqe(&p->ring);

		if (sqe) {
			io_uring_prep_poll_remove(sqe, UD_POLL);
			io_uring_submit(&p->ring);
		}
	}

	complete = p->chunks_done == p->nchunks && !p->error;
	if (complete)
		wait_sink_drained(p);
	e = do_stop(p);         /* final counters, read after the stop (checker frozen) */
	if (e)
		set_error(p, e);
	if (!p->o.quiet && p->o.stats > 0)
		print_stats(p, true);

	want_beats = p->data_bytes / BEAT_BYTES;
	{
		double el = now_s() - p->t0;
		const struct fdrec_chk_stats *c = &p->final.chk;

		printf("fdplay: %s: %" PRIu64 " of %" PRIu64 " bytes (%" PRIu64 " buffers) in %.2f s, %.1f MB/s%s\n",
		       p->o.input, p->bytes_done, p->data_bytes, p->chunks_done, el,
		       el > 0 ? p->bytes_done / el / 1e6 : 0.0,
		       complete ? "" : " -- INCOMPLETE");
		if (!p->o.no_check) {
			/* first sequence number the sink saw (valid without
			 * pattern errors): last + 1 = first + beats + gap_beats */
			uint64_t first_seen = c->last_seq + 1 - c->beats - c->gap_beats;
			bool first_ok = !c->beats || c->errors || first_seen == first_seq;

			printf("fdplay: checker: beats %" PRIu64 " (expected %" PRIu64 "), errors %" PRIu64
			       ", gaps %" PRIu64 ", gap beats %" PRIu64 " (recording drop_count %" PRIu64
			       "%s), underflows %" PRIu64 ", last seq %" PRIu64 ", sink rate %.1f MB/s\n",
			       (uint64_t)c->beats, want_beats, (uint64_t)c->errors, (uint64_t)c->gaps,
			       (uint64_t)c->gap_beats, hdr_drops, hdr_complete ? "" : ", unknown",
			       (uint64_t)c->underflows, (uint64_t)c->last_seq, c->rate_bps / 1e6);
			if (c->errors) {
				printf("PROBLEM: %" PRIu64 " beats failed the pattern check\n", (uint64_t)c->errors);
				check_ok = false;
			}
			if (c->underflows) {
				printf("PROBLEM: %" PRIu64 " underflows: the stream ran dry (reads slower than the sink rate)\n",
				       (uint64_t)c->underflows);
				check_ok = false;
			}
			if (hdr_complete && c->gap_beats != hdr_drops) {
				printf("PROBLEM: gap beats %" PRIu64 " != the recording's drop_count %" PRIu64 "\n",
				       (uint64_t)c->gap_beats, hdr_drops);
				check_ok = false;
			}
			if (!first_ok) {
				printf("PROBLEM: first beat at the sink %" PRIu64 " != header first_seq %" PRIu64 "\n",
				       first_seen, first_seq);
				check_ok = false;
			}
			if (complete && c->beats != want_beats) {
				printf("PROBLEM: the sink took %" PRIu64 " beats, %" PRIu64 " were played\n",
				       (uint64_t)c->beats, want_beats);
				check_ok = false;
			}
		}
		/* One machine-readable line for scripts */
		printf("RESULT bytes=%" PRIu64 " seconds=%.3f sink_rate_bps=%" PRIu64
		       " beats=%" PRIu64 " errors=%" PRIu64 " gaps=%" PRIu64 " gap_beats=%" PRIu64
		       " drop_count=%" PRIu64 " underflows=%" PRIu64 " egr_discard=%" PRIu64
		       " max_reads=%u complete=%d error=%d\n",
		       p->bytes_done, el, (uint64_t)c->rate_bps, (uint64_t)c->beats,
		       (uint64_t)c->errors, (uint64_t)c->gaps, (uint64_t)c->gap_beats, hdr_drops,
		       (uint64_t)c->underflows, (uint64_t)p->final.egr_discard,
		       p->max_reads_inflight, complete, p->error);
	}

	if (!complete || p->error)
		ret = 1;
	else if (!p->o.no_check && !check_ok)
		ret = 2;
	else
		ret = 0;
out:
	if (p->ring_ok)
		io_uring_queue_exit(&p->ring);
	if (p->dev >= 0)
		close(p->dev);          /* driver stops and unpins */
	if (p->in >= 0)
		close(p->in);
	if (p->mem)
		munmap(p->mem, p->mem_len);
	free(p->hdr);
	free(p->st);
	free(addrs);
	free(iov);
	return ret;
}
