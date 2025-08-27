#pragma once

#include "predef.h"

namespace utils
{
#if defined(__aarch64__) || defined(__arm64ec__)
    void neon_convert(const double *input, float *output, size_t count) {
        const double *src = input;
        float *dst = output;
        size_t n = count / 16;
        while (n--) {
            float64x2_t d1 = vld1q_f64(src);
            float64x2_t d2 = vld1q_f64(src + 2);
            float64x2_t d3 = vld1q_f64(src + 4);
            float64x2_t d4 = vld1q_f64(src + 6);
            float64x2_t d5 = vld1q_f64(src + 8);
            float64x2_t d6 = vld1q_f64(src + 10);
            float64x2_t d7 = vld1q_f64(src + 12);
            float64x2_t d8 = vld1q_f64(src + 14);
            src += 16;

            vst1q_f32(dst, vcombine_f32(vcvt_f32_f64(d1), vcvt_f32_f64(d2)));
            vst1q_f32(dst + 4, vcombine_f32(vcvt_f32_f64(d3), vcvt_f32_f64(d4)));
            vst1q_f32(dst + 8, vcombine_f32(vcvt_f32_f64(d5), vcvt_f32_f64(d6)));
            vst1q_f32(dst + 12, vcombine_f32(vcvt_f32_f64(d7), vcvt_f32_f64(d8)));
            dst += 16;
        }

        size_t remaining = count % 16;
        for (size_t i = 0; i < remaining; i++) {
            dst[i] = (float)src[i];
        }
    }
#endif
} // namespace utils
