# Stream video only; audio is handled externally

KuwaharaLive publishes a **video-only** SRT stream. Audio for the live
production is captured and mixed externally (OBS or another source), so the app
deliberately sends no audio track. This keeps the capture/encode path simple and
avoids on-device A/V sync complexity, which is out of scope for a personal
streaming tool. Revisit only if the app is ever used without an external audio
source.
