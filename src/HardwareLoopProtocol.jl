"""
    HardwareLoopProtocol

The shared-memory protocol between a GNSS receiver process and the
allocation-free *loop process* that closes the tracking loops of a hardware
correlator (GNSSReceiver.jl, `docs/plans/2026-09-22-loop-process.md` §2.5).

The two processes share one memory segment — a file under `/dev/shm`, mapped
by both — and nothing else: no serialisation, no syscalls on the hot path, no
futex. The segment holds

  - a **header** (magic, protocol version, layout hash, channel count, the
    band table and both sides' heartbeats), refused on any mismatch;
  - one **command ring** (receiver → loop): arm, release, configure, shutdown,
    each acknowledged by a status event in the channel's ring;
  - per hardware channel one **event ring** (loop → receiver) of fixed-size
    tagged events in loop order — records, bits, epoch states, status — plus a
    **seqlock snapshot** of the newest epoch state for readers that only want
    "now".

Every ring is single-producer single-consumer. Producers never block: a full
event ring overwrites its oldest entry and the consumer learns how much history
it lost from the sequence numbers; a full command ring refuses the command
(`try_publish!` returns `false`) — a command must never be lost silently. Head
and tail are 64-bit counters written with release and read with acquire
ordering through Julia's atomic pointer intrinsics; every slot and the snapshot
carry a sequence word so a torn read is detected rather than believed.

The package depends on nothing but Base and is written so that a `--trim=safe`
build of the loop process can carry it: no strings are built on the hot path,
every record is `isbits`, and the mapping is done with plain `ccall`s.

The same code serves an **in-process** transport: [`create_segment`](@ref) with
`nothing` for the path backs the segment with a heap buffer, so the simulated
device tests and the software-only CI path run the very code the binary runs.
"""
module HardwareLoopProtocol

export PROTOCOL_VERSION,
    NAME_BYTES,
    FixedName,
    EventTag,
    RecordEvent,
    BitEvent,
    EpochStateEvent,
    StatusEvent,
    TapsEvent,
    CommandTag,
    ArmCommand,
    ConfigureCommand,
    ReleaseCommand,
    ShutdownCommand,
    QueryStateCommand,
    BandEntry,
    SegmentConfig,
    Segment,
    create_segment,
    attach_segment,
    open_or_attach_segment,
    segment_config,
    band_table,
    Ring,
    command_ring,
    event_ring,
    publish!,
    try_publish!,
    peek!,
    payload,
    commit!,
    ring_head,
    ring_tail,
    ring_available,
    ring_space,
    ring_capacity,
    consumer_lost,
    producer_overruns,
    SnapshotSlot,
    snapshot_slot,
    write_snapshot!,
    read_snapshot,
    loop_heartbeat!,
    receiver_heartbeat!,
    loop_heartbeat,
    receiver_heartbeat,
    loop_state,
    set_loop_state!,
    loop_pid,
    receiver_pid,
    set_loop_pid!,
    set_receiver_pid!,
    heartbeat_alive,
    segment_exists,
    unlink_segment

include("atomics.jl")
include("types.jl")
include("layout.jl")
include("ring.jl")
include("seqlock.jl")
include("segment.jl")

end # module
