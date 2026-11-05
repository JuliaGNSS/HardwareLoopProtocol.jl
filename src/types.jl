# ─────────────────────────────────────────────────────────────────────────────
# The records that cross the boundary. Every one of them is `isbits`, has a
# C-compatible layout with explicit padding, and is written and read with
# `unsafe_store!` / `unsafe_load` on the mapped memory — no conversion, no
# allocation. Field order and sizes are part of the wire contract; the layout
# hash in the header is computed from them (see `layout.jl`).
# ─────────────────────────────────────────────────────────────────────────────

"The protocol revision. A segment whose header carries another is refused."
const PROTOCOL_VERSION = UInt32(4)

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
    FixedName(ntuple(i -> i <= length(codes) ? codes[i] : 0x00, Val(NAME_BYTES)))
end

FixedName() = FixedName(ntuple(_ -> 0x00, Val(NAME_BYTES)))

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

"A predetection integration the loop has processed and stepped its tracking loop on."
const EVENT_INTEGRATION = UInt8(1)
"One navigation soft bit."
const EVENT_BIT = UInt8(2)
"The newest loop state of a channel (also mirrored into the snapshot slot)."
const EVENT_LOOP_STATE = UInt8(3)
"A command acknowledgement or a channel/loop status change."
const EVENT_STATUS = UInt8(4)
"The correlator outputs of one integration (only when enabled for the channel)."
const EVENT_CORRELATOR_OUTPUTS = UInt8(5)
"A navigation solution, on the loop-wide nav ring (also mirrored into the nav snapshot)."
const EVENT_NAV_SOLUTION = UInt8(6)
"One satellite as a navigation cycle saw it, on the loop-wide nav ring."
const EVENT_NAV_SATELLITE = UInt8(7)

"""
    EventTag

The 16-byte tag every event carries after its sequence word: what kind of event
it is, which hardware channel, band and satellite it belongs to, and the sample
index on the band's device sample counter it refers to (an integration's end,
an NCO update boundary, the sample a status change took effect at).
"""
struct EventTag
    kind::UInt8
    band::UInt8
    channel::UInt16
    prn::UInt16
    signal_index::UInt8
    num_correlators::UInt8
    sample_index::Int64
end

EventTag(kind, channel, sample_index; band = 1, prn = 0, signal_index = 1, num_correlators = 0) =
    EventTag(
        UInt8(kind),
        UInt8(band),
        UInt16(channel),
        UInt16(prn),
        UInt8(signal_index),
        UInt8(num_correlators),
        Int64(sample_index),
    )

# Integration flags.
"The loop wiped the secondary code off the integration's prompt."
const INTEGRATION_SECONDARY_CODE_WIPED = UInt32(2)
"The first integration after the channel was (re)armed."
const INTEGRATION_FIRST_AFTER_ARM = UInt32(4)
"The integration's C/N₀ field is meaningful (a noise density was available)."
const INTEGRATION_HAS_CN0 = UInt32(8)

"""
    IntegrationEvent

One predetection integration, as TrackingLoops' `process_correlator_bank_output!`
returned it — the device's dumps summed into one coherent integration — with
what the receiver's lock detectors and decoder rest on and nothing more: the
filtered prompt, the samples integrated, the code periods they span, the C/N₀
after it, and the mean NCO command (carrier and code Doppler) the device really
ran it under, as TrackingLoops' `calc_mean_nco_command` gives it.
"""
struct IntegrationEvent
    prompt::ComplexF64
    num_integrated_samples::Int64
    num_code_periods::Int32
    flags::UInt32
    cn0_hz::Float64
    mean_nco_carrier_doppler_hz::Float64
    mean_nco_code_doppler_hz::Float64
end

"""
    BitEvent

One navigation soft bit as the bit synchronizer emitted it: its sign is the
hard decision, its magnitude the confidence; `bit_polarity` is the polarity
the synchronizer resolved. `bit_index` counts bits since the channel's bit
synchronizer was last reset (`STATUS_SYNC_RESET`).
"""
struct BitEvent
    soft_bit::Float32
    bit_polarity::Int8
    pad1::UInt8
    pad2::UInt16
    bit_index::Int64
