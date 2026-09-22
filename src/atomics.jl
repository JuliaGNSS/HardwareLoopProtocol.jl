# Acquire/release accessors on raw pointers into the mapped segment.
#
# Julia's atomic pointer intrinsics operate on `Ptr{T}` for primitive `T` with a
# named ordering, which is exactly the shape a cross-process ring needs: the two
# sides share memory, not a runtime, so nothing in `Threads` (which reasons about
# tasks of one process) can stand in. On x86 an acquire load is a plain load and
# a release store a plain store; on the Orin's aarch64 they compile to LDAR/STLR,
# which is what keeps a slot's payload from being observed before its sequence
# word says it is complete.

@inline load_acquire(p::Ptr{UInt64}) = Core.Intrinsics.atomic_pointerref(p, :acquire)
@inline store_release!(p::Ptr{UInt64}, v::UInt64) =
    Core.Intrinsics.atomic_pointerset(p, v, :release)
@inline load_relaxed(p::Ptr{UInt64}) = Core.Intrinsics.atomic_pointerref(p, :monotonic)
@inline store_relaxed!(p::Ptr{UInt64}, v::UInt64) =
    Core.Intrinsics.atomic_pointerset(p, v, :monotonic)
@inline fetch_add!(p::Ptr{UInt64}, v::UInt64) =
    Core.Intrinsics.atomic_pointermodify(p, +, v, :acquire_release)

# A seqlock needs two fences the acquire/release accessors alone do not give:
# the writer must make its "writing" mark visible before any payload store
# (release fence: prior stores before later stores), and the reader must finish
# its payload loads before it re-reads the sequence word (acquire fence: prior
# loads before later loads).
@inline fence_release() = Core.Intrinsics.atomic_fence(:release)
@inline fence_acquire() = Core.Intrinsics.atomic_fence(:acquire)

@inline u64ptr(p::Ptr{UInt8}, offset::Integer) = Ptr{UInt64}(p + offset)
