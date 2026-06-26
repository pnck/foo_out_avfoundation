//
//  dsp_fft_vdsp.cpp
//  foo_out_avfoundation
//
//  Apple/Accelerate (vDSP) backend for dsp::FFT (dsp_fft.h) — the lone platform-specific file of the DSP
//  kernel. Retargeting = replace this translation unit with another that defines FFT::Impl + the same
//  methods over a different FFT library honoring dsp_fft.h's packed convention.
//

#include "dsp_fft.h"

#include <Accelerate/Accelerate.h>

namespace foo_out_avf::dsp
{
    // vDSP's packed real FFT (vDSP_fft_zrip) already uses the DC-in-re[0] / Nyquist-in-im[0] layout the
    // port contract specifies, so the backend is a thin, direct mapping. Impl owns the twiddle setup.
    struct FFT::Impl {
        int n = 0;
        int log2n = 0;
        FFTSetup setup = nullptr;
        ~Impl() {
            if (setup) {
                vDSP_destroy_fftsetup(setup);
            }
        }
    };

    FFT::FFT(int n) : _p(std::make_unique<Impl>()) {
        _p->n = n;
        int l = 0;
        while ((1 << l) < n) {
            ++l; // log2(n) for the power-of-two sizes the kernel asks for (1024 / 2048 / 4096)
        }
        _p->log2n = l;
        _p->setup = vDSP_create_fftsetup(l, kFFTRadix2);
    }

    FFT::~FFT() = default;
    FFT::FFT(FFT &&) noexcept = default;
    FFT &FFT::operator=(FFT &&) noexcept = default;

    int FFT::size() const noexcept { return _p->n; }
    double FFT::roundTripScale() const noexcept { return 2.0 * (double)_p->n; }

    void FFT::forward(const float *timeIn, float *re, float *im) const noexcept {
        if (!_p->setup) {
            for (int i = 0; i < _p->n / 2; ++i) { // no twiddle setup → zero spectrum rather than crash
                re[i] = 0.0f;
                im[i] = 0.0f;
            }
            return;
        }
        DSPSplitComplex s{re, im};
        // Pack the N interleaved reals into the N/2 split-complex, then in-place forward FFT.
        vDSP_ctoz((const DSPComplex *)timeIn, 2, &s, 1, (vDSP_Length)(_p->n / 2));
        vDSP_fft_zrip(_p->setup, &s, 1, _p->log2n, kFFTDirection_Forward);
    }

    void FFT::inverse(float *re, float *im, float *timeOut) const noexcept {
        if (!_p->setup) {
            for (int i = 0; i < _p->n; ++i) {
                timeOut[i] = 0.0f;
            }
            return;
        }
        DSPSplitComplex s{re, im};
        // In-place inverse FFT (clobbers re/im), then unpack the split back to N interleaved reals.
        vDSP_fft_zrip(_p->setup, &s, 1, _p->log2n, kFFTDirection_Inverse);
        vDSP_ztoc(&s, 1, (DSPComplex *)timeOut, 2, (vDSP_Length)(_p->n / 2));
    }

} // namespace foo_out_avf::dsp
