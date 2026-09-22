# ─────────────────────────────────────────────────────────────────────────────
# The records that cross the boundary. Every one of them is `isbits`, has a
# C-compatible layout with explicit padding, and is written and read with
# `unsafe_store!` / `unsafe_load` on the mapped memory — no conversion, no
# allocation. Field order and sizes are part of the wire contract; the layout
# hash in the header is computed from them (see `layout.jl`).
# ─────────────────────────────────────────────────────────────────────────────

"The protocol revision. A segment whose header carries another is refused."
const PROTOCOL_VERSION = UInt32(1)

"Bytes reserved for a fixed-length ASCII name (a signal or group id)."
const NAME_BYTES = 24

"""
    FixedName(s)

A fixed-length, zero-padded ASCII name — how a `Symbol` such as `:GPSL1CA` or a
tracking-group key crosses the segment, since neither side can share a symbol
table. `String(name)` / `Symbol(name)` recover it; a name longer than
`NAME_BYTES` is an `ArgumentError` when built on the receiver side.
"""
struct FixedName
    bytes::NTuple{NAME_BYTES,UInt8}
end

function FixedName(s::Union{AbstractString,Symbol})
    str = String(s)
    ncodeunits(str) <= NAME_BYTES ||
        throw(ArgumentError("name $(repr(str)) is longer than $NAME_BYTES bytes"))
    codes = codeunits(str)
    FixedName(ntuple(i -> i <= length(codes) ? codes[i] : 0x00, NAME_BYTES))
end

FixedName() = FixedName(ntuple(_ -> 0x00, NAME_BYTES))

function Base.length(n::FixedName)
    len = 0
    for b in n.bytes
        b == 0x00 && break
        len += 1
    end
    len
end

Base.String(n::FixedName) = String(UInt8[n.bytes[i] for i = 1:length(n)])
Base.Symbol(n::FixedName) = Symbol(String(n))
Base.isempty(n::FixedName) = n.bytes[1] == 0x00
Base.:(==)(a::FixedName, b::FixedName) = a.bytes == b.bytes

# ── Events (loop → receiver) ─────────────────────────────────────────────────

"A completed correlator record, folded by the loop."
const EVENT_RECORD = UInt8(1)
"One navigation soft bit."
const EVENT_BIT = UInt8(2)
"The newest epoch state of a channel (also mirrored into the snapshot slot)."
const EVENT_EPOCH_STATE = UInt8(3)
"A command acknowledgement or a channel/loop status change."
const EVENT_STATUS = UInt8(4)
"The full correlator taps of one record (only when enabled for the channel)."
const EVENT_TAPS = UInt8(5)

"""
    EventTag

The 16-byte tag every event carries after its sequence word: what kind of event
it is, which hardware channel, band and satellite it belongs to, and the device
sample it refers to (a record's end, an epoch boundary, the sample a status
change took effect at).
"""
struct EventTag
    kind::UInt8
    band::UInt8
    channel::UInt16
    prn::UInt16
    signal_index::UInt8
    num_taps::UInt8
    device_sample::Int64
end

EventTag(kind, channel, device_sample; band = 1, prn = 0, signal_index = 1, num_taps = 0) =
    EventTag(
        UInt8(kind),
        UInt8(band),
        UInt16(channel),
        UInt16(prn),
        UInt8(signal_index),
        UInt8(num_taps),
        Int64(device_sample),
    )

# Record flags.
"The record was correlated before the sync the same fold established."
const RECORD_PRE_SYNC = UInt32(1)
"The record's secondary (overlay) code was removed by the loop."
const RECORD_OVERLAY_WIPED = UInt32(2)
"The first record after the channel was (re)armed."
const RECORD_FIRST_AFTER_ARM = UInt32(4)
"The record's C/N₀ field is meaningful (a noise density was available)."
const RECORD_HAS_CN0 = UInt32(8)

"""
    RecordEvent

What `Tracking._apply_correlator_output` needs of a record and nothing more —
the complete history the receiver's lock detectors and decoder rest on: the
filtered prompt, the record's length, the blocks it credits to the bit clock,
the C/N₀ after it, and the NCO words it really ran under.
"""
struct RecordEvent
    prompt::ComplexF64
    integrated_samples::Int64
    block_credit::Int32
    flags::UInt32
    cn0_linear_hz::Float64
    applied_carrier_hz::Float64
    applied_code_hz::Float64
