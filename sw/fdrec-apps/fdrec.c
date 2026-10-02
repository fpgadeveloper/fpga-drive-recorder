// SPDX-License-Identifier: MIT
/*
 * fdrec -- FPGA Drive Recorder: record the fabric data stream to a file.
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Zero-copy: the AXI DMA fills hugepage buffers in DDR, and the NVMe controller
 * reads the very same buffers when they are written to the file with O_DIRECT
 * (io_uring). The CPU only does the bookkeeping.
 *
 *   WAIT_FILLED -> io_uring write at the next file offset -> on completion,
 *   RELEASE the buffer back to the DMA. Up to --qd writes in flight.
 *
 * Exit codes: 0 = recording complete with zero dropped beats,
 *             2 = recording complete but beats were dropped,
 *             1 = error.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
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

#ifndef FDREC_TARGET
#define FDREC_TARGET "unknown"
#endif

#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB    (21 << 26)      /* MAP_HUGE_SHIFT = 26 */
#endif

#define DEF_DEVICE      "/dev/fdrec0"
#define DEF_BUFFERS     32
#define DEF_BUF_SIZE    (8ull << 20)
#define DEF_QD          8
#define DEF_TIMEOUT     10.0            /* s without a completed buffer = stalled */
#define HDR_SIZE        FDREC_FILE_HEADER_SIZE
/* DMA restart gap at every buffer boundary (~15 us worst case on uzev): the
 * ingest FIFO must absorb it at the source rate */
#define RESTART_GAP_US  15.0

/* user_data of the io_uring poll request on the device */
#define UD_POLL         ((uint64_t)-1)

const char *prog_name = "fdrec";

static volatile sig_atomic_t g_stop;

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

struct opts {
	const char *device;
	const char *output;
	const char *target;
	uint64_t size;          /* 0 = unlimited */
	double duration;        /* 0 = unlimited */
	uint64_t rate;          /* 0 = leave as is */
	bool rate_set;
	unsigned buffers;
	uint64_t buf_size;
	unsigned qd;
	bool no_tpg;
	double stats;
	double timeout;
	bool quiet;
};

static void usage(FILE *f)
{
	fprintf(f,
"Usage: fdrec [options] <output-file>\n"
"\n"
"Record the FPGA fabric data stream to <output-file> (zero-copy: DMA into\n"
"hugepage buffers, O_DIRECT writes from the same buffers).\n"
"\n"
"Options:\n"
"  --size <bytes>        stop after this many bytes of data (suffixes K/M/G/T,\n"
"                        powers of 1024; KB/MB/GB/TB, powers of 1000)\n"
"  --duration <sec>      stop after this many seconds\n"
"  --rate <bytes/s>      program the test pattern generator rate (same\n"
"                        suffixes; default: leave as is)\n"
"  --buffers <n>         number of buffers (default %d)\n"
"  --buf-size <bytes>    buffer size, multiple of 2 MB (default 8M)\n"
"  --qd <n>              io_uring queue depth: writes in flight (default %d)\n"
"  --no-tpg              do not touch the generator (user's own data source)\n"
"  --timeout <sec>       stall watchdog: abort cleanly when no buffer completes\n"
"                        for this long (default %.0f)\n"
"  --stats <sec>         live stats interval, 0 = off (default 1)\n"
"  --device <path>       recorder device (default %s)\n"
"  --target <name>       target name stored in the header (default %s)\n"
"  -q, --quiet           no live stats line\n"
"  -h, --help            this help\n"
"\n"
"Without --size or --duration, records until Ctrl-C. The file is a 4096-byte\n"
"header followed by the raw 16-byte beats; check it with fdverify.\n"
"\n"
"Needs (buffers x buf-size) of free 2 MB hugepages (default 32 x 8 MB =\n"
"256 MB = 128 pages; the reference image reserves 512 MB with the\n"
"hugepagesz=2M hugepages=256 kernel arguments). Change it at run time with:\n"
"  echo <N> > /proc/sys/vm/nr_hugepages\n"
"\n"
"A stall (no buffer filled by the DMA or written to the file for --timeout\n"
"seconds: source not producing, DMA wedged, SSD not completing writes) stops\n"
"the recording; the file keeps what was written and its header is finalised.\n"
"\n"
"Exit code: 0 = complete with zero dropped beats, 2 = beats were dropped,\n"
"1 = error (including a stall).\n",
		DEF_BUFFERS, DEF_QD, DEF_TIMEOUT, DEF_DEVICE, FDREC_TARGET);
}

