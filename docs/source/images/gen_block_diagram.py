#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the diagrams for the FPGA Drive Recorder docs.

    fdrec-block-zynqmp.png     the whole design on a Zynq UltraScale+ target
                               (Vivado/src/bd/bd_zynqmp.tcl, xdma root ports)
    fdrec-block-versal.png     the whole design on a Versal target
                               (bd_versal.tcl as built for vck190_fmcp1, qdma root ports)
    fdrec-custom-source.png    the user_data_source insertion point
    fdrec-custom-sink.png      the user_data_sink insertion point
    fdrec-dataflow.png         the software side: hugepage ring, driver syncs,
                               io_uring O_DIRECT writes, NVMe DMA
    fdrec-record-path.png      the recording path through fdrec_core in detail
    fdrec-play-path.png        the playback path through fdrec_core in detail

Conventions shared with the other Opsero reference-design diagrams
(fpga-drive-aximm-pcie/docs/source/images/gen_block_diagram.py): same palette,
left-to-right layout with the processor and its DDR on the left and the
FMC card on the right; blue arrows = processor access (control registers,
PCIe BAR / ECAM), green arrows = DMA traffic into or out of DDR memory.

The PNGs are written next to this script (i.e. into docs/source/images/).

Usage (from anywhere):
    python3 docs/source/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyArrowPatch, Circle
from matplotlib.lines import Line2D

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # soft logic (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # hard blocks: PCIe, GT (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_SLOT_FILL    = "#FFFFFF"                                # M.2 slots (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clocking (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # notes / control caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # DMA arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # host access + link arrows
C_REFCLK_LINE  = "#C8823C"                                # clocks (orange)
C_THIN         = "#8C8C8C"                                # sideband / interrupts
C_MUTED        = "#6E6E6E"
TXT = "#1A1A1A"
# recorder additions (same family of tints)
C_USER_FILL    = "#E2F0E4"; C_USER_EDGE    = "#7FB08A"   # user insertion points
C_DATA_LINE    = "#6E8F1E"                                # zero-copy data path (dark green)
C_CTRL_LINE    = "#4A7DB5"                                # control path (dark blue)
C_WARN         = "#A0522D"                                # contract annotations


def box(ax, x, y, w, h, fc, ec, label, fs=10, lw=1.2, weight="normal",
        txtcolor=None, ls="-", z=2):
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, ls=ls,
                               zorder=z))
    if label:
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fs, color=txtcolor or TXT, weight=weight,
                zorder=z + 1, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.4, ls="-", z=2):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw, ls=ls, z=z)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=z + 1,
            linespacing=1.15)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=z + 1, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=False, bh=1.1, hh=2.0,
           hl=1.6, fs=7.4, lw=1.0, lab_dy=2.9, lab_color=None, z=2):
    """Horizontal block arrow from x0 to x1 (head at x1; both ends if double)."""
    if double:
        lo, hi = min(x0, x1), max(x0, x1)
        pts = [(lo, yc), (lo + hl, yc + hh), (lo + hl, yc + bh),
               (hi - hl, yc + bh), (hi - hl, yc + hh), (hi, yc),
               (hi - hl, yc - hh), (hi - hl, yc - bh),
               (lo + hl, yc - bh), (lo + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0
        neck = x1 - s * hl
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=lab_color or TXT, zorder=z + 1, linespacing=1.15)


def vblock(ax, xc, y0, y1, fc, ec, bw=1.0, hw=1.9, hl=1.5, lw=1.0, double=True,
           z=2):
    """Vertical block arrow from y0 to y1 (head at y1; both ends if double)."""
    if double:
        lo, hi = min(y0, y1), max(y0, y1)
        pts = [(xc, lo), (xc + hw, lo + hl), (xc + bw, lo + hl),
               (xc + bw, hi - hl), (xc + hw, hi - hl), (xc, hi),
               (xc - hw, hi - hl), (xc - bw, hi - hl),
               (xc - bw, lo + hl), (xc - hw, lo + hl)]
    else:
        s = 1.0 if y1 >= y0 else -1.0
        neck = y1 - s * hl
        pts = [(xc + bw, y0), (xc + bw, neck), (xc + hw, neck), (xc, y1),
               (xc - hw, neck), (xc - bw, neck), (xc - bw, y0)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))


def route(ax, pts, color, lw=1.3, ls="-", z=3, ms=9):
    """Thin elbow arrow through the points in pts (head at the last point)."""
    xs, ys = zip(*pts[:-1])
    ax.add_line(Line2D(list(xs) + [pts[-2][0]], list(ys) + [pts[-2][1]],
                       color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt", solid_joinstyle="miter"))
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=ms, lw=lw, color=color,
                                 zorder=z, shrinkA=0, shrinkB=0))


