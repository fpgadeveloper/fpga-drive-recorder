// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * fdrec -- FPGA Drive Recorder driver
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * Drives the fdrec_core register block (test pattern generator, ingest FIFO,
 * packetizer, and from VERSION 1.1 the fdrec_check sink/checker) and the S2MM
 * and MM2S channels of an AMD AXI DMA through the standard xilinx_dma
 * dmaengine driver:
 *
 *   record:   fabric stream -> S2MM ("rx") -> user hugepage buffers; user
 *             space writes each filled buffer to an NVMe SSD with O_DIRECT.
 *   playback: user space reads a file into the hugepage buffers with
 *             O_DIRECT; MM2S ("tx") streams each buffer to the fabric sink.
 *
 * Either way the sample data is never copied by the CPU.
 *
 * Buffer model (docs/source/driver.md has the full description):
 *
 *   - User space owns the memory: it allocates the buffers from 2 MB hugepages
 *     (mmap MAP_HUGETLB). These are ordinary pages, so O_DIRECT writes from
 *     them work. (Buffers allocated here and exposed with remap_pfn_range
 *     would make O_DIRECT fail with EFAULT, which is why we do not do that.)
 *   - FDREC_IOC_REGISTER_BUFS pins the pages (pin_user_pages_fast with
 *     FOLL_WRITE | FOLL_LONGTERM), builds an sg_table per buffer and maps it
 *     against the DMA channel's device: DMA_FROM_DEVICE for a record set,
 *     DMA_TO_DEVICE for a playback set (one direction per registered set).
 *   - START hands every buffer to the driver's DMA queue, from which one
 *     buffer at a time is kept active and one pending in xilinx_dma (one
 *     dmaengine slave-sg descriptor per buffer, see FDREC_DMA_DEPTH); the
 *     packetizer asserts TLAST every buf_size / 16 beats, so every descriptor
 *     ends exactly on a buffer boundary.
 *   - WAIT_FILLED hands a completed buffer to user space, RELEASE re-queues it.
 *   - If no buffer is free the DMA stalls, the packetizer is back-pressured,
 *     the ingest FIFO fills and beats are dropped and counted. That is the
 *     only failure mode; it is reported, never hidden.
 *   - Playback mirrors it: PLAY_SUBMIT queues a buffer the app has filled
 *     (same one active + one pending feed, one descriptor = one packet, the
 *     xilinx_dma MM2S prep sets SOP on the first and EOP = TLAST on the last
 *     BD), PLAY_WAIT_DONE hands back the buffers the DMA has read. If the app
 *     cannot refill buffers fast enough, the MM2S stream runs dry and the sink
 *     counts underflows -- the mirror image of the recorder's drops.
 *
 * Cache coherency -- READ THIS BEFORE CHANGING ANY SYNC CALL:
 *
 *   The AXI DMA writes to DDR through an S_AXI_HP port, which is NOT cache
 *   coherent with the APU. The buffers are ordinary cacheable user pages that
 *   two different devices touch in turn: the AXI DMA writes them
 *   (DMA_FROM_DEVICE), then the NVMe controller reads them (the NVMe driver
 *   maps them DMA_TO_DEVICE for the O_DIRECT write, which cleans the cache).
 *
 *   - Before a buffer is (re)queued to the AXI DMA we call
 *     dma_sync_sgtable_for_device(DMA_FROM_DEVICE). On arm64 this is a clean
 *     to the point of coherency (arch_sync_dma_for_device): no dirty line of
 *     the buffer may remain in the cache while the fabric writes DDR, because
 *     a later eviction or clean of such a line would overwrite fabric data
 *     with stale CPU data. This matters even though user space only reads the
 *     buffers: the NVMe driver's DMA_TO_DEVICE mapping performs a clean, and a
 *     header write, a debugger or a page-cache fallback can dirty lines.
 *   - Before WAIT_FILLED returns a buffer we call
 *     dma_sync_sgtable_for_cpu(DMA_FROM_DEVICE), an invalidate
 *     (arch_sync_dma_for_cpu), so that neither the CPU nor the clean done by
 *     the NVMe mapping can see or write back stale lines that were speculatively
 *     fetched while the DMA was filling the buffer.
 *
 *   Both syncs are mandatory. They are cache maintenance only (no data copy):
 *   the CPU never moves sample data. If the DMA node in the device tree were
 *   marked dma-coherent (HPC port + CCI) these calls would become no-ops, which
 *   is also correct.
 *
 *   Playback (DMA_TO_DEVICE): the AXI DMA *reads* the buffers through the
 *   same non-coherent port, after the NVMe controller wrote them (the app's
 *   O_DIRECT read: the NVMe driver maps the pages DMA_FROM_DEVICE and
 *   invalidates them when it unmaps).
 *
 *   - Before PLAY_SUBMIT queues a buffer we call
 *     dma_sync_sgtable_for_device(DMA_TO_DEVICE), a clean to the point of
 *     coherency. This is the mandatory one: any line the CPU dirtied (an app
 *     that writes or patches data with the CPU, a page-cache fallback when
 *     O_DIRECT is refused) is written to DDR before the DMA reads DDR, which
 *     it does without looking at the caches. For data that arrived by NVMe
 *     DMA there are no dirty lines; at most clean lines that are stale
 *     (speculatively fetched while the NVMe controller wrote DDR, before the
 *     NVMe unmap invalidated them, or after it). A clean never writes a clean
 *     line back, so stale-clean lines are harmless here: the AXI DMA reads
 *     the NVMe data from DDR.
 *   - When PLAY_WAIT_DONE hands a buffer back we call
 *     dma_sync_sgtable_for_cpu(DMA_TO_DEVICE). On arm64 that is a no-op
 *     (arch_sync_dma_for_cpu returns for DMA_TO_DEVICE: the device did not
 *     write the buffer); it is kept for the DMA API ownership rules and for
 *     swiotlb/IOMMU configurations.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/io.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/uaccess.h>
#include <linux/dmaengine.h>
#include <linux/dma-mapping.h>
#include <linux/dma-map-ops.h>	/* dev_is_dma_coherent() */
#include <linux/scatterlist.h>
#include <linux/spinlock.h>
#include <linux/mutex.h>
#include <linux/wait.h>
#include <linux/poll.h>
#include <linux/sched/signal.h>
#include <linux/iopoll.h>
#include <linux/idr.h>
#include <linux/math64.h>
#include <linux/timekeeping.h>
#include <linux/iommu.h>

#include "fdrec_regs.h"
#include "fdrec_uapi.h"

#define DRV_NAME		"fdrec"
#define FDREC_DRV_VERSION	"1.1"

/* AXI DMA (xilinx_dma) facts used for validation. The driver pre-allocates
 * this many buffer descriptors per channel (XILINX_DMA_NUM_DESCS). */
#define XDMA_NUM_BDS		512
#define XDMA_DEFAULT_LEN_WIDTH	23	/* without xlnx,sg-length-width */

/*
 * Descriptors kept in xilinx_dma at any time: one being filled + one pending.
 *
 * xilinx_dma starts pending descriptors only when the channel is idle (from
 * its IRQ handler), all of them in one go, and sets the AXI DMA interrupt
 * coalescing threshold to their number. Handing it the whole ring therefore
 * makes the channel run in batches: one interrupt per batch, no buffer
 * visible to user space until the whole batch is full (the disk sits idle
 * meanwhile, then gets a burst), and the DMA halts at each batch tail until
 * the IRQ handler restarts it. With exactly one pending descriptor the IRQ
 * handler starts it with threshold 1 straight from hard-IRQ context when the
 * active one completes (the DMA pauses only for the IRQ latency, which the
 * ingest FIFO absorbs), and the completion callback queues the next free
 * buffer as the new pending one. Every buffer is seen by user space as soon
 * as it is full.
 */
#define FDREC_DMA_DEPTH		2

enum fdrec_buf_state {
	BUF_FREE,	/* registered, not queued (stopped); playback: the
			 * app's, may be submitted */
	BUF_QUEUED,	/* waiting in the driver's queue for a DMA slot */
	BUF_DMA,	/* queued to the DMA */
	BUF_READY,	/* filled (played), waiting for WAIT_FILLED (WAIT_DONE) */
	BUF_USER,	/* handed to user space, waiting for RELEASE (record) or
			 * the next PLAY_SUBMIT (playback) */
};

/* Channel slots; dma-names in the device tree */
enum fdrec_dir_idx { FD_RX = 0, FD_TX = 1 };
static const char * const fdrec_chan_names[] = { "rx", "tx" };

struct fdrec_dev;

struct fdrec_buf {
	struct fdrec_dev *fd;
	unsigned int index;
	enum fdrec_buf_state state;
	struct page **pages;
	unsigned long npages;
	struct sg_table sgt;
	bool mapped;
	unsigned int nbds;		/* BDs this buffer needs */
	struct list_head node;		/* ready list */
	/* playback: DMA view of the first len bytes (copy of the mapped sgt,
	 * last entry shortened) */
	struct scatterlist *psg;
	unsigned int psg_n;
	u64 len;			/* playback: bytes submitted */
	/* filled by the completion callback */
	u64 bytes;
	u64 seq;
	u64 drop_count;
	u32 flags;
};

struct fdrec_dev {
	struct device *dev;
	void __iomem *regs;
	spinlock_t reg_lock;		/* 64-bit counter reads (LO latches HI) */
	struct dma_chan *chans[2];	/* FD_RX (S2MM), FD_TX (MM2S, optional) */
	struct dma_chan *chan;		/* channel of the registered set's direction */
	struct device *dma_dev;		/* device the buffers are mapped against */
	u32 max_sg_len;
	int id;
	char name[16];
	struct miscdevice misc;

	/* hardware info read at probe */
	u32 hw_version;
	u32 src_clk_hz;
	u32 dp_clk_hz;
	u32 fifo_depth;
	u32 caps;			/* FDREC_CAP_* */

	struct mutex lock;		/* open state, REGISTER/START/STOP/RELEASE */
	bool in_use;			/* exclusive open */

	/* session state (protected by lock; queue fields by qlock) */
	struct fdrec_buf *bufs;
	unsigned int nbufs;
	u64 buf_size;
	unsigned int dir;		/* FDREC_DIR_* of the registered set */
	bool running;
	bool started_tpg;		/* START enabled the TPG -> STOP disables it */
	bool started_chk;		/* PLAY_START took over the checker */
	bool chk_pending;		/* checker reset, ENABLE waits for the
					 * egress FIFO to prime (qlock) */

