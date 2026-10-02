#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# fdbench.sh -- sustained recording rate sweep.
#
# Records a fixed amount of test-pattern data at increasing generator rates,
# verifies every recording with fdverify, and prints rate vs. pass/fail vs.
# drop count vs. FIFO high-water mark. The highest passing rate is the
# sustained recording rate of this board + SSD (+ filesystem) combination.

set -u

DIR=/mnt/rec
SIZE=32G
FROM=250
TO=""
STEP=250
FDREC_ARGS=""
KEEP=0
STOP_ON_FAIL=0

usage() {
    cat <<EOF
Usage: fdbench.sh [options]

Sweep the test pattern generator rate and record --size bytes at each step
(default $SIZE: large enough to exhaust the SLC cache of typical smaller
SSDs, so the result is the sustained rate, not the cache rate).

Options:
  --dir <dir>          directory on the SSD filesystem (default $DIR)
  --size <bytes>       data per step, fdrec suffixes (default $SIZE)
  --from <MB/s>        first rate in MB/s (10^6 bytes/s, default $FROM)
  --to <MB/s>          last rate (default: generator maximum = src_clk x 16)
  --step <MB/s>        rate step (default $STEP)
  --stop-on-fail       stop at the first failing rate
  --keep               keep the recordings (default: delete after verifying)
  --fdrec-args "<..>"  extra fdrec options (e.g. "--buffers 64 --qd 16")
  -h, --help           this help

Prerequisites: the fdrec module is loaded (/dev/fdrec0) and a filesystem is
mounted at --dir (fdsetup-raid0.sh). The free space must exceed --size.
EOF
}

die() { echo "fdbench: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir) DIR="${2:?}"; shift 2 ;;
        --size) SIZE="${2:?}"; shift 2 ;;
        --from) FROM="${2:?}"; shift 2 ;;
        --to) TO="${2:?}"; shift 2 ;;
        --step) STEP="${2:?}"; shift 2 ;;
        --stop-on-fail) STOP_ON_FAIL=1; shift ;;
        --keep) KEEP=1; shift ;;
        --fdrec-args) FDREC_ARGS="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done

command -v fdrec >/dev/null || die "fdrec not found in PATH"
command -v fdverify >/dev/null || die "fdverify not found in PATH"
[ -c /dev/fdrec0 ] || die "/dev/fdrec0 not found (modprobe fdrec)"
[ -d "$DIR" ] || die "$DIR does not exist (run fdsetup-raid0.sh)"

SYS=/sys/class/misc/fdrec0
if [ -z "$TO" ]; then
    clk=$(cat $SYS/src_clk_hz 2>/dev/null || echo 0)
    [ "$clk" -gt 0 ] || die "cannot read $SYS/src_clk_hz; give --to"
    TO=$(( clk * 16 / 1000000 ))
fi

FS_DEV=$(df -P "$DIR" | awk 'NR==2 {print $1}')
FS_TYPE=$(df -PT "$DIR" | awk 'NR==2 {print $2}')
OUT="$DIR/fdbench.dat"
LOG=$(mktemp /tmp/fdbench.XXXXXX)
trap 'rm -f "$LOG"' EXIT

echo "fdbench: $FS_DEV ($FS_TYPE) at $DIR, $SIZE per step, $FROM..$TO MB/s step $STEP"
for d in /sys/block/nvme*n1; do
    [ -e "$d" ] && echo "  $(basename "$d"): $(cat "$d/device/model" 2>/dev/null | tr -s ' ') ($(cat "$d/device/firmware_rev" 2>/dev/null | tr -d ' '))"
done
echo
printf "%10s  %-6s  %14s  %16s  %12s  %10s\n" "rate MB/s" "result" "drops" "fifo_hwm/depth" "avg MB/s" "fdverify"
printf "%10s  %-6s  %14s  %16s  %12s  %10s\n" "---------" "------" "-----" "--------------" "--------" "--------"

best=0
rate=$FROM
while [ "$rate" -le "$TO" ]; do
    rm -f "$OUT"
    sync
    # shellcheck disable=SC2086
    fdrec --rate "${rate}MB" --size "$SIZE" --stats 0 $FDREC_ARGS "$OUT" >"$LOG" 2>&1
    rc=$?
    res=$(grep '^RESULT ' "$LOG" | tail -n1)
    get() { echo "$res" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
    drops=$(get drops); hwm=$(get fifo_hwm); depth=$(get fifo_depth)
    bytes=$(get bytes); secs=$(get seconds)
    avg=$(awk -v b="${bytes:-0}" -v s="${secs:-0}" 'BEGIN { if (s > 0) printf "%.1f", b / s / 1e6; else print "-" }')
    if [ $rc -eq 0 ]; then
        if fdverify -q "$OUT" >"$LOG.v" 2>&1; then v=PASS; else v=FAIL; fi
    elif [ $rc -eq 2 ]; then
        # dropped beats: fdverify must report the gaps (cross-check)
        if fdverify -q "$OUT" >"$LOG.v" 2>&1; then v=PASS?; else v=gaps; fi
    else
        v=-
    fi
    rm -f "$LOG.v"
    if [ $rc -eq 0 ] && [ "$v" = PASS ]; then
        result=PASS; best=$rate
    elif [ $rc -eq 2 ]; then
        result=DROPS
    else
        result=ERROR
        sed 's/^/    /' "$LOG" | tail -n 5
    fi
    printf "%10s  %-6s  %14s  %16s  %12s  %10s\n" "$rate" "$result" "${drops:--}" "${hwm:--}/${depth:--}" "$avg" "$v"
    [ "$KEEP" -eq 1 ] && mv "$OUT" "$DIR/fdbench-${rate}MBps.dat" 2>/dev/null
    if [ "$result" != PASS ] && [ "$STOP_ON_FAIL" -eq 1 ]; then
        break
    fi
    rate=$(( rate + STEP ))
done
[ "$KEEP" -eq 1 ] || rm -f "$OUT"

echo
if [ "$best" -gt 0 ]; then
    echo "fdbench: sustained recording rate: $best MB/s ($FS_DEV, $FS_TYPE, $SIZE per step)"
else
    echo "fdbench: no rate passed"
    exit 1
fi