end

BitEvent(soft_bit, bit_polarity, bit_index) =
    BitEvent(Float32(soft_bit), Int8(bit_polarity), 0x00, 0x0000, Int64(bit_index))

# Loop-state flags.
"The bit synchronizer has found the bit edge or the secondary code phase."
const STATE_BIT_OR_SECONDARY_CODE_SYNCED = UInt8(1)
"`code_phase_chips` counts from the last bit edge (or secondary code start), not only from the last primary code period."
const STATE_BIT_EDGE_KNOWN = UInt8(2)
"`code_phase_chips` is referenced to the NCO update boundary the tag names."
const STATE_CODE_PHASE_KNOWN = UInt8(4)
"The loop filters were not stepped this NCO update (a stale backlog): only C/N₀ and the bits advanced."
const STATE_LOOP_OPEN = UInt8(8)

"""
    LoopStateEvent

"Newest wins": the channel's loop state at the common NCO update boundary the tag's
`sample_index` names — the Dopplers, the absolute code phase referenced to that
boundary, the carrier phase, the sync state and the code periods into the
current bit, and the NCO command in effect, which the next command replaces at
`application_sample_index`. PVT and the dashboard read this; the same value is
written into the channel's snapshot slot.
"""
struct LoopStateEvent
    carrier_doppler_hz::Float64
    code_doppler_hz::Float64
    code_phase_chips::Float64
    carrier_phase_cycles::Float64
    cn0_hz::Float64
    nco_carrier_doppler_hz::Float64
    nco_code_doppler_hz::Float64
    application_sample_index::Int64
    num_code_periods_into_bit::Int32
    secondary_code_phase::Int16
    bit_polarity::Int8
    flags::UInt8
end

# Status codes.
const STATUS_ARMED = UInt32(1)
const STATUS_ARM_REJECTED = UInt32(2)
const STATUS_RELEASED = UInt32(3)
const STATUS_HISTORY_LOST = UInt32(4)
const STATUS_SYNC_RESET = UInt32(5)
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

A command acknowledgement ("armed at sample index S", "rejected, reason R") or
a channel or loop status change. `sequence` is the command's sequence number
for an acknowledgement, or the event sequence from which history was lost for
`STATUS_HISTORY_LOST`. `STATUS_CHANNEL_STATE` carries the full seed a receiver
needs to adopt the channel's satellite after re-attaching: signal, group,
PRN, Dopplers and code phase at `sample_index`.
"""
struct StatusEvent
    code::UInt32
    reason::UInt32
    sample_index::Int64
    sequence::UInt64
    carrier_doppler_hz::Float64
    code_doppler_hz::Float64
    code_phase_chips::Float64
    signal::FixedName
    group_key::FixedName
end

StatusEvent(code, reason, sample_index, sequence) = StatusEvent(
    UInt32(code),
    UInt32(reason),
    Int64(sample_index),
    UInt64(sequence),
    0.0,
    0.0,
    0.0,
    FixedName(),
    FixedName(),
)

"How many correlators × antennas a `CorrelatorOutputsEvent` can carry."
const MAX_CORRELATOR_OUTPUTS = 10

"""
    CorrelatorOutputsEvent

The correlator outputs of one integration, from the latest to the earliest replica,
antenna-major (`correlator_outputs[(antenna - 1) * num_correlators + correlator]`), on
the host's amplitude scale. Only published for channels configured with
`want_correlator_outputs` (the dashboard, a replay recording).
"""
struct CorrelatorOutputsEvent
    correlator_outputs::NTuple{MAX_CORRELATOR_OUTPUTS,ComplexF64}
    num_integrated_samples::Int64
end

# ── Navigation (loop → receiver, loop-wide) ──────────────────────────────────

"The loop computes no navigation solution: the receiver decodes the bits and solves it."
const NAV_NONE = UInt8(0)
"The loop runs vector tracking and publishes its solution on the nav ring."
const NAV_VECTOR = UInt8(1)

# Navigation-solution flags.
"Vector tracking is running after this cycle."
const NAV_RUNNING = UInt32(1)
"The solution is the navigation filter's, not a scalar fix (TrackingLoops' `solution_from_filter`)."
const NAV_SOLUTION_FROM_FILTER = UInt32(2)
"Vector tracking stopped in this cycle."
const NAV_FELL_BACK = UInt32(4)
"This cycle released at least one satellite from the vector loop."
const NAV_RELEASED = UInt32(8)
"The solution holds a position (the solver has produced a fix)."
const NAV_VALID = UInt32(16)
"`time_tai_s` and `time_tai_frac` hold the solution's time."
const NAV_TIME_VALID = UInt32(32)

"""
    NavSolutionEvent

