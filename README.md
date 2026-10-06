[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://JuliaGNSS.github.io/HardwareLoopProtocol.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://JuliaGNSS.github.io/HardwareLoopProtocol.jl/dev)
[![Tests](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/actions/workflows/ci.yml)
[![Documentation](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/actions/workflows/Documentation.yml/badge.svg)](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/actions/workflows/Documentation.yml)
[![codecov](https://codecov.io/gh/JuliaGNSS/HardwareLoopProtocol.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/JuliaGNSS/HardwareLoopProtocol.jl)

# HardwareLoopProtocol.jl

The shared-memory protocol between a GNSS receiver process and the
allocation-free loop process that closes the tracking loops of a hardware
correlator.

The two processes map one segment: a file, conventionally under `/dev/shm` on
Linux. It holds a versioned header with the band table and both sides'
heartbeats, a single-producer single-consumer command ring (receiver → loop),
and per hardware channel an event ring (loop → receiver) of fixed-size tagged
events plus a seqlock snapshot of the newest epoch state. A loop-wide nav ring
and snapshot carry the navigation solution of a loop that runs vector
tracking. Producers never
block; consumers detect lost history from the sequence numbers. Base only,
`--trim`-friendly, and usable in-process with a heap-backed segment.

```julia
using HardwareLoopProtocol
const HLP = HardwareLoopProtocol

# `nothing` backs the segment with a heap buffer; the loop process passes a
# file path instead, which the receiver then opens with `attach_segment`.
seg = create_segment(nothing, SegmentConfig(; channel_count = 6, bands = [BandEntry(:L1, 4e6)]))
ring = event_ring(seg, 1)
publish!(ring, EventTag(HLP.EVENT_RECORD, 1, 4000; prn = 7), RecordEvent(1.0 + 0im, 4000, 1, 0, 0.0, 0.0, 0.0))

status, view, lost = peek!(ring, EventTag)
record = payload(RecordEvent, ring, view)
commit!(ring, view)
```

See the [documentation](https://JuliaGNSS.github.io/HardwareLoopProtocol.jl/stable)
for the protocol, a walk-through of both sides, and the API reference.
