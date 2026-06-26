//
//  stereo_upmix.cpp
//  foo_out_avfoundation
//
//  STFT Primary/Ambient-Extraction upmix (stereo → 5.1). Design notes are in stereo_upmix.h. This is
//  plain C++ (no ObjC) so the DSP compiles as its own TU; it calls Accelerate/vDSP directly — no Rust,
//  no FFI boundary, no AUv3 render-thread constraints (it runs on foobar's feed thread).
//
//  STFT parameters: N = 2048, hop H = N/4 (75% overlap), sqrt-Hann analysis AND synthesis window
//  (weighted overlap-add → perfect reconstruction for an unmodified spectrum, graceful for a modified
//  one). The overlap-add normalisation constant (winNorm) and the vDSP real-FFT round-trip scale
//  (1/2N) are folded into one output scale, so there is no hand-tuned magic gain to get wrong.
//
//  BASS MANAGEMENT (frequency domain): a smooth power-complementary crossover (≈80–160 Hz) attenuates
//  the five main channels' low end to a −12 dB floor (not −∞) and routes the complementary remainder to
//  the LFE, so the bass keeps body in the mains without being doubled. The crossover gain is smooth →
//  short impulse response → safe to apply per-bin in the STFT domain (unlike a brick-wall, which rings).
//
//  REAR DECORRELATION (time domain): the rear pair is run through a cascade of Schroeder all-pass
//  filters (flat magnitude, frequency-dependent group delay), with DIFFERENT delay lengths for RL vs
//  RR so the surround field is diffuse/enveloping instead of a phasey copy of the front. This is done
//  in the time domain ON THE OUTPUT STREAM — NOT as an STFT-domain random phase, which at 75% overlap
//  would cause circular-convolution time-aliasing (its impulse response spans the whole frame).
//

#include "stereo_upmix.h"

#include <Accelerate/Accelerate.h>
#include <vector>
#include <cmath>
#include <cstring>
#include <algorithm>

namespace foo_out_avf
{

    namespace
    {
        constexpr double kPi = 3.14159265358979323846;
        constexpr float kRear = 0.7071f;     // ambience level into the rear pair (−3 dB), tunable
        constexpr double kSmoothTau = 0.05;  // coherence/balance smoothing time constant (s)
        constexpr float kEps = 1e-9f;
        constexpr float kLfeSum = 0.70710678f; // (L+R)/√2: energy-preserving mono sum for the LFE
        // The FFT window (N, log2N, hop = N/4, half = N/2) and the bass-management crossover (Hz band +
        // a −X dB floor on the mains) are now USER-CONFIGURABLE — see StereoUpmixer::Params — so they are
        // runtime members of Impl set in build() from the passed params, not compile-time constants.

        // 5.1 channel order produced (matches the engine's speakerForChannel 6-channel case).
        enum { CH_FL = 0, CH_FR, CH_C, CH_LFE, CH_RL, CH_RR, CH_COUNT };

        // Schroeder all-pass: H(z) = (z^-M − g) / (1 − g·z^-M). Magnitude is flat (no colouration); it
        // disperses phase, which is exactly what decorrelation wants. Cascaded with co-prime delays per
        // rear channel for a diffuse field.
        struct Allpass {
            std::vector<float> buf;
            size_t idx = 0;
            size_t M = 1;
            float g = 0.7f;
            void init(size_t delay, float gain) {
                M = std::max<size_t>(delay, 1);
                g = gain;
                buf.assign(M, 0.0f);
                idx = 0;
            }
            void clear() {
                std::fill(buf.begin(), buf.end(), 0.0f);
                idx = 0;
            }
            inline float process(float x) {
                const float d = buf[idx];      // v[n-M]
                const float v = x + g * d;     // v[n] = x + g·v[n-M]
                const float y = d - g * v;     // y[n] = v[n-M] − g·v[n]
                buf[idx] = v;
                if (++idx >= M) {
                    idx = 0;
                }
                return y;
            }
        };
    } // namespace