One navigation cycle's solution, the last event of the cycle on the nav ring
and the value in the nav snapshot. The tag's `channel` is 0 (loop-wide) and its
`sample_index` the cycle's sample index on the reference band's counter.

  - `cycle_index` — the tracking loop's navigation-cycle index;
  - `position_ecef_m`, `velocity_ecef_mps` — ECEF, metres and metres per second;
  - `clock_drift_mps` — the receiver clock drift in m/s, as PositionVelocityTime
    gives it. No clock bias is published: the solution's time is the receiver
    clock corrected. Inter-system and inter-frequency biases are not published
    either;
  - `time_tai_s`, `time_tai_frac` — the solution's time as whole TAI seconds
    since J2000 and the fraction of the second, meaningful with `NAV_TIME_VALID`;
  - `position_std_m`, `clock_bias_std_m` — the filter's 1σ uncertainties (`NaN`
    while it is not running), `measurement_deficit_duration_s` its coasting time;
  - `dop` — GDOP, PDOP, HDOP, VDOP and TDOP, PositionVelocityTime's order,
    `NaN` when absent;
  - `num_vector_tracking_members` — members of the vector loop after this cycle,
    one per satellite and ranging signal (a satellite tracked on two bands counts
    twice), as TrackingLoops' `NavigationStatus` gives it; `num_observations` —
    signal observations in the solution, counted the same way;
  - `flags` — `NAV_RUNNING`, `NAV_SOLUTION_FROM_FILTER`, `NAV_FELL_BACK`, `NAV_RELEASED`,
    `NAV_VALID`, `NAV_TIME_VALID`.
"""
struct NavSolutionEvent
    cycle_index::Int64
    position_ecef_m::NTuple{3,Float64}
    velocity_ecef_mps::NTuple{3,Float64}
    clock_drift_mps::Float64
    time_tai_s::Int64
    time_tai_frac::Float64
    position_std_m::Float64
    clock_bias_std_m::Float64
    measurement_deficit_duration_s::Float64
    dop::NTuple{5,Float32}
    num_vector_tracking_members::Int32
    num_observations::Int32
    flags::UInt32
end

# Navigation-satellite flags.
"A satellite is stepped on this PRN now."
const NAV_SAT_TRACKED = UInt8(1)
"Its bit synchronizer has found the bit edges or the secondary code."
const NAV_SAT_BIT_OR_SECONDARY_CODE_SYNCED = UInt8(2)
"Synced and above the tracking C/N₀ threshold: the filter may use its measurement."
const NAV_SAT_MEASUREMENT_READY = UInt8(4)
"Measurement-ready, decoded for positioning and healthy."
const NAV_SAT_POSITIONING_READY = UInt8(8)
"The cycle has it in the vector loop: the navigation filter controls its NCOs."
const NAV_SAT_VECTOR_CONTROLLED = UInt8(16)
"The cycle's solution used it; the position, time and residuals are meaningful."
const NAV_SAT_IN_SOLUTION = UInt8(32)

# Why a cycle released a satellite (mirrors TrackingLoops' `VectorReleaseReason`).
const NAV_NOT_RELEASED = UInt8(0)
const NAV_RELEASE_INELIGIBLE = UInt8(1)
const NAV_RELEASE_BELOW_HORIZON = UInt8(2)
const NAV_RELEASE_FALLBACK = UInt8(3)

"""
    NavSatelliteEvent

