# Engine memo — internal technical notes

Working notes for anyone (human or AI) touching the audio engine. Not user-facing; see
`README.md` for the project overview, and `AGENTS.md` for the hard rules.

## File layout

The engine is split so the C++ facade stays one stable abstraction while AVFoundation backends sit
beside each other, selected at runtime by `OutputMode`:

- **`engine.h`** — public surface: the `AVFOutputBackend` Objective-C protocol (the backend method
  surface), the concrete `@interface`s, and the C++ `foo_out_avf::AVFEngine` (opaque `impl_`) the
  component calls.
- **`engine.mm`** — the C++ facade: forwards each `AVFEngine` call to its `id<AVFOutputBackend>`, and
  is the one place `OutputMode` picks the concrete backend.
- **`engine_sys_spatialized.mm`** (`AVFSysSpatializedBackend`) — the default backend: `AVSampleBufferAudioRenderer`
  + `AVSampleBufferRenderSynchronizer`, the system Spatial Audio path (Control Center, head tracking).
  Everything below in this memo describes this backend.
- **`engine_virtual_surround.h` / `.mm`** (`AVFVirtualSurroundBackend`) — the VSurround backend: a VIRTUAL SPEAKER RIG.
  Each content channel is deinterleaved into its own mono `AVAudioSourceNode`, positioned at a virtual
  loudspeaker location, all feeding one `AVAudioEnvironmentNode` (`HRTFHQ`). The listener sits at the
  origin; the user arranges the speakers. This preserves and spatializes the stereo/multichannel image
  the way real headphone-surround products do — NOT a mono point source (that would collapse the music
  to a toy). Speaker placement is a DAW-style abstraction: front pair + rear pair, each with
  {distance, spacing, center azimuth, center elevation}, plus a free-positioned mono center and LFE;
  the engine converts that (spherical → XYZ) to each bus's `position`. Channel→speaker mapping is by
  content channel count (stereo→front pair; 5.1→front pair + center + LFE + rear pair).
  A PULL graph: each source node pulls on the realtime render thread while foobar pushes on its
  playback thread; they meet at one single-producer/single-consumer lock-free ring PER channel (all fed
  in lockstep). Same shallow-sink contract as the default backend (partial consumption, prime lead,
  kMinFeed batching, device-transport lead floor), but the "queue" is the rings and "start the clock"
  is the shared `primed` flag that lets the render blocks drain. Reconfiguration (format/channel-count
  change, flush) stops the engine first to quiesce the render thread, so the only concurrent access is
  the steady-state SPSC rings — no locks.
- **`vsurround_config.h` / `.cpp`** — the speaker-rig settings (output mode + the `Layout`: front/rear pairs
  with {distance, spacing, azimuth, elevation}, mono centre + LFE positions) and the shared geometry
  (`compute_speakers`: layout → the six speaker XYZ). configStore-backed for persistence, with an
  in-memory cache + a `layout_generation()` counter: the UI's `set_layout` persists and bumps the
  generation; the engine watches it each feed and re-positions its sources live (no observer plumbing,
  no UI-thread node mutation, no configStore race — cache reads under one mutex).
  **`vsurround_config_bridge.h` / `.mm`** is its `VSurroundConfig` Objective-C face for the Swift UI (one class
  property per layout field + `speakerPositions` for the preview).
- **preferences UI** — Swift: `preferences_view_controller.swift` (the page), `stage_view.swift` (the
  top-down stage: drag the front/rear pair centres + mono centre/LFE around the listener, with derived
  speaker feedback dots), `scene_view.swift` (`SceneRigView`, live SceneKit preview of all six speakers).
  Per-pair spacing/elevation and mono height are sliders. Every edit writes through `VSurroundConfig` → live.
  `preferences_page.mm` registers the fb2k `preferences_page` and instantiates the Swift controller by
  its `@objc` runtime name; `bridging_header.h` exposes the ObjC bridge to Swift.

CMake globs `src/*.{cpp,mm}` and `src/*.swift` into the one module (Swift enabled unconditionally),
so new files need no build-system change.

## How it works — the output pipeline contract

This was the hard part, and getting it wrong caused every early bug (startup stall,
"plays one extra buffer after pause", `source is stalling`). The two sides — foobar2000's
`output` interface and AVFoundation's renderer — have **opposite ideas about who owns the
buffer**, and the engine's whole job is to reconcile them.