	spinlock_t qlock;
	struct list_head ready;
	wait_queue_head_t wq;
	u64 fill_seq;
	u64 bytes_filled;
	u32 dma_errors;
	bool dma_error;
	/* DMA feed (qlock): at most FDREC_DMA_DEPTH descriptors in xilinx_dma */
	struct list_head dmaq;		/* BUF_QUEUED, in fill order */
	unsigned int dma_active;	/* descriptors submitted, not completed */
	bool accepting;			/* running: completions may refill */
};

static DEFINE_IDA(fdrec_ida);

/* ------------------------------------------------------------------------ */
/* Register access                                                          */

static inline u32 fd_rd(struct fdrec_dev *fd, u32 off)
{
	return ioread32(fd->regs + off);
}

static inline void fd_wr(struct fdrec_dev *fd, u32 off, u32 val)
{
	iowrite32(val, fd->regs + off);
}

/* 64-bit counter: reading LO latches HI, so LO/HI pairs must not interleave */
static u64 fd_rd64(struct fdrec_dev *fd, u32 lo_off)
{
	unsigned long flags;
	u32 lo, hi;

	spin_lock_irqsave(&fd->reg_lock, flags);
	lo = fd_rd(fd, lo_off);
	hi = fd_rd(fd, lo_off + 4);
	spin_unlock_irqrestore(&fd->reg_lock, flags);
	return ((u64)hi << 32) | lo;
}

static int fd_soft_reset(struct fdrec_dev *fd)
{
	u32 v;

	fd_wr(fd, FDREC_GLOBAL_CTRL, FDREC_GLOBAL_CTRL_SOFT_RST);
	return readl_poll_timeout(fd->regs + FDREC_GLOBAL_CTRL, v,
				  !(v & FDREC_GLOBAL_CTRL_SOFT_RST), 1, 10000);
}

static u64 fd_rate_get(struct fdrec_dev *fd)
{
	u64 inc = fd_rd(fd, FDREC_TPG_RATE_INC);

	if (inc > FDREC_TPG_RATE_INC_ONE)
		inc = FDREC_TPG_RATE_INC_ONE;
	/* rate_bps = INC / 2^31 * SRC_CLK_HZ * 16 */
	return mul_u64_u64_div_u64(inc, (u64)fd->src_clk_hz * FDREC_BEAT_BYTES,
				   1ull << FDREC_TPG_RATE_INC_FRAC_BITS);
}

static u64 fd_rate_set(struct fdrec_dev *fd, u64 rate_bps)
{
	u64 max = (u64)fd->src_clk_hz * FDREC_BEAT_BYTES;
	u64 inc;

	if (!max)
		return 0;
	if (rate_bps > max)
		rate_bps = max;
	/* TPG_RATE_INC = rate_bps * 2^31 / (SRC_CLK_HZ * 16), rounded */
	inc = mul_u64_u64_div_u64(rate_bps, 1ull << FDREC_TPG_RATE_INC_FRAC_BITS,
				  max);
	if (inc > FDREC_TPG_RATE_INC_ONE)
		inc = FDREC_TPG_RATE_INC_ONE;
	fd_wr(fd, FDREC_TPG_RATE_INC, (u32)inc);
	return fd_rate_get(fd);
}

static void fd_read_stats(struct fdrec_dev *fd, struct fdrec_stats *st)
{
	struct fdrec_buf *b;
	unsigned long flags;
	unsigned int i;

	memset(st, 0, sizeof(*st));
	st->drop_count = fd_rd64(fd, FDREC_ING_DROP_COUNT_LO);
	st->beats_in = fd_rd64(fd, FDREC_ING_BEATS_IN_LO);
	st->beats_out = fd_rd64(fd, FDREC_PKT_BEATS_OUT_LO);
	st->seq_next = fd_rd64(fd, FDREC_TPG_SEQ_NEXT_LO);
	st->fifo_hwm = fd_rd(fd, FDREC_ING_FIFO_HWM);
	st->fifo_depth = fd->fifo_depth;
	st->overflow = !!(fd_rd(fd, FDREC_ING_STATUS) & FDREC_ING_STATUS_OVERFLOW);
	st->running = fd->running;

	spin_lock_irqsave(&fd->qlock, flags);
	st->bufs_filled = fd->fill_seq;
	st->bytes_filled = fd->bytes_filled;
	st->dma_errors = fd->dma_errors;
	for (i = 0; i < fd->nbufs; i++) {
		b = &fd->bufs[i];
		if (b->state == BUF_DMA || b->state == BUF_QUEUED)
			st->bufs_dma++;
		else if (b->state == BUF_READY)
			st->bufs_ready++;
		else if (b->state == BUF_USER)
			st->bufs_user++;
	}
	spin_unlock_irqrestore(&fd->qlock, flags);
}

/* ------------------------------------------------------------------------ */
/* DMA                                                                      */

static void fdrec_dma_done(void *param, const struct dmaengine_result *res);
static void fd_chk_enable_pending(struct fdrec_dev *fd);

/*
 * Submit one buffer to xilinx_dma as a slave-sg descriptor and issue it.
 * Called with fd->qlock held (IRQs off), from process context (START,
 * RELEASE) or from the completion callback (tasklet); dmaengine allows both
 * (prep allocates with GFP_NOWAIT; xilinx_dma drops its channel lock around
 * our callback, so the lock order is always qlock -> chan->lock).
 *
 * issue_pending starts the descriptor at once if the channel is idle;
 * otherwise it stays pending and the IRQ handler starts it when the active
 * descriptor completes.
 */