static int parse_args(int argc, char **argv, struct opts *o)
{
	static const struct option lo[] = {
		{ "size", required_argument, NULL, 's' },
		{ "duration", required_argument, NULL, 'd' },
		{ "rate", required_argument, NULL, 'r' },
		{ "buffers", required_argument, NULL, 'b' },
		{ "buf-size", required_argument, NULL, 'B' },
		{ "qd", required_argument, NULL, 'Q' },
		{ "no-tpg", no_argument, NULL, 'N' },
		{ "stats", required_argument, NULL, 'S' },
		{ "timeout", required_argument, NULL, 't' },
		{ "device", required_argument, NULL, 'D' },
		{ "target", required_argument, NULL, 'T' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	int c;

	memset(o, 0, sizeof(*o));
	o->device = DEF_DEVICE;
	o->target = FDREC_TARGET;
	o->buffers = DEF_BUFFERS;
	o->buf_size = DEF_BUF_SIZE;
	o->qd = DEF_QD;
	o->stats = 1.0;
	o->timeout = DEF_TIMEOUT;

	while ((c = getopt_long(argc, argv, "qh", lo, NULL)) != -1) {
		uint64_t v;

		switch (c) {
		case 's':
			if (parse_size(optarg, &o->size) || !o->size)
				return die_usage("invalid --size '%s'", optarg);
			break;
		case 'd':
			if (parse_double(optarg, &o->duration) || o->duration <= 0)
				return die_usage("invalid --duration '%s'", optarg);
			break;
		case 'r':
			if (parse_size(optarg, &o->rate))
				return die_usage("invalid --rate '%s'", optarg);
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
			o->no_tpg = true;
			break;
		case 'S':
			if (parse_double(optarg, &o->stats) || o->stats < 0)
				return die_usage("invalid --stats '%s'", optarg);
			break;
		case 't':
			if (parse_double(optarg, &o->timeout) || o->timeout <= 0)
				return die_usage("invalid --timeout '%s'", optarg);
			break;
		case 'D':
			o->device = optarg;
			break;
		case 'T':
			o->target = optarg;
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
		return die_usage("exactly one <output-file> is required");
	o->output = argv[optind];
	if (o->no_tpg && o->rate_set)
		return die_usage("--rate programs the test pattern generator; it cannot be combined with --no-tpg");
	if (o->qd > o->buffers)
		o->qd = o->buffers;
	return 0;
}

/* ------------------------------------------------------------------------ */

struct rec {
	struct opts o;
	int dev;
	int out;
	struct fdrec_info info;
	uint8_t *mem;
	size_t mem_len;
	struct io_uring ring;
	bool fixed;             /* buffers registered with io_uring */
	struct fdrec_file_header *hdr;

	unsigned inflight;      /* writes in flight */
	bool poll_armed;
	bool dev_hup;
	bool stopped;           /* STOP issued */
	bool done_filling;      /* no more buffers wanted */
	int error;              /* first error (negative errno) */

	uint64_t bytes_submitted;
	uint64_t bytes_written;
	uint64_t bufs_written;
	uint64_t last_drop;     /* drop count snapshot of the last buffer taken */
	uint64_t next_fill_seq;
	struct fdrec_stats final;

	double t0, t_last;
	double t_progress;       /* last buffer filled or written */
	uint64_t bytes_last;
	unsigned max_inflight;
};

static int arm_poll(struct rec *r)
{
	struct io_uring_sqe *sqe;

	if (r->poll_armed || r->dev_hup)
		return 0;
	sqe = io_uring_get_sqe(&r->ring);
	if (!sqe)
		return -EBUSY;
	io_uring_prep_poll_add(sqe, r->dev, POLLIN);
	io_uring_sqe_set_data64(sqe, UD_POLL);
	r->poll_armed = true;
	return 0;
}

static void set_error(struct rec *r, int err)
{
	if (!r->error)
		r->error = err;
}

static int do_stop(struct rec *r)
{
	if (r->stopped)
		return 0;
	r->stopped = true;
	r->done_filling = true;
	if (ioctl(r->dev, FDREC_IOC_STOP, &r->final) < 0) {
		int e = -errno;

		perr("FDREC_IOC_STOP");
		return e;
	}
	return 0;
}

static void release_buf(struct rec *r, unsigned idx)
{
	struct fdrec_release rel = { .index = idx };

	if (ioctl(r->dev, FDREC_IOC_RELEASE, &rel) < 0) {
		perr("FDREC_IOC_RELEASE");
		set_error(r, -errno);
	}
}

/* Take every filled buffer we can submit a write for (non-blocking) */
static void take_filled(struct rec *r)
{
	while (!r->done_filling && r->inflight < r->o.qd) {
		struct fdrec_filled f = { .timeout_ms = 0 };
		struct io_uring_sqe *sqe;
		uint64_t len, remain;
		uint8_t *buf;

		if (ioctl(r->dev, FDREC_IOC_WAIT_FILLED, &f) < 0) {
			if (errno == ETIMEDOUT || errno == EINTR)
				return;
			if (errno == ENODATA) {
				r->dev_hup = true;
				r->done_filling = true;
				return;
			}
			if (errno == EIO)
				err_msg("DMA error reported for buffer %u (fill #%" PRIu64 ")",
					f.index, (uint64_t)f.seq);
			else
				perr("FDREC_IOC_WAIT_FILLED");
			set_error(r, -errno);
			r->done_filling = true;
			return;
		}
		if (f.seq != r->next_fill_seq) {
			err_msg("buffer fill sequence jumped from %" PRIu64 " to %" PRIu64,
				r->next_fill_seq, (uint64_t)f.seq);
			set_error(r, -EPROTO);
		}
		r->next_fill_seq = f.seq + 1;
		r->t_progress = now_s();
		if (f.flags & FDREC_FILLED_SHORT) {
			err_msg("buffer %u holds %" PRIu64 " of %" PRIu64
				" bytes: packet framing lost (PKT_LEN mismatch?)",
				f.index, (uint64_t)f.bytes, r->o.buf_size);
			set_error(r, -EPROTO);
			release_buf(r, f.index);
			r->done_filling = true;
			return;
		}
		r->last_drop = f.drop_count;

		len = f.bytes;
		if (r->o.size) {
			remain = r->o.size - r->bytes_submitted;
			if (len >= remain) {
				len = remain;   /* o.size is a 4 KB multiple */
				r->done_filling = true;
			}
		}
		buf = r->mem + (size_t)f.index * r->o.buf_size;
		sqe = io_uring_get_sqe(&r->ring);
		if (!sqe) {
			io_uring_submit(&r->ring);
			sqe = io_uring_get_sqe(&r->ring);
		}
		if (!sqe) {
			err_msg("io_uring submission queue full");
			set_error(r, -EBUSY);
			release_buf(r, f.index);
			r->done_filling = true;
			return;
		}
		if (r->fixed)
			io_uring_prep_write_fixed(sqe, r->out, buf, (unsigned)len,
						  HDR_SIZE + r->bytes_submitted,
						  (int)f.index);
		else
			io_uring_prep_write(sqe, r->out, buf, (unsigned)len,
					    HDR_SIZE + r->bytes_submitted);
		io_uring_sqe_set_data64(sqe, ((uint64_t)f.index << 32) | (uint32_t)len);
		r->bytes_submitted += len;
		r->inflight++;
		if (r->inflight > r->max_inflight)
			r->max_inflight = r->inflight;
	}
}

static void handle_cqe(struct rec *r, struct io_uring_cqe *cqe)
{
	uint64_t ud = io_uring_cqe_get_data64(cqe);

	if (ud == UD_POLL) {
		r->poll_armed = false;
		if (cqe->res < 0 && cqe->res != -ECANCELED) {
			errno = -cqe->res;
			perr("poll on the recorder device");
			set_error(r, cqe->res);
			r->done_filling = true;
		} else if (cqe->res > 0 && (cqe->res & (POLLHUP | POLLERR)) &&
			   !(cqe->res & POLLIN)) {
			r->dev_hup = true;
			r->done_filling = true;
		}
		return;
	} else {
		unsigned idx = (unsigned)(ud >> 32);
		unsigned len = (unsigned)(ud & 0xffffffffu);

		r->inflight--;
		if (cqe->res != (int)len) {
			if (cqe->res < 0) {
				errno = -cqe->res;
				perr("write to %s", r->o.output);
				set_error(r, cqe->res);
			} else {
				err_msg("short write to %s (%d of %u bytes)",
					r->o.output, cqe->res, len);
				set_error(r, -EIO);
			}
			r->done_filling = true;
		} else {
			r->bytes_written += len;
			r->bufs_written++;
			r->t_progress = now_s();
		}
		release_buf(r, idx);
	}
}

static void print_stats(struct rec *r, bool final)
{
	struct fdrec_stats st;
	double now = now_s();
	double el = now - r->t0;
	double dt = now - r->t_last;
	double inst = dt > 0 ? (r->bytes_written - r->bytes_last) / dt / 1e6 : 0;
	double avg = el > 0 ? r->bytes_written / el / 1e6 : 0;

	if (ioctl(r->dev, FDREC_IOC_GET_STATS, &st) < 0)
		memset(&st, 0, sizeof(st));
	if (r->stopped)
		st = r->final;
	fprintf(stderr,
		"%s%8.1fs %8.1f MB/s (avg %7.1f) %12.3f GB  inflight %2u  fifo_hwm %5u/%u  drops %" PRIu64 "%s",
		isatty(2) ? "\r" : "", el, inst, avg, r->bytes_written / 1e9,
		r->inflight, st.fifo_hwm, st.fifo_depth, (uint64_t)st.drop_count,
		(isatty(2) && !final) ? "   " : "\n");
	fflush(stderr);
	r->t_last = now;
	r->bytes_last = r->bytes_written;
}

static int alloc_buffers(struct rec *r)
{
	unsigned long need, freepg;

	r->mem_len = (size_t)r->o.buffers * r->o.buf_size;
	r->mem = mmap(NULL, r->mem_len, PROT_READ | PROT_WRITE,
		      MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB |
		      MAP_POPULATE, -1, 0);
	if (r->mem == MAP_FAILED) {
		int e = errno;

		r->mem = NULL;
		need = r->mem_len / FDREC_BUF_ALIGN;
		freepg = hugepages_free();
		err_msg("cannot allocate %u x %" PRIu64 " MB from 2 MB hugepages: %s",
			r->o.buffers, r->o.buf_size >> 20, strerror(e));
		err_msg("need %lu free hugepages, %lu free (HugePages_Free in /proc/meminfo); "
			"raise with: echo <N> > /proc/sys/vm/nr_hugepages", need, freepg);
		return -e;
	}
	return 0;
}

static int write_header(struct rec *r)
{
	ssize_t n = pwrite(r->out, r->hdr, HDR_SIZE, 0);

	if (n != HDR_SIZE) {
		perr("write header to %s", r->o.output);
		return n < 0 ? -errno : -EIO;
	}
	return 0;
}

int main(int argc, char **argv)
{
	struct rec rr, *r = &rr;
	struct fdrec_bufs reg;
	struct fdrec_start start;
	struct sigaction sa;
	uint64_t *addrs = NULL;
	struct iovec *iov = NULL;
	double next_stats, deadline = 0;
	int ret = 1, e;
	unsigned i;

	memset(r, 0, sizeof(*r));
	r->dev = r->out = -1;
	if (parse_args(argc, argv, &r->o))
		return 1;
	if (r->o.size % 4096) {
		r->o.size = (r->o.size + 4095) & ~4095ull;
		fprintf(stderr, "fdrec: --size rounded up to %" PRIu64 " bytes (O_DIRECT needs 4 KB multiples)\n",
			r->o.size);
	}

	r->dev = open(r->o.device, O_RDWR | O_CLOEXEC);
	if (r->dev < 0) {
		perr("open %s (is the fdrec module loaded?)", r->o.device);
		goto out;
	}
	if (ioctl(r->dev, FDREC_IOC_GET_INFO, &r->info) < 0) {
		perr("FDREC_IOC_GET_INFO");
		goto out;
	}
	if (r->info.api_version != FDREC_API_VERSION) {
		err_msg("driver API version %u, this fdrec expects %u",
			r->info.api_version, FDREC_API_VERSION);
		goto out;
	}

	if (r->o.rate_set) {
		struct fdrec_rate rt = { .rate_bps = r->o.rate };

		if (ioctl(r->dev, FDREC_IOC_SET_RATE, &rt) < 0) {
			perr("FDREC_IOC_SET_RATE");
			goto out;
		}
		r->o.rate = rt.rate_bps;
		if (r->info.fifo_depth &&
		    r->o.rate * RESTART_GAP_US / 1e6 > (double)r->info.fifo_depth * r->info.beat_bytes)
			fprintf(stderr, "fdrec: warning: at %.1f MB/s the %u-beat ingest FIFO covers only %.1f us of the ~%.0f us DMA restart gap at each buffer boundary: expect drops\n",
				r->o.rate / 1e6, r->info.fifo_depth,
				(double)r->info.fifo_depth * r->info.beat_bytes / r->o.rate * 1e6,
				RESTART_GAP_US);
		if (r->o.rate && (double)r->o.buf_size / r->o.rate > r->o.timeout / 2)
			fprintf(stderr, "fdrec: warning: at %.3f MB/s one %" PRIu64 " MB buffer takes %.1f s to fill; raise --timeout (%.0f s) or lower --buf-size\n",
				r->o.rate / 1e6, r->o.buf_size >> 20,
				(double)r->o.buf_size / r->o.rate, r->o.timeout);
	}

	if (alloc_buffers(r))
		goto out;
	addrs = calloc(r->o.buffers, sizeof(*addrs));
	iov = calloc(r->o.buffers, sizeof(*iov));
	if (!addrs || !iov) {
		err_msg("out of memory");
		goto out;
	}
	for (i = 0; i < r->o.buffers; i++) {
		addrs[i] = (uintptr_t)(r->mem + (size_t)i * r->o.buf_size);
		iov[i].iov_base = r->mem + (size_t)i * r->o.buf_size;
		iov[i].iov_len = r->o.buf_size;
	}
	memset(&reg, 0, sizeof(reg));
	reg.addrs = (uintptr_t)addrs;
	reg.buf_size = r->o.buf_size;
	reg.count = r->o.buffers;
	if (ioctl(r->dev, FDREC_IOC_REGISTER_BUFS, &reg) < 0) {
		perr("FDREC_IOC_REGISTER_BUFS (%u x %" PRIu64 " MB)",
		     r->o.buffers, r->o.buf_size >> 20);
		goto out;
	}

	r->out = open(r->o.output, O_CREAT | O_WRONLY | O_TRUNC | O_DIRECT | O_CLOEXEC, 0644);
	if (r->out < 0) {
		perr("open %s with O_DIRECT", r->o.output);
		goto out;
	}
	if (r->o.size) {
		e = posix_fallocate(r->out, 0, HDR_SIZE + r->o.size);
		if (e == ENOSPC) {
			err_msg("%s: not enough free space for %" PRIu64 " bytes",
				r->o.output, r->o.size);
			goto out;
		} else if (e) {
			fprintf(stderr, "fdrec: note: fallocate not done (%s)\n", strerror(e));
		}
	}

	if (posix_memalign((void **)&r->hdr, 4096, HDR_SIZE)) {
		err_msg("out of memory");
		goto out;
	}
	memset(r->hdr, 0, HDR_SIZE);
	memcpy(r->hdr->magic, FDREC_FILE_MAGIC, FDREC_FILE_MAGIC_LEN);
	r->hdr->header_version = htole32(FDREC_FILE_HEADER_VERSION);
	r->hdr->header_size = htole32(HDR_SIZE);
	r->hdr->beat_bytes = htole32(r->info.beat_bytes);
	r->hdr->flags = htole32(r->o.no_tpg ? 0 : FDREC_FILE_FLAG_TPG);
	r->hdr->design_version = htole32(r->info.hw_version);
	r->hdr->src_clk_hz = htole64(r->info.src_clk_hz);
	r->hdr->rate_bps = htole64(r->o.rate_set ? r->o.rate : 0);
	strncpy(r->hdr->target, r->o.target, sizeof(r->hdr->target) - 1);
	gethostname(r->hdr->hostname, sizeof(r->hdr->hostname) - 1);

	if (io_uring_queue_init(r->o.qd + 2, &r->ring, 0) < 0) {
		err_msg("io_uring_queue_init failed (CONFIG_IO_URING?)");
		goto out;
	}
	/* Fixed buffers spare the kernel a page-pin per write; optional */
	r->fixed = io_uring_register_buffers(&r->ring, iov, r->o.buffers) == 0;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;      /* no SA_RESTART: interrupt the wait */
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);

	memset(&start, 0, sizeof(start));
	start.flags = r->o.no_tpg ? 0 : FDREC_START_TPG;
	if (ioctl(r->dev, FDREC_IOC_START, &start) < 0) {
		perr("FDREC_IOC_START");
		goto out;
	}
	r->t0 = r->t_last = r->t_progress = now_s();
	r->hdr->start_time_ns = htole64(start.start_time_ns);
	r->hdr->first_seq = htole64(r->o.no_tpg ? 0 : start.first_seq);
	if (write_header(r)) {
		set_error(r, -EIO);
		do_stop(r);
	}

	if (!r->o.quiet && isatty(2))
		fprintf(stderr, "fdrec: recording to %s (%u x %" PRIu64 " MB buffers, qd %u%s%s) -- Ctrl-C to stop\n",
			r->o.output, r->o.buffers, r->o.buf_size >> 20, r->o.qd,
			r->fixed ? ", fixed buffers" : "",
			r->o.no_tpg ? ", user source" : ", test pattern");
	if (r->o.duration > 0)
		deadline = r->t0 + r->o.duration;
	next_stats = r->t0 + (r->o.stats > 0 ? r->o.stats : 1e30);

	/* ---- main loop ---- */
	for (;;) {
		struct io_uring_cqe *cqe;
		struct __kernel_timespec ts;
		double now = now_s(), wait_s;
		unsigned head, seen;

		if (g_stop || (deadline && now >= deadline))
			r->done_filling = true;
		if (r->done_filling && !r->stopped) {
			e = do_stop(r);
			if (e)
				set_error(r, e);
		}
		if (!r->done_filling) {
			take_filled(r);
			if (r->done_filling && !r->stopped) {
				e = do_stop(r);
				if (e)
					set_error(r, e);
			}
		}
		if (r->done_filling && r->inflight == 0)
			break;

		/* Stall watchdog: neither a filled buffer nor a finished write
		 * for too long. Stop (the driver gates and drains the DMA), let
		 * the writes in flight finish, then finalise the header. */
		if (!r->done_filling && now - r->t_progress > r->o.timeout) {
			struct fdrec_stats st;

			if (ioctl(r->dev, FDREC_IOC_GET_STATS, &st) < 0)
				memset(&st, 0, sizeof(st));
			if (isatty(2) && !r->o.quiet)
				fputc('\n', stderr);
			err_msg("recording stalled: no buffer completed for %.0f s (%s; writes in flight %u, FIFO high-water %u/%u, drops %" PRIu64 ")",
				r->o.timeout,
				r->inflight ? "SSD not completing writes?" :
				r->o.no_tpg ? "source not producing data?" : "DMA not filling buffers?",
				r->inflight, st.fifo_hwm, st.fifo_depth,
				(uint64_t)st.drop_count);
			set_error(r, -ETIMEDOUT);
			r->done_filling = true;
			continue;
		}
		if (!r->done_filling && r->inflight < r->o.qd)
			arm_poll(r);
		io_uring_submit(&r->ring);

		if (!r->o.quiet && r->o.stats > 0 && now >= next_stats) {
			print_stats(r, false);
			while (next_stats <= now)
				next_stats += r->o.stats;
		}
		wait_s = (r->o.stats > 0 ? next_stats : now + 0.5) - now;
		if (deadline && deadline - now < wait_s)
			wait_s = deadline - now;
		if (wait_s < 0.001)
			wait_s = 0.001;
		if (wait_s > 0.5)
			wait_s = 0.5;
		ts.tv_sec = (long long)wait_s;
		ts.tv_nsec = (long long)((wait_s - (double)ts.tv_sec) * 1e9);
		e = io_uring_wait_cqe_timeout(&r->ring, &cqe, &ts);
		if (e < 0 && e != -ETIME && e != -EINTR) {
			errno = -e;
			perr("io_uring_wait_cqe");
			set_error(r, e);
			r->done_filling = true;
		}
		seen = 0;
		io_uring_for_each_cqe(&r->ring, head, cqe) {
			handle_cqe(r, cqe);
			seen++;
		}
		io_uring_cq_advance(&r->ring, seen);
	}

	/* A poll request may still be pending on the device; cancel it */
	if (r->poll_armed) {
		struct io_uring_sqe *sqe = io_uring_get_sqe(&r->ring);

		if (sqe) {
			io_uring_prep_poll_remove(sqe, UD_POLL);
			io_uring_submit(&r->ring);
		}
	}

	if (!r->o.quiet && r->o.stats > 0)
		print_stats(r, true);

	/* Final header: counts, COMPLETE flag; trim any preallocated tail */
	r->hdr->stop_time_ns = htole64(realtime_ns());
	r->hdr->data_bytes = htole64(r->bytes_written);
	r->hdr->drop_count = htole64(r->last_drop);
	r->hdr->flags = htole32(le32toh(r->hdr->flags) | FDREC_FILE_FLAG_COMPLETE);
	if (write_header(r))
		set_error(r, -EIO);
	if (ftruncate(r->out, HDR_SIZE + r->bytes_written) < 0) {
		perr("ftruncate %s", r->o.output);
		set_error(r, -errno);
	}
	if (fsync(r->out) < 0) {
		perr("fsync %s", r->o.output);
		set_error(r, -errno);
	}

	{
		double el = (double)(le64toh(r->hdr->stop_time_ns) - start.start_time_ns) / 1e9;

		printf("fdrec: %s: %" PRIu64 " bytes (%" PRIu64 " buffers) in %.2f s, %.1f MB/s\n",
		       r->o.output, r->bytes_written, r->bufs_written, el,
		       el > 0 ? r->bytes_written / el / 1e6 : 0.0);
		printf("fdrec: dropped beats %" PRIu64 " (at stop: %" PRIu64 "), FIFO high-water %u of %u beats, max writes in flight %u\n",
		       r->last_drop, (uint64_t)r->final.drop_count, r->final.fifo_hwm,
		       r->final.fifo_depth, r->max_inflight);
		/* One machine-readable line for scripts (fdbench.sh) */
		printf("RESULT bytes=%" PRIu64 " seconds=%.3f rate_bps=%" PRIu64
		       " drops=%" PRIu64 " fifo_hwm=%u fifo_depth=%u error=%d\n",
		       r->bytes_written, el, r->o.rate_set ? r->o.rate : 0,
		       r->last_drop, r->final.fifo_hwm, r->final.fifo_depth,
		       r->error);
	}

	if (r->error)
		ret = 1;
	else if (r->last_drop)
		ret = 2;
	else
		ret = 0;
	if (ret == 2)
		fprintf(stderr, "fdrec: WARNING: %" PRIu64 " beats were dropped -- the recording is not valid\n",
			r->last_drop);
out:
	if (r->ring.ring_fd > 0)
		io_uring_queue_exit(&r->ring);
	if (r->out >= 0)
		close(r->out);
	if (r->dev >= 0)
		close(r->dev);          /* driver stops, unpins and resets */
	if (r->mem)
		munmap(r->mem, r->mem_len);
	free(r->hdr);
	free(addrs);
	free(iov);
	return ret;
}
