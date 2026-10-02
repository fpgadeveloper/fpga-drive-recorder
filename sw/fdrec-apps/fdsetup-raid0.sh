#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# fdsetup-raid0.sh -- prepare the recording filesystem: a RAID0 (striped)
# md array across two NVMe SSDs, or a single SSD, formatted and mounted at
# /mnt/rec (--mount <dir>; the directory is created). DESTROYS all data on the drives used.

set -eu

CHUNK=512K
FS=xfs
MNT=/mnt/rec
MD=/dev/md0
SINGLE=""
FORCE=0
TEARDOWN=0
DEVS=""

usage() {
    cat <<EOF
Usage: fdsetup-raid0.sh [options] [<nvme-dev> <nvme-dev>]

Create a RAID0 array ($MD) from two NVMe drives with mdadm, format it and
mount it at $MNT for recording with fdrec. Without device arguments the
two NVMe namespaces found in /dev (nvme0n1, nvme1n1, ...) are used.
ALL DATA ON THE DRIVES IS DESTROYED.

Options:
  --chunk <size>     RAID0 chunk size (mdadm units, default $CHUNK)
  --fs xfs|ext4      filesystem (default $FS)
  --mount <dir>      mount point, created if missing (default $MNT);
                     give the same --mount to --teardown
  --single <dev>     no RAID: format and mount this one drive instead
                     (an md array that uses it is unmounted and stopped)
  --teardown         unmount the mount point and stop $MD (data is kept)
  -y, --yes          do not ask for confirmation
  -h, --help         this help

Examples:
  fdsetup-raid0.sh                         # both SSDs, RAID0, XFS
  fdsetup-raid0.sh --fs ext4 --chunk 1M
  fdsetup-raid0.sh --single /dev/nvme0n1   # one SSD, XFS

After a reboot the array is re-assembled with:
  mdadm --assemble $MD <dev1> <dev2> && mkdir -p $MNT && mount $MD $MNT
EOF
}

die() { echo "fdsetup-raid0: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --chunk) CHUNK="${2:?}"; shift 2 ;;
        --fs) FS="${2:?}"; shift 2 ;;
        --mount) MNT="${2:?}"; shift 2 ;;
        --single) SINGLE="${2:?}"; shift 2 ;;
        --teardown) TEARDOWN=1; shift ;;
        -y|--yes) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 1 ;;
        *) DEVS="$DEVS $1"; shift ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "must run as root"
case "$FS" in xfs|ext4) ;; *) die "--fs must be xfs or ext4" ;; esac

if [ "$TEARDOWN" -eq 1 ]; then
    mountpoint -q "$MNT" && umount "$MNT"
    [ -e "$MD" ] && mdadm --stop "$MD"
    echo "fdsetup-raid0: $MNT unmounted, $MD stopped"
    exit 0
fi

# chunk size in KiB (for the ext4 stripe hints)
chunk_kib() {
    v=$(echo "$1" | tr 'a-z' 'A-Z')
    case "$v" in
        *K) echo "${v%K}" ;;
        *M) echo $(( ${v%M} * 1024 )) ;;
        *[0-9]) echo "$v" ;;          # mdadm default unit: KiB
        *) die "bad --chunk '$1'" ;;
    esac
}

if [ -n "$SINGLE" ]; then
    TARGET="$SINGLE"
    set -- "$SINGLE"
else
    if [ -z "$DEVS" ]; then
        DEVS=$(ls /dev/nvme[0-9]*n1 2>/dev/null | sort | head -n 2 | tr '\n' ' ')
    fi
    set -- $DEVS
    [ $# -eq 2 ] || die "need exactly two NVMe drives for RAID0 (found: ${DEVS:-none}); use --single <dev> for one"
    TARGET="$MD"
fi
for d in "$@"; do
    [ -b "$d" ] || die "$d is not a block device"
done
command -v mkfs.$FS >/dev/null || die "mkfs.$FS not found"
[ -n "$SINGLE" ] || command -v mdadm >/dev/null || die "mdadm not found"

echo "fdsetup-raid0: about to ERASE: $*"
if [ -n "$SINGLE" ]; then
    echo "  layout: single drive, $FS, mounted at $MNT"
else
    echo "  layout: RAID0 $MD, chunk $CHUNK, $FS, mounted at $MNT"
fi
if [ "$FORCE" -ne 1 ]; then
    printf "Type 'yes' to continue: "
    read -r ans
    [ "$ans" = "yes" ] || die "aborted"
fi

# Release anything that holds the drives
mountpoint -q "$MNT" && umount "$MNT"
for d in "$@"; do
    for p in $(lsblk -nrpo NAME "$d" 2>/dev/null); do
        grep -q "^$p " /proc/mounts && umount "$p"
    done
done
# Stop every md array that uses one of the drives (an assembled $MD keeps
# the drive busy: mkfs/wipefs would fail with "Device or resource busy").
if [ -r /proc/mdstat ]; then
    for d in "$@"; do
        b=$(basename "$d")
        for md in $(awk -v b="$b" '/^md[0-9]+ :/ {
                        for (i = 3; i <= NF; i++) { m = $i; sub(/\[.*/, "", m);
                            if (m == b || index(m, b "p") == 1) print $1 } }' /proc/mdstat); do
            mdp="/dev/$md"
            for p in $(lsblk -nrpo NAME "$mdp" 2>/dev/null); do
                grep -q "^$p " /proc/mounts && { umount "$p" || die "cannot unmount $p (in use?)"; }
            done
            echo "fdsetup-raid0: stopping $mdp (uses $d)"
            mdadm --stop "$mdp" || die "cannot stop $mdp; run 'fdsetup-raid0.sh --teardown' or 'mdadm --stop $mdp' first"
        done
    done
fi
if [ -z "$SINGLE" ]; then
    [ -e "$MD" ] && mdadm --stop "$MD" 2>/dev/null || true
fi
for d in "$@"; do
    mdadm --zero-superblock "$d" 2>/dev/null || true
done
for d in "$@"; do
    wipefs -a "$d" >/dev/null 2>&1 || true
done

if [ -z "$SINGLE" ]; then
    mdadm --create "$MD" --run --level=0 --raid-devices=2 --chunk="$CHUNK" \
          --metadata=1.2 "$@"
    mdadm --wait "$MD" 2>/dev/null || true
fi

case "$FS" in
    xfs)
        # mkfs.xfs reads the md stripe geometry (su/sw) itself
        mkfs.xfs -f "$TARGET" ;;
    ext4)
        if [ -z "$SINGLE" ]; then
            stride=$(( $(chunk_kib "$CHUNK") / 4 ))
            mkfs.ext4 -F -b 4096 -E "stride=$stride,stripe_width=$(( stride * 2 )),lazy_itable_init=0,lazy_journal_init=0" "$TARGET"
        else
            mkfs.ext4 -F -b 4096 -E "lazy_itable_init=0,lazy_journal_init=0" "$TARGET"
        fi ;;
esac

mkdir -p "$MNT"
mount -o noatime "$TARGET" "$MNT"
echo "fdsetup-raid0: $TARGET ($FS) mounted at $MNT"
df -h "$MNT"
[ -n "$SINGLE" ] || mdadm --detail "$MD" | grep -E "Raid Level|Array Size|Chunk Size|Raid Devices|/dev/"