def line(ax, pts, color, lw=1.1, ls="-", z=3):
    xs, ys = zip(*pts)
    ax.add_line(Line2D(xs, ys, color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt"))


def clk_tag(ax, x, y, text, fs=7.2, ha="center"):
    """An orange clock-domain label."""
    ax.text(x, y, text, ha=ha, va="center", fontsize=fs, color=C_REFCLK_LINE,
            weight="bold", zorder=6, linespacing=1.15)


def marker(ax, x, y, n, color=C_CTRL_LINE, r=1.25, fs=7.5):
    """A numbered circle (step marker)."""
    ax.add_patch(Circle((x, y), r, fc="white", ec=color, lw=1.3, zorder=7))
    ax.text(x, y, str(n), ha="center", va="center", fontsize=fs, weight="bold",
            color=color, zorder=8)


def new_fig(w=17.0, h=10.6, xmax=170, ymax=106):
    fig, ax = plt.subplots(figsize=(w, h), dpi=120)
    ax.set_xlim(0, xmax)
    ax.set_ylim(0, ymax)
    ax.axis("off")
    return fig, ax


def save(fig, name):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    plt.close(fig)
    print("wrote", out)


def legend(ax, x, y):
    """Arrow-colour key used by the block diagrams."""
    harrow(ax, x, x + 6.0, y, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5,
           hl=1.2)
    ax.text(x + 7.5, y, "processor access (control registers, PCIe BAR / ECAM)",
            ha="left", va="center", fontsize=7.0, color=TXT)
    harrow(ax, x, x + 6.0, y - 3.6, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.8,
           hh=1.5, hl=1.2)
    ax.text(x + 7.5, y - 3.6, "DMA into / out of DDR (recorded data, NVMe)",
            ha="left", va="center", fontsize=7.0, color=TXT)
    harrow(ax, x, x + 6.0, y - 7.2, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5,
           hl=1.2)
    ax.text(x + 7.5, y - 7.2, "AXI4-Stream, 128 bit",
            ha="left", va="center", fontsize=7.0, color=TXT)


# -----------------------------------------------------------------------------
# 1. Whole design, per device family.
#
# Every string of the zynqmp entry comes from Vivado/src/bd/bd_zynqmp.tcl and the
# address map of the exported XSA (see docs/source/architecture.md); the versal
# entry likewise from the vck190_fmcp1 build.
# -----------------------------------------------------------------------------
FAMILIES = {
    "zynqmp": dict(
        out="fdrec-block-zynqmp.png",
        title="FPGA Drive Recorder  —  Zynq UltraScale+ designs",
        proc_title="Zynq\nUltraScale+\nPS",
        proc_body="Arm Cortex-A53\n\nLinux (Yocto / EDF)\nfdrec driver\nfdrec / fdplay\n\n"
                  "pl_clk0  100 MHz\npl_clk1  250 MHz\n(dp_clk)\npl_clk2  200 MHz\n(src_clk)",
        ddr="PS DDR4",
        ddr_body="ring of 2 MB-hugepage\nbuffers (default 32 x 8 MB)",
        ctl_lbl="M_AXI_HPM0_FPD → periph_intercon_0  (AXI-Lite)",
        smc="axi_smc_dma\nSmartConnect\n\nto PS port\nS_AXI_HP2_FPD\n128 bit,\nnon-coherent",
        dma_title="axi_dma_0",
        dma_body="AXI DMA, scatter-gather\n\nS2MM  record\nMM2S  playback\nSG  descriptor fetch\n\n"
                 "128-bit stream + MM\nburst 256, 26-bit length\n64-bit addresses",
        dp_clk="dp_clk  250 MHz",
        src_clk="src_clk  200 MHz",
        host_lbl=("M_AXI_HPM0_FPD", "M_AXI_HPM1_FPD"),
        nvme_lbl=("S_AXI_HP0_FPD", "S_AXI_HP1_FPD"),
        rp_title=("xdma_0", "xdma_1"),
        rp_body=("DMA/Bridge Subsystem for PCIe\nAXI Bridge, Root Port, Gen3",
                 "DMA/Bridge Subsystem for PCIe\nAXI Bridge, Root Port, Gen3"),
        pcie_clk="axi_aclk  250 MHz (PCIe)",
        gt_body="GTH / GTY\nx4",
        link=("x4 @ 8 GT/s\nFMC DP0–3", "x4 @ 8 GT/s\nFMC DP4–7"),
        irq="s2mm_introut, mm2s_introut → pl_ps_irq0[6], [7];  xdma interrupt_out + MSI → pl_ps_irq0[5:0]",
        notes="The PCIe part (root ports, reference clocks, PERST#, SSD2 power) is the design of fpga-drive-aximm-pcie.\n"
              "The NVMe controller reads the recorded data from the same DDR buffers that the AXI DMA wrote (zero-copy):\n"
              "fabric → S2MM → DDR → NVMe write.   Playback runs the other way: NVMe read → DDR → MM2S → fabric.",
    ),
    "versal": dict(
        out="fdrec-block-versal.png",
        title="FPGA Drive Recorder  —  Versal designs  (vck190_fmcp1)",
        proc_title="Versal\nCIPS",
        proc_body="versal_cips_0\nArm Cortex-A72\n\nLinux (Yocto / EDF)\nfdrec driver\nfdrec / fdplay\n\n"
                  "pl0_ref_clk 250 MHz\npl1_ref_clk 250 MHz\n(dp_clk)\npl2_ref_clk 200 MHz\n(src_clk)",
        ddr="DDR4 via NoC",
        ddr_body="axi_noc_0: hugepage ring\nvia S09_AXI → MC_2",
        ctl_lbl="M_AXI_FPD → smc_m_axi_fpd  (AXI-Lite: fdrec 0x4_2001_0000, DMA 0x4_2000_0000)",
        smc="axi_smc_dma\nSmartConnect\n\nto NoC port\nS09_AXI\n(MC_2),\nnon-coherent",
        dma_title="axi_dma_0",
        dma_body="AXI DMA, scatter-gather\n\nS2MM  record\nMM2S  playback\nSG  descriptor fetch\n\n"
                 "128-bit stream + MM\nburst 256, 26-bit length\n64-bit addresses",
        dp_clk="dp_clk  250 MHz (pl1_ref_clk)",
        src_clk="src_clk  200 MHz (pl2_ref_clk)",
        host_lbl=("M_AXI_FPD (BAR)\nM_AXI_LPD (CSR)", "M_AXI_FPD (BAR)\nM_AXI_LPD (CSR)"),
        nvme_lbl=("NoC S08_AXI", "NoC S08_AXI"),
        rp_title=("qdma_0  +  qdma_support_0", "qdma_1  +  qdma_support_1"),
        rp_body=("QDMA Subsystem for PCIe\nAXI Bridge, Root Port, Gen4",
                 "QDMA Subsystem for PCIe\nAXI Bridge, Root Port, Gen4"),
        pcie_clk="QDMA AXI clock (PCIe)",
        gt_body="GTY\nx4",
        link=("x4 @ 16 GT/s\nFMCP1 DP0–3", "x4 @ 16 GT/s\nFMCP1 DP4–7"),
        irq="QDMA irq → pl_ps_irq0–5 (SPI 84–89);  s2mm_introut → pl_ps_irq6 (SPI 90);  mm2s_introut → pl_ps_irq7 (SPI 91)",
        notes="Same user_data_source / fdrec_core / user_data_sink hierarchies and AXI DMA as the Zynq UltraScale+ designs.\n"
              "SSD NVMe DMA: qdma_N/M_AXI_BRIDGE → smc_m_axi_bridge → axi_noc_0 S08_AXI (MC_1) → DDR4.  QDMA control: M_AXI_LPD → smc_m_axi_lpd.\n"
              "The PCIe part (qdma_support = PL PCIe block + GTY quad, VADJ, PERST#) is the Versal design of fpga-drive-aximm-pcie.",
    ),
}


def draw_block(fam):
    s = FAMILIES[fam]
    fig, ax = new_fig()

    # ---- processor column -----------------------------------------------------
    ps_x0, ps_w = 2.0, 19.0
    ps_r = ps_x0 + ps_w
    titled_box(ax, ps_x0, 86.0, ps_w, 14.0, C_PS_FILL, C_PS_EDGE, s["ddr"],
               s["ddr_body"], title_fs=9.6, body_fs=7.0, title_dy=2.6, lw=1.3)
    vblock(ax, ps_x0 + ps_w / 2, 82.0, 86.0, C_AXARR_FILL, C_AXARR_EDGE,
           bw=0.9, hw=1.7, hl=1.2)
    box(ax, ps_x0, 14.0, ps_w, 68.0, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    ax.text(ps_x0 + ps_w / 2, 75.5, s["proc_title"], ha="center", va="center",
            fontsize=11.0, weight="bold", color=TXT, linespacing=1.2)
    ax.text(ps_x0 + ps_w / 2, 47.0, s["proc_body"], ha="center", va="center",
            fontsize=7.4, color=TXT, linespacing=1.35)

    # ---- fabric container -----------------------------------------------------
    fab_x0, fab_x1 = 25.0, 131.0
    ax.add_patch(plt.Rectangle((fab_x0, 12.0), fab_x1 - fab_x0, 86.0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 99.0, "Programmable logic and hard PCIe / GT blocks",
            ha="center", va="bottom", fontsize=11.5, weight="bold", color=TXT)

    # ---- upper half: recorder datapath -----------------------------------------
    smc_x, smc_w = 30.0, 11.0
    dma_x, dma_w = 46.0, 18.0
    core_x, core_w = 70.0, 33.0
    usr_x, usr_w = 109.0, 19.0
    top_y0, top_y1 = 54.0, 90.0
    rec_y, ply_y = 81.0, 68.0             # stream rows: record (upper), playback

    titled_box(ax, smc_x, top_y0 + 2.0, smc_w, top_y1 - top_y0 - 8.0, C_MAC_FILL,
               C_MAC_EDGE, "", s["smc"], body_fs=6.4)
    titled_box(ax, dma_x, top_y0 + 2.0, dma_w, top_y1 - top_y0 - 8.0, C_GT_FILL,
               C_GT_EDGE, s["dma_title"], s["dma_body"], title_fs=9.4,
               body_fs=6.9, title_dy=2.6, lw=1.3)

    # fdrec_core hierarchy with its blocks
    box(ax, core_x, top_y0, core_w, top_y1 - top_y0, "#FAFAFD", C_MAC_EDGE, "",
        lw=1.3)
    ax.text(core_x + core_w / 2, top_y1 - 2.2, "fdrec_core", ha="center",
            va="center", fontsize=9.6, weight="bold", color=TXT)
    cdc_x = core_x + 21.0                   # clock-domain boundary inside the core
    titled_box(ax, core_x + 1.0, rec_y - 4.5, 16.0, 9.0, C_MAC_FILL, C_MAC_EDGE,
               "packetizer", "TLAST every\nPKT_LEN beats",
               title_fs=7.8, body_fs=6.4, title_dy=1.9, z=3)
    titled_box(ax, cdc_x - 2.0, rec_y - 4.5, 13.0, 9.0, C_MAC_FILL, C_MAC_EDGE,
               "ingest FIFO", "async, 64 KB\nfull → drop\n+ count",
               title_fs=7.8, body_fs=6.2, title_dy=1.9, z=3)
    titled_box(ax, core_x + 1.0, ply_y - 4.5, 31.0, 9.0, C_MAC_FILL, C_MAC_EDGE,
               "egress FIFO", "async, 64 KB, lossless:\nbackpressure to the DMA",
               title_fs=7.8, body_fs=6.2, title_dy=1.9, z=3)
    box(ax, core_x + 1.0, top_y0 + 1.5, 31.0, 5.5, C_CTRL_FILL, C_CTRL_EDGE,
        "AXI-Lite register block (fdrec_regs.h)", fs=6.6, z=3)
    # internal stream arrow ingest -> packetizer
    harrow(ax, cdc_x - 2.0, core_x + 17.0, rec_y, "", C_USER_FILL, C_USER_EDGE,
           bh=0.6, hh=1.2, hl=0.8, z=4)

    # user hierarchies
    titled_box(ax, usr_x, rec_y - 6.0, usr_w, 12.0, C_USER_FILL, C_USER_EDGE,
               "user_data_source", "default: fdrec_tpg\n(test pattern, rate\nregister; models an ADC)",
               title_fs=8.2, body_fs=6.6, title_dy=2.2, lw=1.3)
    titled_box(ax, usr_x, ply_y - 6.0, usr_w, 12.0, C_USER_FILL, C_USER_EDGE,
               "user_data_sink", "default: fdrec_check\n(pattern checker,\nTREADY rate throttle)",
               title_fs=8.2, body_fs=6.6, title_dy=2.2, lw=1.3)

    # streams: source -> core -> DMA (record), DMA -> core -> sink (playback)
    harrow(ax, usr_x, core_x + core_w, rec_y, "", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.3)
    harrow(ax, core_x, dma_x + dma_w, rec_y, "S2MM\n+ TLAST", C_USER_FILL,
           C_USER_EDGE, bh=1.0, hh=1.9, hl=1.3, fs=6.3, lab_dy=3.9)
    harrow(ax, dma_x + dma_w, core_x, ply_y, "MM2S\n+ TLAST", C_USER_FILL,
           C_USER_EDGE, bh=1.0, hh=1.9, hl=1.3, fs=6.3, lab_dy=3.9)
    harrow(ax, core_x + core_w, usr_x, ply_y, "", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.3)
    ax.text((core_x + core_w + usr_x) / 2, rec_y + 3.6, "TREADY\nignored",
            ha="center", va="center", fontsize=5.9, color=C_WARN)
    ax.text((core_x + core_w + usr_x) / 2, ply_y + 3.6, "TREADY =\nrate",
            ha="center", va="center", fontsize=5.9, color=C_WARN)
    # DMA <-> SmartConnect <-> PS (green: DMA to DDR)
    harrow(ax, dma_x, smc_x + smc_w, rec_y, "", C_AXARR_FILL, C_AXARR_EDGE,
           bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, smc_x + smc_w, dma_x, ply_y, "", C_AXARR_FILL, C_AXARR_EDGE,
           bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, smc_x, ps_r, rec_y, "write", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=6.0, lab_dy=3.2)
    harrow(ax, ps_r, smc_x, ply_y, "read", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=6.0, lab_dy=-3.2)

    # clock domains (orange): dashed boundary through fdrec_core
    cdc_lx = cdc_x + 4.5
    line(ax, [(cdc_lx, top_y0 + 7.5), (cdc_lx, top_y1 - 4.0)],
         C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)), z=2.5)
    clk_tag(ax, (smc_x + cdc_lx) / 2 + 9.0, top_y1 + 2.8, s["dp_clk"])
    clk_tag(ax, (cdc_lx + usr_x + usr_w) / 2, top_y1 + 2.8, s["src_clk"])
    line(ax, [(smc_x, top_y1 + 1.0), (cdc_lx, top_y1 + 1.0)], C_REFCLK_LINE,
         lw=1.0)
    line(ax, [(cdc_lx, top_y1 + 1.0), (usr_x + usr_w, top_y1 + 1.0)],
         C_REFCLK_LINE, lw=1.0, ls=(0, (3, 2)))
    line(ax, [(cdc_lx, top_y1 + 1.0), (cdc_lx, top_y1 - 4.0)], C_REFCLK_LINE,
         lw=1.0, ls=(0, (3, 2)))

    # AXI-Lite control (blue): PS -> register block and DMA lite
    ctl_y = top_y0 - 3.0
    harrow(ax, ps_r, smc_x - 1.0, ctl_y, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1)
    route(ax, [(smc_x - 1.0, ctl_y), (core_x + 16.0, ctl_y), (core_x + 16.0, top_y0 + 1.5)],
          C_CTRL_LINE, lw=1.2)
    route(ax, [(dma_x + dma_w / 2, ctl_y), (dma_x + dma_w / 2, top_y0 + 2.0)],
          C_CTRL_LINE, lw=1.2)
    ax.text(smc_x + 1.0, ctl_y + 1.4, s["ctl_lbl"], ha="left",
            va="center", fontsize=6.3, color=C_CTRL_LINE)
    # register block -> user hierarchies (tpg_* / chk_* control pins)
    route(ax, [(core_x + 32.0, top_y0 + 4.25), (usr_x + 4.0, top_y0 + 4.25),
               (usr_x + 4.0, ply_y - 6.0)], C_THIN, lw=1.0)
    ax.text(usr_x + 5.5, top_y0 + 2.6, "tpg_*, chk_* control / status", ha="left",
            va="center", fontsize=5.8, color=C_MUTED)

    # ---- lower half: PCIe root ports (from the base design) --------------------
    ic_x, ic_w = 32.0, 12.0
    rp_x, rp_w = 52.0, 31.0
    gt_x, gt_w = 92.0, 10.0
    rows = [(33.0, 13.0), (16.0, 13.0)]      # (y0, height)
    for i, (y0, rh) in enumerate(rows):
        yc = y0 + rh / 2
        titled_box(ax, ic_x, y0 + 0.5, ic_w, rh - 1.0, C_MAC_FILL, C_MAC_EDGE,
                   "", "AXI\ninterconnect", body_fs=6.6)
        harrow(ax, ps_r, ic_x, yc + 2.6, s["host_lbl"][i], C_LINKARR_FILL,
               C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=5.8, lab_dy=2.4)
        harrow(ax, ic_x, ps_r, yc - 2.6, s["nvme_lbl"][i], C_AXARR_FILL,
               C_AXARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=5.8, lab_dy=-2.4)
        harrow(ax, ic_x + ic_w, rp_x, yc + 2.6, "BAR / ECAM", C_LINKARR_FILL,
               C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=5.8, lab_dy=2.4)
        harrow(ax, rp_x, ic_x + ic_w, yc - 2.6, "NVMe DMA", C_AXARR_FILL,
               C_AXARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=5.8, lab_dy=-2.4)
        titled_box(ax, rp_x, y0, rp_w, rh, C_GT_FILL, C_GT_EDGE, s["rp_title"][i],
                   s["rp_body"][i], title_fs=8.6, body_fs=6.6, title_dy=2.2, lw=1.3)
        titled_box(ax, gt_x, y0 + 2.0, gt_w, rh - 4.0, C_GT_FILL, C_GT_EDGE, "GT",
                   s["gt_body"], title_fs=7.8, body_fs=6.2, title_dy=1.8)
        harrow(ax, rp_x + rp_w, gt_x, yc, "", C_GT_FILL, C_GT_EDGE, double=True,
               bh=0.9, hh=1.7, hl=1.1)
    clk_tag(ax, rp_x + rp_w / 2, 47.6, s["pcie_clk"], fs=6.8)

    # ---- external: FMC with the M.2 slots --------------------------------------
    fmc_x0, fmc_x1 = 136.0, 168.0
    ax.add_patch(plt.Rectangle((fmc_x0, 12.0), fmc_x1 - fmc_x0, 41.0,
                               fc=C_FMC_FILL, ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((fmc_x0 + fmc_x1) / 2, 50.0,
            "FPGA Drive FMC Gen4 (OP063)\nor M.2 M-key Stack FMC (OP073)",
            ha="center", va="center", fontsize=7.4, weight="bold", color=TXT,
            linespacing=1.2)
    for i, (y0, rh) in enumerate(rows):
        yc = y0 + rh / 2
        titled_box(ax, fmc_x0 + 9.0, y0 + 0.5, 21.0, rh - 1.0, C_SLOT_FILL,
                   C_FMC_EDGE, "M.2 slot  SSD%d" % (i + 1), "NVMe SSD",
                   title_fs=7.8, body_fs=6.6, title_dy=2.0)
        harrow(ax, gt_x + gt_w, fmc_x0 + 9.0, yc, "", C_LINKARR_FILL,
               C_LINKARR_EDGE, double=True, bh=1.0, hh=1.9, hl=1.2)
        ax.text((gt_x + gt_w + fmc_x0 + 9.0) / 2, yc + 3.6, s["link"][i],
                ha="center", va="center", fontsize=6.0, color=TXT, linespacing=1.15)
    ax.text((fmc_x0 + fmc_x1) / 2, 63.0,
            "External to the FPGA\n\n(your own ADC / DAC\nconnects to the user\nhierarchies through\nany free FPGA I/O)",
            ha="center", va="center", fontsize=7.2, color=C_MUTED, linespacing=1.25)

    # zero-copy annotation on the DDR box
    ax.text(ps_x0 + ps_w + 1.0, 93.0,
            "zero-copy: the AXI DMA fills a buffer,\nthe NVMe controller reads the same buffer",
            ha="left", va="center", fontsize=7.0, color=C_DATA_LINE, weight="bold",
            linespacing=1.2)

    legend(ax, 136.0, 96.0)

    # ---- interrupts and notes strip --------------------------------------------
    titled_box(ax, 2.0, 0.5, 166.0, 10.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Interrupts: " + s["irq"], s["notes"], title_fs=7.6, body_fs=6.8,
               title_dy=1.8)
    ax.text(85.0, 104.5, s["title"], ha="center", va="center", fontsize=13.0,
            weight="bold", color=TXT)
    save(fig, s["out"])


# -----------------------------------------------------------------------------
# 2. / 3. Insertion points. Pins and behaviour from bd_zynqmp.tcl and the
# headers of Vivado/src/hdl/fdrec_core.v, fdrec_tpg.v and fdrec_check.v.
# -----------------------------------------------------------------------------
def pin(ax, x, y, name, into, side="right", fs=6.6, color=TXT, desc=None,
        desc_color=C_MUTED, desc_dy=0.0):
    """A pin stub on a hierarchy boundary at x.

    side  = which boundary of the hierarchy the pin is on ("right" / "left");
            the pin name is written inside the hierarchy, desc outside.
    into  = True for a hierarchy input (the arrow points into the hierarchy).
    """
    inside = -1.0 if side == "right" else 1.0
    p_in, p_out = (x + inside * 3.0, y), (x - inside * 3.0, y)
    route(ax, [p_out, p_in] if into else [p_in, p_out], color, lw=1.1, ms=7)
    ax.text(x + inside * 3.6, y, name, ha="right" if side == "right" else "left",
            va="center", fontsize=fs, color=color, zorder=6)
    if desc:
        ax.text(x - inside * 4.0, y + desc_dy, desc,
                ha="left" if side == "right" else "right", va="center",
                fontsize=6.0, color=desc_color, zorder=6, linespacing=1.15)


def draw_custom_source():
    fig, ax = new_fig(17.0, 9.8, 170, 98)

    # external front end and (optional) clock
    ax.text(12.0, 77.0, "External to the FPGA", ha="center", va="bottom",
            fontsize=9.0, weight="bold", color=TXT)
    titled_box(ax, 2.0, 50.0, 20.0, 24.0, C_FMC_FILL, C_FMC_EDGE, "Your ADC /\nsensor",
               "on an FMC card or\nany FPGA I/O\n\nsample data\n+ data clock",
               title_fs=8.6, body_fs=6.8, title_dy=3.4)
    box(ax, 2.0, 22.0, 20.0, 12.0, C_CLK_FILL, C_CLK_EDGE,
        "your clock (optional)\nADC data clock or a\nclocking wizard; replaces\npl_clk2 at the top level",
        fs=6.2)
    route(ax, [(12.0, 50.0), (12.0, 34.0)], C_REFCLK_LINE, lw=1.0, ls=(0, (3, 2)))

    # hierarchy boundary
    hx0, hx1, hy0, hy1 = 30.0, 100.0, 14.0, 88.0
    box(ax, hx0, hy0, hx1 - hx0, hy1 - hy0, "#F4FAF5", C_USER_EDGE, "", lw=2.0,
        ls=(0, (6, 3)))
    ax.text((hx0 + hx1) / 2, hy1 + 1.5, "user_data_source  (block-design hierarchy)",
            ha="center", va="bottom", fontsize=10.5, weight="bold", color=TXT)

    # default content
    titled_box(ax, 34.0, 66.0, 40.0, 17.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Default content: fdrec_tpg",
               "test pattern: TDATA[63:0] = seq, TDATA[127:64] = ~seq\n"
               "rate = TPG_RATE_INC (Q1.31 beats per src_clk)\n"
               "uses tpg_enable / tpg_seq_rst / tpg_rate_inc,\ndrives tpg_seq_next",
               title_fs=8.0, body_fs=6.3, title_dy=2.2, ls=(0, (3, 2)))
    ax.text(54.0, 63.5, "remove it, keep the hierarchy pins", ha="center",
            va="center", fontsize=7.2, color=C_WARN, weight="bold")

    # replacement content
    titled_box(ax, 34.0, 32.0, 19.0, 24.0, C_USER_FILL, C_USER_EDGE,
               "Your logic", "ADC / sensor\ninterface,\nprocessing\n\nW-bit samples",
               title_fs=8.2, body_fs=6.6, title_dy=2.4)
    titled_box(ax, 57.0, 32.0, 20.0, 24.0, C_USER_FILL, C_USER_EDGE,
               "Packer\n(optional)", "for W < 128:\naxis_dwidth_\nconverter or a\nshift register\n\n"
                                    "first sample in\nTDATA[W-1:0]",
               title_fs=8.0, body_fs=6.3, title_dy=3.4, ls=(0, (3, 2)))
    harrow(ax, 53.0, 57.0, 45.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 22.0, 34.0, 45.0, "samples", C_FMC_FILL, C_FMC_EDGE, bh=1.0, hh=1.9,
           hl=1.2, fs=6.4, lab_dy=3.4)
    harrow(ax, 77.0, hx1 - 3.0, 45.0, "M_AXIS", C_USER_FILL, C_USER_EDGE, bh=0.9,
           hh=1.7, hl=1.1, fs=6.6, lab_dy=2.8)

    # pins on the right boundary (M_AXIS drawn as a block arrow through it)
    ax.text(hx1 + 4.0, 49.5, "TDATA[127:0], TVALID\n(one TVALID cycle per beat)",
            ha="left", va="center", fontsize=6.0, color=C_MUTED)
    pin(ax, hx1, 40.0, "TREADY", True, color=C_WARN,
        desc="always 1 — ignore it, never wait for it", desc_color=C_WARN)
    pin(ax, hx1, 26.0, "src_clk", True, color=C_REFCLK_LINE,
        desc="pl_clk2 (200 MHz) by default,\nor your clock", desc_dy=3.2)
    pin(ax, hx1, 19.0, "src_resetn", True, desc="from rst_src_clk (same clock)")
    pin(ax, hx1, 82.0, "tpg_enable", True, fs=6.4, color=C_MUTED,
        desc="optional: use as run / stop")
    pin(ax, hx1, 78.0, "tpg_seq_rst", True, fs=6.4, color=C_MUTED,
        desc="optional: leave unconnected inside")
    pin(ax, hx1, 74.0, "tpg_rate_inc[31:0]", True, fs=6.4, color=C_MUTED,
        desc="optional: leave unconnected inside")
    pin(ax, hx1, 70.0, "tpg_seq_next[63:0]", False, fs=6.4, color=C_MUTED,
        desc="tie to 0 if you have no counter")
    # your clock -> src_clk (below the hierarchy, in at the right)
    route(ax, [(22.0, 26.0), (26.0, 26.0), (26.0, 11.8), (124.0, 11.8), (124.0, 26.0),
               (hx1 + 3.0, 26.0)], C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)))

    # fdrec_core
    cx0, cx1 = 128.0, 166.0
    box(ax, cx0, 14.0, cx1 - cx0, 74.0, "#FAFAFD", C_MAC_EDGE, "", lw=1.3)
    ax.text((cx0 + cx1) / 2, 85.0, "fdrec_core (unchanged)", ha="center",
            va="center", fontsize=9.6, weight="bold", color=TXT)
    titled_box(ax, cx0 + 2.0, 35.0, cx1 - cx0 - 4.0, 22.0, C_MAC_FILL, C_MAC_EDGE,
               "ingest: async FIFO",
               "src_clk → dp_clk (250 MHz)\n64 KB (FIFO_DEPTH 4096 beats)\n\n"
               "TREADY held at 1\nFIFO full: the beat is dropped\nand counted (ING_DROP_COUNT)",
               title_fs=8.2, body_fs=6.5, title_dy=2.4)
    titled_box(ax, cx0 + 2.0, 61.0, cx1 - cx0 - 4.0, 18.0, C_CTRL_FILL, C_CTRL_EDGE,
               "register block", "drives tpg_enable, tpg_seq_rst,\ntpg_rate_inc\n(TPG_CTRL, TPG_RATE_INC);\n"
                                 "reads tpg_seq_next\n(TPG_SEQ_NEXT)",
               title_fs=7.8, body_fs=6.2, title_dy=2.0)
    titled_box(ax, cx0 + 2.0, 17.0, cx1 - cx0 - 4.0, 13.0, C_MAC_FILL, C_MAC_EDGE,
               "packetizer → AXI DMA S2MM", "adds TLAST (buffer boundary)\ndownstream of the drop point",
               title_fs=7.8, body_fs=6.3, title_dy=2.0)
    vblock(ax, (cx0 + cx1) / 2, 35.0, 30.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7,
           hl=1.1, double=False)
    harrow(ax, hx1 + 3.0, cx0 + 2.0, 45.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9,
           hh=1.7, hl=1.1)

    titled_box(ax, 2.0, 0.0, 166.0, 10.6, "#FBF3EC", C_CLK_EDGE,
               "No-backpressure contract (the source models an ADC)",
               "The source is never stalled: TREADY is always 1.  If the ingest FIFO is full the beat is dropped and counted — "
               "data is never delayed or corrupted.\n"
               "A recording is valid only if its drop count is 0 (fdrec exits 2 otherwise).  No framing on the source side: "
               "put frame markers or timestamps inside TDATA.\n"
               "Bytes are recorded as they appear on TDATA, little-endian (TDATA[7:0] is the first byte of each 16-byte beat).",
               title_fs=8.2, body_fs=6.7, title_dy=2.0)
    ax.text(85.0, 96.0, "Replacing the test pattern generator with your own data source",
            ha="center", va="center", fontsize=12.5, weight="bold", color=TXT)
    save(fig, "fdrec-custom-source.png")


def draw_custom_sink():
    fig, ax = new_fig(17.0, 9.8, 170, 98)

    # fdrec_core on the left
    cx0, cx1 = 2.0, 40.0
    box(ax, cx0, 14.0, cx1 - cx0, 74.0, "#FAFAFD", C_MAC_EDGE, "", lw=1.3)
    ax.text((cx0 + cx1) / 2, 85.0, "fdrec_core (unchanged)", ha="center",
            va="center", fontsize=9.6, weight="bold", color=TXT)
    titled_box(ax, cx0 + 2.0, 17.0, cx1 - cx0 - 4.0, 13.0, C_GT_FILL, C_GT_EDGE,
               "AXI DMA MM2S", "one packet per buffer\n(TLAST on its last beat)",
               title_fs=7.8, body_fs=6.3, title_dy=2.0)
    titled_box(ax, cx0 + 2.0, 35.0, cx1 - cx0 - 4.0, 22.0, C_MAC_FILL, C_MAC_EDGE,
               "egress: async FIFO",
               "dp_clk (250 MHz) → src_clk\n64 KB (EGR_FIFO_DEPTH 4096)\n\n"
               "lossless: when full, the DMA\nwaits.  Bridges the DMA pause\n"
               "at each buffer boundary",
               title_fs=8.2, body_fs=6.5, title_dy=2.4)
    titled_box(ax, cx0 + 2.0, 61.0, cx1 - cx0 - 4.0, 18.0, C_CTRL_FILL, C_CTRL_EDGE,
               "register block", "drives chk_enable, chk_reset,\nchk_rate_inc (CHK_CTRL,\nCHK_RATE_INC); reads the\n"
                                 "chk_* counters (CHK_*);\nEGR_CTRL.FLUSH",
               title_fs=7.8, body_fs=6.2, title_dy=2.0)
    vblock(ax, (cx0 + cx1) / 2, 30.0, 35.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7,
           hl=1.1, double=False)

    # hierarchy boundary
    hx0, hx1, hy0, hy1 = 70.0, 142.0, 14.0, 88.0
    box(ax, hx0, hy0, hx1 - hx0, hy1 - hy0, "#F4FAF5", C_USER_EDGE, "", lw=2.0,
        ls=(0, (6, 3)))
    ax.text((hx0 + hx1) / 2, hy1 + 1.5, "user_data_sink  (block-design hierarchy)",
            ha="center", va="bottom", fontsize=10.5, weight="bold", color=TXT)

    # pins on the left boundary
    harrow(ax, cx1 - 2.0, hx0 + 3.0, 45.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9,
           hh=1.7, hl=1.1)
    ax.text(hx0 - 4.0, 49.0, "TDATA[127:0], TVALID, TLAST\n(TLAST = end of a DMA buffer)",
            ha="right", va="center", fontsize=6.0, color=C_MUTED, linespacing=1.15)
    ax.text(hx0 + 3.6, 48.0, "S_AXIS", ha="left", va="center", fontsize=6.6, color=TXT)
    pin(ax, hx0, 40.0, "TREADY", False, side="left", color=C_WARN,
        desc="your rate control\n(backpressure allowed)", desc_color=C_WARN)
    pin(ax, hx0, 26.0, "snk_clk", True, side="left", color=C_REFCLK_LINE,
        desc="= src_clk (200 MHz)")
    pin(ax, hx0, 19.0, "snk_resetn", True, side="left", desc="from rst_src_clk")
    pin(ax, hx0, 82.0, "chk_enable", True, side="left", fs=6.4, color=C_MUTED,
        desc="optional: run / stop")
    pin(ax, hx0, 78.0, "chk_reset", True, side="left", fs=6.4, color=C_MUTED,
        desc="optional")
    pin(ax, hx0, 74.0, "chk_rate_inc[31:0]", True, side="left", fs=6.4, color=C_MUTED,
        desc="optional")
    pin(ax, hx0, 70.0, "chk_* counters, 6 x 64 bit", False, side="left", fs=6.4,
        color=C_MUTED, desc="tie to 0 if unused")

    # default content
    titled_box(ax, 98.0, 64.0, 40.0, 19.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Default content: fdrec_check",
               "TREADY on the ticks of a Q1.31 rate throttle\n(CHK_RATE_INC; models a DAC)\n"
               "checks the TPG pattern and sequence;\ncounts errors, gaps, underflows",
               title_fs=8.0, body_fs=6.3, title_dy=2.2, ls=(0, (3, 2)))
    ax.text(118.0, 61.5, "remove it, keep the hierarchy pins", ha="center",
            va="center", fontsize=7.2, color=C_WARN, weight="bold")

    # replacement content
    titled_box(ax, 92.0, 30.0, 21.0, 26.0, C_USER_FILL, C_USER_EDGE,
               "Clock / width\n(optional)", "axis_data_fifo\n(independent\nclocks) for\nyour own clock\n\n"
                                            "axis_dwidth_\nconverter\n16 B → your width",
               title_fs=7.8, body_fs=6.2, title_dy=3.4, ls=(0, (3, 2)))
    titled_box(ax, 117.0, 30.0, 21.0, 26.0, C_USER_FILL, C_USER_EDGE,
               "Your logic", "DAC / transmitter\ninterface\n\nTREADY = your\nconsumption rate\n\n"
                            "on underflow:\nrepeat the last\nsample or output 0",
               title_fs=8.2, body_fs=6.2, title_dy=2.4)
    harrow(ax, hx0 + 3.0, 92.0, 45.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 113.0, 117.0, 45.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 138.0, 150.0, 45.0, "", C_FMC_FILL, C_FMC_EDGE, bh=1.0, hh=1.9, hl=1.2)
    box(ax, 117.0, 17.0, 21.0, 9.0, C_CLK_FILL, C_CLK_EDGE,
        "your clock (optional)\nDAC sample clock", fs=6.4)
    route(ax, [(117.0, 21.5), (102.5, 21.5), (102.5, 30.0)], C_REFCLK_LINE, lw=1.0,
          ls=(0, (3, 2)))
    route(ax, [(127.5, 26.0), (127.5, 30.0)], C_REFCLK_LINE, lw=1.0, ls=(0, (3, 2)))

    # external DAC
    ax.text(159.0, 59.0, "External to\nthe FPGA", ha="center", va="bottom",
            fontsize=9.0, weight="bold", color=TXT)
    titled_box(ax, 150.0, 34.0, 18.0, 22.0, C_FMC_FILL, C_FMC_EDGE, "Your DAC /\ntransmitter",
               "on an FMC card or\nany FPGA I/O", title_fs=8.4, body_fs=6.6, title_dy=3.4)

    titled_box(ax, 2.0, 0.0, 166.0, 10.6, "#FBF3EC", C_CLK_EDGE,
               "Stream contract (the sink sets the playback rate)",
               "Backpressure is allowed: deassert TREADY whenever you are not ready — nothing is lost, the egress FIFO fills and the DMA waits.\n"
               "Underflow: a fixed-rate sink that finds TVALID low after the first beat was starved (SSD / ring too slow for the rate); "
               "fdrec_check counts these ticks in CHK_UNDERFLOWS.\n"
               "Start the DMA first and enable the sink once the egress FIFO has primed; to stop with data in flight, EGR_CTRL.FLUSH lets the DMA finish.",
               title_fs=8.2, body_fs=6.7, title_dy=2.0)
    ax.text(85.0, 96.0, "Replacing the checker with your own data sink",
            ha="center", va="center", fontsize=12.5, weight="bold", color=TXT)
    save(fig, "fdrec-custom-sink.png")


# -----------------------------------------------------------------------------
# 4. Software data flow of a recording (sw/fdrec-driver/fdrec.c, sw/fdrec-apps/fdrec.c)
# -----------------------------------------------------------------------------
def draw_dataflow():
    fig, ax = new_fig(17.0, 10.2, 170, 102)

    lanes = [  # (y0, y1, label, fill, edge)
        (78.0, 94.0, "FPGA fabric", C_FAB_FILL, C_FAB_EDGE),
        (56.0, 76.0, "PS DDR", C_PS_FILL, C_PS_EDGE),
        (32.0, 54.0, "Linux kernel", "#EEF2F8", C_LINKARR_EDGE),
        (14.0, 30.0, "user space", "#F4FAF5", C_USER_EDGE),
    ]
    for y0, y1, lab, fc, ec in lanes:
        ax.add_patch(plt.Rectangle((2.0, y0), 140.0, y1 - y0, fc=fc, ec=ec,
                                   lw=1.0, zorder=0.5))
        ax.text(4.0, (y0 + y1) / 2, lab, ha="left", va="center", fontsize=9.0,
                weight="bold", color=TXT, rotation=90)

    # fabric: source -> fdrec_core -> AXI DMA S2MM
    box(ax, 10.0, 81.0, 22.0, 10.0, C_USER_FILL, C_USER_EDGE,
        "user_data_source\n(TPG or your ADC)", fs=7.2)
    box(ax, 38.0, 81.0, 22.0, 10.0, C_MAC_FILL, C_MAC_EDGE,
        "fdrec_core\ningest FIFO + packetizer", fs=7.2)
    box(ax, 66.0, 81.0, 20.0, 10.0, C_GT_FILL, C_GT_EDGE,
        "AXI DMA S2MM\n1 active + 1 pending", fs=7.2)
    harrow(ax, 32.0, 38.0, 86.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 60.0, 66.0, 86.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.1)

    # SSD on the right, outside the lanes
    titled_box(ax, 146.0, 50.0, 22.0, 30.0, C_FMC_FILL, C_FMC_EDGE, "NVMe SSD",
               "on the FMC card,\nbehind a PCIe\nroot port\n\nits controller DMAs\nthe buffer out\nof DDR",
               title_fs=8.6, body_fs=6.6, title_dy=2.6)

    # DDR: ring of buffers
    nbuf, bx0, bw, gap = 8, 14.0, 13.0, 2.0
    states = ["free\n(queued)", "DMA\nactive", "DMA\npending", "filled",
              "NVMe\nwriting", "NVMe\nwriting", "free\n(queued)", "free\n(queued)"]
    fills = [C_SLOT_FILL, C_AXARR_FILL, C_AXARR_FILL, "#FFF6D5", C_LINKARR_FILL,
             C_LINKARR_FILL, C_SLOT_FILL, C_SLOT_FILL]
    for k in range(nbuf):
        x = bx0 + k * (bw + gap)
        box(ax, x, 59.0, bw, 11.0, fills[k], C_PS_EDGE, "", lw=1.0)
        ax.text(x + bw / 2, 67.8, "buf %d" % k if k < nbuf - 1 else "buf N-1",
                ha="center", va="center", fontsize=6.8, weight="bold", color=TXT)
        ax.text(x + bw / 2, 62.8, states[k], ha="center", va="center", fontsize=6.0,
                color=TXT, linespacing=1.1)
    ax.text(90.0, 73.4, "ring of N buffers (default 32 x 8 MB), each 4 x 2 MB hugepages,\n"
                        "allocated by the app with mmap(MAP_HUGETLB)",
            ha="left", va="center", fontsize=6.8, color=TXT, linespacing=1.15)

    xb = lambda k: bx0 + k * (bw + gap) + bw / 2
    # DMA writes buf 1 (green, data)
    route(ax, [(76.0, 81.0), (76.0, 78.0), (xb(1), 78.0), (xb(1), 70.0)],
          C_DATA_LINE, lw=2.0)
    ax.text(48.0, 79.4, "S2MM writes the data (HP port, no CPU)", ha="center",
            va="center", fontsize=6.6, color=C_DATA_LINE, weight="bold")
    # NVMe reads buf 4/5 (green, data)
    route(ax, [(xb(4), 59.0), (xb(4), 57.2), (143.5, 57.2), (143.5, 65.0), (146.0, 65.0)],
          C_DATA_LINE, lw=2.0)
    ax.text(157.0, 88.0, "the NVMe controller\nreads the SAME buffer\n(PCIe DMA, no CPU copy)",
            ha="center", va="center", fontsize=6.8, color=C_DATA_LINE, weight="bold",
            linespacing=1.15)

    # kernel: fdrec driver + NVMe driver
    titled_box(ax, 10.0, 34.0, 62.0, 18.0, C_SLOT_FILL, C_LINKARR_EDGE,
               "fdrec driver  (/dev/fdrec0)",
               "REGISTER_BUFS: pin_user_pages_fast + dma_map_sgtable\n"
               "completion IRQ → next pending descriptor; buffer → filled list\n"
               "WAIT_FILLED: dma_sync_sgtable_for_cpu  (invalidate)   [sync 1]\n"
               "RELEASE: dma_sync_sgtable_for_device  (clean) → re-queue   [sync 2]",
               title_fs=8.2, body_fs=6.5, title_dy=2.4)
    titled_box(ax, 84.0, 34.0, 50.0, 18.0, C_SLOT_FILL, C_LINKARR_EDGE,
               "block layer + NVMe driver",
               "O_DIRECT: pins the user pages,\nmaps them DMA_TO_DEVICE,\n"
               "builds the NVMe write command\n(PRP list → buffer pages)",
               title_fs=8.2, body_fs=6.5, title_dy=2.4)
    # descriptor/IRQ (blue control lines)
    route(ax, [(82.0, 81.0), (82.0, 76.8), (73.0, 76.8), (73.0, 55.0), (62.0, 55.0),
               (62.0, 52.0)], C_CTRL_LINE, lw=1.1, ls=(0, (4, 2)))
    ax.text(72.0, 53.6, "IRQ per buffer", ha="right", va="center", fontsize=6.2,
            color=C_CTRL_LINE)
    route(ax, [(30.0, 52.0), (30.0, 55.8), (58.0, 55.8), (58.0, 77.5), (68.0, 77.5),
               (68.0, 81.0)], C_CTRL_LINE, lw=1.1)
    ax.text(31.0, 54.4, "SG descriptors", ha="left", va="center", fontsize=6.2,
            color=C_CTRL_LINE)
    route(ax, [(110.0, 52.0), (110.0, 54.5), (143.0, 54.5), (143.0, 50.0), (146.0, 50.0)],
          C_CTRL_LINE, lw=1.1)
    ax.text(127.0, 53.2, "NVMe command (doorbell)", ha="center", va="center",
            fontsize=6.2, color=C_CTRL_LINE)

    # user space: fdrec app loop
    titled_box(ax, 10.0, 16.0, 124.0, 12.0, C_SLOT_FILL, C_USER_EDGE,
               "fdrec  (one io_uring for both kinds of event)",
               "", title_fs=8.2, title_dy=2.2)
    steps = [(22.0, "1", "poll /dev/fdrec0\n→ WAIT_FILLED k"),
             (56.0, "2", "io_uring write of buf k\nO_DIRECT at the next file offset"),
             (92.0, "3", "write completes\n(up to --qd in flight)"),
             (120.0, "4", "RELEASE k")]
    for x, n, t in steps:
        marker(ax, x - 9.0, 20.5, n)
        ax.text(x - 7.0, 20.5, t, ha="left", va="center", fontsize=6.6, color=TXT,
                linespacing=1.15)
    # app <-> kernel arrows
    for x0, y0, y1 in ((22.0, 34.0, 28.0), (40.0, 28.0, 34.0)):
        route(ax, [(x0, y0), (x0, y1)], C_CTRL_LINE, lw=1.1)
    ax.text(23.0, 31.0, "ioctl", ha="left", va="center", fontsize=6.2, color=C_CTRL_LINE)
    route(ax, [(60.0, 28.0), (60.0, 31.0), (100.0, 31.0), (100.0, 34.0)], C_CTRL_LINE, lw=1.1)
    ax.text(80.0, 29.2, "submission (SQE)", ha="center", va="center", fontsize=6.2,
            color=C_CTRL_LINE)
    route(ax, [(124.0, 34.0), (124.0, 28.0)], C_CTRL_LINE, lw=1.1)
    ax.text(125.0, 31.0, "completion", ha="left", va="center", fontsize=6.2,
            color=C_CTRL_LINE)

    # side notes
    titled_box(ax, 146.0, 14.0, 22.0, 32.0, "#FBF3EC", C_CLK_EDGE,
               "What the CPU does", "descriptors, ioctls,\nio_uring entries,\ncache maintenance\n"
               "(sync 1 + sync 2)\n\nIt never reads,\nwrites or copies\nthe recorded data.",
               title_fs=7.8, body_fs=6.5, title_dy=2.2)
    titled_box(ax, 2.0, 0.5, 166.0, 11.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Why both syncs are needed (S_AXI_HP is not cache coherent)",
               "sync 1 (invalidate, before the app gets buffer k): no stale line fetched while the DMA was writing may be seen or written back.\n"
               "sync 2 (clean, before buffer k goes back to the DMA): no dirty line may exist while the fabric writes it — a later clean or\n"
               "eviction (e.g. by the NVMe driver's DMA_TO_DEVICE mapping) would overwrite fabric data.  Both are cache operations, not copies.",
               title_fs=8.0, body_fs=6.7, title_dy=2.0)
    ax.text(85.0, 99.0, "Zero-copy recording: who touches a buffer, and when",
            ha="center", va="center", fontsize=12.5, weight="bold", color=TXT)
    save(fig, "fdrec-dataflow.png")


# -----------------------------------------------------------------------------
# 5. / 6. Record and playback paths in detail (Zynq UltraScale+ cell names from
# Vivado/src/bd/bd_zynqmp.tcl; behaviour from Vivado/src/hdl/fdrec_*.v)
# -----------------------------------------------------------------------------
def path_frame(ax, title, irq_text):
    """PS column (DDR ring + processor) shared by the two path diagrams."""
    titled_box(ax, 2.0, 50.0, 20.0, 24.0, C_PS_FILL, C_PS_EDGE, "PS DDR",
               "ring of 2 MB-hugepage\nbuffers\n\nbuf 0 … buf N-1\n(default 32 x 8 MB)",
               title_fs=9.4, body_fs=6.8, title_dy=2.6, lw=1.3)
    titled_box(ax, 2.0, 12.0, 20.0, 34.0, C_PS_FILL, C_PS_EDGE, "Zynq\nUltraScale+ PS",
               "Linux\nfdrec driver\n\n" + irq_text, title_fs=9.4, body_fs=6.6,
               title_dy=3.6, lw=1.3)
    vblock(ax, 12.0, 46.0, 50.0, C_AXARR_FILL, C_AXARR_EDGE, bw=0.9, hw=1.7, hl=1.1)
    ax.text(85.0, 86.0, title, ha="center", va="center", fontsize=12.5,
            weight="bold", color=TXT)


def draw_record_path():
    fig, ax = new_fig(17.0, 8.8, 170, 89)
    path_frame(ax, "Recording path: user_data_source → fdrec_core → AXI DMA S2MM → DDR",
               "s2mm_introut\n→ pl_ps_irq0[6]\n(GIC SPI 95):\none IRQ per\nfilled buffer")

    # AXI DMA side
    titled_box(ax, 27.0, 46.0, 12.0, 28.0, C_MAC_FILL, C_MAC_EDGE, "axi_smc_dma",
               "SmartConnect\n\nS2MM + SG\nmasters", title_fs=7.6, body_fs=6.4,
               title_dy=2.2)
    titled_box(ax, 44.0, 46.0, 18.0, 28.0, C_GT_FILL, C_GT_EDGE, "axi_dma_0",
               "S2MM channel\nscatter-gather\n\none descriptor =\none buffer;\n"
               "1 active + 1 pending", title_fs=8.6, body_fs=6.4, title_dy=2.4, lw=1.3)
    harrow(ax, 27.0, 22.0, 62.0, "S_AXI_HP2_FPD\nwrite", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=5.8, lab_dy=4.2)
    harrow(ax, 44.0, 39.0, 64.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 44.0, 39.0, 56.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.9, hh=1.7, hl=1.1)
    ax.text(41.5, 59.9, "SG", ha="center", va="center", fontsize=5.8, color=TXT)

    # fdrec_core
    cx0, cx1 = 68.0, 132.0
    box(ax, cx0, 14.0, cx1 - cx0, 64.0, "#FAFAFD", C_MAC_EDGE, "", lw=1.3)
    ax.text((cx0 + cx1) / 2, 75.5, "fdrec_core", ha="center", va="center",
            fontsize=9.8, weight="bold", color=TXT)
    titled_box(ax, 72.0, 46.0, 22.0, 24.0, C_MAC_FILL, C_MAC_EDGE, "packetizer",
               "TLAST on every\nPKT_LEN-th beat\n(PKT_LEN = buffer\nsize / 16)\n\n"
               "ENABLE = 0: TVALID\nheld low\nPKT_BEATS_OUT", title_fs=8.2, body_fs=6.3,
               title_dy=2.4, z=3)
    titled_box(ax, 102.0, 46.0, 26.0, 24.0, C_MAC_FILL, C_MAC_EDGE, "ingest FIFO",
               "xpm_fifo_async\n4096 x 128 bit (64 KB)\n\nING_FIFO_HWM\n(high-water mark)",
               title_fs=8.2, body_fs=6.3, title_dy=2.4, z=3)
    harrow(ax, 102.0, 94.0, 58.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 72.0, 62.0, 58.0, "AXIS 128b\n+ TLAST", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=6.0, lab_dy=4.0)
    # drop point (at the FIFO input)
    titled_box(ax, 104.0, 21.0, 26.0, 18.0, "#FBF3EC", C_CLK_EDGE, "drop point",
               "TREADY held at 1.\nFIFO full: the beat\nis dropped and counted:\n"
               "ING_DROP_COUNT,\nOVERFLOW (sticky, W1C)\nING_BEATS_IN counts all",
               title_fs=7.8, body_fs=6.1, title_dy=2.0, z=3)
    route(ax, [(124.0, 46.0), (124.0, 39.0)], C_WARN, lw=1.1, ls=(0, (3, 2)))
    ax.text(98.0, 43.0, "the packetizer is downstream of the drop point:\n"
                        "drops never break the TLAST framing",
            ha="center", va="center", fontsize=6.2, color=C_WARN, linespacing=1.15)
    # registers
    box(ax, 72.0, 17.0, 28.0, 12.0, C_CTRL_FILL, C_CTRL_EDGE,
        "AXI-Lite register block\n(fdrec_regs.h)\nTPG_*, ING_*, PKT_*", fs=6.4, z=3)

    # clock domains
    cdc = 115.0
    line(ax, [(cdc, 40.0), (cdc, 73.0)], C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)), z=2.5)
    line(ax, [(cdc, 80.0), (cdc, 73.0)], C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)), z=2.5)
    clk_tag(ax, (27.0 + cdc) / 2, 80.5, "dp_clk  250 MHz  (DMA side)")
    clk_tag(ax, (cdc + 168.0) / 2, 80.5, "src_clk  200 MHz  (source side)")
    line(ax, [(27.0, 79.0), (cdc, 79.0)], C_REFCLK_LINE, lw=1.0)
    line(ax, [(cdc, 79.0), (168.0, 79.0)], C_REFCLK_LINE, lw=1.0, ls=(0, (3, 2)))

    # source
    titled_box(ax, 140.0, 46.0, 28.0, 24.0, C_USER_FILL, C_USER_EDGE,
               "user_data_source", "fdrec_tpg (default)\n\nTDATA[63:0] = seq\nTDATA[127:64] = ~seq\n"
               "rate: TPG_RATE_INC", title_fs=8.4, body_fs=6.4, title_dy=2.4, lw=1.3)
    harrow(ax, 140.0, 128.0, 58.0, "AXIS 128b", C_USER_FILL, C_USER_EDGE, bh=1.0,
           hh=1.9, hl=1.2, fs=6.0, lab_dy=3.0)
    ax.text(134.0, 52.5, "TREADY = 1\n(ignored)", ha="center", va="center",
            fontsize=5.9, color=C_WARN, linespacing=1.1)
    route(ax, [(100.0, 23.0), (154.0, 23.0), (154.0, 46.0)], C_THIN, lw=1.0)
    ax.text(146.0, 25.0, "tpg_enable, tpg_seq_rst,\ntpg_rate_inc / tpg_seq_next",
            ha="center", va="bottom", fontsize=5.9, color=C_MUTED, linespacing=1.1)

    # control (blue) and interrupt
    harrow(ax, 22.0, 30.0, 20.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1)
    route(ax, [(30.0, 20.0), (72.0, 20.0)], C_CTRL_LINE, lw=1.2)
    route(ax, [(53.0, 20.0), (53.0, 46.0)], C_CTRL_LINE, lw=1.2)
    ax.text(31.0, 17.8, "M_AXI_HPM0_FPD → periph_intercon_0 (AXI-Lite)", ha="left",
            va="center", fontsize=6.0, color=C_CTRL_LINE)
    route(ax, [(48.0, 46.0), (48.0, 34.0), (22.0, 34.0)], C_THIN, lw=1.0, ls=(0, (4, 2)))
    ax.text(35.0, 35.6, "s2mm_introut (IRQ)", ha="center", va="center", fontsize=6.0,
            color=C_MUTED)

    titled_box(ax, 2.0, 0.5, 166.0, 9.5, C_CTRL_FILL, C_CTRL_EDGE,
               "If no buffer is free, the DMA stops accepting data, the packetizer stalls, the ingest FIFO fills and beats are dropped and counted.",
               "That is the only failure mode, and it is always visible in ING_DROP_COUNT and in the drop_count of the file header.",
               title_fs=7.4, body_fs=6.8, title_dy=2.0)
    save(fig, "fdrec-record-path.png")