One satellite as a navigation cycle saw it. A cycle publishes one per satellite
it knows, before its `NavSolutionEvent`; the tag carries the satellite's `prn`
and `band`, `channel` 0 and the cycle's sample index.

  - `cycle_index` — the cycle it belongs to; `channel` — the loop channel that drives
    the satellite; `signal` — the signal's id;
  - `satellite_position_ecef_m`, `transmit_time_s`, `residual_m` and
    `rate_residual_mps` — from the solution, `NaN` unless `NAV_SAT_IN_SOLUTION`;
  - `cn0_dbhz` — at the latest NCO update boundary the satellite was snapshotted at;
  - `flags` — the `NAV_SAT_*` bits; `release_reason` — one of the
    `NAV_RELEASE_*` codes, or `NAV_NOT_RELEASED`.
"""
struct NavSatelliteEvent
    cycle_index::Int64
    signal::FixedName
    satellite_position_ecef_m::NTuple{3,Float64}
    transmit_time_s::Float64
    residual_m::Float64
    rate_residual_mps::Float64
    cn0_dbhz::Float64
    channel::UInt16
    flags::UInt8
    release_reason::UInt8
    pad::UInt32
end

NavSatelliteEvent(cycle_index, signal, satellite_position_ecef_m, transmit_time_s, residual_m, rate_residual_mps, cn0_dbhz,
                  channel, flags, release_reason) = NavSatelliteEvent(
    Int64(cycle_index),
    signal isa FixedName ? signal : FixedName(signal),
    map(Float64, Tuple(satellite_position_ecef_m)),
    Float64(transmit_time_s),
    Float64(residual_m),
    Float64(rate_residual_mps),
    Float64(cn0_dbhz),
    UInt16(channel),
    UInt8(flags),
    UInt8(release_reason),
    UInt32(0),
)

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

"The device replicates the primary code only; the loop wipes the secondary code."
const SECONDARY_CODE_LOOP_WIPES = UInt8(0)
"The device wipes the secondary code itself (reserved, never requested today)."
const SECONDARY_CODE_DEVICE_WIPES = UInt8(1)

"""
    ArmCommand

"Arm channel k with this configuration": GNSSReceiver's `HardwareChannelConfig`
with every Julia object replaced by a plain value — the signal and group ids as
fixed names, the correlators' sample offsets from the prompt as a fixed tuple. The
loop *executes* the arm; the allocation policy stays with the receiver.

The arm takes effect at `application_sample_index`, on the channel's band
counter like every sample index in this protocol; the Dopplers and the code phase
are valid there. What follows from the signal, the correlators or the band is
not sent: the loop process takes the carrier phase offset from GNSSSignals, the
early–late spacing from `correlator_sample_offsets`, and the sampling frequency,
RF input and device from the `band`'s [`BandEntry`](@ref). Nor are loop bandwidths:
they belong to the tracking loop the loop process was started with. For a noise
reference (`signal_index = 0`) the loop process chooses the correlators itself
and ignores `correlator_sample_offsets` and `num_correlators`.
"""
struct ArmCommand
    signal::FixedName
    group_key::FixedName
    prn::Int32
    signal_index::Int32
    carrier_doppler_hz::Float64
    code_doppler_hz::Float64
    code_phase_chips::Float64
    application_sample_index::Int64
    correlator_sample_offsets::NTuple{5,Int32}
    num_correlators::Int32
    band::Int32
    secondary_code_mode::UInt8
    want_correlator_outputs::UInt8
    pad::UInt16
    replica_amplitude::Float64
    code_amplitude::Float64
end

"""
    ArmCommand(; signal, prn, carrier_doppler_hz, code_doppler_hz, code_phase_chips,
               application_sample_index, correlator_sample_offsets, num_correlators, kwargs...)

