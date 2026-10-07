# Changelog

# [3.0.0](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/compare/v2.0.0...v3.0.0) (2026-10-07)


* feat!: carry each band's intermediate frequency in the band table ([ef55977](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/commit/ef55977af41695b76c587d62c8139e553195cda1))


### BREAKING CHANGES

* PROTOCOL_VERSION is 3 and BandEntry's field layout
changed, so 2.x and 3.x builds refuse each other's segments; rebuild
both sides against 3.x. BandEntry's positional constructor now takes
the IF after the sampling frequency and two pad words; the keyword
constructor is unchanged apart from the new
`intermediate_frequency_hz = 0.0` keyword.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

# [2.0.0](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/compare/v1.0.2...v2.0.0) (2026-10-07)


* feat!: add a loop-wide nav ring for the vector-tracking solution ([d8ae7e4](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/commit/d8ae7e44bd21a62dd32fae2014b6d9b27f235e1c))


### BREAKING CHANGES

* PROTOCOL_VERSION is 2 and the segment layout changed
(the nav area sits between the command ring and the channels), so a
receiver and a loop process built against 1.x and 2.x refuse each
other's segments. Rebuild both sides against 2.x. SegmentConfig has a
new nav_capacity field; code that calls its positional constructor
must pass it (the keyword constructor defaults it to 1024).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

## [1.0.2](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/compare/v1.0.1...v1.0.2) (2026-09-30)

No changes to the package. Replaces the accidental 2.0.0 release.

## [1.0.1](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/compare/v1.0.0...v1.0.1) (2026-09-23)


### Bug Fixes

* **segment:** pass open(2)'s mode as the vararg it is ([87cf48f](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/commit/87cf48f55d246b13984461f6802e47567fd37b15))

# 1.0.0 (2026-09-23)


### Features

* keyword ArmCommand, commit-lead configuration, splat-free layout hash ([a8212b4](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/commit/a8212b4e64d5a8e87652f12e1c111af8540f5970))
* the shared-memory protocol between receiver and loop process ([e92b96d](https://github.com/JuliaGNSS/HardwareLoopProtocol.jl/commit/e92b96df6be6f164a7c32dc136283fe33b891e03))