end

"""
    BitEvent

One navigation soft bit as the bit buffer emitted it: its sign is the hard
decision, its magnitude the confidence. `bit_index` counts bits since the
channel's bit clock was last (re)started.
"""
struct BitEvent
    soft_bit::Float32
    polarity::Int8
    pad1::UInt8
    pad2::UInt16
    bit_index::Int64
end

BitEvent(soft_bit, polarity, bit_index) =
    BitEvent(Float32(soft_bit), Int8(polarity), 0x00, 0x0000, Int64(bit_index))

# Epoch-state flags.
const STATE_SYNC_FOUND = UInt8(1)
const STATE_BIT_PHASE_ANCHORED = UInt8(2)
const STATE_CODE_PHASE_ANCHORED = UInt8(4)
const STATE_OBSERVATION_ONLY = UInt8(8)   # the fold stepped C/N₀ and bits only (stale backlog)

"""
    EpochStateEvent

"Newest wins": the channel's loop state at the common fold boundary the tag's
`device_sample` names — the Dopplers, the absolute code phase referenced to that
boundary, the carrier phase, the sync state and block count, and the NCO words
in effect. PVT and the dashboard read this; the same value is written into the
channel's snapshot slot.
"""
struct EpochStateEvent
    carrier_doppler_hz::Float64
    code_doppler_hz::Float64
    code_phase_chips::Float64
    carrier_phase_cycles::Float64
    cn0_linear_hz::Float64
    nco_carrier_hz::Float64
    nco_code_hz::Float64
    landing_sample::Int64
    block_count::Int32
    secondary_phase::Int16
    polarity::Int8
    flags::UInt8
end

# Status codes.
const STATUS_ARMED = UInt32(1)
const STATUS_ARM_REJECTED = UInt32(2)
const STATUS_RELEASED = UInt32(3)
const STATUS_HISTORY_LOST = UInt32(4)
const STATUS_BIT_CLOCK_RESTART = UInt32(5)
const STATUS_CHANNEL_STATE = UInt32(6)
const STATUS_CONFIGURED = UInt32(7)
const STATUS_SHUTDOWN = UInt32(8)
const STATUS_DEVICE_FAULT = UInt32(9)
const STATUS_COMMAND_REJECTED = UInt32(10)

# Rejection reasons.
const REJECT_NONE = UInt32(0)
const REJECT_NO_SUCH_CHANNEL = UInt32(1)
const REJECT_CHANNEL_BUSY = UInt32(2)
const REJECT_UNSUPPORTED_SIGNAL = UInt32(3)
const REJECT_BAD_CONFIG = UInt32(4)
const REJECT_DEVICE_ERROR = UInt32(5)
const REJECT_UNKNOWN_COMMAND = UInt32(6)
const REJECT_NOT_ARMED = UInt32(7)

"""
    StatusEvent

A command acknowledgement ("armed at device sample S", "rejected, reason R") or
a channel or loop status change. `sequence` is the command's sequence number
for an acknowledgement, or the event sequence from which history was lost for
`STATUS_HISTORY_LOST`. `STATUS_CHANNEL_STATE` carries the full seed a receiver
needs to adopt the channel's satellite after re-attaching: signal, group,
PRN, Dopplers and code phase at `sample`.
"""
struct StatusEvent
    code::UInt32
    reason::UInt32
    sample::Int64
    sequence::UInt64
    carrier_doppler_hz::Float64
    code_doppler_hz::Float64
    code_phase_chips::Float64
    signal::FixedName
    group_key::FixedName
end

StatusEvent(code, reason, sample, sequence) = StatusEvent(
    UInt32(code),
    UInt32(reason),
    Int64(sample),
    UInt64(sequence),
    0.0,
    0.0,
    0.0,
    FixedName(),
    FixedName(),
)

"How many taps × antennas a `TapsEvent` can carry."
const MAX_TAP_VALUES = 10

"""
    TapsEvent

The full correlator accumulators of one record, latest tap first, antenna-major
(`taps[(antenna - 1) * num_taps + tap]`), on the host's amplitude scale. Only
published for channels configured with `want_taps` (the dashboard, a replay
recording, a future vector-tracking path).
"""
struct TapsEvent
    taps::NTuple{MAX_TAP_VALUES,ComplexF64}
    integrated_samples::Int64
end

# ── Commands (receiver → loop) ───────────────────────────────────────────────

