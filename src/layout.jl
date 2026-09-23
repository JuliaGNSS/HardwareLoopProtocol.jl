# ─────────────────────────────────────────────────────────────────────────────
# Where everything sits in the segment.
#
#   [0, 4096)            header: fixed fields, heartbeats, band table
#   [4096, …)            the command ring (receiver → loop)
#   then, per channel:   the event ring (loop → receiver) and the snapshot slot
#
# Every region starts on a 64-byte line, rings on a 4 KiB page. Offsets are
# written into the header by the creator and read back by whoever attaches, so
# a receiver never recomputes a layout it did not create — it checks the hash
# and reads the offsets.
# ─────────────────────────────────────────────────────────────────────────────

const HEADER_BYTES = 4096
const RING_HEADER_BYTES = 128
const SNAPSHOT_BYTES = 256
const MAX_BANDS = 8
const CACHE_LINE = 64
const PAGE = 4096

# "GNSSLOOP" as a little-endian UInt64.
const MAGIC = 0x504F4F4C5353_4E47

# Header field offsets. Plain fields are written once by the creator and are
# immutable afterwards; the atomically updated ones each own a cache line.
const OFF_MAGIC = 0
const OFF_VERSION = 8
const OFF_LAYOUT_HASH = 16
const OFF_CHANNEL_COUNT = 24
const OFF_BAND_COUNT = 28
const OFF_EVENT_CAPACITY = 32
const OFF_COMMAND_CAPACITY = 36
const OFF_EVENT_SLOT_BYTES = 40
const OFF_COMMAND_SLOT_BYTES = 44
const OFF_DEVICE_INDEX = 48
const OFF_COMMAND_RING = 56
const OFF_CHANNELS = 64
const OFF_CHANNEL_STRIDE = 72
const OFF_TOTAL_BYTES = 80
const OFF_LOOP_HEARTBEAT = 1024
const OFF_LOOP_STATE = 1088
const OFF_RECEIVER_HEARTBEAT = 1152
const OFF_LOOP_PID = 1216
const OFF_RECEIVER_PID = 1280
const OFF_BAND_TABLE = 2048
const BAND_ENTRY_BYTES = 64

# Loop states.
const LOOP_STATE_STARTING = UInt64(0)
const LOOP_STATE_RUNNING = UInt64(1)
const LOOP_STATE_STOPPING = UInt64(2)
const LOOP_STATE_STOPPED = UInt64(3)
const LOOP_STATE_FAULT = UInt64(4)

# Slot geometry: a sequence word, a 16-byte tag, then the payload.
const SLOT_SEQ_BYTES = 8
const SLOT_TAG_BYTES = 16
const SLOT_PAYLOAD_OFFSET = SLOT_SEQ_BYTES + SLOT_TAG_BYTES
const EVENT_SLOT_BYTES = 192
const COMMAND_SLOT_BYTES = 256

const EVENT_PAYLOAD_BYTES = EVENT_SLOT_BYTES - SLOT_PAYLOAD_OFFSET
const COMMAND_PAYLOAD_BYTES = COMMAND_SLOT_BYTES - SLOT_PAYLOAD_OFFSET

align(n::Integer, a::Integer) = (n + a - 1) ÷ a * a

"""
    SegmentConfig(; channel_count, bands, event_capacity, command_capacity, device_index)

What a loop process creates a segment for: how many hardware channels, which
bands (a vector of [`BandEntry`](@ref)s, the first one the reference band),
and how deep the rings are. Capacities are rounded up to powers of two; the
event capacity defaults to 8192 per channel, eight seconds of records at a
1 kHz fold rate.
"""
struct SegmentConfig
    channel_count::Int
    bands::Vector{BandEntry}
    event_capacity::Int
    command_capacity::Int
    device_index::Int
end

function SegmentConfig(;
    channel_count::Integer,
    bands::AbstractVector{BandEntry},
    event_capacity::Integer = 8192,
    command_capacity::Integer = 256,
    device_index::Integer = 1,
)
    channel_count >= 1 || throw(ArgumentError("channel_count must be at least 1"))
    channel_count <= typemax(UInt16) || throw(ArgumentError("too many channels"))
    1 <= length(bands) <= MAX_BANDS ||
        throw(ArgumentError("between 1 and $MAX_BANDS bands are supported"))
    event_capacity >= 2 || throw(ArgumentError("event_capacity must be at least 2"))
    command_capacity >= 2 || throw(ArgumentError("command_capacity must be at least 2"))
    SegmentConfig(
        Int(channel_count),
        collect(BandEntry, bands),
        nextpow(2, Int(event_capacity)),
        nextpow(2, Int(command_capacity)),
        Int(device_index),
    )
