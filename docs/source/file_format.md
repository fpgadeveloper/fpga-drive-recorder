# File format

A recording made by `fdrec` is a 4096-byte header followed by the raw data, exactly as the
AXI DMA wrote it to memory:

| Offset | Size | Content |
|--------|------|---------|
| 0 | 4096 | Header (`struct fdrec_file_header`), little-endian, zero-padded |
| 4096 | `data_bytes` | Beats 0, 1, 2, … — 16 bytes each, little-endian |

The 4 KB header keeps the data aligned for `O_DIRECT`. The header is written once when the
recording starts (without the *complete* flag) and rewritten when it stops, with the final
counts and `flags.bit1` set. A file whose header lacks the *complete* flag was interrupted
(power loss, crash) and is reported as such by `fdverify`.

The structure is defined as a packed C struct in
[`include/fdrec_file.h`](https://github.com/fpgadeveloper/fpga-drive-recorder/blob/dev/include/fdrec_file.h)
(its size is checked at compile time).

## Header

| Offset | Field | Type | Notes |
|--------|-------|------|-------|
| 0 | `magic` | char[8] | `"FDREC\0\0\0"` |
| 8 | `header_version` | u32 | 1 |
| 12 | `header_size` | u32 | 4096 |
| 16 | `beat_bytes` | u32 | 16 |
| 20 | `flags` | u32 | bit0: the source was the test pattern generator; bit1: complete (header rewritten at stop) |
| 24 | `design_version` | u32 | `VERSION` register of the design, `[31:16]` major, `[15:0]` minor |
| 28 | `src_clk_hz` | u64 | source clock frequency |
| 36 | `rate_bps` | u64 | TPG rate programmed by `fdrec --rate`, 0 if not set by fdrec |
| 44 | `start_time_ns` | u64 | `CLOCK_REALTIME` (ns since the epoch) when the datapath was enabled |
| 52 | `stop_time_ns` | u64 | `CLOCK_REALTIME` at stop |
| 60 | `data_bytes` | u64 | bytes of data after the header |
| 68 | `drop_count` | u64 | beats dropped by the ingest FIFO (see below) |
| 76 | `first_seq` | u64 | sequence number of the first beat, if the TPG was the source (0) |
| 84 | `target` | char[32] | target design, e.g. `uzev`, NUL-padded |
| 116 | `hostname` | char[64] | NUL-padded |
| 180 | reserved | u8[3916] | zero |

`drop_count` is the ingest FIFO's drop counter read when the last recorded buffer
completed. It covers every beat lost before the last recorded beat (and possibly a few
dropped just after it), so a recording is valid only if it is **0**. `fdrec` exits with code
2 when it is not.

## Data

Each 16-byte beat is one 128-bit AXI-Stream word as it came out of the data source: bytes 0–7
are `TDATA[63:0]`, bytes 8–15 are `TDATA[127:64]`, both little-endian. The recorder adds no
framing, padding or timestamps, so a file of N beats has `data_bytes = 16 × N`.

With the test pattern generator as the source, beat `n` carries:

* `TDATA[63:0]` = `seq` (a 64-bit counter that increments on every beat the generator emits,
  including beats that are later dropped),
* `TDATA[127:64]` = `~seq`.

So in a clean recording `lower` increases by exactly one from beat to beat, starting at
`first_seq`, and `upper == ~lower` on every beat. A jump in `lower` is a gap of dropped beats
(its size is the jump minus one); a beat with `upper != ~lower` is corrupted. This is what
`fdverify` checks.

With your own data source, the data is whatever your logic presents on the 128-bit
interface; see [Replacing the test pattern generator](custom_source).

## Reading a recording

Python:

```python
import struct, numpy as np

with open("rec.dat", "rb") as f:
    hdr = f.read(4096)
    magic, ver, hsize, beat, flags, dver = struct.unpack_from("<8s5I", hdr, 0)
    src_clk, rate, t0, t1, nbytes, drops, first = struct.unpack_from("<7Q", hdr, 28)
    data = np.fromfile(f, dtype="<u8").reshape(-1, 2)   # [:,0] = lower, [:,1] = upper
```

C: include `fdrec_file.h` and read the first 4096 bytes into a `struct fdrec_file_header`.
