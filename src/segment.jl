# ─────────────────────────────────────────────────────────────────────────────
# The segment: a mapped file under /dev/shm (two processes) or a heap buffer
# (one process, the tests and the in-process transport), with the header the
# creator writes and the attaching side verifies.
# ─────────────────────────────────────────────────────────────────────────────

"""
    Segment

A mapped protocol segment. Build one with [`create_segment`](@ref) (the loop
process, which owns the layout) or [`attach_segment`](@ref) (the receiver);
`close` unmaps it. The creator of a file-backed segment may [`unlink_segment`](@ref)
it when the session is over.
"""
mutable struct Segment
    base::Ptr{UInt8}
    bytes::Int
    path::String
    fd::Cint
    owner::Bool
    # Keeps a heap-backed segment alive for as long as the handle is.
    backing::Union{Nothing,Vector{UInt8}}
    open::Bool
end

# ── mmap through libc, so the package stays Base-only and trim-friendly ─────

const O_RDWR = Cint(0x0002)
const O_CREAT = Sys.isapple() ? Cint(0x0200) : Cint(0o100)
const O_EXCL = Sys.isapple() ? Cint(0x0800) : Cint(0o200)
const PROT_READ = Cint(1)
const PROT_WRITE = Cint(2)
const MAP_SHARED = Cint(1)
const MAP_FAILED = Ptr{Cvoid}(-1 % UInt)

function _open_file(path::String, flags::Cint)
    # `open(2)` is variadic and the mode is a vararg: spelled as one, or the
    # Apple arm64 ABI passes it in the wrong place and the file is created with
    # whatever permissions the stack held (seen as "Permission denied" on the
    # macOS CI runner).
    fd = @ccall open(path::Cstring, flags::Cint; Cuint(0o644)::Cuint)::Cint
    fd < 0 && systemerror("open($path)", Libc.errno())
    fd
end

function _file_size(fd::Cint)
    # struct stat is platform-specific; `lseek` to the end is portable enough.
    size = ccall(:lseek, Int64, (Cint, Int64, Cint), fd, 0, 2 #= SEEK_END =#)
    size < 0 && systemerror("lseek", Libc.errno())
    Int(size)
end

function _mmap(fd::Cint, bytes::Int)
    p = ccall(
        :mmap,
        Ptr{Cvoid},
        (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int64),
        C_NULL,
        bytes,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        fd,
        0,
    )
    p == MAP_FAILED && systemerror("mmap", Libc.errno())
    Ptr{UInt8}(p)
end

function _munmap(p::Ptr{UInt8}, bytes::Int)
    ccall(:munmap, Cint, (Ptr{Cvoid}, Csize_t), p, bytes)
    nothing
end

# ── Header accessors ─────────────────────────────────────────────────────────

@inline _u32(seg::Segment, off) = unsafe_load(Ptr{UInt32}(seg.base + off))
@inline _u64(seg::Segment, off) = unsafe_load(Ptr{UInt64}(seg.base + off))
@inline _set_u32!(seg::Segment, off, v) = unsafe_store!(Ptr{UInt32}(seg.base + off), UInt32(v))
@inline _set_u64!(seg::Segment, off, v) = unsafe_store!(Ptr{UInt64}(seg.base + off), UInt64(v))

channel_count(seg::Segment) = Int(_u32(seg, OFF_CHANNEL_COUNT))
band_count(seg::Segment) = Int(_u32(seg, OFF_BAND_COUNT))
event_capacity(seg::Segment) = Int(_u32(seg, OFF_EVENT_CAPACITY))
command_capacity(seg::Segment) = Int(_u32(seg, OFF_COMMAND_CAPACITY))
device_index(seg::Segment) = Int(_u32(seg, OFF_DEVICE_INDEX))

"""
    segment_config(seg) -> SegmentConfig

The configuration the segment was created with, read back from its header.
"""
segment_config(seg::Segment) = SegmentConfig(
    channel_count(seg),
    band_table(seg),
    event_capacity(seg),
    command_capacity(seg),
    device_index(seg),
)

"""
    band_table(seg) -> Vector{BandEntry}

The bands the loop process serves, the reference band first.
"""
function band_table(seg::Segment)
    n = band_count(seg)
    [unsafe_load(Ptr{BandEntry}(seg.base + OFF_BAND_TABLE + (i - 1) * BAND_ENTRY_BYTES)) for i = 1:n]
end

function _write_header!(seg::Segment, config::SegmentConfig, layout::Layout)
    # Zero the header first so no stale field can be read as meaningful before
    # the magic is written last.
    ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), seg.base, 0, HEADER_BYTES)
    _set_u32!(seg, OFF_VERSION, PROTOCOL_VERSION)
    _set_u64!(seg, OFF_LAYOUT_HASH, layout_hash())
    _set_u32!(seg, OFF_CHANNEL_COUNT, config.channel_count)
    _set_u32!(seg, OFF_BAND_COUNT, length(config.bands))
    _set_u32!(seg, OFF_EVENT_CAPACITY, config.event_capacity)
    _set_u32!(seg, OFF_COMMAND_CAPACITY, config.command_capacity)
    _set_u32!(seg, OFF_EVENT_SLOT_BYTES, EVENT_SLOT_BYTES)
    _set_u32!(seg, OFF_COMMAND_SLOT_BYTES, COMMAND_SLOT_BYTES)
    _set_u32!(seg, OFF_DEVICE_INDEX, config.device_index)
    _set_u64!(seg, OFF_COMMAND_RING, layout.command_ring)
    _set_u64!(seg, OFF_CHANNELS, layout.channels)
    _set_u64!(seg, OFF_CHANNEL_STRIDE, layout.channel_stride)
    _set_u64!(seg, OFF_TOTAL_BYTES, layout.total)
    for (i, band) in enumerate(config.bands)
        unsafe_store!(Ptr{BandEntry}(seg.base + OFF_BAND_TABLE + (i - 1) * BAND_ENTRY_BYTES), band)
    end
    _init_ring!(seg.base + layout.command_ring, config.command_capacity, COMMAND_SLOT_BYTES)
    for channel = 1:config.channel_count
        base = seg.base + layout.channels + (channel - 1) * layout.channel_stride
        _init_ring!(base, config.event_capacity, EVENT_SLOT_BYTES)
        _init_snapshot!(base + RING_HEADER_BYTES + config.event_capacity * EVENT_SLOT_BYTES)
    end
    store_relaxed!(u64ptr(seg.base, OFF_LOOP_STATE), LOOP_STATE_STARTING)
    fence_release()
    # The magic last: a reader that sees it sees a complete header.
    store_release!(u64ptr(seg.base, OFF_MAGIC), MAGIC)
    nothing
