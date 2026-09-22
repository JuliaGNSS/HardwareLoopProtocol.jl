# ─────────────────────────────────────────────────────────────────────────────
# A single-producer single-consumer ring of fixed-size slots with lap detection.
#
# Ring header (one line each):
#   +0   head           slots the producer has published (its next index)
#   +8   overruns       times the producer found the consumer > capacity behind
#   +16  capacity
#   +24  slot_bytes
#   +64  tail           the consumer's next index
#   +72  consumer_lost  slots the consumer had to skip as overwritten
#
# Each slot: [seq::UInt64][tag 16 B][payload]. The producer marks a slot
# `2i + 1` before writing index `i` into it and `2i + 2` after, so a consumer
# that reads the tag or payload and then finds the sequence word changed knows
# the producer lapped it mid-read. The producer never waits for the consumer:
# a full event ring overwrites the oldest slot (the consumer counts what it
# lost from the sequence gap), a full command ring refuses (`try_publish!`).
# ─────────────────────────────────────────────────────────────────────────────

"""
    Ring

A handle on one ring inside a segment: a base pointer plus the geometry, all
`isbits`, so building one costs nothing and it can live in a hot loop's state.
Obtain one with [`command_ring`](@ref) or [`event_ring`](@ref).
"""
struct Ring
    base::Ptr{UInt8}
    capacity::UInt64
    slot_bytes::UInt64
end

const RING_OFF_HEAD = 0
const RING_OFF_OVERRUNS = 8
const RING_OFF_CAPACITY = 16
const RING_OFF_SLOT_BYTES = 24
const RING_OFF_TAIL = 64
const RING_OFF_CONSUMER_LOST = 72

# Initialise a ring's header in freshly created memory.
function _init_ring!(base::Ptr{UInt8}, capacity::Integer, slot_bytes::Integer)
    store_relaxed!(u64ptr(base, RING_OFF_HEAD), UInt64(0))
    store_relaxed!(u64ptr(base, RING_OFF_OVERRUNS), UInt64(0))
    store_relaxed!(u64ptr(base, RING_OFF_CAPACITY), UInt64(capacity))
    store_relaxed!(u64ptr(base, RING_OFF_SLOT_BYTES), UInt64(slot_bytes))
    store_relaxed!(u64ptr(base, RING_OFF_TAIL), UInt64(0))
    store_relaxed!(u64ptr(base, RING_OFF_CONSUMER_LOST), UInt64(0))
    # Zero every sequence word so an unwritten slot can never look valid.
    for i = 0:(capacity-1)
        store_relaxed!(u64ptr(base, RING_HEADER_BYTES + i * slot_bytes), UInt64(0))
    end
    nothing
end

_ring_at(base::Ptr{UInt8}) = Ring(
    base,
    load_relaxed(u64ptr(base, RING_OFF_CAPACITY)),
    load_relaxed(u64ptr(base, RING_OFF_SLOT_BYTES)),
)

"Slots the producer has published so far (its next index)."
@inline ring_head(r::Ring) = load_acquire(u64ptr(r.base, RING_OFF_HEAD))
"The consumer's next index."
@inline ring_tail(r::Ring) = load_acquire(u64ptr(r.base, RING_OFF_TAIL))
@inline ring_capacity(r::Ring) = Int(r.capacity)
"Slots published and not yet consumed (may exceed the capacity after a lap)."
@inline ring_available(r::Ring) = Int(ring_head(r) - ring_tail(r))
"Free slots before the producer would overwrite unconsumed ones."
@inline ring_space(r::Ring) = max(0, ring_capacity(r) - ring_available(r))
"Times the producer found the consumer more than a capacity behind."
@inline producer_overruns(r::Ring) = load_relaxed(u64ptr(r.base, RING_OFF_OVERRUNS))
"Slots the consumer had to skip because they had been overwritten."
@inline consumer_lost(r::Ring) = load_relaxed(u64ptr(r.base, RING_OFF_CONSUMER_LOST))

@inline _slot(r::Ring, index::UInt64) =
    r.base + RING_HEADER_BYTES + (index & (r.capacity - 1)) * r.slot_bytes

# The producer side, shared by `publish!` and `try_publish!`.
@inline function _write_slot!(r::Ring, index::UInt64, tag::T, body::P) where {T,P}
    slot = _slot(r, index)
    seq = u64ptr(slot, 0)
    store_release!(seq, 2 * index + 1)
    fence_release()
    unsafe_store!(Ptr{T}(slot + SLOT_SEQ_BYTES), tag)
    unsafe_store!(Ptr{P}(slot + SLOT_PAYLOAD_OFFSET), body)
    store_release!(seq, 2 * index + 2)
    store_release!(u64ptr(r.base, RING_OFF_HEAD), index + 1)
    nothing
end

