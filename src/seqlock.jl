# ─────────────────────────────────────────────────────────────────────────────
# The per-channel snapshot: one `EpochStateEvent` behind a seqlock, for readers
# that only want the newest state (PVT, the dashboard) and must never block the
# writer. Layout: [seq::UInt64][EpochStateEvent], inside a 256-byte slot.
# ─────────────────────────────────────────────────────────────────────────────

"""
    SnapshotSlot

A handle on one channel's seqlock-protected epoch-state snapshot. Obtain it
with [`snapshot_slot`](@ref).
"""
struct SnapshotSlot
    base::Ptr{UInt8}
end

function _init_snapshot!(base::Ptr{UInt8})
    store_relaxed!(u64ptr(base, 0), UInt64(0))
    nothing
end

"""
    write_snapshot!(slot, tag, state)

Publish a new epoch state. The sequence word is odd while the write is in
progress and even once it is complete; readers retry on an odd or changed word.
"""
function write_snapshot!(slot::SnapshotSlot, tag::EventTag, state::EpochStateEvent)
    seq = u64ptr(slot.base, 0)
    s = load_relaxed(seq)
    store_release!(seq, s + 1)
    fence_release()
    unsafe_store!(Ptr{EventTag}(slot.base + 8), tag)
    unsafe_store!(Ptr{EpochStateEvent}(slot.base + 8 + SLOT_TAG_BYTES), state)
    store_release!(seq, s + 2)
    nothing
end

"""
    read_snapshot(slot) -> Union{Nothing,Tuple{EventTag,EpochStateEvent}}

The newest epoch state, or `nothing` while none has been written. Retries a
bounded number of times if the writer is mid-update.
"""
function read_snapshot(slot::SnapshotSlot; retries::Integer = 64)
    seq = u64ptr(slot.base, 0)
    for _ = 1:retries
        s1 = load_acquire(seq)
        s1 == 0 && return nothing
        isodd(s1) && continue
        tag = unsafe_load(Ptr{EventTag}(slot.base + 8))
        state = unsafe_load(Ptr{EpochStateEvent}(slot.base + 8 + SLOT_TAG_BYTES))
        fence_acquire()
        load_relaxed(seq) == s1 && return (tag, state)
    end
    nothing
end

"The snapshot's sequence word: even and non-zero once something is published."
snapshot_sequence(slot::SnapshotSlot) = load_acquire(u64ptr(slot.base, 0))