static int fdrec_submit(struct fdrec_dev *fd, struct fdrec_buf *b)
{
	struct dma_async_tx_descriptor *tx;
	dma_cookie_t cookie;

	if (fd->dir == FDREC_DIR_PLAY)
		/* MM2S: one descriptor = one packet; xilinx_dma sets SOP on
		 * its first BD and EOP (TLAST) on its last */
		tx = dmaengine_prep_slave_sg(fd->chan, b->psg, b->psg_n,
					     DMA_MEM_TO_DEV,
					     DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	else
		tx = dmaengine_prep_slave_sg(fd->chan, b->sgt.sgl, b->sgt.nents,
					     DMA_DEV_TO_MEM,
					     DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!tx) {
		dev_err_ratelimited(fd->dev, "buffer %u: dmaengine_prep_slave_sg failed (BD pool exhausted?)\n",
				    b->index);
		return -ENOMEM;
	}
	tx->callback_result = fdrec_dma_done;
	tx->callback_param = b;
	b->state = BUF_DMA;
	cookie = dmaengine_submit(tx);
	if (dma_submit_error(cookie)) {
		dev_err_ratelimited(fd->dev, "buffer %u: dmaengine_submit failed (%d)\n",
				    b->index, cookie);
		return -EIO;
	}
	fd->dma_active++;
	dma_async_issue_pending(fd->chan);
	return 0;
}

/*
 * Keep FDREC_DMA_DEPTH descriptors in xilinx_dma (see FDREC_DMA_DEPTH).
 * Caller holds fd->qlock. A submit failure is reported to user space as a
 * DMA error (POLLERR; the buffer goes back to the head of the queue).
 */
static void fdrec_feed(struct fdrec_dev *fd)
{
	while (fd->accepting && fd->dma_active < FDREC_DMA_DEPTH &&
	       !list_empty(&fd->dmaq)) {
		struct fdrec_buf *b = list_first_entry(&fd->dmaq,
						       struct fdrec_buf, node);

		list_del_init(&b->node);
		if (fdrec_submit(fd, b)) {
			b->state = BUF_QUEUED;
			list_add(&b->node, &fd->dmaq);
			fd->dma_errors++;
			fd->dma_error = true;
			wake_up(&fd->wq);
			break;
		}
	}
}

/*
 * Completion callback (xilinx_dma tasklet context). xilinx_dma reports the
 * bytes NOT transferred of the descriptor in result->residue (sum over the
 * descriptor's BDs of control.length - status.transferred).
 */
static void fdrec_dma_done(void *param, const struct dmaengine_result *res)
{
	struct fdrec_buf *b = param;
	struct fdrec_dev *fd = b->fd;
	bool play = fd->dir == FDREC_DIR_PLAY;
	u64 drops = play ? 0 : fd_rd64(fd, FDREC_ING_DROP_COUNT_LO);
	u64 len = play ? b->len : fd->buf_size;
	unsigned long flags;
	u32 residue = res ? res->residue : 0;

	spin_lock_irqsave(&fd->qlock, flags);
	if (b->state != BUF_DMA) {
		spin_unlock_irqrestore(&fd->qlock, flags);
		return;
	}
	b->flags = 0;
	b->bytes = residue < len ? len - residue : 0;
	if (!play && b->bytes < len)
		b->flags |= FDREC_FILLED_SHORT;
	if (res && res->result != DMA_TRANS_NOERROR) {
		b->flags |= FDREC_FILLED_ERROR;	/* == FDREC_DONE_ERROR */
		fd->dma_errors++;
		fd->dma_error = true;
	}
	b->drop_count = drops;
	b->seq = fd->fill_seq++;
	fd->bytes_filled += b->bytes;
	b->state = BUF_READY;
	list_add_tail(&b->node, &fd->ready);
	if (fd->dma_active)
		fd->dma_active--;
	/* Playback: a first buffer that fits in the egress FIFO completes
	 * without the sink; that is "primed" too. */
	if (play)
		fd_chk_enable_pending(fd);
	/* The IRQ handler has already started the pending descriptor (if any);
	 * queue the next free (playback: next submitted) buffer behind it. */
	fdrec_feed(fd);
	spin_unlock_irqrestore(&fd->qlock, flags);
	wake_up(&fd->wq);	/* WAIT_FILLED/WAIT_DONE/poll, the drain in STOP */
}

/*
 * Get a fresh channel. xilinx_dma keeps its 512 BDs in a ring whose hardware
 * next-pointers are fixed at allocation time, and allocates them from a free
 * list. dmaengine_terminate_sync() frees the pending/done/active descriptors
 * in that order, which leaves the free list out of ring order; descriptors
 * allocated from it later would not be chained correctly in hardware. A
 * release + request rebuilds the ring (xilinx_dma_alloc_chan_resources), so
 * we do that after every STOP. The DMA device (and so the buffer mappings)
 * does not change. The same BD code serves both directions, so the MM2S
 * channel gets the same treatment after PLAY_STOP.
 */
static int fdrec_renew_one(struct fdrec_dev *fd, enum fdrec_dir_idx slot)
{
	const char *name = fdrec_chan_names[slot];
	struct dma_chan *chan;
	bool cur = fd->chan == fd->chans[slot];

	if (fd->chans[slot])
		dma_release_channel(fd->chans[slot]);
	fd->chans[slot] = NULL;
	if (cur)
		fd->chan = NULL;
	chan = dma_request_chan(fd->dev, name);
	if (IS_ERR(chan)) {
		dev_err(fd->dev, "cannot re-acquire DMA channel %s: %ld\n",
			name, PTR_ERR(chan));
		return PTR_ERR(chan);
	}
	if (dmaengine_get_dma_device(chan) != fd->dma_dev) {
		dev_err(fd->dev, "DMA channel %s moved to another device\n", name);
		dma_release_channel(chan);
		return -ENODEV;
	}
	fd->chans[slot] = chan;
	if (cur)
		fd->chan = chan;
	return 0;
}

/*
 * Renew the channel that was just terminated, and then the other one too.
 * On an AXI DMA, xilinx_dma_terminate_all() ends in xilinx_dma_chan_reset():
 * DMACR.Reset resets the WHOLE core (both channels), which clears the other
 * channel's interrupt enables, and xilinx_dma re-enables only those of the
 * channel it reset. The other channel would then never interrupt again: its
 * first buffer completes and the stream stops (seen on uzev 2026-10-02: the
 * first playback after a recording stalled after 8 MB with 0 MM2S IRQs, and
 * a recording after a playback likewise). xilinx_dma_alloc_chan_resources()
 * re-enables a channel's interrupts, so a release + request of the idle
 * other channel restores them (only one direction runs at a time).
 */
static int fdrec_renew_chan(struct fdrec_dev *fd, enum fdrec_dir_idx slot)
{
	enum fdrec_dir_idx other = slot == FD_RX ? FD_TX : FD_RX;
	int ret = fdrec_renew_one(fd, slot);

	if (fd->chans[other]) {
		int r = fdrec_renew_one(fd, other);

		if (!ret)
			ret = r;
	}
	return ret;
}

static enum fdrec_dir_idx fdrec_slot(struct fdrec_dev *fd)
{
	return fd->dir == FDREC_DIR_PLAY ? FD_TX : FD_RX;
}

/* ------------------------------------------------------------------------ */
/* Buffers                                                                  */

static void fdrec_free_buf(struct fdrec_dev *fd, struct fdrec_buf *b)
{
	bool play = fd->dir == FDREC_DIR_PLAY;

	if (b->mapped)
		dma_unmap_sgtable(fd->dma_dev, &b->sgt,
				  play ? DMA_TO_DEVICE : DMA_FROM_DEVICE, 0);
	b->mapped = false;
	kfree(b->psg);
	b->psg = NULL;
	b->psg_n = 0;
	if (b->sgt.sgl)
		sg_free_table(&b->sgt);
	b->sgt.sgl = NULL;
	if (b->pages) {
		/* Record: the device wrote these pages, mark them dirty on
		 * unpin. Playback: the device only read them. */
		if (b->npages)
			unpin_user_pages_dirty_lock(b->pages, b->npages, !play);
		kvfree(b->pages);
	}
	b->pages = NULL;
	b->npages = 0;
}

static void fdrec_unregister(struct fdrec_dev *fd)
{
	unsigned int i;

	for (i = 0; i < fd->nbufs; i++)
		fdrec_free_buf(fd, &fd->bufs[i]);
	kfree(fd->bufs);
	fd->bufs = NULL;
	fd->nbufs = 0;
	fd->buf_size = 0;
	INIT_LIST_HEAD(&fd->ready);
}

static int fdrec_pin_buf(struct fdrec_dev *fd, struct fdrec_buf *b, u64 uaddr)
{
	unsigned long npages = fd->buf_size >> PAGE_SHIFT;
	unsigned long done = 0;
	struct scatterlist *sg;
	unsigned int i;
	int ret;

	b->pages = kvmalloc_array(npages, sizeof(*b->pages), GFP_KERNEL);
	if (!b->pages)
		return -ENOMEM;

	while (done < npages) {
		int chunk = min_t(unsigned long, npages - done, INT_MAX);

		ret = pin_user_pages_fast(uaddr + (done << PAGE_SHIFT), chunk,
					  FOLL_WRITE | FOLL_LONGTERM,
					  b->pages + done);
		if (ret <= 0) {
			ret = ret ? ret : -EFAULT;
			goto err;
		}
		done += ret;
		b->npages = done;
	}

	/* Physically contiguous pages are merged: one entry per hugepage (or
	 * more when hugepages happen to be adjacent). xilinx_dma splits entries
	 * longer than its max_buffer_len into several BDs itself. */
	ret = sg_alloc_table_from_pages(&b->sgt, b->pages, npages, 0,
					fd->buf_size, GFP_KERNEL);
	if (ret)
		goto err;

	ret = dma_map_sgtable(fd->dma_dev, &b->sgt,
			      fd->dir == FDREC_DIR_PLAY ? DMA_TO_DEVICE : DMA_FROM_DEVICE,
			      0);
	if (ret) {
		dev_err(fd->dev, "dma_map_sgtable failed: %d\n", ret);
		goto err;
	}
	b->mapped = true;
	if (fd->dir == FDREC_DIR_PLAY) {
		b->psg = kcalloc(b->sgt.nents, sizeof(*b->psg), GFP_KERNEL);
		if (!b->psg) {
			ret = -ENOMEM;
			goto err;
		}
	}

	b->nbds = 0;
	for_each_sgtable_dma_sg(&b->sgt, sg, i) {
		/*
		 * Zero-copy check: without an IOMMU the DMA address must be the
		 * physical address. Anything else means swiotlb bounce buffering,
		 * i.e. the AXI DMA cannot reach this memory (xlnx,addrwidth too
		 * small) and the CPU would copy every byte -- refuse.
		 */
		if (!device_iommu_mapped(fd->dma_dev) &&
		    sg_dma_address(sg) != sg_phys(sg)) {
			dev_err(fd->dev,
				"buffer at phys %pa is bounce-buffered: the AXI DMA cannot address it (check xlnx,addrwidth of the DMA node)\n",
				&(phys_addr_t){ sg_phys(sg) });
			ret = -EIO;
			goto err;
		}
		b->nbds += DIV_ROUND_UP(sg_dma_len(sg), fd->max_sg_len);
	}
	return 0;
err:
	fdrec_free_buf(fd, b);
	return ret;
}

static int fdrec_register(struct fdrec_dev *fd, struct fdrec_bufs __user *uarg)
{
	struct fdrec_bufs a;
	u64 *addrs = NULL;
	unsigned int i, total_bds = 0;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (a.flags & ~FDREC_BUFS_DIR_MASK)
		return -EINVAL;
	if (fd->running)
		return -EBUSY;
	/* Record buffers handed out by WAIT_FILLED and not yet RELEASEd may still
	 * be in an O_DIRECT write; playback buffers are the app's when stopped. */
	if (fd->dir == FDREC_DIR_RECORD)
		for (i = 0; i < fd->nbufs; i++)
			if (fd->bufs[i].state == BUF_USER)
				return -EBUSY;

	fdrec_unregister(fd);
	if (!a.count)
		return 0;
	if ((a.flags & FDREC_BUFS_DIR_MASK) == FDREC_DIR_PLAY &&
	    !(fd->caps & FDREC_CAP_MM2S))
		return -EOPNOTSUPP;
	fd->dir = a.flags & FDREC_BUFS_DIR_MASK;
	fd->chan = fd->chans[fdrec_slot(fd)];

	if (a.count > FDREC_MAX_BUFS || a.count < 2)
		return -EINVAL;
	if (!a.buf_size || a.buf_size % FDREC_BUF_ALIGN ||
	    a.buf_size > FDREC_MAX_BUF_SIZE)
		return -EINVAL;
	if (a.buf_size / FDREC_BEAT_BYTES > FDREC_MAX_PKT_LEN)
		return -EINVAL;

	addrs = memdup_array_user(u64_to_user_ptr(a.addrs), a.count, sizeof(u64));
	if (IS_ERR(addrs))
		return PTR_ERR(addrs);

	fd->bufs = kcalloc(a.count, sizeof(*fd->bufs), GFP_KERNEL);
	if (!fd->bufs) {
		ret = -ENOMEM;
		goto out;
	}
	fd->buf_size = a.buf_size;
	fd->nbufs = 0;
	for (i = 0; i < a.count; i++) {
		struct fdrec_buf *b = &fd->bufs[i];

		b->fd = fd;
		b->index = i;
		b->state = BUF_FREE;
		INIT_LIST_HEAD(&b->node);
		if (addrs[i] % FDREC_BUF_ALIGN) {
			ret = -EINVAL;
			goto err;
		}
		ret = fdrec_pin_buf(fd, b, addrs[i]);
		if (ret)
			goto err;
		fd->nbufs = i + 1;
		total_bds += b->nbds;
	}
	/* Conservative: all buffers' BDs fit the channel's ring (keep one spare
	 * so head never meets tail), although only FDREC_DMA_DEPTH buffers are
	 * in xilinx_dma at a time. */
	if (total_bds >= XDMA_NUM_BDS) {
		dev_err(fd->dev, "%u buffers need %u DMA BDs, the channel has %u\n",
			a.count, total_bds, XDMA_NUM_BDS);
		ret = -E2BIG;
		goto err;
	}
	dev_dbg(fd->dev, "registered %u x %llu bytes (%u BDs)\n",
		a.count, a.buf_size, total_bds);
	ret = 0;
	goto out;
err:
	fdrec_unregister(fd);
out:
	kfree(addrs);
	return ret;
}

/* ------------------------------------------------------------------------ */
/* Start / stop                                                             */

static int fdrec_start(struct fdrec_dev *fd, struct fdrec_start __user *uarg)
{
	struct fdrec_start a;
	bool tpg_was_on;
	unsigned int i;
	u32 pkt_len;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (a.flags & ~FDREC_START_TPG)
		return -EINVAL;
	if (fd->running)
		return -EBUSY;
	if (fd->nbufs < 2)
		return -ENOBUFS;
	if (fd->dir != FDREC_DIR_RECORD)
		return -EINVAL;
	if (!fd->chan)
		return -ENODEV;	/* lost in an earlier channel renewal */
	for (i = 0; i < fd->nbufs; i++)
		if (fd->bufs[i].state != BUF_FREE)
			return -EBUSY;

	pkt_len = (u32)(fd->buf_size / FDREC_BEAT_BYTES);
	tpg_was_on = fd_rd(fd, FDREC_TPG_CTRL) & FDREC_TPG_CTRL_ENABLE;

	/* Flush the FIFO and clear every counter; disables packetizer + TPG */
	ret = fd_soft_reset(fd);
	if (ret) {
		dev_err(fd->dev, "GLOBAL_CTRL.SOFT_RST did not clear\n");
		return ret;
	}
	fd_wr(fd, FDREC_PKT_LEN, pkt_len);

	spin_lock_irq(&fd->qlock);
	INIT_LIST_HEAD(&fd->ready);
	fd->fill_seq = 0;
	fd->bytes_filled = 0;
	fd->dma_errors = 0;
	fd->dma_error = false;
	spin_unlock_irq(&fd->qlock);

	/*
	 * Hand every buffer to the DMA queue; fdrec_feed() submits the first
	 * FDREC_DMA_DEPTH of them (buffer 0 starts at once, buffer 1 pending)
	 * and each completion submits the next. The packetizer is still
	 * disabled, so nothing completes before it is enabled below.
	 */
	for (i = 0; i < fd->nbufs; i++)
		dma_sync_sgtable_for_device(fd->dma_dev, &fd->bufs[i].sgt,
					    DMA_FROM_DEVICE);
	spin_lock_irq(&fd->qlock);
	INIT_LIST_HEAD(&fd->dmaq);
	for (i = 0; i < fd->nbufs; i++) {
		fd->bufs[i].state = BUF_QUEUED;
		list_add_tail(&fd->bufs[i].node, &fd->dmaq);
	}
	fd->dma_active = 0;
	fd->accepting = true;
	fdrec_feed(fd);
	ret = fd->dma_error ? -EIO : 0;
	spin_unlock_irq(&fd->qlock);
	if (ret)
		goto err;

	fd->running = true;
	fd_wr(fd, FDREC_PKT_CTRL, FDREC_PKT_CTRL_ENABLE);
	a.start_time_ns = ktime_get_real_ns();

	/*
	 * SOFT_RST cleared the TPG sequence counter and left the TPG disabled,
	 * and the packetizer is already passing data, so the first beat the
	 * TPG emits from here on -- sequence number 0 -- is the first beat
	 * recorded. (TPG_SEQ_NEXT is not read back here: it is a src_clk-domain
	 * snapshot that may lag by ~0.5 us.)
	 */
	a.first_seq = 0;
	fd->started_tpg = false;
	if (a.flags & FDREC_START_TPG) {
		fd_wr(fd, FDREC_TPG_CTRL, FDREC_TPG_CTRL_SEQ_RST);
		fd_wr(fd, FDREC_TPG_CTRL, FDREC_TPG_CTRL_ENABLE);
		fd->started_tpg = true;
	} else if (tpg_was_on) {
		/* "do not touch the generator": restore its enable state */
		fd_wr(fd, FDREC_TPG_CTRL, FDREC_TPG_CTRL_ENABLE);
	}
	a.pkt_len = pkt_len;
	memset(a.reserved, 0, sizeof(a.reserved));
	if (copy_to_user(uarg, &a, sizeof(a)))
		return -EFAULT;	/* running; user space must STOP or close */
	return 0;
err:
	spin_lock_irq(&fd->qlock);
	fd->accepting = false;
	spin_unlock_irq(&fd->qlock);
	dmaengine_terminate_sync(fd->chan);
	fdrec_renew_chan(fd, FD_RX);
	spin_lock_irq(&fd->qlock);
	for (i = 0; i < fd->nbufs; i++)
		fd->bufs[i].state = BUF_FREE;
	INIT_LIST_HEAD(&fd->ready);
	INIT_LIST_HEAD(&fd->dmaq);
	fd->dma_active = 0;
	fd->dma_error = false;
	spin_unlock_irq(&fd->qlock);
	return ret;
}

/* Buffers currently owned by the AXI DMA (submitted to xilinx_dma) */
static unsigned int fdrec_bufs_in_dma(struct fdrec_dev *fd)
{
	unsigned int i, n = 0;

	spin_lock_irq(&fd->qlock);
	for (i = 0; i < fd->nbufs; i++)
		if (fd->bufs[i].state == BUF_DMA)
			n++;
	spin_unlock_irq(&fd->qlock);
	return n;
}

/*
 * Let every descriptor the DMA owns complete before the channel is
 * terminated.
 *
 * The AXI DMA S2MM channel cannot halt in the middle of a packet: with the
 * packetizer gated mid-buffer it keeps waiting for the rest of the packet,
 * DMASR.Halted never sets, and xilinx_dma_terminate_all() busy-polls for it
 * with readl_poll_timeout_atomic(delay 0, 1000000 us). That timeout counts
 * loop iterations as nanoseconds, and each iteration is an AXI-Lite read of
 * ~0.4 us, so the poll spins a CPU for ~7 minutes (RCU stall warnings, "Cannot
 * stop channel ...: 50008") before the channel is reset. Seen on uzev with the
 * first driver version, which gated the packetizer before terminating.
 * meta-fdrec patches xilinx_dma to poll with a 1 us delay, which bounds that
 * case to ~1 s, but a clean drain still avoids the engine reset entirely.
 *
 * So STOP keeps the datapath running until the DMA reaches the tail of its
 * descriptor chain (every queued buffer full; nothing is re-queued during the
 * drain) and is idle; an idle channel halts at once. With the test pattern
 * generator the generator runs at full rate meanwhile, so the drain takes at
 * most a few ms (the discarded buffers' data is never handed out). With a
 * user source we can only wait for it to deliver the rest of the packets.
 */
static unsigned int stop_drain_ms = 5000;
module_param(stop_drain_ms, uint, 0644);
MODULE_PARM_DESC(stop_drain_ms,
		 "STOP: max time to let queued buffers fill before the DMA is terminated (ms)");

static bool fdrec_drain(struct fdrec_dev *fd)
{
	unsigned long tmo = msecs_to_jiffies(stop_drain_ms);
	u32 rate_inc = 0;

	if (fd->started_tpg) {
		rate_inc = fd_rd(fd, FDREC_TPG_RATE_INC);
		fd_wr(fd, FDREC_TPG_RATE_INC, FDREC_TPG_RATE_INC_ONE);
	}
	wait_event_timeout(fd->wq, fdrec_bufs_in_dma(fd) == 0, tmo);
	if (fd->started_tpg)
		fd_wr(fd, FDREC_TPG_RATE_INC, rate_inc);
	return fdrec_bufs_in_dma(fd) == 0;
}

static void fdrec_stop(struct fdrec_dev *fd, struct fdrec_stats *st)
{
	unsigned int i;
	bool drained;

	if (!fd->running) {
		if (st)
			fd_read_stats(fd, st);
		return;
	}
	/* Counters as they are when the recording is stopped (the drain below
	 * runs the generator at full rate; its beats are not recorded) */
	if (st)
		fd_read_stats(fd, st);

	/* No completion may submit another buffer from here on */
	spin_lock_irq(&fd->qlock);
	fd->accepting = false;
	spin_unlock_irq(&fd->qlock);

	drained = fdrec_drain(fd);

	/* Gate the datapath: the DMA sees no further data */
	fd_wr(fd, FDREC_PKT_CTRL, 0);
	if (fd->started_tpg)
		fd_wr(fd, FDREC_TPG_CTRL, 0);
	fd->started_tpg = false;
	if (!drained)
		dev_info(fd->dev, "STOP: source stalled, the DMA still owns buffers after %u ms; terminating a channel that is mid-packet -- xilinx_dma will report \"Cannot stop channel\" and the DMA engine will be reset\n",
			 stop_drain_ms);

	/* Halts the channel, frees every descriptor and waits for running
	 * callbacks (tasklet_kill) -- no callback runs after this. If the
	 * channel is mid-packet it cannot halt: xilinx_dma's stop poll times
	 * out (~1 s with meta-fdrec's xilinx_dma poll-delay patch; ~7 min of a
	 * spinning CPU without it) and xilinx_dma_chan_reset() resets the
	 * engine. fdrec_renew_chan() below then rebuilds both channels, as
	 * after every STOP. */
	dmaengine_terminate_sync(fd->chan);
	fd->running = false;
	fdrec_renew_chan(fd, FD_RX);

	/* Buffers that were queued or filled-but-not-collected are discarded;
	 * buffers user space holds stay BUF_USER until RELEASE. */
	spin_lock_irq(&fd->qlock);
	for (i = 0; i < fd->nbufs; i++) {
		struct fdrec_buf *b = &fd->bufs[i];

		if (b->state == BUF_DMA || b->state == BUF_READY ||
		    b->state == BUF_QUEUED)
			b->state = BUF_FREE;
	}
	INIT_LIST_HEAD(&fd->ready);
	INIT_LIST_HEAD(&fd->dmaq);
	fd->dma_active = 0;
	spin_unlock_irq(&fd->qlock);
	if (st)
		st->running = 0;
	wake_up_all(&fd->wq);
}

/* ------------------------------------------------------------------------ */
/* Playback (MM2S)                                                          */

/* Checker / egress registers exist from fdrec_core VERSION 1.1 on */
static bool fd_has_chk(struct fdrec_dev *fd)
{
	return fd->caps & FDREC_CAP_CHECK;
}

static u64 fd_sink_rate_get(struct fdrec_dev *fd)
{
	u64 inc = fd_rd(fd, FDREC_CHK_RATE_INC);

	if (inc > FDREC_CHK_RATE_INC_ONE)
		inc = FDREC_CHK_RATE_INC_ONE;
	/* same Q1.31 scheme as the TPG, on snk_clk = src_clk */
	return mul_u64_u64_div_u64(inc, (u64)fd->src_clk_hz * FDREC_BEAT_BYTES,
				   1ull << FDREC_TPG_RATE_INC_FRAC_BITS);
}

/* rate_bps 0 is refused by the callers: a sink that is never ready would
 * keep the MM2S channel from ever finishing a buffer */
static u64 fd_sink_rate_set(struct fdrec_dev *fd, u64 rate_bps)
{
	u64 max = (u64)fd->src_clk_hz * FDREC_BEAT_BYTES;
	u64 inc;

	if (!max)
		return 0;
	if (rate_bps > max)
		rate_bps = max;
	inc = mul_u64_u64_div_u64(rate_bps, 1ull << FDREC_TPG_RATE_INC_FRAC_BITS,
				  max);
	if (!inc)
		inc = 1;
	if (inc > FDREC_CHK_RATE_INC_ONE)
		inc = FDREC_CHK_RATE_INC_ONE;
	fd_wr(fd, FDREC_CHK_RATE_INC, (u32)inc);
	return fd_sink_rate_get(fd);
}

/* CHK_CTRL.RESET: counters cleared, expected sequence := next first beat.
 * The bit reads 1 while the reset is in progress (a few hundred dp_clk). */
static int fd_chk_reset(struct fdrec_dev *fd, bool enable_after)
{
	u32 v;
	int ret;

	fd_wr(fd, FDREC_CHK_CTRL, FDREC_CHK_CTRL_RESET);	/* ENABLE := 0 */
	ret = readl_poll_timeout(fd->regs + FDREC_CHK_CTRL, v,
				 !(v & FDREC_CHK_CTRL_RESET), 1, 10000);
	if (ret)
		dev_err(fd->dev, "CHK_CTRL.RESET did not clear\n");
	if (enable_after)
		fd_wr(fd, FDREC_CHK_CTRL, FDREC_CHK_CTRL_ENABLE);
	return ret;
}

/* Called with qlock held: enable a checker that PLAY_START left waiting */
static void fd_chk_enable_pending(struct fdrec_dev *fd)
{
	if (fd->chk_pending) {
		fd->chk_pending = false;
		fd_wr(fd, FDREC_CHK_CTRL, FDREC_CHK_CTRL_ENABLE);
	}
}

/*
 * Enable the checker once the stream has primed the egress FIFO. Enabled any
 * earlier, it would start consuming as soon as the first beat arrives, while
 * the MM2S is still ramping up, and count those starved ticks as underflows.
 * Wait (sleeping, process context) until the FIFO holds 31/32 of its depth
 * or the whole first buffer; if the first buffer completes first (it fits in
 * the FIFO), the completion callback enables it.
 */
static void fd_chk_enable_primed(struct fdrec_dev *fd, u64 first_bytes)
{
	u32 depth = fd_rd(fd, FDREC_EGR_FIFO_DEPTH);
	u32 want = depth - depth / 32;
	u32 v;

	if (first_bytes / FDREC_BEAT_BYTES < want)
		want = (u32)(first_bytes / FDREC_BEAT_BYTES);
	if (readl_poll_timeout(fd->regs + FDREC_EGR_FIFO_LEVEL, v, v >= want ||
			       !READ_ONCE(fd->chk_pending), 2, 100000))
		dev_warn(fd->dev, "egress FIFO did not prime (level %u of %u) in 100 ms; enabling the checker anyway\n",
			 v, want);
	spin_lock_irq(&fd->qlock);
	fd_chk_enable_pending(fd);
	spin_unlock_irq(&fd->qlock);
}

static void fd_read_chk(struct fdrec_dev *fd, struct fdrec_chk_stats *c)
{
	memset(c, 0, sizeof(*c));
	if (!fd_has_chk(fd))
		return;
	c->beats = fd_rd64(fd, FDREC_CHK_BEATS_LO);
	c->errors = fd_rd64(fd, FDREC_CHK_ERRORS_LO);
	c->gaps = fd_rd64(fd, FDREC_CHK_GAPS_LO);
	c->gap_beats = fd_rd64(fd, FDREC_CHK_GAP_BEATS_LO);
	c->underflows = fd_rd64(fd, FDREC_CHK_UNDERFLOWS_LO);
	c->last_seq = fd_rd64(fd, FDREC_CHK_LAST_SEQ_LO);
	c->rate_bps = fd_sink_rate_get(fd);
	c->enabled = !!(fd_rd(fd, FDREC_CHK_CTRL) & FDREC_CHK_CTRL_ENABLE);
}

static void fd_read_play_stats(struct fdrec_dev *fd, struct fdrec_play_stats *st)
{
	struct fdrec_buf *b;
	unsigned long flags;
	unsigned int i;

	memset(st, 0, sizeof(*st));
	fd_read_chk(fd, &st->chk);
	if (fd_has_chk(fd)) {
		st->egr_beats_in = fd_rd64(fd, FDREC_EGR_BEATS_IN_LO);
		st->egr_discard = fd_rd64(fd, FDREC_EGR_DISCARD_LO);
		st->egr_level = fd_rd(fd, FDREC_EGR_FIFO_LEVEL);
		st->egr_depth = fd_rd(fd, FDREC_EGR_FIFO_DEPTH);
	}
	st->running = fd->running && fd->dir == FDREC_DIR_PLAY;

	spin_lock_irqsave(&fd->qlock, flags);
	if (fd->dir == FDREC_DIR_PLAY) {
		st->bufs_done = fd->fill_seq;
		st->bytes_done = fd->bytes_filled;
		st->dma_errors = fd->dma_errors;
		for (i = 0; i < fd->nbufs; i++) {
			b = &fd->bufs[i];
			if (b->state == BUF_DMA || b->state == BUF_QUEUED)
				st->bufs_dma++;
			else if (b->state == BUF_READY)
				st->bufs_ready++;
		}
	}
	spin_unlock_irqrestore(&fd->qlock, flags);
}

static int fdrec_play_start(struct fdrec_dev *fd, struct fdrec_play_start __user *uarg)
{
	struct fdrec_play_start a;
	unsigned int i;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (a.flags & ~FDREC_PLAY_CHECK)
		return -EINVAL;
	if (fd->running)
		return -EBUSY;
	if (fd->nbufs < 2)
		return -ENOBUFS;
	if (fd->dir != FDREC_DIR_PLAY)
		return -EINVAL;
	if ((a.flags & FDREC_PLAY_CHECK) && !fd_has_chk(fd))
		return -EOPNOTSUPP;
	if (!fd->chan)
		return -ENODEV;	/* lost in an earlier channel renewal */

	fd->started_chk = false;
	if (a.flags & FDREC_PLAY_CHECK) {
		/* Empty the egress FIFO of an earlier, aborted playback and
		 * clear every counter (CHK_RATE_INC survives), then start the
		 * checker on the first beat of this playback. */
		ret = fd_soft_reset(fd);
		if (ret) {
			dev_err(fd->dev, "GLOBAL_CTRL.SOFT_RST did not clear\n");
			return ret;
		}
		/* reset with ENABLE = 0; enabled once the FIFO has primed
		 * (fd_chk_enable_primed, first PLAY_SUBMIT) */
		ret = fd_chk_reset(fd, false);
		if (ret)
			return ret;
		fd->started_chk = true;
	}

	spin_lock_irq(&fd->qlock);
	INIT_LIST_HEAD(&fd->ready);
	INIT_LIST_HEAD(&fd->dmaq);
	for (i = 0; i < fd->nbufs; i++)
		fd->bufs[i].state = BUF_FREE;	/* all the app's */
	fd->fill_seq = 0;
	fd->bytes_filled = 0;
	fd->dma_errors = 0;
	fd->dma_error = false;
	fd->dma_active = 0;
	fd->accepting = true;
	fd->chk_pending = fd->started_chk;
	spin_unlock_irq(&fd->qlock);
	fd->running = true;

	a.start_time_ns = ktime_get_real_ns();
	a.reserved0 = 0;
	memset(a.reserved, 0, sizeof(a.reserved));
	if (copy_to_user(uarg, &a, sizeof(a)))
		return -EFAULT;	/* running; user space must PLAY_STOP or close */
	return 0;
}

/* DMA view of the first len bytes of a playback buffer */
static void fdrec_build_psg(struct fdrec_buf *b, u64 len)
{
	struct scatterlist *sg;
	unsigned int i, n = 0;
	u64 left = len;

	sg_init_table(b->psg, b->sgt.nents);
	for_each_sgtable_dma_sg(&b->sgt, sg, i) {
		u32 l = (u32)min_t(u64, sg_dma_len(sg), left);

		sg_dma_address(&b->psg[n]) = sg_dma_address(sg);
		sg_dma_len(&b->psg[n]) = l;
		n++;
		left -= l;
		if (!left)
			break;
	}
	sg_mark_end(&b->psg[n - 1]);
	b->psg_n = n;
}

static int fdrec_play_submit(struct fdrec_dev *fd, struct fdrec_play_submit __user *uarg)
{
	struct fdrec_play_submit a;
	struct fdrec_buf *b;
	enum fdrec_buf_state st;
	int ret = 0;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (fd->dir != FDREC_DIR_PLAY || a.flags || a.index >= fd->nbufs)
		return -EINVAL;
	if (!a.bytes || a.bytes > fd->buf_size || a.bytes % FDREC_BEAT_BYTES)
		return -EINVAL;
	if (!fd->running)
		return -EPIPE;
	b = &fd->bufs[a.index];
	spin_lock_irq(&fd->qlock);
	st = b->state;
	spin_unlock_irq(&fd->qlock);
	if (st != BUF_FREE && st != BUF_USER)
		return -EBUSY;	/* the driver still owns it */

	fdrec_build_psg(b, a.bytes);
	b->len = a.bytes;
	/* Clean: see "Cache coherency" at the top -- mandatory for TO_DEVICE */
	dma_sync_sgtable_for_device(fd->dma_dev, &b->sgt, DMA_TO_DEVICE);

	spin_lock_irq(&fd->qlock);
	if (!fd->accepting) {
		ret = -EPIPE;
	} else {
		b->state = BUF_QUEUED;
		list_add_tail(&b->node, &fd->dmaq);
		fdrec_feed(fd);
		if (fd->dma_error)
			ret = -EIO;
	}
	spin_unlock_irq(&fd->qlock);
	if (!ret && READ_ONCE(fd->chk_pending))
		fd_chk_enable_primed(fd, a.bytes);
	return ret;
}

static int fdrec_play_wait_done(struct fdrec_dev *fd, struct fdrec_play_done __user *uarg)
{
	struct fdrec_play_done a;
	struct fdrec_buf *b = NULL;
	long tmo;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	tmo = a.timeout_ms < 0 ? MAX_SCHEDULE_TIMEOUT : msecs_to_jiffies(a.timeout_ms);

	for (;;) {
		ret = mutex_lock_interruptible(&fd->lock);
		if (ret)
			return ret;
		if (fd->dir != FDREC_DIR_PLAY) {
			mutex_unlock(&fd->lock);
			return -EINVAL;
		}
		spin_lock_irq(&fd->qlock);
		if (!list_empty(&fd->ready)) {
			b = list_first_entry(&fd->ready, struct fdrec_buf, node);
			list_del_init(&b->node);
			b->state = BUF_USER;
		}
		spin_unlock_irq(&fd->qlock);
		if (b) {
			/* No-op on arm64 for TO_DEVICE; ownership back to the CPU */
			dma_sync_sgtable_for_cpu(fd->dma_dev, &b->sgt, DMA_TO_DEVICE);
			a.index = b->index;
			a.bytes = b->bytes;
			a.seq = b->seq;
			a.flags = b->flags & FDREC_DONE_ERROR;
			mutex_unlock(&fd->lock);
			break;
		}
		if (!fd->running) {
			mutex_unlock(&fd->lock);
			return -ENODATA;
		}
		mutex_unlock(&fd->lock);
		if (!tmo)
			return -ETIMEDOUT;
		tmo = wait_event_interruptible_timeout(fd->wq,
				!list_empty(&fd->ready) || !fd->running, tmo);
		if (tmo < 0)
			return tmo;	/* -ERESTARTSYS */
		if (tmo == 0) {
			spin_lock_irq(&fd->qlock);
			ret = list_empty(&fd->ready);
			spin_unlock_irq(&fd->qlock);
			if (ret)
				return -ETIMEDOUT;
		}
	}
	a.reserved0 = 0;
	memset(a.reserved, 0, sizeof(a.reserved));
	if (copy_to_user(uarg, &a, sizeof(a)))
		return -EFAULT;
	return (a.flags & FDREC_DONE_ERROR) ? -EIO : 0;
}

/*
 * Stop a playback.
 *
 * Like S2MM, the AXI DMA MM2S channel halts (DMACR.RS = 0 -> DMASR.Halted)
 * only once the transfers it has started are complete, i.e. once the stream
 * side has taken the data it fetched; a sink that is disabled or throttled
 * to a crawl would leave xilinx_dma_stop_transfer() spinning in its atomic
 * poll for minutes (see the S2MM note above fdrec_drain). So PLAY_STOP stops
 * feeding, sets EGR_CTRL.FLUSH -- the egress FIFO then accepts and discards
 * every beat from the DMA -- waits until the (at most two) descriptors left
 * in xilinx_dma complete, and terminates the now idle channel. Without the
 * flush control (VERSION 1.0 has no MM2S anyway) or if the wait times out we
 * terminate regardless and warn. An idle MM2S channel at the end of a normal
 * playback halts at once; nothing is discarded then.
 */
static void fdrec_play_stop(struct fdrec_dev *fd, struct fdrec_play_stats *st)
{
	unsigned long tmo = msecs_to_jiffies(stop_drain_ms);
	unsigned int i;
	bool flushed = false;

	if (!fd->running || fd->dir != FDREC_DIR_PLAY) {
		if (st)
			fd_read_play_stats(fd, st);
		return;
	}

	spin_lock_irq(&fd->qlock);
	fd->accepting = false;
	fd->chk_pending = false;
	spin_unlock_irq(&fd->qlock);

	if (fdrec_bufs_in_dma(fd) && fd_has_chk(fd)) {
		fd_wr(fd, FDREC_EGR_CTRL, FDREC_EGR_CTRL_FLUSH);
		flushed = true;
	}
	wait_event_timeout(fd->wq, fdrec_bufs_in_dma(fd) == 0, tmo);
	if (fdrec_bufs_in_dma(fd))
		dev_info(fd->dev, "PLAY_STOP: sink stalled, the DMA still owns buffers after %u ms; terminating a channel that is mid-transfer -- xilinx_dma will report \"Cannot stop channel\" and the DMA engine will be reset\n",
			 stop_drain_ms);

	dmaengine_terminate_sync(fd->chan);
	if (flushed)
		fd_wr(fd, FDREC_EGR_CTRL, 0);
	if (fd->started_chk)
		fd_wr(fd, FDREC_CHK_CTRL, 0);	/* freeze; counters keep their values */
	fd->started_chk = false;
	fd->running = false;
	fdrec_renew_chan(fd, FD_TX);

	spin_lock_irq(&fd->qlock);
	for (i = 0; i < fd->nbufs; i++)
		fd->bufs[i].state = BUF_FREE;	/* all the app's again */
	INIT_LIST_HEAD(&fd->ready);
	INIT_LIST_HEAD(&fd->dmaq);
	fd->dma_active = 0;
	spin_unlock_irq(&fd->qlock);
	/* Final counters, read once everything has stopped: the checker is
	 * frozen (ENABLE = 0), so BEATS / GAP_BEATS / LAST_SEQ are one coherent
	 * set even after an interrupted playback (read while the stream still
	 * ran, they were not: fdplay then saw a bogus "first beat" mismatch),
	 * and EGR_DISCARD includes what the FLUSH above threw away. */
	if (st)
		fd_read_play_stats(fd, st);
	wake_up_all(&fd->wq);
}

/* close / remove: stop whatever runs */
static void fdrec_stop_any(struct fdrec_dev *fd)
{
	if (fd->dir == FDREC_DIR_PLAY)
		fdrec_play_stop(fd, NULL);
	else
		fdrec_stop(fd, NULL);
}

/* ------------------------------------------------------------------------ */
/* File operations                                                          */

static int fdrec_wait_filled(struct fdrec_dev *fd, struct fdrec_filled __user *uarg)
{
	struct fdrec_filled a;
	struct fdrec_buf *b = NULL;
	long tmo;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	tmo = a.timeout_ms < 0 ? MAX_SCHEDULE_TIMEOUT : msecs_to_jiffies(a.timeout_ms);

	for (;;) {
		ret = mutex_lock_interruptible(&fd->lock);
		if (ret)
			return ret;
		if (fd->dir != FDREC_DIR_RECORD) {
			mutex_unlock(&fd->lock);
			return -EINVAL;
		}
		spin_lock_irq(&fd->qlock);
		if (!list_empty(&fd->ready)) {
			b = list_first_entry(&fd->ready, struct fdrec_buf, node);
			list_del_init(&b->node);
			b->state = BUF_USER;
		}
		spin_unlock_irq(&fd->qlock);
		if (b) {
			/* Invalidate: see "Cache coherency" at the top */
			dma_sync_sgtable_for_cpu(fd->dma_dev, &b->sgt, DMA_FROM_DEVICE);
			a.index = b->index;
			a.bytes = b->bytes;
			a.seq = b->seq;
			a.drop_count = b->drop_count;
			a.flags = b->flags;
			mutex_unlock(&fd->lock);
			break;
		}
		if (!fd->running) {
			mutex_unlock(&fd->lock);
			return -ENODATA;
		}
		mutex_unlock(&fd->lock);
		if (!tmo)
			return -ETIMEDOUT;
		tmo = wait_event_interruptible_timeout(fd->wq,
				!list_empty(&fd->ready) || !fd->running, tmo);
		if (tmo < 0)
			return tmo;	/* -ERESTARTSYS */
		if (tmo == 0) {
			/* timed out: one last look */
			spin_lock_irq(&fd->qlock);
			ret = list_empty(&fd->ready);
			spin_unlock_irq(&fd->qlock);
			if (ret)
				return -ETIMEDOUT;
		}
	}
	a.reserved0 = 0;
	memset(a.reserved, 0, sizeof(a.reserved));
	if (copy_to_user(uarg, &a, sizeof(a)))
		return -EFAULT;
	return (a.flags & FDREC_FILLED_ERROR) ? -EIO : 0;
}

static int fdrec_release_buf(struct fdrec_dev *fd, struct fdrec_release __user *uarg)
{
	struct fdrec_release a;
	struct fdrec_buf *b;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	if (a.flags || a.index >= fd->nbufs || fd->dir != FDREC_DIR_RECORD)
		return -EINVAL;
	b = &fd->bufs[a.index];
	if (b->state != BUF_USER)
		return -EINVAL;

	/* Clean: see "Cache coherency" at the top */
	dma_sync_sgtable_for_device(fd->dma_dev, &b->sgt, DMA_FROM_DEVICE);

	spin_lock_irq(&fd->qlock);
	if (fd->accepting) {
		b->state = BUF_QUEUED;
		list_add_tail(&b->node, &fd->dmaq);
		fdrec_feed(fd);
	} else {
		b->state = BUF_FREE;
	}
	spin_unlock_irq(&fd->qlock);
	return 0;
}

static long fdrec_ioctl(struct file *f, unsigned int cmd, unsigned long arg)
{
	struct fdrec_dev *fd = f->private_data;
	void __user *uarg = (void __user *)arg;
	struct fdrec_stats st;
	struct fdrec_play_stats pst;
	long ret;

	/* WAIT_FILLED / PLAY_WAIT_DONE sleep; they take the lock themselves,
	 * around queue access only */
	if (cmd == FDREC_IOC_WAIT_FILLED)
		return fdrec_wait_filled(fd, uarg);
	if (cmd == FDREC_IOC_PLAY_WAIT_DONE)
		return fdrec_play_wait_done(fd, uarg);

	if (mutex_lock_interruptible(&fd->lock))
		return -ERESTARTSYS;

	switch (cmd) {
	case FDREC_IOC_GET_INFO: {
		struct fdrec_info info = {
			.api_version = FDREC_API_VERSION,
			.hw_version = fd->hw_version,
			.src_clk_hz = fd->src_clk_hz,
			.dp_clk_hz = fd->dp_clk_hz,
			.beat_bytes = FDREC_BEAT_BYTES,
			.fifo_depth = fd->fifo_depth,
			.max_bufs = FDREC_MAX_BUFS,
			.caps = fd->caps,
			.buf_align = FDREC_BUF_ALIGN,
			.max_buf_size = FDREC_MAX_BUF_SIZE,
			.max_sg_len = fd->max_sg_len,
		};

		ret = copy_to_user(uarg, &info, sizeof(info)) ? -EFAULT : 0;
		break;
	}
	case FDREC_IOC_REGISTER_BUFS:
		ret = fdrec_register(fd, uarg);
		break;
	case FDREC_IOC_START:
		ret = fdrec_start(fd, uarg);
		break;
	case FDREC_IOC_RELEASE:
		ret = fdrec_release_buf(fd, uarg);
		break;
	case FDREC_IOC_STOP:
		if (fd->dir != FDREC_DIR_RECORD && fd->running) {
			ret = -EINVAL;
			break;
		}
		fdrec_stop(fd, &st);
		ret = copy_to_user(uarg, &st, sizeof(st)) ? -EFAULT : 0;
		break;
	case FDREC_IOC_GET_STATS:
		fd_read_stats(fd, &st);
		ret = copy_to_user(uarg, &st, sizeof(st)) ? -EFAULT : 0;
		break;
	case FDREC_IOC_SET_RATE: {
		struct fdrec_rate r;

		if (copy_from_user(&r, uarg, sizeof(r))) {
			ret = -EFAULT;
			break;
		}
		r.rate_bps = fd_rate_set(fd, r.rate_bps);
		ret = copy_to_user(uarg, &r, sizeof(r)) ? -EFAULT : 0;
		break;
	}
	case FDREC_IOC_PLAY_START:
		ret = fdrec_play_start(fd, uarg);
		break;
	case FDREC_IOC_PLAY_SUBMIT:
		ret = fdrec_play_submit(fd, uarg);
		break;
	case FDREC_IOC_PLAY_STOP:
		if (fd->dir != FDREC_DIR_PLAY && fd->running) {
			ret = -EINVAL;
			break;
		}
		fdrec_play_stop(fd, &pst);
		ret = copy_to_user(uarg, &pst, sizeof(pst)) ? -EFAULT : 0;
		break;
	case FDREC_IOC_GET_PLAY_STATS:
		fd_read_play_stats(fd, &pst);
		ret = copy_to_user(uarg, &pst, sizeof(pst)) ? -EFAULT : 0;
		break;
	case FDREC_IOC_SET_SINK_RATE: {
		struct fdrec_rate r;

		if (!fd_has_chk(fd)) {
			ret = -EOPNOTSUPP;
			break;
		}
		if (copy_from_user(&r, uarg, sizeof(r))) {
			ret = -EFAULT;
			break;
		}
		if (!r.rate_bps) {
			ret = -EINVAL;
			break;
		}
		r.rate_bps = fd_sink_rate_set(fd, r.rate_bps);
		ret = copy_to_user(uarg, &r, sizeof(r)) ? -EFAULT : 0;
		break;
	}
	default:
		ret = -ENOTTY;
	}
	mutex_unlock(&fd->lock);
	return ret;
}

static int fdrec_open(struct inode *inode, struct file *f)
{
	struct miscdevice *misc = f->private_data;
	struct fdrec_dev *fd = container_of(misc, struct fdrec_dev, misc);
	int ret = 0;

	mutex_lock(&fd->lock);
	if (fd->in_use)
		ret = -EBUSY;	/* one recorder at a time */
	else
		fd->in_use = true;
	mutex_unlock(&fd->lock);
	if (ret)
		return ret;
	f->private_data = fd;
	return nonseekable_open(inode, f);
}

static int fdrec_close(struct inode *inode, struct file *f)
{
	struct fdrec_dev *fd = f->private_data;

	mutex_lock(&fd->lock);
	fdrec_stop_any(fd);
	/* Record: leave the hardware idle (FIFO flushed, packetizer and TPG
	 * off; from 1.1 SOFT_RST also disables the checker). Playback: leave the
	 * sink alone -- PLAY_STOP already disabled a checker PLAY_START enabled,
	 * and "fdplay --no-check" must not touch a sink set up by hand. */
	if (fd->dir == FDREC_DIR_RECORD)
		fd_soft_reset(fd);
	fdrec_unregister(fd);
	fd->in_use = false;
	mutex_unlock(&fd->lock);
	return 0;
}

/* POLLIN when a filled buffer is waiting (WAIT_FILLED will not block),
 * POLLHUP once stopped with nothing left, POLLERR after a DMA error. Lets an
 * app wait for "buffer filled" and "disk write done" in one place (e.g. an
 * io_uring poll request next to its write requests). */
static __poll_t fdrec_poll(struct file *f, struct poll_table_struct *wait)
{
	struct fdrec_dev *fd = f->private_data;
	unsigned long flags;
	__poll_t mask = 0;

	poll_wait(f, &fd->wq, wait);
	spin_lock_irqsave(&fd->qlock, flags);
	if (!list_empty(&fd->ready))
		mask |= EPOLLIN | EPOLLRDNORM;
	else if (!READ_ONCE(fd->running))
		mask |= EPOLLHUP;
	if (fd->dma_error)
		mask |= EPOLLERR;
	spin_unlock_irqrestore(&fd->qlock, flags);
	return mask;
}

static const struct file_operations fdrec_fops = {
	.owner = THIS_MODULE,
	.open = fdrec_open,
	.release = fdrec_close,
	.poll = fdrec_poll,
	.unlocked_ioctl = fdrec_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
};

/* ------------------------------------------------------------------------ */
/* sysfs: /sys/class/misc/fdrecN/<attr>                                     */

static struct fdrec_dev *to_fd(struct device *dev)
{
	struct miscdevice *misc = dev_get_drvdata(dev);

	return container_of(misc, struct fdrec_dev, misc);
}

#define FDREC_RO_U64(_name, _expr)					\
static ssize_t _name##_show(struct device *dev,				\
			    struct device_attribute *attr, char *buf)	\
{									\
	struct fdrec_dev *fd = to_fd(dev);				\
	return sysfs_emit(buf, "%llu\n", (unsigned long long)(_expr));	\
}									\
static DEVICE_ATTR_RO(_name)

