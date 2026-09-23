using Test
using HardwareLoopProtocol
const HLP = HardwareLoopProtocol

const BANDS = [BandEntry(:L1, 4e6), BandEntry(:L5, 25e6; rf_input = 2)]

record(k) = RecordEvent(ComplexF64(k, -k), 4000, 1, HLP.RECORD_HAS_CN0, 1e4, 100.0 + k, 0.1)
tag(k; channel = 1) = EventTag(HLP.EVENT_RECORD, channel, 4000k; band = 1, prn = 7)

@testset "Fixed names round-trip" begin
    n = FixedName(:GalileoE1B_BOC11)
    @test String(n) == "GalileoE1B_BOC11"
    @test Symbol(n) === :GalileoE1B_BOC11
    @test length(n) == 16
    @test isempty(FixedName())
    @test_throws ArgumentError FixedName("x"^(NAME_BYTES + 1))
    @test FixedName(:GPSL1CA) == FixedName("GPSL1CA")
end

@testset "Record geometry is what the wire contract says" begin
    @test sizeof(EventTag) == 16
    @test sizeof(CommandTag) == 16
    @test sizeof(BandEntry) == 64
    for T in (RecordEvent, BitEvent, EpochStateEvent, StatusEvent, TapsEvent)
        @test isbitstype(T)
        @test sizeof(T) <= HLP.EVENT_PAYLOAD_BYTES
    end
    for T in (ArmCommand, ConfigureCommand)
        @test isbitstype(T)
        @test sizeof(T) <= HLP.COMMAND_PAYLOAD_BYTES
    end
    @test HLP.layout_hash() == HLP.layout_hash()
    @test HLP.layout_hash() != HLP._fnv1a_mix(0xcbf29ce484222325, 1)
end

@testset "A heap-backed segment carries its configuration" begin
    config = SegmentConfig(; channel_count = 3, bands = BANDS, event_capacity = 100, command_capacity = 5)
    @test config.event_capacity == 128     # rounded up to a power of two
    @test config.command_capacity == 8
    seg = create_segment(nothing, config)
    @test HLP.channel_count(seg) == 3
    @test band_table(seg) == BANDS
    @test segment_config(seg).event_capacity == 128
    @test loop_state(seg) == HLP.LOOP_STATE_STARTING
    set_loop_state!(seg, HLP.LOOP_STATE_RUNNING)
    @test loop_state(seg) == HLP.LOOP_STATE_RUNNING
    @test !heartbeat_alive(seg, :loop)
    loop_heartbeat!(seg)
    @test heartbeat_alive(seg, :loop)
    @test !heartbeat_alive(seg, :loop; now_ns = time_ns() + 10^10)
    @test_throws ArgumentError event_ring(seg, 4)
    @test ring_capacity(event_ring(seg, 1)) == 128
    @test ring_capacity(command_ring(seg)) == 8
    @test_throws ArgumentError SegmentConfig(; channel_count = 0, bands = BANDS)
    close(seg)
    @test seg.base == Ptr{UInt8}(0)
end

@testset "Events cross a ring in order with their payloads intact" begin
    seg = create_segment(nothing, SegmentConfig(; channel_count = 1, bands = BANDS, event_capacity = 16))
    ring = event_ring(seg, 1)
    status, _, _ = peek!(ring, EventTag)
    @test status === :empty
    for k = 1:10
        @test publish!(ring, tag(k), record(k)) == k - 1
    end
    @test ring_available(ring) == 10
    @test ring_space(ring) == 6
    for k = 1:10
        status, view, lost = peek!(ring, EventTag)
        @test status === :ok
        @test lost == 0
        @test view.tag.kind == HLP.EVENT_RECORD
        @test view.tag.device_sample == 4000k
        @test view.tag.prn == 7
        body = payload(RecordEvent, ring, view)
        @test body == record(k)
        # Peeking again without committing returns the same slot.
        @test peek!(ring, EventTag)[2].index == view.index
        commit!(ring, view)
    end
    @test peek!(ring, EventTag)[1] === :empty
    @test consumer_lost(ring) == 0
    @test producer_overruns(ring) == 0
    # Mixed kinds share one ring; the tag says which payload to read.
    publish!(ring, EventTag(HLP.EVENT_BIT, 1, 8000), BitEvent(-3.5, -1, 42))
    publish!(ring, EventTag(HLP.EVENT_STATUS, 1, 8000),
             StatusEvent(HLP.STATUS_ARMED, HLP.REJECT_NONE, 8000, 3, 1500.0, 1.5, 512.25,
                         FixedName(:GPSL1CA), FixedName(:GPSL1CA)))
    _, view, _ = peek!(ring, EventTag)
    @test view.tag.kind == HLP.EVENT_BIT
    bit = payload(BitEvent, ring, view)
    @test bit.soft_bit == -3.5f0 && bit.polarity == -1 && bit.bit_index == 42
    commit!(ring, view)
    _, view, _ = peek!(ring, EventTag)
    st = payload(StatusEvent, ring, view)
    @test st.code == HLP.STATUS_ARMED && st.sequence == 3 && Symbol(st.signal) === :GPSL1CA
    @test st.code_phase_chips == 512.25
    commit!(ring, view)
    close(seg)