def draw_play_path():
    fig, ax = new_fig(17.0, 8.8, 170, 89)
    path_frame(ax, "Playback path: DDR → AXI DMA MM2S → fdrec_core → user_data_sink",
               "mm2s_introut\n→ pl_ps_irq0[7]\n(GIC SPI 96):\none IRQ per\nplayed buffer")

    titled_box(ax, 27.0, 46.0, 12.0, 28.0, C_MAC_FILL, C_MAC_EDGE, "axi_smc_dma",
               "SmartConnect\n\nMM2S + SG\nmasters", title_fs=7.6, body_fs=6.4,
               title_dy=2.2)
    titled_box(ax, 44.0, 46.0, 18.0, 28.0, C_GT_FILL, C_GT_EDGE, "axi_dma_0",
               "MM2S channel\nscatter-gather\n\none buffer = one\npacket (TLAST on\nits last beat)",
               title_fs=8.6, body_fs=6.4, title_dy=2.4, lw=1.3)
    harrow(ax, 22.0, 27.0, 62.0, "S_AXI_HP2_FPD\nread", C_AXARR_FILL, C_AXARR_EDGE,
           bh=1.1, hh=2.0, hl=1.3, fs=5.8, lab_dy=4.2)
    harrow(ax, 39.0, 44.0, 64.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.9, hh=1.7, hl=1.1)
    harrow(ax, 44.0, 39.0, 56.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=0.9, hh=1.7, hl=1.1)
    ax.text(41.5, 59.9, "SG", ha="center", va="center", fontsize=5.8, color=TXT)

    cx0, cx1 = 68.0, 118.0
    box(ax, cx0, 14.0, cx1 - cx0, 64.0, "#FAFAFD", C_MAC_EDGE, "", lw=1.3)
    ax.text((cx0 + cx1) / 2, 75.5, "fdrec_core", ha="center", va="center",
            fontsize=9.8, weight="bold", color=TXT)
    titled_box(ax, 72.0, 46.0, 42.0, 24.0, C_MAC_FILL, C_MAC_EDGE, "egress FIFO",
               "xpm_fifo_async, 4096 x 129 bit (64 KB of data + TLAST)\n"
               "lossless: when full, TREADY to the DMA goes low\n"
               "bridges the DMA pause at each buffer boundary\n\n"
               "EGR_FIFO_LEVEL, EGR_BEATS_IN\n"
               "EGR_CTRL.FLUSH: accept and discard (EGR_DISCARD)",
               title_fs=8.2, body_fs=6.2, title_dy=2.4, z=3)
    box(ax, 72.0, 17.0, 42.0, 12.0, C_CTRL_FILL, C_CTRL_EDGE,
        "AXI-Lite register block (fdrec_regs.h)\nCHK_* (sink control + counters), EGR_*", fs=6.4, z=3)
    harrow(ax, 62.0, 72.0, 58.0, "AXIS 128b\n+ TLAST", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=6.0, lab_dy=4.0)
    # backpressure (TREADY) arrows, right to left
    route(ax, [(72.0, 52.5), (62.0, 52.5)], C_WARN, lw=1.2)
    ax.text(67.0, 50.6, "TREADY", ha="center", va="center", fontsize=5.9, color=C_WARN)

    cdc = 100.0
    line(ax, [(cdc, 40.0), (cdc, 73.0)], C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)), z=2.5)
    line(ax, [(cdc, 80.0), (cdc, 73.0)], C_REFCLK_LINE, lw=1.2, ls=(0, (3, 2)), z=2.5)
    clk_tag(ax, (27.0 + cdc) / 2, 80.5, "dp_clk  250 MHz  (DMA side)")
    clk_tag(ax, (cdc + 168.0) / 2, 80.5, "src_clk  200 MHz  (sink side)")
    line(ax, [(27.0, 79.0), (cdc, 79.0)], C_REFCLK_LINE, lw=1.0)
    line(ax, [(cdc, 79.0), (168.0, 79.0)], C_REFCLK_LINE, lw=1.0, ls=(0, (3, 2)))

    titled_box(ax, 128.0, 30.0, 40.0, 40.0, C_USER_FILL, C_USER_EDGE,
               "user_data_sink",
               "fdrec_check (default), models a DAC:\n"
               "TREADY on the ticks of a Q1.31 rate\nthrottle (CHK_RATE_INC)\n\n"
               "per beat, seq = TDATA[63:0]:\n"
               "CHK_ERRORS: upper != ~lower,\n  or seq going backwards\n"
               "CHK_GAPS / CHK_GAP_BEATS:\n  missing sequence numbers\n"
               "CHK_UNDERFLOWS: tick with\n  no data after the first beat\n"
               "CHK_BEATS, CHK_LAST_SEQ",
               title_fs=8.4, body_fs=6.2, title_dy=2.4, lw=1.3)
    harrow(ax, 114.0, 128.0, 58.0, "AXIS 128b\n+ TLAST", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=6.0, lab_dy=4.0)
    route(ax, [(128.0, 52.5), (114.0, 52.5)], C_WARN, lw=1.2)
    ax.text(121.0, 50.6, "TREADY\n(rate)", ha="center", va="top", fontsize=5.9,
            color=C_WARN, linespacing=1.1)
    route(ax, [(114.0, 23.0), (148.0, 23.0), (148.0, 30.0)], C_THIN, lw=1.0)
    ax.text(131.0, 24.6, "chk_enable, chk_reset, chk_rate_inc /\nchk_* counters",
            ha="center", va="bottom", fontsize=5.9, color=C_MUTED, linespacing=1.1)

    harrow(ax, 22.0, 30.0, 20.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1)
    route(ax, [(30.0, 20.0), (72.0, 20.0)], C_CTRL_LINE, lw=1.2)
    route(ax, [(53.0, 20.0), (53.0, 46.0)], C_CTRL_LINE, lw=1.2)
    ax.text(31.0, 17.8, "M_AXI_HPM0_FPD → periph_intercon_0 (AXI-Lite)", ha="left",
            va="center", fontsize=6.0, color=C_CTRL_LINE)
    route(ax, [(48.0, 46.0), (48.0, 34.0), (22.0, 34.0)], C_THIN, lw=1.0, ls=(0, (4, 2)))
    ax.text(35.0, 35.6, "mm2s_introut (IRQ)", ha="center", va="center", fontsize=6.0,
            color=C_MUTED)

    titled_box(ax, 2.0, 0.5, 166.0, 9.5, C_CTRL_FILL, C_CTRL_EDGE,
               "The sink sets the playback rate; backpressure (TREADY low) flows back to the DMA and nothing is lost.",
               "If the SSDs, the DMA and the egress FIFO cannot keep up with the sink, the FIFO runs empty and the sink counts underflows.",
               title_fs=7.4, body_fs=6.8, title_dy=2.0)
    save(fig, "fdrec-play-path.png")


def main():
    for fam in FAMILIES:
        draw_block(fam)
    draw_custom_source()
    draw_custom_sink()
    draw_dataflow()
    draw_record_path()
    draw_play_path()


if __name__ == "__main__":
    main()
