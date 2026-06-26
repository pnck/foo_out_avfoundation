//
//  dsp_fft.h
//  foo_out_avfoundation
//
//  Real FFT used by the stereo→5.1 upmix kernel (dsp_upmix.*). Concrete class with a pImpl backend: the
//  implementation translation unit is chosen at LINK time (dsp_fft_vdsp.cpp on Apple), so retargeting is
//  "link a different backend file" — no virtual dispatch, no base class, no templating of the kernel.
//
//  PACKED CONVENTION (matches Accelerate's vDSP zrip, which the kernel is written against — any other
//  backend must reproduce it): a size-N real FFT maps N real samples <-> N/2 complex bins held as SPLIT
//  arrays re[]/im[] (each length N/2). Bin 0 is packed: re[0]=DC, im[0]=Nyquist; bins 1..N/2-1 are the
//  ordinary complex bins. The kernel's bin-0 routing (DC→LFE, Nyquist→mains) depends on this.
//

#pragma once

#include <memory>

namespace foo_out_avf::dsp
{

    class FFT {
    public:
        // Build a size-n (power of two) FFT. forward/inverse degrade to silence if the backend can't init.
        explicit FFT(int n);
        ~FFT();
        FFT(FFT &&) noexcept;
        FFT &operator=(FFT &&) noexcept;
        FFT(const FFT &) = delete;
        FFT &operator=(const FFT &) = delete;

        int size() const noexcept; // N

        // N interleaved real samples (timeIn, read-only) -> split half-spectrum (re, im; each N/2).
        void forward(const float *timeIn, float *re, float *im) const noexcept;

        // Split half-spectrum (re, im; each N/2) -> N real samples (timeOut). UNNORMALIZED: the caller
        // divides by roundTripScale()·(its window norm). May overwrite re/im in place.
        void inverse(float *re, float *im, float *timeOut) const noexcept;

        // forward∘inverse round-trip gain on an identity spectrum (vDSP packed real = 2N), so the kernel
        // can fold 1/roundTripScale() into its output gain independently of the backend's normalization.
        double roundTripScale() const noexcept;

    private:
        struct Impl;
        std::unique_ptr<Impl> _p;
    };

} // namespace foo_out_avf::dsp
