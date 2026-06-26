//
//  stereo_upmix.h
//  foo_out_avfoundation
//
//  Clean-room stereo → 5.1 upmix, so the V3D virtual speaker rig is fed from all six speakers even
//  when the source is plain stereo (the common case). Written from first principles for this project
//  (Apache-2.0); it does NOT derive from FreeSurround (GPL-3.0) or any Dolby Pro Logic decoder.
//
//  ALGORITHM — frequency-domain Primary/Ambient Extraction (PAE) over a short-time Fourier transform,
//  the standard for modern headphone-surround upmixers (vs. the time-domain matrix this file used to
//  hold). Per STFT bin we form the time-smoothed 2×2 inter-channel covariance and do a PCA-style
//  primary/ambient decomposition: the dominant eigenvector is the primary's pan direction, the primary
//  is beamformed toward it, and the AMBIENT is the orthogonal residual (so the rears carry no leaked
//  lead and don't pump). The discrete stereo image is preserved up front; only the extracted centre
//  energy is removed from the fronts (energy-aware), and the rears get the ambient residual.
//
//    + BASS MANAGEMENT: a smooth power-complementary crossover (≈80–160 Hz) attenuates the five main
//      channels' low end to a −12 dB floor (not −∞) and routes the complementary remainder to the LFE —
//      so the bass keeps body in the mains instead of living only in the LFE, and still isn't doubled.
//    + REAR DECORRELATION: the rear pair is run through cascaded Schroeder all-passes (time domain,
//      flat magnitude) with distinct delays per side, for a diffuse/enveloping surround field rather
//      than a phasey copy of the front.
//
//  THREADING / REAL-TIME — this runs on foobar2000's feed thread (engine_virtual_3d.mm's feedAudioData),
//  NOT the AVAudioSourceNode render thread (which only memcpys the rings). So the heavy DSP is off the
//  real-time path; buffers are still preallocated in reset() so steady-state push/pull don't allocate.
//
//  INTERFACE — decoupled push/pull because the STFT is block-based: output frames != input frames (one
//  block of latency, then ~1:1 throughput). Feed pushes interleaved stereo; the engine pulls however
//  many 5.1 frames are ready and advances its rings by that count. The vDSP/FFT machinery lives behind
//  a pImpl so this header has zero Accelerate dependency and stays cheap to include from the .mm.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

namespace foo_out_avf
{

    class StereoUpmixer {
    public:
        static constexpr uint32_t kOutChannels = 6; // FL FR C LFE RL RR (5.1 interleave order)

        // User-configurable DSP parameters (from v3d_config). The bass-management high-pass on the mains
        // and the FFT window size; defaults reproduce the original hardcoded behaviour.
        struct Params {
            float bassFloorDb = -12.0f;   // mains' low-end floor below the crossover (dB)
            float bassCutoffHz = 113.0f;  // crossover centre frequency (Hz)
            float bassQ = 1.0f;           // crossover steepness (higher = narrower transition)
            int fftSize = 2048;           // STFT window: 1024 | 2048 | 4096 (others snap to 2048)
        };

        StereoUpmixer();
        ~StereoUpmixer();
        StereoUpmixer(const StereoUpmixer &) = delete;
        StereoUpmixer &operator=(const StereoUpmixer &) = delete;

        // (Re)build the STFT machinery for a sample rate + params and clear all state. Allocates; call off
        // the real-time path (the engine calls it during a stopped-engine graph rebuild).
        void reset(uint32_t sampleRate, const Params &params);

        // Drop buffered audio + analysis state for a seek/flush, keeping the FFT setup and window.
        void clear();

        // Push `frames` of interleaved stereo (L R …). Accumulates into STFT blocks internally.
        void pushStereo(const float *interleavedLR, size_t frames);

        // How many interleaved 5.1 frames are ready to pull right now.
        size_t available() const;

        // Pull up to `maxFrames` interleaved 5.1 frames (FL FR C LFE RL RR …) into `out`. Returns the
        // number of frames actually written (<= maxFrames, <= available()).
        size_t pull(float *interleaved51, size_t maxFrames);

        // Algorithmic latency in frames: one STFT analysis block (the latency common to all six
        // channels). The rear decorrelator adds a further small group delay to the rears only, which
        // is not included here — see the note in latencyFrames().
        size_t latencyFrames() const;

    private:
        struct Impl;
        std::unique_ptr<Impl> _impl;
    };

} // namespace foo_out_avf
