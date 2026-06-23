# Enjoy Awesome Spatialized Music in foobar2000
![screenshot](/docs/screenshot-control_center.png)

A macOS output component for foobar2000 that renders playback through AVFoundation's
`AVSampleBufferAudioRenderer`, letting your music tap into macOS Spatial Audio —
spatialized stereo and head tracking, controlled from the system Control Center.

> - mostly done by AI agents  
> - mostly inspired by [mpv](https://github.com/mpv-player/mpv/blob/master/audio/out/ao_avfoundation.m)


### building

The project builds with CMake. You need the Command Line Tools (`xcode-select --install`)
and CMake; Xcode.app is not required.

```sh
git submodule update --init --recursive   # fetch the foobar2000 SDK
./build.sh                                 # -> dist/mac/foo_out_avfoundation.component
```

`build.sh` is a thin wrapper over `cmake -S . -B build -G Ninja && cmake --build build`,
which compiles the vendored SDK from source as part of the build. Pass `Debug` or `Release`
to `build.sh` (default `Release`); set `CODESIGN_IDENTITY` for a signed build (ad-hoc by
default). Prefer an IDE? Generate an Xcode project on demand with `cmake -S . -B build-xcode -G Xcode`.

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
   too small a lead is what caused the crackle/stutter. **Fix:** keep a lead equal to
   foobar's configured buffer length (`_targetLeadSeconds`, from `p_buffer_length`) and
   report partial consumption. foobar's buffer length *is* the intended output latency, so
   filling exactly that much both avoids underruns and keeps foobar's pacing happy.
2. **Startup priming.** foobar buffers-then-plays; AVF plays immediately on `setRate:1`, so a
   tiny first buffer underran instantly → `get_latency` hit ~0 → `source is stalling`.
   **Fix:** the clock stays at rate 0 until we've banked `_primeSeconds` (a *small* threshold,
   so startup stays snappy), *then* `setRate:1`; we keep filling up to the full
   `_targetLeadSeconds` while already playing. `is_progressing()` reports the real clock
   state; `force_play()` starts early.
3. **Partial consumption.** Because we take only what fits and return the count, foobar holds
   the rest and **the engine needs no staging queue / second thread of its own** — it is a
   thin adapter whose every method runs on foobar's playback thread (no locks).
4. **Pause** (matches): foobar pause = stop but keep the queue; `setRate:0` does exactly that.

### Engine state (the whole model)

- `_targetLeadSeconds` — steady-state lead, set from foobar's `p_buffer_length`. This is how
  much we keep enqueued in the renderer; sizing it to the configured buffer is what stops the
  underrun crackle.
- `_primeSeconds` — the smaller "start playing" threshold (`min(buffer, 0.2 s)`): bank this,
  start the clock, then keep filling to `_targetLeadSeconds`.
- `_presentationTime` — PTS accumulator (end of everything enqueued); next buffer starts
  here. Reset to 0 (with the synchronizer clock) at `enable`/`flush`. Each buffer's actual PTS
  is `max(_presentationTime, currentTime)` so an underrun never places a buffer in the past
  (which would trigger AVFoundation's `Resyncing AQ timeline` + `AudioQueueFlush` cascade).
- `_primed` — false until `_primeSeconds` is banked, then the clock runs.
- Lead at any moment = `_presentationTime − synchronizer.currentTime`; that is both
  `get_latency()` and the gate for "can we take more" (`lead < _targetLeadSeconds`).

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
  (`_targetLeadSeconds`), honour partial consumption (`process_samples_v2` returns the count
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

## bugs & todo

- [ ] glitch when audio sample rate changes
- [ ] `source is stalling` shown on stop (matches CoreAudio output; treated as benign for now)
- [ ] custom virtual space configuration & UI