FDREC_RO_U64(drop_count, fd_rd64(fd, FDREC_ING_DROP_COUNT_LO));
FDREC_RO_U64(beats_in, fd_rd64(fd, FDREC_ING_BEATS_IN_LO));
FDREC_RO_U64(beats_out, fd_rd64(fd, FDREC_PKT_BEATS_OUT_LO));
FDREC_RO_U64(seq_next, fd_rd64(fd, FDREC_TPG_SEQ_NEXT_LO));
FDREC_RO_U64(src_clk_hz, fd->src_clk_hz);
FDREC_RO_U64(dp_clk_hz, fd->dp_clk_hz);
FDREC_RO_U64(fifo_depth, fd->fifo_depth);

static ssize_t version_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct fdrec_dev *fd = to_fd(dev);

	return sysfs_emit(buf, "%u.%u\n", fd->hw_version >> 16,
			  fd->hw_version & 0xffff);
}
static DEVICE_ATTR_RO(version);

static ssize_t rate_bps_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	return sysfs_emit(buf, "%llu\n", fd_rate_get(to_fd(dev)));
}

static ssize_t rate_bps_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct fdrec_dev *fd = to_fd(dev);
	u64 v;
	int ret = kstrtou64(buf, 0, &v);

	if (ret)
		return ret;
	mutex_lock(&fd->lock);
	fd_rate_set(fd, v);
	mutex_unlock(&fd->lock);
	return count;
}
static DEVICE_ATTR_RW(rate_bps);

