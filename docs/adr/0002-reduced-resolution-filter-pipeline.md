# Filter runs at reduced resolution to stay real-time on A15

The Kuwahara pipeline downsamples to a reduced resolution (currently 960×540)
before filtering so it can sustain real-time frame rates on the target device,
an iPhone 13 Pro Max (A15). Full-sensor-resolution filtering is intentionally
avoided because it exceeds the real-time GPU/thermal budget on that chip.

The specific 960×540 is a **compromise, not a target** — resolution is treated
as a performance lever to be re-tuned once we have frame-time and thermal
measurements (see the perf-visibility work). Raising it is expected to be the
single largest thermal cost, so any increase must be justified against measured
`thermalState` headroom.