Keyword form with the receiver's usual defaults: `group_key = signal`,
`signal_index = 1`, the first band, unit amplitudes, no correlator outputs published.
"""
function ArmCommand(;
    signal,
    prn::Integer,
    carrier_doppler_hz::Real,
    code_doppler_hz::Real,
    code_phase_chips::Real,
    application_sample_index::Integer,
    correlator_sample_offsets,
    num_correlators::Integer,
    group_key = signal,
    signal_index::Integer = 1,
    band::Integer = 1,
    replica_amplitude::Real = 1.0,
    code_amplitude::Real = 1.0,
    secondary_code_mode::Integer = SECONDARY_CODE_LOOP_WIPES,
    want_correlator_outputs::Bool = false,
)
    offsets = ntuple(i -> i <= length(correlator_sample_offsets) ? Int32(correlator_sample_offsets[i]) : Int32(0), Val(5))
    ArmCommand(
        FixedName(signal),
        FixedName(group_key),
        Int32(prn),
        Int32(signal_index),
        Float64(carrier_doppler_hz),
        Float64(code_doppler_hz),
        Float64(code_phase_chips),
        Int64(application_sample_index),
        offsets,
        Int32(num_correlators),
        Int32(band),
        UInt8(secondary_code_mode),
        UInt8(want_correlator_outputs),
        0x0000,
        Float64(replica_amplitude),
        Float64(code_amplitude),
    )
end

"""
    ConfigureCommand

Loop-wide configuration: the NCO update interval in reference-band samples, the
predicted NCO command delay (how many samples past the device counter a command
is expected to take effect), the code periods to integrate coherently
(`INTEGRATE_WHOLE_BIT` for one whole bit), the predetection integration
time ceiling, how many NCO updates the noise reference stays on one probe and the
loop may fall behind the device, and which events are published (`EVENTS_*`).

Only the fields whose `CONFIGURE_SET_*` bit is in `set_fields` change, each to
exactly the value given; the others keep theirs. A set field must lie in its
range:

| Field                           | Allowed                     |
|:--------------------------------|:----------------------------|
| `nco_update_interval_samples`   | ≥ 1                         |
| `max_integration_time_s`        | finite and > 0              |
| `nco_command_delay_samples`     | ≥ 0                         |
| `num_code_periods_to_integrate` | ≥ 0                         |
| `noise_rearm_nco_updates`       | ≥ 1                         |
| `max_backlog_nco_updates`       | ≥ 0                         |
| `event_flags`                   | known `EVENTS_*` bits only  |

If a set field is out of range, or `set_fields` holds a bit that is not a
`CONFIGURE_SET_*` bit, the loop applies none of them and rejects the command
(`STATUS_COMMAND_REJECTED`, `REJECT_BAD_CONFIG`): a field the loop does not
know is never silently ignored.
"""
struct ConfigureCommand
    nco_update_interval_samples::Int64
    max_integration_time_s::Float64
    nco_command_delay_samples::Int32
    num_code_periods_to_integrate::Int32
    noise_rearm_nco_updates::Int32
    max_backlog_nco_updates::Int32
    event_flags::UInt32
    set_fields::UInt32
end

const CONFIGURE_SET_NCO_UPDATE_INTERVAL = UInt32(1)
const CONFIGURE_SET_MAX_INTEGRATION_TIME = UInt32(2)
const CONFIGURE_SET_NCO_COMMAND_DELAY = UInt32(4)
const CONFIGURE_SET_NUM_CODE_PERIODS_TO_INTEGRATE = UInt32(8)
const CONFIGURE_SET_NOISE_REARM_NCO_UPDATES = UInt32(16)
const CONFIGURE_SET_MAX_BACKLOG_NCO_UPDATES = UInt32(32)
const CONFIGURE_SET_EVENT_FLAGS = UInt32(64)
"Every `CONFIGURE_SET_*` bit; a configure command with any other bit set is rejected."
const CONFIGURE_SET_ALL = UInt32(127)

"`num_code_periods_to_integrate` value that integrates coherently over one whole bit."
const INTEGRATE_WHOLE_BIT = Int32(0)

"""
    ConfigureCommand(; nco_update_interval_samples, max_integration_time_s,
                     nco_command_delay_samples, num_code_periods_to_integrate,
                     noise_rearm_nco_updates, max_backlog_nco_updates, event_flags)