static ssize_t tpg_enable_show(struct device *dev, struct device_attribute *attr,
			       char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  !!(fd_rd(to_fd(dev), FDREC_TPG_CTRL) & FDREC_TPG_CTRL_ENABLE));
}

static ssize_t tpg_enable_store(struct device *dev, struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct fdrec_dev *fd = to_fd(dev);
	bool v;
	int ret = kstrtobool(buf, &v);

	if (ret)
		return ret;
	mutex_lock(&fd->lock);
	fd_wr(fd, FDREC_TPG_CTRL, v ? FDREC_TPG_CTRL_ENABLE : 0);
	mutex_unlock(&fd->lock);
	return count;
}
static DEVICE_ATTR_RW(tpg_enable);

static ssize_t overflow_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  !!(fd_rd(to_fd(dev), FDREC_ING_STATUS) & FDREC_ING_STATUS_OVERFLOW));
}

static ssize_t overflow_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct fdrec_dev *fd = to_fd(dev);
	u32 v;
	int ret = kstrtou32(buf, 0, &v);

	if (ret)
		return ret;
	if (v & 1)
		fd_wr(fd, FDREC_ING_STATUS, FDREC_ING_STATUS_OVERFLOW);	/* W1C */
	return count;
}
static DEVICE_ATTR_RW(overflow);