### What foobar2000 expects of an output (from `SDK/output.h`)

foobar2000 is the **deep buffer**: it decodes ahead by the configured buffer length (e.g.
1000 ms) and hands it out in pieces. The output is meant to be a **shallow sink**:

- **`update(p_ready)` / `update_v2()`** — foobar is the active driver; it polls "can you
  take more, and how much?" and calls `update()` *again after every* `process_samples()`.
  We are the side being *pulled from*.
- **`process_samples_v2(chunk)` → returns samples actually taken** — "allowed to read only
  part of the chunk if out of buffer space". We take only what fits our small lead and
  **return the count**; foobar keeps the remainder and re-offers it. foobar is our backlog.
- **`get_latency()`** — *our* queued seconds, decoupled from how much foobar has decoded.
- **`is_progressing()`** — "initially sent data is **not played** until enough is queued to
  start without glitches." There is a documented **priming** phase where not-yet-playing is
  normal; foobar does **not** treat it as a stall.
- **`force_play()`** — called when no more data is coming, precisely because an output is
  expected to *wait until its buffer reaches some level before playing*. It's the override
  for "you never reached the priming threshold, play what you have anyway" (short tracks/EOS).

### What AVFoundation's renderer is

`AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` is itself a **deep buffer
with its own clock**. `enqueueSampleBuffer` commits audio into an opaque queue;
`isReadyForMoreMediaData` is greedy. Playback is **PTS-vs-clock**: once `setRate:1` starts
the clock, a buffer plays the moment the clock passes its presentation timestamp. There is
no built-in "accumulate, then play" gate.

### The contract conflicts (and how the engine resolves them)

1. **How deep the lead should be.** We must *not* forward everything eagerly (that makes the
   renderer the deep buffer, sinking audio into its opaque queue), but the lead must still be
   **deep enough that the gaps between foobar's refill calls don't underrun the renderer** —
   too small a lead is what caused the crackle/stutter. **Fix:** keep a lead of `targetLead`
   (= `max(p_buffer_length, device floor)`) and report partial consumption. foobar's buffer
   length *is* the intended output latency, so filling that much avoids underruns and keeps
   foobar's pacing happy; the device floor guarantees a safe minimum on high-latency routes.
2. **Startup priming.** foobar buffers-then-plays; AVF plays immediately on `setRate:1`, so a
   tiny first buffer underran instantly → `get_latency` hit ~0 → `source is stalling`.
   **Fix:** the clock stays at rate 0 until we've banked `primeLead` (a *small* threshold,
   so startup stays snappy), *then* `setRate:1`; we keep filling up to the full
   `targetLead` while already playing. `is_progressing()` reports the real clock
   state; `force_play()` starts early.
3. **Partial consumption.** Because we take only what fits and return the count, foobar holds
   the rest and **the engine needs no staging queue / second thread of its own** — it is a
   thin adapter whose every method runs on foobar's playback thread (no locks).
4. **Pause** (matches): foobar pause = stop but keep the queue; `setRate:0` does exactly that.

### Engine state (the whole model)

- `targetLead` — steady-state lead = `max(_configured, _deviceFloor)`. `_configured` is foobar's
  `p_buffer_length` (0 if unset); `_deviceFloor` is a transport-type floor for the current output
  device — built-in/wired 200 ms, wireless (Bluetooth / BluetoothLE / AirPlay) 500 ms — queried from
  the CoreAudio HAL and refreshed on the default-output-device-changed notification, so it follows
  speakers ↔ AirPods switches. Sizing the lead to this is what stops the underrun crackle.
- `primeLead` — the smaller "start playing" threshold = `min(targetLead / 2, kPrime)` (kPrime =
  200 ms): bank this, start the clock, then keep filling to `targetLead`. Must stay *below* target,
  or the instant the clock starts we'd report "full", foobar would stop feeding, and the renderer
  would drain the whole lead before the next poll (immediate underrun).