Keyword form: sets exactly the keywords given, and their `CONFIGURE_SET_*` bits.
"""
function ConfigureCommand(;
    nco_update_interval_samples::Union{Nothing,Integer} = nothing,
    max_integration_time_s::Union{Nothing,Real} = nothing,
    nco_command_delay_samples::Union{Nothing,Integer} = nothing,
    num_code_periods_to_integrate::Union{Nothing,Integer} = nothing,
    noise_rearm_nco_updates::Union{Nothing,Integer} = nothing,
    max_backlog_nco_updates::Union{Nothing,Integer} = nothing,
    event_flags::Union{Nothing,Integer} = nothing,
)
    set_fields = UInt32(0)
    isnothing(nco_update_interval_samples) || (set_fields |= CONFIGURE_SET_NCO_UPDATE_INTERVAL)
    isnothing(max_integration_time_s) || (set_fields |= CONFIGURE_SET_MAX_INTEGRATION_TIME)
    isnothing(nco_command_delay_samples) || (set_fields |= CONFIGURE_SET_NCO_COMMAND_DELAY)
    isnothing(num_code_periods_to_integrate) || (set_fields |= CONFIGURE_SET_NUM_CODE_PERIODS_TO_INTEGRATE)
    isnothing(noise_rearm_nco_updates) || (set_fields |= CONFIGURE_SET_NOISE_REARM_NCO_UPDATES)
    isnothing(max_backlog_nco_updates) || (set_fields |= CONFIGURE_SET_MAX_BACKLOG_NCO_UPDATES)
    isnothing(event_flags) || (set_fields |= CONFIGURE_SET_EVENT_FLAGS)
    ConfigureCommand(
        Int64(something(nco_update_interval_samples, 0)),
        Float64(something(max_integration_time_s, 0.0)),
        Int32(something(nco_command_delay_samples, 0)),
        Int32(something(num_code_periods_to_integrate, 0)),
        Int32(something(noise_rearm_nco_updates, 0)),
        Int32(something(max_backlog_nco_updates, 0)),
        UInt32(something(event_flags, 0)),
        set_fields,
    )
end

"Publish `CorrelatorOutputsEvent`s for every armed channel."
const EVENTS_CORRELATOR_OUTPUTS = UInt32(1)
"Every `EVENTS_*` bit; a configure command setting any other bit is rejected."
const EVENTS_ALL = EVENTS_CORRELATOR_OUTPUTS

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
    BandEntry(band_id, sampling_frequency_hz; intermediate_frequency_hz = 0.0, rf_input = 1, device_index = 1)

One RF band the loop process serves: its id, the rate its channels' sample
counters run at, its intermediate frequency, and the RF input and device it
arrives on. Written by the loop process, checked by the receiver against its
own band plan.

`intermediate_frequency_hz` is where a signal at zero Doppler sits in the band's
samples: the front end's IF, including any fixed offset its tuning leaves (an
RTL-SDR's LO synthesizer lands a fixed number of Hz off the requested
frequency). Every carrier Doppler in this protocol is relative to it — a
channel's carrier NCO runs at the IF plus the Doppler — so a receiver that
acquires from the band's samples searches around it.
"""
struct BandEntry
    band_id::FixedName
    sampling_frequency_hz::Float64
    intermediate_frequency_hz::Float64
    rf_input::Int32
    device_index::Int32
    pad::NTuple{2,UInt64}
end

BandEntry(band_id, sampling_frequency_hz; intermediate_frequency_hz = 0.0, rf_input = 1, device_index = 1) = BandEntry(
    FixedName(band_id),
    Float64(sampling_frequency_hz),
    Float64(intermediate_frequency_hz),
    Int32(rf_input),
    Int32(device_index),
    (0, 0),
)

Base.:(==)(a::BandEntry, b::BandEntry) =
    a.band_id == b.band_id &&
    a.sampling_frequency_hz == b.sampling_frequency_hz &&
    a.intermediate_frequency_hz == b.intermediate_frequency_hz &&
    a.rf_input == b.rf_input &&
    a.device_index == b.device_index