    struct StereoUpmixer::Impl {
        uint32_t sr = 0;
        int N = 2048, log2N = 11, hop = 512, half = 1024; // FFT window — set in build() from Params
        FFTSetup setup = nullptr;
        float alpha = 0.0f;    // one-pole smoothing coefficient
        float olaScale = 0.0f; // 1 / (2N · winNorm) — vDSP round-trip × window normalisation

        std::vector<float> win;              // sqrt-Hann, length N
        std::vector<float> hpGain, lpGain;   // bass-management crossover gains (mains/LFE), length half

        // Input accumulator (one analysis block, slid by H each frame).
        std::vector<float> inL, inR; // length N
        int inFill = 0;

        // Windowed analysis frame + input spectra (packed real FFT: realp[0]=DC, imagp[0]=Nyquist).
        std::vector<float> fL, fR;         // length N
        std::vector<float> Lr, Li, Rr, Ri; // length half

        // Output spectra per channel + overlap-add accumulators + a real scratch buffer.
        std::vector<float> outRe[CH_COUNT], outIm[CH_COUNT]; // length half
        std::vector<float> ola[CH_COUNT];                    // length N
        std::vector<float> scratch;                          // length N

        // Smoothed inter-channel statistics per bin.
        std::vector<float> sLL, sRR, sCre, sCim; // length half

        // Rear decorrelators (two cascaded all-passes each; distinct delays L vs R).
        Allpass apRL[2];
        Allpass apRR[2];

        // Output FIFO of finished 5.1 frames (interleaved, power-of-two frame ring).
        std::vector<float> fifo;
        size_t fifoFrames = 0; // capacity in frames (power of two)
        size_t fifoMask = 0;
        size_t fHead = 0, fTail = 0; // free-running frame counters

        void build(uint32_t sampleRate, const Params &params);
        void clearState();
        void processFrame();
    };

