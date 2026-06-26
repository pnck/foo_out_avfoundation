# AGENTS.md — foo_out_avfoundation engine

Authoritative notes for anyone (human or AI) touching the audio engine. **Read
`README.md` → "How it works — the output pipeline contract" first.** That section is the
source of truth for the model; this file only adds the hard rules and the history of what
went wrong, so the same mistakes aren't repeated.

## The model in one paragraph

foobar2000 is the **deep buffer**; this engine is a **shallow sink**. foobar drives the
cadence — it polls `update()`/`update_v2()` ("can you take more, how much?") and offers
chunks via `process_samples_v2()`. We keep a **lead** equal to foobar's configured buffer
length (`_targetLeadSeconds`, from `p_buffer_length`) enqueued in
`AVSampleBufferAudioRenderer`, **return the count of samples actually taken**, and let foobar
hold the rest. Before playback we **prime** a smaller threshold (`_primeSeconds`) with the
synchronizer at rate 0, then `setRate:1` and keep filling to the full lead. Everything runs
on foobar's single playback thread; there are no AVF callbacks, no staging queue, no locks.

## Hard rules (regressing any of these reintroduces a specific past bug)

- **🚫 NEVER copy-paste logic between files. Shared code lives in exactly ONE place
  (`src/common/…`) and both sites include it.** This rule is absolute because copy-paste is a
  recurring LLM failure mode and a genuine source of big bugs: duplicating a helper "to avoid
  touching the other file" silently creates two copies that *drift* — a later edit fixes/changes one
  and leaves the other subtly wrong, and nothing flags it. If the same function / constant / struct /
  block is needed in two TUs, **extract it** (an `inline` function or `inline constexpr`/`inline`
  variable in a header so there's a single definition), don't replicate it. Applies to helpers,
  policy constants, channel maps, geometry, everything. Already bitten once: the output-lead policy
  (`fsec`, `currentOutputFloor`, the device-transport floors, the device-change address) was
  copy-pasted into both `engine_sys_spatialized.mm` and `engine_virtual_3d.mm` and had already begun
  to drift in comments/values before being consolidated into `common/lead.h`. If you catch
  yourself pasting, stop and extract instead.
- **Take partial, return the count; don't forward everything in one go.**
  `process_samples_v2` takes at most `freeFramesAtRate:` and returns that count; foobar holds
  the rest. (This is why there is no `sampleQueue` / staging — partial consumption makes
  foobar the backlog.)
- **Never feed 1-sample dribbles — batch (`kMinFeedSeconds`).** Once the lead is at the
  target, foobar polls faster than the renderer drains, so the free room is often 1–2 samples.
  If `freeFramesAtRate:` returns those, we enqueue a flood of ~1-sample `CMSampleBuffer`s and
  AVFoundation's AudioQueue thrashes (`Resyncing AQ timeline` + `AudioQueueFlush`) → crackle +
  `source is stalling`, *independent of buffer size* (this is why making the buffer huge never
  helped). Return 0 until at least `kMinFeedSeconds` of room has opened, then feed the batch.
  Proven from a foobar-console capture: `feed … take=1 lead=50ms` repeating.
- **`_targetLeadSeconds` comes from `p_buffer_length`, floored at `kMinBufferSeconds`.** It is
  NOT the cause of the crackle (batching is); keep a sane floor so a tiny configured buffer
  still leaves a usable working set.
- **`setDelaysRateChangeUntilHasSufficientMediaData = YES` (the default — never set NO).** The
  synchronizer must hold the clock until the renderer has buffered enough to start *in step with
  the device*. With NO, `setRate:1` advances our clock immediately; on a high-latency route
  (AirPods: ~315 ms Bluetooth startup + ~160 ms device latency) the clock runs ahead during the
  device's startup, so when audio finally begins there's a gap and the spatializer/AudioQueue
  underruns after one chunk while the seek bar keeps moving. Built-in starts in ~20 ms, which is
  why this hid there. Diagnosed from a macOS unified-log capture on AirPods.
- **The lead floor (`kMinBufferSeconds`) is load-bearing *because* of the rule above, not
  redundant with it.** We cap how much we feed at the lead, and YES won't start the clock until
  the renderer has "sufficient" data, which on AirPods ≈ its device latency (~160 ms). So the
  lead must be ≥ that or the clock never starts (silence). The floor is currently a blunt 300 ms
  on every device; the clean alternative is to stop capping the feed until `currentTime > 0`
  (clock actually started), letting the renderer buffer per-device, then cap small again.
- **Prime before playing; don't start the clock at `enable()`.** The clock starts only when
  the banked lead reaches `_primeSeconds` (small, for snappy startup), or on `force_play()`;
  filling continues up to `_targetLeadSeconds` while playing. Starting at `enable()` let a
  tiny first buffer underrun instantly → `get_latency` ≈ 0 → `source is stalling`.
- **`is_progressing()` must tell the truth.** It returns whether the clock is running. False
  during priming is correct and is NOT a stall — foobar's `output.h` documents this.
- **Honor `force_play()`.** No-more-data + still priming ⇒ start now and play what we have
  (short tracks / EOS), or playback hangs forever.
- **Anchor every buffer's PTS to the clock: `pts = max(_presentationTime, currentTime)`.** Do
  NOT enqueue a buffer whose timestamp is already behind `synchronizer.currentTime`. If a
  feeding gap drains the renderer (underrun), currentTime runs past `_presentationTime`; a
  buffer placed in the past makes AVFoundation log `Resyncing AQ timeline` + call
  `AudioQueueFlush`, which dumps the queue and cascades into "plays a few tens of ms then goes
  dead" (decoder-dependent: a slower decoder hits the first gap sooner). This was diagnosed
  straight from a macOS unified-log capture. The snap turns an underrun into one small gap and
  lets playback continue. (This is mpv's `end_time_av = max(end_time_av, currentTime)`.)
- **`get_latency()` reports the real lead** (`_presentationTime − currentTime`). foobar uses
  it for the seek bar and A/V sync; a constant breaks both.
- **No timers / dispatch_source / busy-wait.** foobar's `update`/`process_samples` polling
  is the only pump. We never poll AVF and never spin.
- **Log across threads via `fb2k::inMainThread`, never synchronously from the feed thread.**
  `process_samples_v2`/`feedAudioData` run on foobar's audio thread. `console::print` is
  thread-safe but dispatches to receivers *synchronously* (UI marshaling), so calling it there
  can stall feeding → crackle (it bit only Debug, since Release compiles the diag macros out).
  The log callback hands every line to `fb2k::inMainThread([line]{ FB2K_console_print(...); })`,
  which queues and returns immediately (SDK `threadsLite.h`). Diagnostics stay behind the single
  Debug-only `AVF_DIAG` macro — do not split it or block the audio thread on console I/O.
- **Volume is pass-through** to `renderer.volume` (linear, no dB/curve conversion). foobar
  already scaled the samples.
- **Pause = `setRate:0`, resume = `setRate:1` (only if primed), flush = `[renderer flush]` +
  rewind to priming.** Keep `setDelaysRateChangeUntilHasSufficientMediaData = NO` so our
  priming, not AVF's, governs the start.

## References (verified)

- foobar2000 `SDK/output.h` — the contract (`process_samples_v2` partial return,
  `update_v2`, `is_progressing`, `force_play`, `get_latency`). `output_impl` in the same
  header is the official shallow-sink reference (it has `m_incoming` + a read pointer +
  `can_write_samples()`).
- Apple `AVQueuedSampleBufferRendering` / `AVSampleBufferAudioRenderer` /
  `AVSampleBufferRenderSynchronizer` — `enqueueSampleBuffer:`, `isReadyForMoreMediaData`,
  `setRate:time:`, `setDelaysRateChangeUntilHasSufficientMediaData`.
- mpv `ao_avfoundation.m` — useful for the nanosecond PTS/`enqueueSampleBuffer` mechanics,
  but note mpv has its OWN ring buffer, so it forwards eagerly; we must not (see rule 1).
