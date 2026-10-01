# Usage

The loop process creates the segment and the receiver attaches to it. Both
sides then use the same handles: the command ring, one event ring per hardware
channel, and one snapshot slot per channel.

The examples on this page use a heap-backed segment (`nothing` for the path),
so they run in one process on any platform. Across two processes, the loop
process calls `create_segment(path, config)` with a file path, conventionally
under `/dev/shm` on Linux, and the receiver calls [`attach_segment`](@ref) with
the same path.

The constants for event, command and status kinds (`EVENT_RECORD`,
`COMMAND_ARM`, `STATUS_ARMED`, ...) are not exported. Qualify them with the
module name.

```@example usage
using HardwareLoopProtocol
const HLP = HardwareLoopProtocol

config = SegmentConfig(; channel_count = 2, bands = [BandEntry(:L1, 4e6)])
seg = create_segment(nothing, config)
band_table(seg)
```

## Commands: receiver → loop

The receiver sends commands with [`try_publish!`](@ref). It returns `false` if
the command ring is full, so a command is never lost silently. Each command
carries a sequence number, which the loop echoes in its acknowledgement.

```@example usage
commands = command_ring(seg)
arm = ArmCommand(;
    signal = :GPSL1CA,
    prn = 7,
    carrier_doppler_hz = 1500.0,
    code_doppler_hz = 1.5,
    code_phase_chips = 100.5,
    valid_at_sample = 40_000,
    tap_sample_shifts = (-2, 0, 2),
    num_taps = 3,
    sampling_freq_hz = 4e6,
)
try_publish!(commands, CommandTag(HLP.COMMAND_ARM, 1, 1), arm)
```

The loop process reads the command with [`peek!`](@ref) and [`payload`](@ref),
then consumes it with [`commit!`](@ref):

```@example usage
status, view, lost = peek!(commands, CommandTag)
if status !== :empty && view.tag.kind == HLP.COMMAND_ARM
    received = payload(ArmCommand, commands, view)
    commit!(commands, view)
    (Symbol(received.signal), received.prn)
end
```

## Events: loop → receiver

The loop process writes events to a channel's event ring with
[`publish!`](@ref). It never blocks: if the receiver falls behind, the oldest
events are overwritten.

```@example usage
events = event_ring(seg, 1)
publish!(events, EventTag(HLP.EVENT_STATUS, 1, 40_000; prn = 7),
         StatusEvent(HLP.STATUS_ARMED, HLP.REJECT_NONE, 40_000, 1))
for k = 1:3
    publish!(events, EventTag(HLP.EVENT_RECORD, 1, 40_000 + 4000k; prn = 7),
             RecordEvent(1.0 + 0im, 4000, 1, 0, 0.0, 1500.0, 1.5))
end
ring_available(events)
```

The receiver drains the ring. `status` is `:lost` when events were overwritten
before it read them; `lost` then says how many.

```@example usage
while true
    status, view, lost = peek!(events, EventTag)
    status === :empty && break
    status === :lost && println("lost $lost events")
    if view.tag.kind == HLP.EVENT_STATUS
        ack = payload(StatusEvent, events, view)
        println("status $(ack.code) for command $(ack.sequence)")
    elseif view.tag.kind == HLP.EVENT_RECORD
        record = payload(RecordEvent, events, view)
        println("record ending at sample $(view.tag.device_sample): $(record.prompt)")
    end
    commit!(events, view)
end
```

## Snapshots

A reader that only needs the newest epoch state of a channel can read its
snapshot slot instead of draining the event ring.

```@example usage
slot = snapshot_slot(seg, 1)
state = EpochStateEvent(1500.0, 1.5, 123.5, 0.25, 2e4, 1499.0, 1.49, 48_000, 13, 0, 1, 0)
write_snapshot!(slot, EventTag(HLP.EVENT_EPOCH_STATE, 1, 44_000; prn = 7), state)
tag, newest = read_snapshot(slot)
newest.carrier_doppler_hz
```

## Liveness

Each side stamps its heartbeat regularly. The other side checks it with
[`heartbeat_alive`](@ref).

```@example usage
loop_heartbeat!(seg)
heartbeat_alive(seg, :loop), heartbeat_alive(seg, :receiver)
```

```@example usage
close(seg)
```