static ssize_t fifo_hwm_show(struct device *dev, struct device_attribute *attr,
			     char *buf)
{
	return sysfs_emit(buf, "%u\n", fd_rd(to_fd(dev), FDREC_ING_FIFO_HWM));
}

static ssize_t fifo_hwm_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	fd_wr(to_fd(dev), FDREC_ING_FIFO_HWM, 0);	/* any write clears */
	return count;
}
static DEVICE_ATTR_RW(fifo_hwm);

/* Playback checker / egress FIFO (VERSION >= 1.1; hidden otherwise) */
FDREC_RO_U64(chk_beats, fd_rd64(fd, FDREC_CHK_BEATS_LO));
FDREC_RO_U64(chk_errors, fd_rd64(fd, FDREC_CHK_ERRORS_LO));
FDREC_RO_U64(chk_gaps, fd_rd64(fd, FDREC_CHK_GAPS_LO));
FDREC_RO_U64(chk_gap_beats, fd_rd64(fd, FDREC_CHK_GAP_BEATS_LO));
FDREC_RO_U64(chk_underflows, fd_rd64(fd, FDREC_CHK_UNDERFLOWS_LO));
FDREC_RO_U64(chk_last_seq, fd_rd64(fd, FDREC_CHK_LAST_SEQ_LO));
FDREC_RO_U64(egr_beats_in, fd_rd64(fd, FDREC_EGR_BEATS_IN_LO));
FDREC_RO_U64(egr_discard, fd_rd64(fd, FDREC_EGR_DISCARD_LO));
FDREC_RO_U64(egr_fifo_level, fd_rd(fd, FDREC_EGR_FIFO_LEVEL));
FDREC_RO_U64(egr_fifo_depth, fd_rd(fd, FDREC_EGR_FIFO_DEPTH));