end

"""
    create_segment(path, config::SegmentConfig) -> Segment

Create (or re-create) the segment at `path` — a file, conventionally
`/dev/shm/gnss-loop-<device>` — sized and laid out for `config`, with every
ring empty and the header written last. This is the loop process's side. Pass
`nothing` for `path` to back the segment with a heap buffer instead, for the
in-process transport and the tests.
"""
function create_segment(path::Union{Nothing,AbstractString}, config::SegmentConfig)
    _check_geometry()
    layout = Layout(config)
    if isnothing(path)
        backing = zeros(UInt8, layout.total + PAGE)
        # Page-align the base so the atomics' alignment assumptions hold.
        raw = pointer(backing)
        base = Ptr{UInt8}(align(UInt(raw), PAGE))
        seg = Segment(base, layout.total, "", Cint(-1), true, backing, true)
    else
        fd = _open_file(String(path), O_RDWR | O_CREAT)
        rc = ccall(:ftruncate, Cint, (Cint, Int64), fd, layout.total)
        rc == 0 || (ccall(:close, Cint, (Cint,), fd); systemerror("ftruncate($path)", Libc.errno()))
        base = _mmap(fd, layout.total)
        seg = Segment(base, layout.total, String(path), fd, true, nothing, true)
    end
    _write_header!(seg, config, layout)
    seg
end

"""
    attach_segment(path) -> Segment

Map the segment at `path` and verify its header: magic, protocol version and
layout hash must match this package's, or an `ArgumentError` names what did
not. This is the receiver's side.
"""
function attach_segment(path::AbstractString)
    _check_geometry()
    fd = _open_file(String(path), O_RDWR)
    bytes = _file_size(fd)
    if bytes < HEADER_BYTES
        ccall(:close, Cint, (Cint,), fd)
        throw(ArgumentError("$path is $bytes bytes, too small to hold a segment header"))
    end
    base = _mmap(fd, bytes)
    seg = Segment(base, bytes, String(path), fd, false, nothing, true)
    try
        _verify_header(seg)
    catch
        close(seg)
        rethrow()
    end
    seg
end

function _verify_header(seg::Segment)
    magic = load_acquire(u64ptr(seg.base, OFF_MAGIC))
    magic == MAGIC || throw(
        ArgumentError(
            "$(seg.path) does not carry a hardware-loop segment (magic $(repr(magic)))",
        ),
    )
    version = _u32(seg, OFF_VERSION)
    version == PROTOCOL_VERSION || throw(
        ArgumentError(
            "$(seg.path) speaks protocol version $version; this package speaks $PROTOCOL_VERSION",
        ),
    )
    hash = _u64(seg, OFF_LAYOUT_HASH)
    hash == layout_hash() || throw(
        ArgumentError(
            "$(seg.path) was written with another record layout (hash $(repr(hash)) vs " *
            "$(repr(layout_hash()))); rebuild both sides against the same HardwareLoopProtocol",
        ),
    )
    total = Int(_u64(seg, OFF_TOTAL_BYTES))
    total <= seg.bytes || throw(
        ArgumentError("$(seg.path) header claims $total bytes but the file holds $(seg.bytes)"),
    )
    _u32(seg, OFF_EVENT_SLOT_BYTES) == EVENT_SLOT_BYTES &&
        _u32(seg, OFF_COMMAND_SLOT_BYTES) == COMMAND_SLOT_BYTES ||
        throw(ArgumentError("$(seg.path) uses other slot sizes than this package"))
    nothing
