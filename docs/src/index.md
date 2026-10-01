# HardwareLoopProtocol.jl

```@docs
HardwareLoopProtocol
```

## Versioning

The public API is every exported symbol, listed in the
[API Reference](@ref). It follows [semantic versioning](https://semver.org):
breaking changes to these symbols bump the major version.

The memory layout of the segment is versioned separately. Every segment header
carries [`PROTOCOL_VERSION`](@ref) and a hash of the record layouts, and
[`attach_segment`](@ref) refuses a segment whose version or layout does not
match. The receiver and the loop process must therefore be built against
compatible versions of this package.