const COMMAND_ARM = UInt8(1)
const COMMAND_RELEASE = UInt8(2)
const COMMAND_CONFIGURE = UInt8(3)
const COMMAND_SHUTDOWN = UInt8(4)
const COMMAND_QUERY_STATE = UInt8(5)

"""
    CommandTag

The 16-byte tag every command carries: its kind, the channel it addresses (0
for the whole loop) and the receiver's sequence number, which the acknowledging
status event echoes.
"""
struct CommandTag
    kind::UInt8
    pad::UInt8
    channel::UInt16
    pad2::UInt32
    sequence::UInt64
end

CommandTag(kind, channel, sequence) =
    CommandTag(UInt8(kind), 0x00, UInt16(channel), 0x00000000, UInt64(sequence))

"The device replicates the primary code only; the loop removes the overlay."
const SECONDARY_PRIMARY_ONLY = UInt8(0)
"The device removes the overlay itself (reserved, never requested today)."
const SECONDARY_WIPEOFF = UInt8(1)

"""
    ArmCommand

"Arm channel k with this configuration": GNSSReceiver's `HardwareChannelConfig`
with every Julia object replaced by a plain value — the signal and group ids as
fixed names, the tap offsets as a fixed tuple. The loop *executes* the arm; the
allocation policy stays with the receiver.

`carrier_loop_bandwidth_hz` / `code_loop_bandwidth_hz` of `0` mean the signal's
defaults. `valid_at_sample` is on the channel's band counter, like every sample
in this protocol.
"""
struct ArmCommand
    signal::FixedName
    group_key::FixedName
    prn::Int32
    signal_index::Int32
    carrier_doppler_hz::Float64
    code_doppler_hz::Float64
    code_phase_chips::Float64
    valid_at_sample::Int64
    tap_sample_shifts::NTuple{5,Int32}
    num_taps::Int32
    el_sample_spacing::Int32
    band::Int32
    replica_amplitude::Float64
    code_amplitude::Float64
    carrier_phase_offset::Float64
    sampling_freq_hz::Float64
    carrier_loop_bandwidth_hz::Float64
    code_loop_bandwidth_hz::Float64
    secondary_code_mode::UInt8
    rf_input::UInt8
    device_index::UInt8
    want_taps::UInt8
    pad::UInt32
end

"""
    ConfigureCommand

Loop-wide configuration: the fold epoch, the feedback delay, the coherent
accumulation ceiling, the record integration ceiling and which events are
published. Zero leaves a field unchanged.
"""
struct ConfigureCommand
    epoch_length_samples::Int64
    feedback_delay_epochs::Int32
    coherent_code_blocks::Int32
    max_integration_time_s::Float64
    noise_rearm_epochs::Int32
    event_flags::UInt32
    max_backlog_epochs::Int32
    pad::UInt32
end

"Publish `TapsEvent`s for every armed channel."
const EVENTS_TAPS = UInt32(1)

"Release channel k. Carries nothing beyond its tag."
struct ReleaseCommand
    pad::UInt64
end
ReleaseCommand() = ReleaseCommand(0)

"Stop the loop process. Carries nothing beyond its tag."
struct ShutdownCommand
    pad::UInt64
end
ShutdownCommand() = ShutdownCommand(0)

"Ask for a `STATUS_CHANNEL_STATE` event on every armed channel (adoption)."
struct QueryStateCommand
    pad::UInt64
end
QueryStateCommand() = QueryStateCommand(0)

# ── The band table ───────────────────────────────────────────────────────────

"""
    BandEntry

One RF band the loop process serves: its id, the rate its channels' sample
counters run at, and the RF input and device it arrives on. Written by the loop
process, checked by the receiver against its own band plan.
"""
struct BandEntry
    band_id::FixedName
    sampling_freq_hz::Float64
    rf_input::Int32
    device_index::Int32
    pad::NTuple{3,UInt64}
end

BandEntry(band_id, sampling_freq_hz; rf_input = 1, device_index = 1) = BandEntry(
    FixedName(band_id),
    Float64(sampling_freq_hz),
    Int32(rf_input),
    Int32(device_index),
    (0, 0, 0),
)

Base.:(==)(a::BandEntry, b::BandEntry) =
    a.band_id == b.band_id &&
    a.sampling_freq_hz == b.sampling_freq_hz &&
    a.rf_input == b.rf_input &&
    a.device_index == b.device_index