end

@testset "A full event ring drops the oldest and the consumer counts the loss" begin
    seg = create_segment(nothing, SegmentConfig(; channel_count = 1, bands = BANDS, event_capacity = 8))
    ring = event_ring(seg, 1)
    for k = 1:20
        publish!(ring, tag(k), record(k))
    end
    @test producer_overruns(ring) == 12
    status, view, lost = peek!(ring, EventTag)
    @test status === :lost
    @test lost == 12
    @test consumer_lost(ring) == 12
    # The oldest intact slot is record 13.
    @test payload(RecordEvent, ring, view) == record(13)
    commit!(ring, view)
    for k = 14:20
        status, view, lost = peek!(ring, EventTag)
        @test status === :ok && lost == 0
        @test payload(RecordEvent, ring, view) == record(k)
        commit!(ring, view)
    end
    @test peek!(ring, EventTag)[1] === :empty
    close(seg)
end

@testset "A full command ring refuses rather than overwrites" begin
    seg = create_segment(nothing, SegmentConfig(; channel_count = 1, bands = BANDS, command_capacity = 4))
    ring = command_ring(seg)
    arm = ArmCommand(
        FixedName(:GPSL1CA), FixedName(:GPSL1CA), 7, 1, 1500.0, 1.5, 100.5, 40_000,
        (-2, 0, 2, 0, 0), 3, 4, 1, 1.0, 1.0, 0.0, 4e6, 0.0, 0.0,
        HLP.SECONDARY_PRIMARY_ONLY, 1, 1, 0, 0,
    )
    for seq = 1:4
        @test try_publish!(ring, CommandTag(HLP.COMMAND_ARM, 1, seq), arm)
    end
    @test !try_publish!(ring, CommandTag(HLP.COMMAND_ARM, 1, 5), arm)
    @test ring_space(ring) == 0
    _, view, _ = peek!(ring, CommandTag)
    @test view.tag.kind == HLP.COMMAND_ARM && view.tag.sequence == 1
    got = payload(ArmCommand, ring, view)
    @test got == arm
    @test got.tap_sample_shifts == (-2, 0, 2, 0, 0)
    commit!(ring, view)
    @test try_publish!(ring, CommandTag(HLP.COMMAND_RELEASE, 1, 5), ReleaseCommand())
    @test try_publish!(ring, CommandTag(HLP.COMMAND_SHUTDOWN, 0, 6), ShutdownCommand()) == false
    close(seg)
end

@testset "The snapshot slot is a seqlock" begin
    seg = create_segment(nothing, SegmentConfig(; channel_count = 2, bands = BANDS, event_capacity = 8))
    slot = snapshot_slot(seg, 2)
    @test isnothing(read_snapshot(slot))
    state = EpochStateEvent(1500.0, 1.5, 123.5, 0.25, 2e4, 1499.0, 1.49, 48_000, 13, 0, 1,
                            HLP.STATE_SYNC_FOUND | HLP.STATE_CODE_PHASE_ANCHORED)
    write_snapshot!(slot, EventTag(HLP.EVENT_EPOCH_STATE, 2, 44_000; prn = 9), state)
    got = read_snapshot(slot)
    @test !isnothing(got)
    @test got[1].prn == 9 && got[1].device_sample == 44_000
    @test got[2] == state
    @test HLP.snapshot_sequence(slot) == 2
    # The other channel's slot is untouched.
    @test isnothing(read_snapshot(snapshot_slot(seg, 1)))
    close(seg)
end

