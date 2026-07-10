# Adaptive thermal backoff caps filter radius; it does not try to cool the device

Under sustained streaming the A15 heats up and throttles the GPU, so a radius
that renders fine when cool starts dropping frames after ~30–60 s. We cap the
*effective* Kuwahara radius (the dominant, ~r² cost) based on
`ProcessInfo.thermalState` — full radius at `nominal`/`fair`, capped at `serious`
(7) and `critical` (5) — while leaving the user's chosen radius untouched. This
recovers the frame rate without dropping frames.

We deliberately **do not** try to cool the device back to `nominal`. The camera
ISP, H.264 encoder, and network radios run continuously, so heat generation ≈
dissipation and temperature **plateaus** at `serious`; you cannot both stream
continuously and return to a cool state. Chasing cooling with more aggressive
throttling only trades quality for the same thermal outcome, or makes the radius
oscillate visibly. A **stable plateau at `serious` with recovered frame rate is
the accepted operating point**; only `critical` warrants the hardest cap.

Consequence: during sustained streaming the radius stays capped for the session
(it won't restore until the device actually cools, e.g. after stopping). An
orange banner surfaces when backoff is active so the softer look isn't a mystery.
