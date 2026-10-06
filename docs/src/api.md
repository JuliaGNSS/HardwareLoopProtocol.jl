# API Reference

## Segment

```@docs
SegmentConfig
BandEntry
Segment
create_segment
attach_segment
open_or_attach_segment
segment_exists
unlink_segment
segment_config
band_table
PROTOCOL_VERSION
```

## Rings

```@docs
Ring
command_ring
event_ring
publish!
try_publish!
peek!
payload
commit!
ring_head
ring_tail
ring_available
ring_space
ring_capacity
consumer_lost
producer_overruns
```

## Snapshots

```@docs
SnapshotSlot
snapshot_slot
write_snapshot!
read_snapshot
```

## Navigation

```@docs
navigation_mode
set_navigation_mode!
nav_ring
publish_nav_solution!
read_nav_snapshot
NavSolutionEvent
NavSatelliteEvent
```

## Heartbeats, state and process ids

```@docs
loop_heartbeat!
receiver_heartbeat!
loop_heartbeat
receiver_heartbeat
heartbeat_alive
loop_state
set_loop_state!
loop_pid
receiver_pid
set_loop_pid!
set_receiver_pid!
```

## Events

```@docs
EventTag
RecordEvent
BitEvent
EpochStateEvent
StatusEvent
TapsEvent
```

## Commands

```@docs
CommandTag
ArmCommand
ConfigureCommand
ReleaseCommand
ShutdownCommand
QueryStateCommand
```

## Names

```@docs
FixedName
NAME_BYTES
```