static ssize_t chk_enable_show(struct device *dev, struct device_attribute *attr,
			       char *buf)
{
	return sysfs_emit(buf, "%u\n",
			  !!(fd_rd(to_fd(dev), FDREC_CHK_CTRL) & FDREC_CHK_CTRL_ENABLE));
}

/* 1 = enable, 0 = disable (counters keep their values), "reset" = clear the
 * counters and the expected sequence number, keeping the enable state */
static ssize_t chk_enable_store(struct device *dev, struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct fdrec_dev *fd = to_fd(dev);
	bool v;
	int ret;

	mutex_lock(&fd->lock);
	if (sysfs_streq(buf, "reset")) {
		v = fd_rd(fd, FDREC_CHK_CTRL) & FDREC_CHK_CTRL_ENABLE;
		ret = fd_chk_reset(fd, v);
	} else {
		ret = kstrtobool(buf, &v);
		if (!ret)
			fd_wr(fd, FDREC_CHK_CTRL, v ? FDREC_CHK_CTRL_ENABLE : 0);
	}
	mutex_unlock(&fd->lock);
	return ret ? ret : count;
}
static DEVICE_ATTR_RW(chk_enable);

static ssize_t chk_rate_bps_show(struct device *dev, struct device_attribute *attr,
				 char *buf)
{
	return sysfs_emit(buf, "%llu\n", fd_sink_rate_get(to_fd(dev)));
}