end

"Whether a segment file exists at `path`."
segment_exists(path::AbstractString) = isfile(path)

"""
    open_or_attach_segment(path, config; stale_after_ns) -> (segment, attached::Bool)

Attach to the segment at `path` if one exists whose loop heartbeat is younger
than `stale_after_ns`, otherwise create a fresh one for `config`. Returns the
segment and whether it was attached (`true`) or created (`false`).
"""
function open_or_attach_segment(path::AbstractString, config::SegmentConfig; stale_after_ns = 500_000_000)
    if segment_exists(path)
        seg = try
            attach_segment(path)
        catch
            nothing
        end
        if !isnothing(seg)
            heartbeat_alive(seg, :loop; stale_after_ns) && return (seg, true)
            close(seg)
        end
    end
    (create_segment(path, config), false)
end

function Base.close(seg::Segment)
    seg.open || return nothing
    seg.open = false
    if isnothing(seg.backing)
        _munmap(seg.base, seg.bytes)
        ccall(:close, Cint, (Cint,), seg.fd)
    else
        seg.backing = nothing
    end
    seg.base = Ptr{UInt8}(0)
    nothing
end

"""
    unlink_segment(path)

Remove the segment file. The loop process does this when it shuts down cleanly;
a receiver never does.
"""
unlink_segment(path::AbstractString) = (isfile(path) && rm(path); nothing)

# ── Rings and snapshots inside the segment ───────────────────────────────────

"The command ring (receiver → loop)."
command_ring(seg::Segment) = _ring_at(seg.base + Int(_u64(seg, OFF_COMMAND_RING)))

@inline function _channel_base(seg::Segment, channel::Integer)
    1 <= channel <= channel_count(seg) ||
        throw(ArgumentError("channel $channel is outside 1:$(channel_count(seg))"))
    seg.base + Int(_u64(seg, OFF_CHANNELS)) + (channel - 1) * Int(_u64(seg, OFF_CHANNEL_STRIDE))
end

"Hardware channel `channel`'s event ring (loop → receiver)."
event_ring(seg::Segment, channel::Integer) = _ring_at(_channel_base(seg, channel))

"Hardware channel `channel`'s epoch-state snapshot."
snapshot_slot(seg::Segment, channel::Integer) = SnapshotSlot(
    _channel_base(seg, channel) + RING_HEADER_BYTES + event_capacity(seg) * EVENT_SLOT_BYTES,
)

# ── Heartbeats, state and pids ───────────────────────────────────────────────

"Stamp the loop process's heartbeat with `time_ns()` (monotonic within the host)."
loop_heartbeat!(seg::Segment, now_ns = time_ns()) =
    store_release!(u64ptr(seg.base, OFF_LOOP_HEARTBEAT), UInt64(now_ns))
"Stamp the receiver's heartbeat."
receiver_heartbeat!(seg::Segment, now_ns = time_ns()) =
    store_release!(u64ptr(seg.base, OFF_RECEIVER_HEARTBEAT), UInt64(now_ns))
loop_heartbeat(seg::Segment) = load_acquire(u64ptr(seg.base, OFF_LOOP_HEARTBEAT))
receiver_heartbeat(seg::Segment) = load_acquire(u64ptr(seg.base, OFF_RECEIVER_HEARTBEAT))

"""
    heartbeat_alive(seg, side; stale_after_ns = 500_000_000, now_ns = time_ns()) -> Bool

Whether `side` (`:loop` or `:receiver`) has heartbeated within `stale_after_ns`.
A heartbeat of zero (never stamped) is not alive.
"""
function heartbeat_alive(seg::Segment, side::Symbol; stale_after_ns = 500_000_000, now_ns = time_ns())
    beat = side === :loop ? loop_heartbeat(seg) : receiver_heartbeat(seg)
    beat == 0 && return false
    Int64(now_ns) - Int64(beat) <= Int64(stale_after_ns)
end

loop_state(seg::Segment) = load_acquire(u64ptr(seg.base, OFF_LOOP_STATE))
set_loop_state!(seg::Segment, state::Integer) =
    store_release!(u64ptr(seg.base, OFF_LOOP_STATE), UInt64(state))
loop_pid(seg::Segment) = Int(_u64(seg, OFF_LOOP_PID))
receiver_pid(seg::Segment) = Int(_u64(seg, OFF_RECEIVER_PID))
set_loop_pid!(seg::Segment, pid::Integer) = _set_u64!(seg, OFF_LOOP_PID, pid)
set_receiver_pid!(seg::Segment, pid::Integer) = _set_u64!(seg, OFF_RECEIVER_PID, pid)
