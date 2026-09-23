[![CI](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/JuliaGNSS/HardwareLoopProtocol.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaGNSS/HardwareLoopProtocol.jl)

# HardwareLoopProtocol.jl

The shared-memory protocol between a GNSS receiver process and the
allocation-free loop process that closes the tracking loops of a hardware
correlator (see GNSSReceiver.jl, `docs/plans/2026-09-22-loop-process.md`).

One segment under `/dev/shm`, mapped by both processes: a versioned header with
the band table and both sides' heartbeats, a single-producer single-consumer
command ring (receiver → loop), and per hardware channel an event ring
(loop → receiver) of fixed-size tagged events plus a seqlock snapshot of the
newest epoch state. Producers never block; consumers detect lost history from
the sequence numbers. Base only, `--trim`-friendly, and usable in-process with a
heap-backed segment.

```julia
using HardwareLoopProtocol
seg = create_segment("/dev/shm/gnss-loop-1", SegmentConfig(; channel_count = 6, bands = [BandEntry(:L1, 4e6)]))
ring = event_ring(seg, 1)
publish!(ring, EventTag(HardwareLoopProtocol.EVENT_RECORD, 1, 4000; prn = 7), RecordEvent(1.0 + 0im, 4000, 1, 0, 0.0, 0.0, 0.0))
```
