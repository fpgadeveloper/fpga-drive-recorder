# Test the design in Linux

Once the board has booted the Linux image (see [Yocto](yocto)) and you are logged in, work
through the steps below: check that the SSDs and the recorder are there, measure the SSDs
with the `dd` speed-test scripts, then make a recording, verify it and play it back.

Most commands need root privileges: prefix them with `sudo` (the `amd-edf` user may use
it). The outputs below are examples; the numbers on your board depend on the target, the
SSDs and the rate you choose.

## 1. Check that the PCIe links are up

The kernel reports each Root Port as it probes it. Look for `PCIe Link is UP` and an NVMe
controller per SSD:

```
dmesg | grep -iE "pcie link|nvme"
```

On a target with two active M.2 slots and two SSDs you should see one link and one NVMe
controller per slot, similar to:

Example output (representative):

```none
xilinx-xdma-pcie 400000000.axi-pcie: PCIe Link is UP
xilinx-xdma-pcie 500000000.axi-pcie: PCIe Link is UP
nvme nvme0: pci function 0000:01:00.0
nvme nvme1: pci function 0001:01:00.0
nvme nvme0: 4/0/0 default/read/poll queues
nvme nvme1: 4/0/0 default/read/poll queues
```

Check the negotiated link speed and width with `lspci`; the Root Port's `LnkSta` should
match the design (Gen3 x4, 8 GT/s, on the Zynq UltraScale+ targets; on `vck190_fmcp1`, Gen4 x4,
16 GT/s, with a Gen4 SSD and Gen3 x4 with a Gen3 SSD):

```
lspci -vv | grep -E "^[0-9a-f]|LnkCap:|LnkSta:"
```

An SSD that supports Gen4 reports its link as `(downgraded)` on a Gen3 design; that is
expected. Then identify the SSDs:

```
nvme list
```

If a link does not come up or an SSD is missing, see [Troubleshooting](troubleshooting).

## 2. Check the recorder driver

The `fdrec` driver is loaded at boot. It prints a few lines when it binds to the hardware:

```
dmesg | grep fdrec
```

Example output (representative):

```none
fdrec 420010000.fdrec_core: dma-channel: IRQ 74 -> CPU3
fdrec 420010000.fdrec_core: dma-channel: IRQ 75 -> CPU3
fdrec 420010000.fdrec_core: /dev/fdrec0: fdrec_core v1.2, src_clk 249975021 Hz, dp_clk 249975021 Hz, beat 32 bytes, FIFO 8192 beats, DMA rx dma0chan1 tx dma0chan0 (max segment 67108863 bytes), checker
```

The `dma-channel` lines give the CPU each AXI DMA channel interrupt was pinned to (the
`dma_irq_cpu` module parameter, see [Kernel driver](driver.md)). The last line gives the
version of the hardware's register map (`fdrec_core v1.2`: record and playback, with the
beat size in a register), the actual source and datapath clock frequencies, the size of a
fabric beat (32 bytes: the 256-bit datapath), the ingest FIFO depth in beats, the two DMA
channels (`rx` = record, `tx` = playback) and `checker` when the playback checker is present.
`v1.2` is the register map, not the driver: `modinfo -F version fdrec` gives the driver's
version, 1.3. Then check the device, its sysfs attributes and the hugepage pool that the
buffers come from:

```
ls -l /dev/fdrec0
cat /sys/class/misc/fdrec0/version          # 1.2 (register map)
cat /sys/class/misc/fdrec0/beat_bytes       # 32
cat /sys/class/misc/fdrec0/src_clk_hz
modinfo -F version fdrec                    # 1.3 (driver)
grep HugePages_ /proc/meminfo               # HugePages_Total: 256
```

## 3. Prepare the SSD filesystem

```{warning}
`fdsetup-raid0.sh` erases the SSDs it uses. Make sure they hold no data you need.
```

With two SSDs, make a RAID0 array of both, formatted with XFS and mounted at `/mnt/rec`:

```
sudo fdsetup-raid0.sh
```