end

# The layout as a set of plain integers: where each region starts and how large
# the whole thing is.
struct Layout
    command_ring::Int
    channels::Int
    channel_stride::Int
    total::Int
end

function Layout(config::SegmentConfig)
    command_ring = HEADER_BYTES
    command_bytes = align(RING_HEADER_BYTES + config.command_capacity * COMMAND_SLOT_BYTES, PAGE)
    channels = command_ring + command_bytes
    channel_stride =
        align(RING_HEADER_BYTES + config.event_capacity * EVENT_SLOT_BYTES + SNAPSHOT_BYTES, PAGE)
    total = channels + config.channel_count * channel_stride
    Layout(command_ring, channels, channel_stride, total)
end

# FNV-1a over the record geometry, so a segment written by one build of this
# package is refused by another whose structs differ. Deliberately not
# `Base.hash`: the two processes need not run the same Julia version. Mixed in
# one value at a time — no splatting — so `--trim=safe` can resolve every call.
@inline function _fnv1a_mix(h::UInt64, v::Integer)
    x = UInt64(v)
    for shift = 0:8:56
        h = (h ⊻ ((x >> shift) & 0xff)) * 0x00000100000001b3
    end
    h
end

function _hash_struct(h::UInt64, ::Type{T}) where {T}
    h = _fnv1a_mix(h, sizeof(T))
    h = _fnv1a_mix(h, fieldcount(T))
    for i = 1:fieldcount(T)
        h = _fnv1a_mix(h, fieldoffset(T, i))
    end
    h
end

"""
    layout_hash() -> UInt64

The hash of every record's size and field offsets plus the ring geometry. A
receiver built against different definitions than the loop process refuses the
segment instead of misreading it.
"""
function layout_hash()
    h = 0xcbf29ce484222325
    h = _fnv1a_mix(h, PROTOCOL_VERSION)
    h = _fnv1a_mix(h, HEADER_BYTES)
    h = _fnv1a_mix(h, RING_HEADER_BYTES)
    h = _fnv1a_mix(h, SNAPSHOT_BYTES)
    h = _fnv1a_mix(h, EVENT_SLOT_BYTES)
    h = _fnv1a_mix(h, COMMAND_SLOT_BYTES)
    h = _fnv1a_mix(h, NAME_BYTES)
    h = _hash_struct(h, EventTag)
    h = _hash_struct(h, RecordEvent)
    h = _hash_struct(h, BitEvent)
    h = _hash_struct(h, EpochStateEvent)
    h = _hash_struct(h, StatusEvent)
    h = _hash_struct(h, TapsEvent)
    h = _hash_struct(h, CommandTag)
    h = _hash_struct(h, ArmCommand)
    h = _hash_struct(h, ConfigureCommand)
    h = _hash_struct(h, BandEntry)
    h
end

# Every payload has to fit its slot, and every tag its 16 bytes. Checked once at
# load; a violation is a programming error in this package.
function _check_geometry()
    sizeof(EventTag) == SLOT_TAG_BYTES || error("EventTag must be $SLOT_TAG_BYTES bytes")
    sizeof(CommandTag) == SLOT_TAG_BYTES || error("CommandTag must be $SLOT_TAG_BYTES bytes")
    for T in (RecordEvent, BitEvent, EpochStateEvent, StatusEvent, TapsEvent)
        sizeof(T) <= EVENT_PAYLOAD_BYTES ||
            error("$T ($(sizeof(T)) bytes) does not fit an event slot's $EVENT_PAYLOAD_BYTES-byte payload")
        isbitstype(T) || error("$T must be isbits")
    end
    for T in (ArmCommand, ConfigureCommand, ReleaseCommand, ShutdownCommand, QueryStateCommand)
        sizeof(T) <= COMMAND_PAYLOAD_BYTES ||
            error("$T ($(sizeof(T)) bytes) does not fit a command slot's $COMMAND_PAYLOAD_BYTES-byte payload")
        isbitstype(T) || error("$T must be isbits")
    end
    sizeof(BandEntry) == BAND_ENTRY_BYTES || error("BandEntry must be $BAND_ENTRY_BYTES bytes")
    sizeof(EpochStateEvent) <= SNAPSHOT_BYTES - 8 || error("EpochStateEvent does not fit the snapshot")
    nothing
end
