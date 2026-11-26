# Glossary

The protocol's terms and the textbook terms they stand for, in the vocabulary of
TrackingLoops, whose [glossary](https://JuliaGNSS.github.io/TrackingLoops.jl/dev/glossary/)
gives the sources (Kaplan & Hegarty, Misra & Enge, Spilker et al.). Tracking.jl's
[glossary](https://JuliaGNSS.github.io/Tracking.jl/dev/glossary/) adds the software
receiver's terms. Where the protocol names a quantity TrackingLoops or
PositionVelocityTime also names, it uses their name and adds the unit.

## Roles and layout

- **Loop process, receiver**: the loop process drives the device and closes the
  tracking loops at the device's rate; the receiver arms channels, decodes, solves
  the position (unless the loop runs vector tracking) and displays. They share one
  segment: rings for events and commands, seqlocked snapshot slots for the newest
  values.
- **Channel**: a hardware channel, one signal of one satellite on one band
  (TrackingLoops: a host's hardware channel is per signal). Channel 0 addresses the
  whole loop.
- **Band**: one RF band the loop process serves ([`BandEntry`](@ref)), with its
  sampling frequency, intermediate frequency, RF input and device. The first band
  is the *reference band*.
- **Sample index**: a position on a band's device sample counter. A record's
  sample index is on the counter of the band its tag names; the navigation records
  carry the update's measurement epoch on the reference band's counter instead.
  The NCO update interval counts reference-band samples.
- **Snapshot**: here, a seqlocked slot holding the newest loop state or navigation
  solution. Not TrackingLoops' *snapshot*, what a satellite latches at a
  measurement epoch.

## Tracking

- **Integration** (coherent integration): Kaplan and Hegarty's predetection
  integration, the device's dumps of one signal summed over one or more primary code
  periods ([`IntegrationEvent`](@ref)).
- **Prompt**, **correlator outputs**: the on-time correlator and all correlators'
  outputs of an integration. A correlator's *sample offset* is its distance from the
  prompt in samples; Kaplan and Hegarty's early–late spacing follows from the
  offsets.
- **NCO command**: the carrier and code Doppler a channel's NCOs run at. A command
  takes effect at its *application sample index*. The *NCO command delay* is how
  many samples past the device counter a command is predicted to take effect.
- **NCO update span, interval and boundary**: the loop process updates every
  channel's NCO command once per *NCO update span*, the samples between two NCO
  updates (Tracking.jl's term), on a common grid of the reference band. The span's
  length is the *NCO update interval* (`nco_update_interval_samples`); a grid point
  between two spans is an *NCO update boundary*, where the loop process publishes
  the channel's loop state ([`LoopStateEvent`](@ref)).
- **Open loop**: a loop state from an update in which the loop filters were not
  stepped (`STATE_LOOP_OPEN`).
- **Code period, secondary code, bit synchronizer**: the primary code period, the
  code overlaid on it (also Neuman-Hofman code), and the part that finds the bit
  edge or the secondary code phase. A *bit* is a navigation bit as tracked, a channel
  symbol where the signal has FEC, as in TrackingLoops and GNSSSignals.
- **Noise reference**: a channel armed with `signal_index = 0` that despreads
  noise for the noise density behind C/N₀, one TrackingLoops *noise probe* (a
  random code phase and a dithered carrier) at a time; it moves to a new probe
  every `noise_rearm_nco_updates` NCO updates.
- **Loop bandwidth**: not on the wire. It belongs to the tracking loop the loop
  process is started with.
- **Replica amplitudes**: the device's carrier table gain and code table RMS, not on
  the wire. The loop process's driver knows its device's replica and scales the
  correlator outputs to the host's amplitude scale.
- **Host's amplitude scale**: correlator outputs as Tracking.jl's correlator gives
  them: the samples times a unit-amplitude carrier replica times GNSSSignals' code
  table, whose RMS is `get_code_amplitude` (1 for a ±1 code, about 19.9 for Galileo
  E1B's integer CBOC table), summed over the integration. Not a code replica of unit
  RMS, as `get_code` gives it. TrackingLoops divides the outputs by the number of
  integrated samples times `get_code_amplitude`.

## Navigation

- **Navigation update**: one update of the tracking loop's navigation processor at a
  *measurement epoch*: the navigation filter's time and measurement update, or a
  scalar PVT solve while the filter does not run. `update_index` counts them, and an
  update's records carry its measurement epoch as their sample index. *Cycles* are
  carrier-phase cycles only.
- **Vector tracking**: the tracking loops of all satellites closed through one
  navigation filter (Kaplan and Hegarty's integrated tracker). A *member* is a
  satellite in the vector loop on one ranging signal. An update *releases* a member
  to its scalar loop, and *falls back* when vector tracking stops.
- **Residual, rate residual**: measured minus predicted pseudorange and pseudorange
  rate, as PositionVelocityTime reports them.

## Units and signs

- **Units**: a field's name ends in its unit: `_hz`, `_dbhz`, `_m`, `_mps`, `_s`,
  `_chips`, `_cycles`, `_samples`; `_ecef_m` is an ECEF position in metres. A sample
  index and a count carry none.
- **C/N₀**: in dB-Hz on every record, `-Inf` for no estimate, as TrackingLoops'
  estimators give it.
- **Carrier Doppler**: relative to the band's intermediate frequency (a channel's
  carrier NCO runs at the IF plus the Doppler), positive for a closing satellite.
  The code Doppler has the same sign, scaled by the chip rate over the carrier
  frequency.
- **Accumulated carrier phase**: the carrier Doppler integrated over the NCO
  commands since the arm, in cycles and unfolded, plus TrackingLoops'
  `calc_carrier_phase_correction` while the vector loop steers the channel. It
  grows while the satellite closes and is not Tracking.jl's replica carrier phase,
  which is folded to [-0.5, 0.5).