With one SSD (or to use one SSD of two):

```
sudo fdsetup-raid0.sh --single /dev/nvme0n1
```

The script asks for confirmation (`-y` skips it), creates the mount point, and prints what
it did. `--mount <dir>` mounts somewhere else, `--fs ext4` uses ext4. See
[Applications](apps.md#fdsetup-raid0sh) for all options.

## 4. Measure the SSDs with the dd speed-test scripts

The image contains the four speed-test scripts of
[fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie), so you can
compare the plain `dd` method with the recorder on the same board. Each script times a
4000 MiB transfer (`dd`, 1000 blocks of 4 MiB, `O_DIRECT`) to or from a file `test.img` on
a mounted SSD. Run the write test first: the read test reads back the file that the write
test created, and deletes it.

One SSD (for example the single-drive filesystem mounted at `/mnt/rec` in step 3):

```
single_write_test.sh /mnt/rec
single_read_test.sh  /mnt/rec
```

Example output (representative):

```none
Single SSD Write:
  - Data:  4000 MBytes
  - Delay: 3.13 seconds
  - Speed: 1277 MBytes/s
```

The dual scripts run one `dd` per SSD in parallel and need each SSD mounted on its own,
not as RAID0:

```
sudo fdsetup-raid0.sh --teardown
sudo fdsetup-raid0.sh -y --single /dev/nvme0n1 --mount /mnt/ssd1
sudo fdsetup-raid0.sh -y --single /dev/nvme1n1 --mount /mnt/ssd2
dual_write_test.sh /mnt/ssd1 /mnt/ssd2
dual_read_test.sh  /mnt/ssd1 /mnt/ssd2
```

Notes on reading the figures:

* The scripts print "MBytes" but count in MiB (4 MiB × 1000 blocks = 4000 MiB). Multiply
  the speed by 1.0486 to compare it with the MB/s (10⁶ bytes/s) that `fdrec` and
  `fdplay` report. The dual scripts divide the data of both SSDs by the elapsed time, so
  they print the combined rate.
* 4000 MiB fits inside the SLC write cache of most consumer SSDs, so the write figure is a
  burst rate, not a rate the SSD can sustain (see [supported SSDs](supported_ssds)).
* `dd` runs one synchronous 4 MiB I/O at a time, and the CPU produces (or discards) every
  byte. It measures something different from the recorder; the
  [comparison](benchmarks.md#comparison-with-fpga-drive-aximm-pcie-dd-method) explains
  the difference.

Before you continue, put the recording filesystem back (RAID0 or single, as in step 3).

## 5. Record, verify and play back

Record 10 GB of the test pattern at 1 GB/s:

```
sudo fdrec --rate 1000MB --size 10G /mnt/rec/test.dat; echo "exit code $?"
```

While it runs, `fdrec` prints a live statistics line every second, then a summary:

Example output (representative):

```none
fdrec: recording to /mnt/rec/test.dat (32 x 8 MB buffers, qd 8, fixed buffers, 32-byte beats, test pattern) -- Ctrl-C to stop
     10.0s   1000.1 MB/s (avg   999.9)       10.000 GB  inflight  2  fifo_hwm     1/8192  drops 0
fdrec: /mnt/rec/test.dat: 10737418240 bytes (1280 buffers) in 10.75 s, 999.1 MB/s
fdrec: dropped beats 0 (at stop: 0), FIFO high-water 1 of 8192 beats (32 bytes each), max writes in flight 3
RESULT bytes=10737418240 seconds=10.747 rate_bps=999999997 drops=0 fifo_hwm=1 fifo_depth=8192 error=0 beat_bytes=32 no_write=0
exit code 0
```

| `fdrec` exit code | Meaning |
|---|---|
| 0 | Recording complete, zero dropped beats |
| 2 | Beats were dropped: the SSD could not keep up with the rate; the recording is not valid |
| 1 | Error, or a stall: nothing completed for `--timeout` seconds (default 10) |

Verify the recording:

```
sudo fdverify /mnt/rec/test.dat; echo "exit code $?"
```

`fdverify` prints the header, then checks every 16-byte word of the test pattern (a 32-byte
beat holds two; a progress line is shown while it reads) and ends with `RESULT PASS` and exit
code 0 for a clean recording:

Example output (representative, the end of the header and the result):

```none
  header          version 1, 4096 bytes, 32-byte beats
  ...
  words           671088640 (10737418240 bytes, 335544320 beats of 32 bytes)
  first sequence  0
  last sequence   671088639
  discontinuities 0, words missing 0 (0 beats)
  corrupted words 0
RESULT PASS
exit code 0
```

Play the recording back into the fabric, where the hardware checker consumes it at 1 GB/s
and checks both words of every beat:

```
sudo fdplay --rate 1000MB /mnt/rec/test.dat; echo "exit code $?"
```

Example output (representative):

```none
fdplay: /mnt/rec/test.dat: 10737418240 of 10737418240 bytes (1280 buffers) in 10.83 s, 991.8 MB/s
fdplay: checker: beats 335544320 (expected 335544320, 32 bytes each), errors 0, gaps 0, gap beats 0 (recording drop_count 0), underflows 0, last seq 671088638, sink rate 1000.0 MB/s
RESULT bytes=10737418240 seconds=10.826 sink_rate_bps=1000000000 beats=335544320 errors=0 gaps=0 gap_beats=0 drop_count=0 underflows=0 egr_discard=0 max_reads=8 complete=1 error=0 beat_bytes=32 file_beat_bytes=32
exit code 0
```

The checker counts beats of 32 bytes; `last seq` is the sequence number of the first 16-byte
word of the last beat (`fdverify`'s last sequence minus one).

| `fdplay` exit code | Meaning |
|---|---|
| 0 | Playback complete, and the checker saw every beat with no errors, no underflows, and gap beats equal to the recording's drop count |
| 2 | Playback complete, but the checker found a problem (for example underflows: the SSD could not deliver the data as fast as `--rate`) |
| 1 | Error or incomplete playback (Ctrl-C, read error, stall) |

```{note}
Without `--rate`, `fdplay` leaves the sink rate as it is; its default is one beat per
`src_clk` cycle (8 GB/s), faster than the SSDs can read, so the checker reports
underflows. Always give `fdplay` a `--rate` below the read rate of your SSDs.
```

## 6. See a failure on purpose

To see what an overload looks like, record faster than the SSD can write, for example
6 GB/s to one drive. (That is above what one SSD wrote on every target on the
[Benchmarks](benchmarks) page: a Gen4 drive on the Gen3 x4 slots of the Zynq UltraScale+
targets writes ~2.9-3.0 GB/s, and on `vck190_fmcp1` one Samsung 980 PRO 1TB ~4.95-4.98 GB/s and
one Sabrent Rocket 2230 1TB ~4.6 GB/s.)

```
sudo fdrec --rate 6000MB --size 10G /mnt/rec/over.dat; echo "exit code $?"
sudo fdverify /mnt/rec/over.dat
sudo fdplay --rate 500MB /mnt/rec/over.dat; echo "exit code $?"
```

`fdrec` warns that beats were dropped and exits with code 2. `fdverify` lists the gaps
(the first `--max-errors` of them), reports that the missing words match the header's
`drop_count` exactly (two 16-byte words per dropped 32-byte beat), and ends with
`RESULT FAIL`. `fdplay` still exits 0: the file, the
read path and the playback are lossless, and the checker's gap beats equal the recording's
drop count.

## 7. Find the sustained recording rate

`fdbench.sh` sweeps the rate in 500 MB/s steps from 500 MB/s up to the generator maximum
(8000 MB/s), with 32 GB per step, and prints the highest rate that recorded cleanly. It takes
a while (32 GB at every step); `--stop-on-fail` ends it at the first failing step, and
`--from` / `--to` / `--step` narrow it:

```
sudo fdbench.sh --stop-on-fail
```

Run it once on a single SSD and once on RAID0. See [Benchmarks](benchmarks) for the
method and for results.