- `_presentationTime` — PTS accumulator (end of everything enqueued); next buffer starts
  here. Reset to 0 (with the synchronizer clock) at `enable`/`flush`. Each buffer's actual PTS
  is `max(_presentationTime, currentTime)` so an underrun never places a buffer in the past
  (which would trigger AVFoundation's `Resyncing AQ timeline` + `AudioQueueFlush` cascade).
- `_primed` — false until `primeLead` is banked, then the clock runs.
- `kMinFeed` (20 ms) — minimum room that must open before we accept another batch, so we never
  dribble ~1-sample `CMSampleBuffer`s (which thrash the AudioQueue regardless of buffer size).
- All time-valued state is `std::chrono::duration<double>` (`fsec`); conversions to/from foobar's
  double seconds, `CMTime` and frame counts happen at exactly one named boundary each.
- Lead at any moment = `_presentationTime − synchronizer.currentTime`; that is both
  `get_latency()` and the gate for "can we take more" (`lead < targetLead`).

## Design history: from the original engine to now

### The original (experimental) engine

- **API:** `AVAudioEngine` + `AVAudioPlayerNode`, feeding via
  `scheduleBuffer:completionHandler:` through an `AVAudioEnvironmentNode` for spatialization.
- **Backpressure:** an `NSCondition` + a pending-buffer counter (`_maxPendingBuffers`).
- **Pacing:** it **blocked foobar's playback thread** with
  `[NSThread sleepForTimeInterval:bufferDuration * 0.8]` to slow the producer — a direct
  violation of the `output` contract ("process_samples SHOULD NOT block"). It also had to
  manually `[_playerNode play]` again whenever the node stopped on an empty queue.

This worked well enough to make noise but fought the host: blocking the thread, owning a deep
buffer foobar couldn't see, and no clean clock to anchor Spatial Audio against.

### This engine

- **API:** `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` — the path that
  exposes Spatial Audio (`allowedAudioSpatializationFormats`) and gives an explicit playback
  clock to time buffers against.
- **Model:** a **shallow sink**. foobar is the deep buffer; we keep a small lead
  (`targetLead`), honour partial consumption (`process_samples_v2` returns the count
  taken), **prime** before starting the clock, feed in **batches** (never 1-sample dribbles),
  and anchor every PTS to the clock (`max(_presentationTime, currentTime)`).
- **Threading:** every method runs on foobar's single playback thread. No staging queue, no
  render thread, no locks, and it never blocks.

See "How it works — the output pipeline contract" above for the full model.

### The wrong turns we took (don't repeat these)

1. **"AVF must be obeyed" → a pull model with a staging queue + `requestMediaDataWhenReady`.**
   We built a second thread that pulled from a `std::queue` into the renderer. It ran, but it
   fought `process_samples_v2`'s partial-consumption contract: once you return the taken count
   and let foobar hold the remainder, **foobar is the backlog** and the whole staging
   queue/thread/lock apparatus disappears.
2. **Starting the synchronizer clock in `enable()` (construction).** The clock then ran for
   hundreds of ms before the first audio arrived, so the first (short) buffer was already
   "late" and underran instantly → "source is stalling". Fix: don't start at enable; **prime**
   a small lead, *then* `setRate:1`.
3. **Chasing buffer DEPTH for the crackle.** We sized the lead 0.2 s → 0.8 s → foobar's full
   `p_buffer_length` → even 100 s. None of it helped, because the crackle wasn't underrun —
   it was the renderer being fed **one sample at a time** once the lead sat at the target
   (foobar polls faster than the renderer drains). That floods AVFoundation with ~1-sample
   `CMSampleBuffer`s and its AudioQueue thrashes (`Resyncing AQ timeline` + `AudioQueueFlush`),
   which is **independent of buffer size**. Fix: **batch** — only accept once `kMinFeedSeconds`
   of room has opened. (This is why "make the buffer bigger" was always a red herring.)
4. **Removing the PTS `max(currentTime)` anchor as "over-design".** It turned out to be the
   exact thing that stops AVFoundation resyncing/flushing after any gap; a buffer must never be
   enqueued behind the clock.
5. **Volume:** briefly converted to dB / applied a curve. Wrong — foobar already scaled the
   samples; we pass `renderer.volume` straight through (linear).
6. **A fixed latency cap of our own** (e.g. "stop at 50 ms") that starved the renderer into
   silence. Removed.
7. **Timers / `dispatch_source` / busy-loops** to pump feeding. Removed — foobar's
   `update`/`process_samples` polling is the only pump, and the renderer's readiness throttles
   nothing we don't already gate.

The throughline: treat the foobar `output` contract (`output.h`) as the source of truth, keep
our side a thin shallow sink, and let the macOS/foobar logs — not guesses about AVFoundation's
reactions — drive the diagnosis.
