# HardwareLoopProtocol.jl

```@docs
HardwareLoopProtocol
```

## Versioning

The public API is every name the [API Reference](@ref) and the
[Constants](@ref) list, and only those are part of the API the version number
makes promises about. The names a caller writes are exported; the wire's codes
and flags are written qualified, `HardwareLoopProtocol.STATUS_ARMED`, as
TrackingLoops writes its values. It follows [semantic versioning](https://semver.org):
breaking changes to these names bump the major version.

The memory layout of the segment is versioned separately. Every segment header
carries [`PROTOCOL_VERSION`](@ref) and a hash of the record layouts, and
[`attach_segment`](@ref) refuses a segment whose version or layout does not
match. The receiver and the loop process must therefore be built against
compatible versions of this package.
