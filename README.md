# Enjoy Awesome Spatialized Music in foobar2000
![screenshot](/docs/screenshot-control_center.png)

A macOS output component for foobar2000 that renders playback through AVFoundation, with two
spatial modes you pick from its preferences:

- **System Spatial Audio** — routes through `AVSampleBufferAudioRenderer` so your music taps
  into macOS Spatial Audio: spatialized stereo and dynamic head tracking, controlled from the
  system Control Center.
- **Virtual 3D** — place yourself anywhere in a custom virtual sound field, DAW-panner style,
  rendered in-process with Apple's high-quality HRTF (`HRTFHQ`). Set your listening position
  from a 3D panner in the component's preferences page.

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

Working on the engine internals? The output-pipeline contract and design notes live in
[`docs/memo.md`](docs/memo.md); the hard rules are in `AGENTS.md`.

## bugs & todo

- [ ] `source is stalling` shown on stop (matches CoreAudio output; treated as benign for now)
- [ ] Virtual 3D mode: positional engine (`AVAudioEngine` + `AVAudioEnvironmentNode`, `HRTFHQ`)
      and the preferences panner UI (in progress)