    void StereoUpmixer::Impl::build(uint32_t sampleRate, const Params &params) {
        sr = sampleRate;
        // FFT window: only 1024/2048/4096 are offered; anything else snaps to 2048. hop = N/4 (75%
        // overlap), half = N/2 (real-FFT bins). All buffers below are sized to N/half, so a different N
        // just reallocates — nothing else in the kernel assumes a fixed size.
        switch (params.fftSize) {
            case 1024: N = 1024; log2N = 10; break;
            case 4096: N = 4096; log2N = 12; break;
            default:   N = 2048; log2N = 11; break;
        }
        hop = N / 4;
        half = N / 2;
        if (setup) {
            vDSP_destroy_fftsetup(setup);
            setup = nullptr;
        }
        setup = vDSP_create_fftsetup(log2N, kFFTRadix2);

        // sqrt-Hann window (periodic; w² = Hann, which is COLA at 75% overlap).
        win.assign(N, 0.0f);
        for (int n = 0; n < N; ++n) {
            const double hann = 0.5 * (1.0 - std::cos(2.0 * kPi * (double)n / (double)N));
            win[n] = (float)std::sqrt(hann);
        }
        // Overlap-add normalisation: Σ w² at the hop grid (constant for a COLA window/overlap).
        double winNorm = 0.0;
        for (int p = 0; p < N; p += hop) {
            winNorm += (double)win[p] * (double)win[p];
        }
        if (winNorm <= 0.0) {
            winNorm = 1.0;
        }
        olaScale = (float)(1.0 / (2.0 * (double)N * winNorm));

        const double tau = std::max(1e-4, kSmoothTau);
        alpha = (float)(1.0 - std::exp(-(double)hop / ((double)std::max<uint32_t>(sr, 1) * tau)));

        // Bass-management crossover: smooth (log-spaced raised-cosine) power-complementary split. mains
        // get hpGain, the LFE gets lpGain, hpGain² + lpGain² = 1.
        const double srd = (double)std::max<uint32_t>(sr, 1);
        // Power-complementary log raised-cosine crossover gain at bin k for a [lo, hi] transition.
        auto crossoverHp = [&](int k, double lo, double hi) -> float {
            const double f = (double)k * srd / (double)N;
            double t;
            if (f <= lo) {
                t = 0.0;
            } else if (f >= hi) {
                t = 1.0;
            } else {
                t = (std::log(f) - std::log(lo)) / (std::log(hi) - std::log(lo));
            }
            return (float)std::sin(t * kPi * 0.5);
        };
        // Configurable crossover from Params: centre frequency + Q (steepness) → a [lo, hi] transition
        // band (Q 1.0 ⇒ ±half-octave, i.e. the original 80–160 Hz around 113 Hz); and a floor so the mains
        // keep `floor` of their low end below the band instead of dropping to zero (mapping the raw [0,1]
        // crossover onto [floor, 1]).
        const double q = std::max(0.05, (double)params.bassQ);
        const double fc = std::max(1.0, (double)params.bassCutoffHz);
        const double octHalf = 0.5 / q;               // half the transition width in octaves
        const double lo = fc * std::pow(2.0, -octHalf);
        const double hi = fc * std::pow(2.0, octHalf);
        const float floor = (float)std::pow(10.0, (double)params.bassFloorDb / 20.0);
        hpGain.assign(half, 0.0f);
        lpGain.assign(half, 0.0f);
        for (int k = 0; k < half; ++k) {
            hpGain[k] = floor + (1.0f - floor) * crossoverHp(k, lo, hi);
            lpGain[k] = std::sqrt(std::max(0.0f, 1.0f - hpGain[k] * hpGain[k])); // power-complementary
        }

        inL.assign(N, 0.0f);
        inR.assign(N, 0.0f);
        fL.assign(N, 0.0f);
        fR.assign(N, 0.0f);
        Lr.assign(half, 0.0f);
        Li.assign(half, 0.0f);
        Rr.assign(half, 0.0f);
        Ri.assign(half, 0.0f);
        scratch.assign(N, 0.0f);
        for (int ch = 0; ch < CH_COUNT; ++ch) {
            outRe[ch].assign(half, 0.0f);
            outIm[ch].assign(half, 0.0f);
            ola[ch].assign(N, 0.0f);
        }
        sLL.assign(half, 0.0f);
        sRR.assign(half, 0.0f);
        sCre.assign(half, 0.0f);
        sCim.assign(half, 0.0f);

        // Decorrelator delays: small (a few ms), co-prime, distinct between L and R.
        apRL[0].init(149, 0.7f);
        apRL[1].init(211, 0.7f);
        apRR[0].init(179, 0.7f);
        apRR[1].init(263, 0.7f);

        // FIFO: a few blocks of headroom is plenty (the engine drains it every feed call).
        size_t cap = 1;
        while (cap < (size_t)(N * 4)) {
            cap <<= 1;
        }
        fifoFrames = cap;
        fifoMask = cap - 1;
        fifo.assign(cap * CH_COUNT, 0.0f);

        clearState();
    }

    void StereoUpmixer::Impl::clearState() {
        inFill = 0;
        std::fill(inL.begin(), inL.end(), 0.0f);
        std::fill(inR.begin(), inR.end(), 0.0f);
        for (int ch = 0; ch < CH_COUNT; ++ch) {
            std::fill(ola[ch].begin(), ola[ch].end(), 0.0f);
        }
        std::fill(sLL.begin(), sLL.end(), 0.0f);
        std::fill(sRR.begin(), sRR.end(), 0.0f);
        std::fill(sCre.begin(), sCre.end(), 0.0f);
        std::fill(sCim.begin(), sCim.end(), 0.0f);
        apRL[0].clear();
        apRL[1].clear();
        apRR[0].clear();
        apRR[1].clear();
        fHead = fTail = 0;
    }

