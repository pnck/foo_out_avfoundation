# Enjoy Awesome Spatialized Music in foobar2000

A macOS output component for foobar2000 that renders playback through AVFoundation. It ships a
**dual-engine** design — pick one of two spatial modes from the component's preferences page,
each backed by a different AVFoundation renderer:

### System Spatial Audio

Routes playback through `AVSampleBufferAudioRenderer`, so your music taps straight into macOS
Spatial Audio — spatialized stereo with dynamic head tracking, driven from the system Control
Center exactly like Apple Music. No setup: enable it and it follows your AirPods.

<img src="/docs/screenshot-control_center.png" alt="System Spatial Audio via Control Center" height="380"/>

### Virtual Surround

A **headphone-only** virtual **5.1 renderer**: it reconstructs a full 5.1 speaker field — every
speaker freely placeable anywhere around the listener — in-process through Apple's high-quality
HRTF (`HRTFHQ`). Even two-channel music is drawn into that field by an optimized STFT
primary/ambient upmix to 5.1.

<img src="/docs/screenshot-vsurround_preferences.png" alt="Virtual Surround preferences — virtual speaker rig panner" height="380"/>


## Build

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

Working on the engine internals? The output-pipeline contract and design notes live in
[`docs/memo.md`](docs/memo.md); the hard rules are in `AGENTS.md`.

## Bugs & Todo

- [ ] **AirPods + the DSP Manager preferences page → choppy playback** (known, unsolved). Only on
      Bluetooth (AirPods) while that specific page is shown, and only with this output. Sampled
      exhaustively (foobar2000 and coreaudiod, normal vs choppy): both processes are byte-for-byte
      identical and healthy — it's a scheduling/timing artifact in AVFoundation's out-of-process audio
      delivery, below this plugin, so it isn't fixable here. Transient; doesn't affect normal use.
- [ ] `source is stalling` shown on stop (matches CoreAudio output; treated as benign for now)
- [ ] Custom head-tracking for Virtual Surround.
- [ ] Custom DSP routing around the `AVAudioEnvironmentNode`