static ssize_t chk_rate_bps_store(struct device *dev, struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct fdrec_dev *fd = to_fd(dev);
	u64 v;
	int ret = kstrtou64(buf, 0, &v);

	if (ret)
		return ret;
	if (!v)
		return -EINVAL;	/* never ready would wedge the MM2S channel */
	mutex_lock(&fd->lock);
	fd_sink_rate_set(fd, v);
	mutex_unlock(&fd->lock);
	return count;
}
static DEVICE_ATTR_RW(chk_rate_bps);

static struct attribute *fdrec_attrs[] = {
	&dev_attr_rate_bps.attr,
	&dev_attr_tpg_enable.attr,
	&dev_attr_drop_count.attr,
	&dev_attr_overflow.attr,
	&dev_attr_beats_in.attr,
	&dev_attr_beats_out.attr,
	&dev_attr_fifo_hwm.attr,
	&dev_attr_fifo_depth.attr,
	&dev_attr_seq_next.attr,
	&dev_attr_src_clk_hz.attr,
	&dev_attr_dp_clk_hz.attr,
	&dev_attr_version.attr,
	/* VERSION >= 1.1 */
	&dev_attr_chk_enable.attr,
	&dev_attr_chk_rate_bps.attr,
	&dev_attr_chk_beats.attr,
	&dev_attr_chk_errors.attr,
	&dev_attr_chk_gaps.attr,
	&dev_attr_chk_gap_beats.attr,
	&dev_attr_chk_underflows.attr,
	&dev_attr_chk_last_seq.attr,
	&dev_attr_egr_beats_in.attr,
	&dev_attr_egr_discard.attr,
	&dev_attr_egr_fifo_level.attr,
	&dev_attr_egr_fifo_depth.attr,
	NULL,
};

static umode_t fdrec_attr_visible(struct kobject *kobj, struct attribute *a, int n)
{
	struct fdrec_dev *fd = to_fd(kobj_to_dev(kobj));

	if (!strncmp(a->name, "chk_", 4) || !strncmp(a->name, "egr_", 4))
		return fd_has_chk(fd) ? a->mode : 0;
	return a->mode;
}

static const struct attribute_group fdrec_group = {
	.attrs = fdrec_attrs,
	.is_visible = fdrec_attr_visible,
};

static const struct attribute_group *fdrec_groups[] = {
	&fdrec_group,
	NULL,
};

/* ------------------------------------------------------------------------ */
/* Platform driver                                                          */

/* The AXI DMA's max_buffer_len, as xilinx_dma derives it (2^width - 1) */
static u32 fdrec_dma_max_len(struct device *dma_dev)
{
	u32 width = XDMA_DEFAULT_LEN_WIDTH;

	if (dma_dev && dma_dev->of_node &&
	    !of_property_read_u32(dma_dev->of_node, "xlnx,sg-length-width", &width)) {
		if (width < 8 || width > 26)
			width = XDMA_DEFAULT_LEN_WIDTH;
	}
	return (u32)((1ull << width) - 1);
}

static int fdrec_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct fdrec_dev *fd;
	int ret;

	fd = devm_kzalloc(dev, sizeof(*fd), GFP_KERNEL);
	if (!fd)
		return -ENOMEM;
	fd->dev = dev;
	spin_lock_init(&fd->reg_lock);
	spin_lock_init(&fd->qlock);
	mutex_init(&fd->lock);
	INIT_LIST_HEAD(&fd->ready);
	INIT_LIST_HEAD(&fd->dmaq);
	init_waitqueue_head(&fd->wq);

	fd->regs = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(fd->regs))
		return PTR_ERR(fd->regs);

	fd->hw_version = fd_rd(fd, FDREC_VERSION);
	if ((fd->hw_version & FDREC_VERSION_MAJOR_MASK) !=
	    (FDREC_VERSION_EXPECTED & FDREC_VERSION_MAJOR_MASK))
		return dev_err_probe(dev, -ENODEV,
				     "unsupported fdrec_core VERSION 0x%08x (expected major %u)\n",
				     fd->hw_version,
				     FDREC_VERSION_EXPECTED >> FDREC_VERSION_MAJOR_SHIFT);
	fd->src_clk_hz = fd_rd(fd, FDREC_SRC_CLK_HZ);
	fd->dp_clk_hz = fd_rd(fd, FDREC_DP_CLK_HZ);
	fd->fifo_depth = fd_rd(fd, FDREC_ING_FIFO_DEPTH);

	fd->caps = FDREC_CAP_TPG | FDREC_CAP_S2MM;
	if ((fd->hw_version & FDREC_VERSION_MINOR_MASK) >= 1)
		fd->caps |= FDREC_CAP_CHECK;	/* CHK_* / EGR_* registers */

	fd->chans[FD_RX] = dma_request_chan(dev, "rx");
	if (IS_ERR(fd->chans[FD_RX]))
		return dev_err_probe(dev, PTR_ERR(fd->chans[FD_RX]),
				     "cannot get DMA channel \"rx\"\n");
	fd->chan = fd->chans[FD_RX];
	fd->dma_dev = dmaengine_get_dma_device(fd->chan);

	/* Playback channel: optional (a 1.0 design has no MM2S). dmas index 0
	 * of the AXI DMA = MM2S (xilinx_dma xlate: chan id 0 = MM2S, 1 = S2MM). */
	fd->chans[FD_TX] = dma_request_chan(dev, "tx");
	if (IS_ERR(fd->chans[FD_TX])) {
		ret = PTR_ERR(fd->chans[FD_TX]);
		fd->chans[FD_TX] = NULL;
		if (ret == -EPROBE_DEFER) {
			dma_release_channel(fd->chans[FD_RX]);
			return ret;
		}
		dev_info(dev, "no DMA channel \"tx\" (%d): record only\n", ret);
	} else if (dmaengine_get_dma_device(fd->chans[FD_TX]) != fd->dma_dev) {
		dev_err(dev, "DMA channels rx and tx must belong to the same AXI DMA; playback disabled\n");
		dma_release_channel(fd->chans[FD_TX]);
		fd->chans[FD_TX] = NULL;
	} else {
		fd->caps |= FDREC_CAP_MM2S;
	}
	fd->max_sg_len = fdrec_dma_max_len(fd->dma_dev);
	if (dev_is_dma_coherent(fd->dma_dev))
		dev_info(dev, "DMA device is marked dma-coherent: cache syncs are no-ops\n");
	if (dma_addressing_limited(fd->dma_dev))
		dev_warn(dev, "the AXI DMA cannot address all of DDR (xlnx,addrwidth); buffers above its limit will be refused\n");

	/* Datapath idle, FIFO flushed */
	ret = fd_soft_reset(fd);
	if (ret) {
		dev_err(dev, "GLOBAL_CTRL.SOFT_RST did not clear\n");
		goto err_chan;
	}

	fd->id = ida_alloc(&fdrec_ida, GFP_KERNEL);
	if (fd->id < 0) {
		ret = fd->id;
		goto err_chan;
	}
	snprintf(fd->name, sizeof(fd->name), FDREC_DEV_NAME "%d", fd->id);
	fd->misc.minor = MISC_DYNAMIC_MINOR;
	fd->misc.name = fd->name;
	fd->misc.fops = &fdrec_fops;
	fd->misc.parent = dev;
	fd->misc.groups = fdrec_groups;
	ret = misc_register(&fd->misc);
	if (ret)
		goto err_ida;

	platform_set_drvdata(pdev, fd);
	dev_info(dev, "/dev/%s: fdrec_core v%u.%u, src_clk %u Hz, dp_clk %u Hz, FIFO %u beats, DMA rx %s tx %s (max segment %u bytes)%s\n",
		 fd->name, fd->hw_version >> 16, fd->hw_version & 0xffff,
		 fd->src_clk_hz, fd->dp_clk_hz, fd->fifo_depth,
		 dma_chan_name(fd->chans[FD_RX]),
		 fd->chans[FD_TX] ? dma_chan_name(fd->chans[FD_TX]) : "-",
		 fd->max_sg_len,
		 (fd->caps & FDREC_CAP_CHECK) ? ", checker" : "");
	return 0;

err_ida:
	ida_free(&fdrec_ida, fd->id);
err_chan:
	if (fd->chans[FD_TX])
		dma_release_channel(fd->chans[FD_TX]);
	dma_release_channel(fd->chans[FD_RX]);
	return ret;
}

static void fdrec_remove(struct platform_device *pdev)
{
	struct fdrec_dev *fd = platform_get_drvdata(pdev);

	misc_deregister(&fd->misc);	/* no new opens; an open file keeps fd->misc
					 * alive only until it is closed */
	mutex_lock(&fd->lock);
	fdrec_stop_any(fd);
	fdrec_unregister(fd);
	fd_soft_reset(fd);
	mutex_unlock(&fd->lock);
	if (fd->chans[FD_TX])
		dma_release_channel(fd->chans[FD_TX]);
	if (fd->chans[FD_RX])
		dma_release_channel(fd->chans[FD_RX]);
	ida_free(&fdrec_ida, fd->id);
}

static const struct of_device_id fdrec_of_match[] = {
	{ .compatible = "opsero,fdrec" },
	{ }
};
MODULE_DEVICE_TABLE(of, fdrec_of_match);

static struct platform_driver fdrec_driver = {
	.driver = {
		.name = DRV_NAME,
		.of_match_table = fdrec_of_match,
	},
	.probe = fdrec_probe,
	.remove = fdrec_remove,
};
module_platform_driver(fdrec_driver);

MODULE_AUTHOR("Opsero Electronic Design Inc.");
MODULE_DESCRIPTION("FPGA Drive Recorder: zero-copy fabric-to-NVMe recording");
MODULE_LICENSE("Dual MIT/GPL");
MODULE_VERSION(FDREC_DRV_VERSION);