    // One STFT hop: analyse the current N-sample block (inL/inR), do per-bin PAE + bass management into
    // the six output spectra, inverse-transform + window + overlap-add, decorrelate the rears, and emit
    // H finished 5.1 frames into the FIFO.
    void StereoUpmixer::Impl::processFrame() {
        // --- window + forward FFT of L and R --------------------------------------------------------
        for (int n = 0; n < N; ++n) {
            fL[n] = inL[n] * win[n];
            fR[n] = inR[n] * win[n];
        }
        DSPSplitComplex scL{Lr.data(), Li.data()};
        DSPSplitComplex scR{Rr.data(), Ri.data()};
        vDSP_ctoz((const DSPComplex *)fL.data(), 2, &scL, 1, half);
        vDSP_ctoz((const DSPComplex *)fR.data(), 2, &scR, 1, half);
        vDSP_fft_zrip(setup, &scL, 1, log2N, kFFTDirection_Forward);
        vDSP_fft_zrip(setup, &scR, 1, log2N, kFFTDirection_Forward);

        // --- DC (bin 0 real, f=0 → LFE) and Nyquist (bin 0 imag, f=sr/2 → mains) --------------------
        const float hpDC = hpGain[0]; // = floor (e.g. −12 dB): the mains keep a little sub/DC
        const float lpDC = lpGain[0]; // ≈0.97: the LFE takes the complementary remainder
        outRe[CH_FL][0] = Lr[0] * hpDC; outIm[CH_FL][0] = Li[0]; // Nyquist (imag) passes to the fronts
        outRe[CH_FR][0] = Rr[0] * hpDC; outIm[CH_FR][0] = Ri[0];
        // Centre and rears intentionally drop the single f=sr/2 (Nyquist) bin: it would need its own
        // pan/ambient decision that the per-bin loop below doesn't run for bin 0, and one bin at half
        // the sample rate is inaudible. LFE's Nyquist is zero by construction (it's low-passed).
        outRe[CH_C][0] = 0.0f;  outIm[CH_C][0] = 0.0f;
        outRe[CH_LFE][0] = lpDC * kLfeSum * (Lr[0] + Rr[0]); outIm[CH_LFE][0] = 0.0f;
        outRe[CH_RL][0] = 0.0f; outIm[CH_RL][0] = 0.0f;
        outRe[CH_RR][0] = 0.0f; outIm[CH_RR][0] = 0.0f;

        // --- per-bin Primary/Ambient extraction + bass management -----------------------------------
        for (int k = 1; k < half; ++k) {
            const float lr = Lr[k], li = Li[k], rr = Rr[k], ri = Ri[k];
            const float PL = lr * lr + li * li;
            const float PR = rr * rr + ri * ri;
            const float Cre = lr * rr + li * ri; // Re(L · conj(R))
            const float Cim = li * rr - lr * ri; // Im(L · conj(R))

            // Time-smooth the powers and the complex cross term (instantaneous per-bin is too noisy).
            sLL[k] += alpha * (PL - sLL[k]);
            sRR[k] += alpha * (PR - sRR[k]);
            sCre[k] += alpha * (Cre - sCre[k]);
            sCim[k] += alpha * (Cim - sCim[k]);

            // PCA primary/ambient decomposition. The smoothed stats ARE the 2×2 covariance
            //   R = [[a, e+j·im], [e−j·im, dd]],  a=E[|L|²], dd=E[|R|²], (e,im)=E[L·conj(R)].
            // Eigenvalues λ± = (a+dd)/2 ± √(((a−dd)/2)² + |b|²); the model is primary (rank-1 along the
            // dominant eigenvector) + isotropic ambient of power λ_min per channel. So primary power
            // P = λ_max − λ_min, and the ambient is the residual orthogonal to the primary direction —
            // which is why the rears stay free of the (correlated) lead and don't pump.
            const float a = sLL[k], dd = sRR[k];
            const float e = sCre[k], im = sCim[k];
            const float hs = 0.5f * (a + dd);
            const float hd = 0.5f * (a - dd);
            const float delta = std::sqrt(hd * hd + e * e + im * im);
            const float lmax = hs + delta;
            const float lmin = std::max(hs - delta, 0.0f);
            const float P = lmax - lmin; // primary power

            float ambLre = lr, ambLim = li, ambRre = rr, ambRim = ri; // default (P≈0): all ambient
            float gc = 0.0f;                                          // centre presence ∈ [0,1]
            if (P > kEps) {
                // Dominant (λ_max) eigenvector of the real-symmetric part, sign-aware = the pan.
                float vL = lmax - dd, vR = e;
                const float nrm = std::sqrt(vL * vL + vR * vR);
                if (nrm > kEps) {
                    vL /= nrm;
                    vR /= nrm;
                } else {
                    vL = 1.0f;
                    vR = 0.0f;
                }
                // Beamform the primary toward that direction; ambient = the residual.
                const float sre = vL * lr + vR * rr;
                const float sim = vL * li + vR * ri;
                ambLre = lr - vL * sre; ambLim = li - vL * sim;
                ambRre = rr - vR * sre; ambRim = ri - vR * sim;
                const float fp = P / (a + dd + kEps);          // primary energy fraction ∈ [0,1]
                const float centre = std::max(0.0f, 2.0f * vL * vR); // centred-ness ∈ [0,1]
                gc = fp * centre;
            }

            const float hp = hpGain[k]; // bass management: high-pass the mains

            // Fronts keep the discrete stereo image, minus the centre energy we extract (energy-aware).
            const float frontG = (1.0f - 0.5f * gc) * hp;
            outRe[CH_FL][k] = frontG * lr; outIm[CH_FL][k] = frontG * li;
            outRe[CH_FR][k] = frontG * rr; outIm[CH_FR][k] = frontG * ri;

            // Centre = the centred primary, collapsed to mono. Same bass-management high-pass (hp) as the
            // other mains — the −12 dB floor already keeps dialogue/vocal warmth, so no separate curve.
            const float cg = gc * 0.5f * hp;
            outRe[CH_C][k] = cg * (lr + rr); outIm[CH_C][k] = cg * (li + ri);

            // Rears = the PCA ambient residual (primary-free), decorrelated in the time domain on output.
            const float rg = kRear * hp;
            outRe[CH_RL][k] = rg * ambLre; outIm[CH_RL][k] = rg * ambLim;
            outRe[CH_RR][k] = rg * ambRre; outIm[CH_RR][k] = rg * ambRim;

            // LFE = low-passed, energy-preserving mono sum (the bass removed from the mains).
            const float lg = lpGain[k] * kLfeSum;
            outRe[CH_LFE][k] = lg * (lr + rr); outIm[CH_LFE][k] = lg * (li + ri);
        }

        // --- inverse FFT each channel, synthesis-window, overlap-add --------------------------------
        for (int ch = 0; ch < CH_COUNT; ++ch) {
            DSPSplitComplex so{outRe[ch].data(), outIm[ch].data()};
            vDSP_fft_zrip(setup, &so, 1, log2N, kFFTDirection_Inverse);
            vDSP_ztoc(&so, 1, (DSPComplex *)scratch.data(), 2, half);
            float *acc = ola[ch].data();
            for (int n = 0; n < N; ++n) {
                acc[n] += scratch[n] * win[n];
            }
        }

        // --- emit the H now-complete frames (decorrelating the rears), then slide the OLA by H ------
        for (int f = 0; f < hop; ++f) {
            float *slot = fifo.data() + (fTail & fifoMask) * CH_COUNT;
            slot[CH_FL] = ola[CH_FL][f] * olaScale;
            slot[CH_FR] = ola[CH_FR][f] * olaScale;
            slot[CH_C] = ola[CH_C][f] * olaScale;
            slot[CH_LFE] = ola[CH_LFE][f] * olaScale;
            float rlOut = ola[CH_RL][f] * olaScale;
            float rrOut = ola[CH_RR][f] * olaScale;
            rlOut = apRL[1].process(apRL[0].process(rlOut)); // distinct delays L vs R → inter-channel decorrelation
            rrOut = apRR[1].process(apRR[0].process(rrOut));
            slot[CH_RL] = rlOut;
            slot[CH_RR] = rrOut;
            ++fTail;
            if (fTail - fHead > fifoFrames) {
                ++fHead; // FIFO overflow guard (should not happen — the engine drains every call)
            }
        }
        for (int ch = 0; ch < CH_COUNT; ++ch) {
            float *acc = ola[ch].data();
            std::memmove(acc, acc + hop, (size_t)(N - hop) * sizeof(float));
            std::memset(acc + (N - hop), 0, (size_t)hop * sizeof(float));
        }
    }