"""
    publish!(ring, tag, body) -> UInt64

Append one slot and return its sequence index. Never blocks: if the consumer is
more than a capacity behind, the oldest unconsumed slot is overwritten and the
ring's `overruns` counter is incremented — the consumer will see the gap as
lost history. For event rings.
"""
function publish!(r::Ring, tag::T, body::P) where {T,P}
    index = load_relaxed(u64ptr(r.base, RING_OFF_HEAD))
    tail = ring_tail(r)
    if index - tail >= r.capacity
        fetch_add!(u64ptr(r.base, RING_OFF_OVERRUNS), UInt64(1))
    end
    _write_slot!(r, index, tag, body)
    index
end

"""
    try_publish!(ring, tag, body) -> Bool

Append one slot unless that would overwrite an unconsumed one, in which case
nothing is written and `false` is returned. For command rings, where losing an
entry silently is the one unacceptable outcome.
"""
function try_publish!(r::Ring, tag::T, body::P) where {T,P}
    index = load_relaxed(u64ptr(r.base, RING_OFF_HEAD))
    tail = ring_tail(r)
    index - tail >= r.capacity && return false
    _write_slot!(r, index, tag, body)
    true
end

"""
    SlotView

What [`peek!`](@ref) hands the consumer: the slot's index and its tag, read
consistently. Read the payload with [`payload`](@ref) and advance with
[`commit!`](@ref).
"""
struct SlotView{T}
    index::UInt64
    tag::T
end

"""
    peek!(ring, ::Type{Tag}) -> (status, view::SlotView{Tag}, lost::UInt64)

Look at the consumer's next slot without consuming it. `status` is
`:empty` (nothing published), `:ok` (the view is valid) or `:lost` (the
consumer had fallen a whole capacity behind — `lost` slots were skipped, the
ring's `consumer_lost` counter was advanced and the view is the oldest slot
still intact). A slot the producer overwrote *while* it was being read is
skipped and counted the same way, so a caller only ever sees a consistent tag.
"""
function peek!(r::Ring, ::Type{T}) where {T}
    tail_ptr = u64ptr(r.base, RING_OFF_TAIL)
    index = load_relaxed(tail_ptr)
    lost = UInt64(0)
    while true
        head = ring_head(r)
        index >= head && return (:empty, SlotView{T}(index, _zero_tag(T)), lost)
        if head - index > r.capacity
            skipped = head - r.capacity - index
            lost += skipped
            index = head - r.capacity
        end
        slot = _slot(r, index)
        seq = u64ptr(slot, 0)
        s1 = load_acquire(seq)
        if s1 == 2 * index + 2
            tag = unsafe_load(Ptr{T}(slot + SLOT_SEQ_BYTES))
            fence_acquire()
            s2 = load_relaxed(seq)
            if s2 == s1
                if lost > 0
                    store_release!(tail_ptr, index)
                    fetch_add!(u64ptr(r.base, RING_OFF_CONSUMER_LOST), lost)
                end
                return (lost > 0 ? :lost : :ok, SlotView{T}(index, tag), lost)
            end
        end
        # Torn: the producer is lapping this very slot. Skip it.
        lost += 1
        index += 1
    end
end

@inline _zero_tag(::Type{EventTag}) = EventTag(0x00, 0x00, 0x0000, 0x0000, 0x00, 0x00, 0)
@inline _zero_tag(::Type{CommandTag}) = CommandTag(0x00, 0x00, 0x0000, 0x00000000, 0)

"""
    payload(::Type{P}, ring, view) -> Union{Nothing,P}

Read the payload of a peeked slot as a `P`, or `nothing` if the producer
overwrote the slot in the meantime (the caller then treats the slot as lost and
calls [`commit!`](@ref) to move past it).
"""
function payload(::Type{P}, r::Ring, view::SlotView) where {P}
    slot = _slot(r, view.index)
    seq = u64ptr(slot, 0)
    s1 = load_acquire(seq)
    s1 == 2 * view.index + 2 || return nothing
    body = unsafe_load(Ptr{P}(slot + SLOT_PAYLOAD_OFFSET))
    fence_acquire()
    load_relaxed(seq) == s1 || return nothing
    body
end

"""
    commit!(ring, view)

Consume the peeked slot: advance the consumer's tail past it.
"""
@inline function commit!(r::Ring, view::SlotView)
    store_release!(u64ptr(r.base, RING_OFF_TAIL), view.index + 1)
    nothing
end

# Read the tag of an arbitrary published index without consuming anything —
# diagnostics only.
function _tag_at(r::Ring, ::Type{T}, index::UInt64) where {T}
    slot = _slot(r, index)
    load_acquire(u64ptr(slot, 0)) == 2 * index + 2 || return nothing
    unsafe_load(Ptr{T}(slot + SLOT_SEQ_BYTES))
end
