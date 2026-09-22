# A second process: attach to the segment named on the command line, consume
# `expected` record events from channel 1 (counting what was lost), answer every
# command with a status event, and report on stdout.
using HardwareLoopProtocol
const HLP = HardwareLoopProtocol

path = ARGS[1]
expected = parse(Int, ARGS[2])
seg = attach_segment(path)
set_receiver_pid!(seg, getpid())
ring = event_ring(seg, 1)
commands = command_ring(seg)
seen = 0
lost_total = 0
checksum = 0.0
# The receiver side produces commands: one configure command, sequence 77.
try_publish!(commands, CommandTag(HLP.COMMAND_CONFIGURE, 0, 77),
             ConfigureCommand(4000, 2, 0, 0.02, 1000, 0, 4, 0)) || error("command ring full")
deadline = time_ns() + 30_000_000_000
while seen + lost_total < expected && time_ns() < deadline
    status, view, lost = peek!(ring, EventTag)
    global lost_total += Int(lost)
    if status === :empty
        receiver_heartbeat!(seg)
        continue
    end
    body = payload(RecordEvent, ring, view)
    if isnothing(body)
        global lost_total += 1
    else
        global seen += 1
        global checksum += real(body.prompt)
    end
    commit!(ring, view)
end
println("seen=", seen, " lost=", lost_total, " checksum=", round(Int, checksum))
close(seg)