    // --- public interface ---------------------------------------------------------------------------

    StereoUpmixer::StereoUpmixer() : _impl(new Impl()) {}

    StereoUpmixer::~StereoUpmixer() {
        if (_impl && _impl->setup) {
            vDSP_destroy_fftsetup(_impl->setup);
            _impl->setup = nullptr;
        }
    }

    void StereoUpmixer::reset(uint32_t sampleRate, const Params &params) {
        _impl->build(sampleRate, params);
    }

    void StereoUpmixer::clear() {
        if (_impl->setup) {
            _impl->clearState();
        }
    }

    void StereoUpmixer::pushStereo(const float *interleavedLR, size_t frames) {
        Impl *p = _impl.get();
        if (!p->setup || frames == 0) {
            return; // not built yet (reset() not called) — nothing to do
        }
        const int N = p->N, hop = p->hop;
        size_t i = 0;
        while (i < frames) {
            const size_t space = (size_t)(N - p->inFill);
            const size_t take = std::min(space, frames - i);
            for (size_t j = 0; j < take; ++j) {
                p->inL[p->inFill + j] = interleavedLR[2 * (i + j) + 0];
                p->inR[p->inFill + j] = interleavedLR[2 * (i + j) + 1];
            }
            p->inFill += (int)take;
            i += take;
            if (p->inFill == N) {
                p->processFrame();
                // Keep the last (N − H) samples as the overlap for the next block.
                std::memmove(p->inL.data(), p->inL.data() + hop, (size_t)(N - hop) * sizeof(float));
                std::memmove(p->inR.data(), p->inR.data() + hop, (size_t)(N - hop) * sizeof(float));
                p->inFill = N - hop;
            }
        }
    }

    size_t StereoUpmixer::available() const {
        return _impl->setup ? (size_t)(_impl->fTail - _impl->fHead) : 0;
    }

    size_t StereoUpmixer::pull(float *interleaved51, size_t maxFrames) {
        Impl *p = _impl.get();
        if (!p->setup) {
            return 0;
        }
        const size_t avail = (size_t)(p->fTail - p->fHead);
        const size_t n = std::min(maxFrames, avail);
        for (size_t i = 0; i < n; ++i) {
            const float *slot = p->fifo.data() + (p->fHead & p->fifoMask) * CH_COUNT;
            std::memcpy(interleaved51 + i * CH_COUNT, slot, CH_COUNT * sizeof(float));
            ++p->fHead;
        }
        return n;
    }

    size_t StereoUpmixer::latencyFrames() const {
        // One analysis block — the dominant, common-to-all-channels latency. The rear-decorrelation
        // all-passes add a further small, frequency-dependent group delay to the REARS only; it's left
        // out here (it's not a flat frame count, and a few-ms rear-only skew doesn't affect A/V sync).
        return (size_t)_impl->N;
    }

} // namespace foo_out_avf