@testset "Two threads: producer and consumer never see a torn slot" begin
    if Threads.nthreads() < 2
        @info "skipping the two-thread ring test: started with one thread"
    else
        seg = create_segment(nothing, SegmentConfig(; channel_count = 1, bands = BANDS, event_capacity = 64))
        ring = event_ring(seg, 1)
        n = 200_000
        consumer = Threads.@spawn begin
            seen = 0
            lost = 0        # slots `peek!` skipped (counted by the ring)
            torn_payload = 0 # slots overwritten between `peek!` and `payload`
            torn = 0
            checksum = 0.0
            while seen + lost + torn_payload < n
                status, view, l = peek!(ring, EventTag)
                lost += Int(l)
                status === :empty && continue
                body = payload(RecordEvent, ring, view)
                if isnothing(body)
                    torn_payload += 1
                else
                    # Every field of a record is derived from its index; a torn
                    # read would break the relation.
                    k = Int(view.tag.device_sample ÷ 4000)
                    body == record(k) || (torn += 1)
                    seen += 1
                    checksum += real(body.prompt)
                end
                commit!(ring, view)
            end
            (seen, lost, torn_payload, torn, checksum)
        end
        producer = Threads.@spawn begin
            for k = 1:n
                publish!(ring, tag(k), record(k))
            end
        end
        wait(producer)
        seen, lost, torn_payload, torn, checksum = fetch(consumer)
        @test torn == 0
        @test seen + lost + torn_payload == n
        @test seen > 0
        @test consumer_lost(ring) == lost
        close(seg)
    end
end

@testset "Two processes share a file-backed segment" begin
    dir = Sys.islinux() && isdir("/dev/shm") ? "/dev/shm" : mktempdir()
    path = joinpath(dir, "gnss-loop-test-$(getpid())")
    isfile(path) && rm(path)
    config = SegmentConfig(; channel_count = 2, bands = BANDS, event_capacity = 1024, command_capacity = 8)
    seg = create_segment(path, config)
    @test segment_exists(path)
    @test filesize(path) == HLP.Layout(config).total
    set_loop_pid!(seg, getpid())
    ring = event_ring(seg, 1)
    commands = command_ring(seg)
    n = 5000
    child = run(
        pipeline(`$(Base.julia_cmd()) --project=$(dirname(@__DIR__)) $(joinpath(@__DIR__, "child_consumer.jl")) $path $n`;
                 stdout = joinpath(dir, "gnss-loop-test-child-$(getpid()).out")),
        wait = false,
    )
    # Let the child attach, then produce slowly enough that nothing is lost.
    sleep(2)
    for k = 1:n
        publish!(ring, tag(k), record(k))
        k % 500 == 0 && sleep(0.01)
    end
    loop_heartbeat!(seg)
    wait(child)
    out = read(joinpath(dir, "gnss-loop-test-child-$(getpid()).out"), String)
    @test occursin("seen=$n lost=0 checksum=$(sum(1:n))", out)
    # The child (the receiver side) published a command; this side consumes it.
    cstatus, cview, _ = peek!(commands, CommandTag)
    @test cstatus === :ok
    @test cview.tag.kind == HLP.COMMAND_CONFIGURE && cview.tag.sequence == 77
    cfg = payload(ConfigureCommand, commands, cview)
    @test cfg.epoch_length_samples == 4000 && cfg.commit_lead_samples == 2
    commit!(commands, cview)
    @test peek!(commands, CommandTag)[1] === :empty
    @test receiver_pid(seg) > 0
    @test heartbeat_alive(seg, :receiver; stale_after_ns = 60_000_000_000)
    # Attaching once more verifies the header; a corrupted magic is refused.
    other = attach_segment(path)
    @test HLP.channel_count(other) == 2
    @test band_table(other) == BANDS
    close(other)
    unsafe_store!(Ptr{UInt64}(seg.base), UInt64(0))
    @test_throws ArgumentError attach_segment(path)
    unsafe_store!(Ptr{UInt64}(seg.base), HLP.MAGIC)
    unsafe_store!(Ptr{UInt32}(seg.base + HLP.OFF_VERSION), UInt32(99))
    @test_throws ArgumentError attach_segment(path)
    close(seg)
    unlink_segment(path)
    @test !segment_exists(path)
    rm(joinpath(dir, "gnss-loop-test-child-$(getpid()).out"))
end

@testset "open_or_attach picks up a live loop and replaces a dead one" begin
    dir = Sys.islinux() && isdir("/dev/shm") ? "/dev/shm" : mktempdir()
    path = joinpath(dir, "gnss-loop-test-attach-$(getpid())")
    config = SegmentConfig(; channel_count = 1, bands = BANDS, event_capacity = 8)
    seg, attached = open_or_attach_segment(path, config)
    @test !attached
    # No heartbeat yet: a second opener treats it as dead and recreates it.
    seg2, attached2 = open_or_attach_segment(path, config)
    @test !attached2
    close(seg)
    loop_heartbeat!(seg2)
    seg3, attached3 = open_or_attach_segment(path, config)
    @test attached3
    close(seg2)
    close(seg3)
    unlink_segment(path)
end
