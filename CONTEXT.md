# KuwaharaLive

A personal iOS tool that applies a real-time painterly (generalized Kuwahara)
filter to the live camera and feeds the filtered result into a live-stream
setup (OBS) over SRT. Secondary goal: a vehicle for learning Swift/iOS.

## Language

### Capture

**Source**:
A selectable physical camera the app can draw frames from — back `0.5×` / `1×` /
`Tele`, or the front camera. Exactly one Source is active at a time.
_Avoid_: Lens (this is the on-screen label for a Source, not the concept), Camera, Input.

### Filter

**Filter**:
The generalized-Kuwahara effect applied to every frame, giving a painterly /
oil-paint look. The one and only effect in the app today.
_Avoid_: Shader (that's the implementation), Effect.

**Pass**:
One application of the Filter over a frame. Passes stack (1–4); more passes
deepen the painterly look at higher GPU cost.
_Avoid_: Iteration, Loop.

**Radius / Sharpness / Hardness**:
The live-tunable knobs that shape the Filter's look — how large each painterly
region is (Radius) and how crisply regions separate (Sharpness, Hardness).

### Output

**Filtered frame**:
The processed output of the pipeline. The single Filtered frame each tick is
shared by the Preview, the Stream, and Capture — never re-rendered per consumer.
_Avoid_: Output buffer, Result.

**Preview**:
The live, on-device rendering of Filtered frames the user sees while composing.

**Stream**:
The SRT publish of Filtered frames to an external host (e.g. OBS). Always
landscape 16:9. Video-only.
_Avoid_: Broadcast, Feed.

**Capture / Still**:
A single Filtered frame saved to the Photos library.
_Avoid_: Screenshot, Snapshot.
