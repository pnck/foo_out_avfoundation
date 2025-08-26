//
//  predef.h
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/7.
//

#pragma once

#ifdef __OBJC__
#include <Cocoa/Cocoa.h>
#endif

#include "foobar2000/SDK/foobar2000.h"
#include "pfc/primitives.h"
#include "pfc/cpuid.h"

#if (defined(_M_IX86_FP) && _M_IX86_FP >= 2) || (defined(_M_X64) && !defined(_M_ARM64EC)) || defined(__x86_64__) || defined(__SSE2__)
#define AUDIO_MATH_SSE
#include <xmmintrin.h>
#include <tmmintrin.h> // _mm_shuffle_epi8
#include <smmintrin.h> // _mm_blend_epi16

#ifndef _mm_loadu_si32
#define _mm_loadu_si32(p) _mm_cvtsi32_si128(*(unsigned int const *)(p))
#endif
#ifndef _mm_storeu_si32
#define _mm_storeu_si32(p, a) (void)(*(int *)(p) = _mm_cvtsi128_si32((a)))
#endif

#ifdef __AVX__
#define allowAVX 1
#define haveAVX 1
#elif PFC_HAVE_CPUID
#define allowAVX 1
static const bool haveAVX = pfc::query_cpu_feature_set(pfc::CPU_HAVE_AVX);
#else
#define allowAVX 0
#define haveAVX 0
#endif

#ifdef __SSE4_1__
#define haveSSE41 true
#elif PFC_HAVE_CPUID
static const bool haveSSE41 = pfc::query_cpu_feature_set(pfc::CPU_HAVE_SSE41);
#else
#define haveSSE41 false
#endif

#if allowAVX
#include <immintrin.h> // _mm256_set1_pd
#endif

#endif // end SSE

#if defined(__aarch64__) || defined(_M_ARM64) || defined(_M_ARM64EC)
#define AUDIO_MATH_ARM64
#endif

#if defined(AUDIO_MATH_ARM64) || defined(__ARM_NEON__)
#define AUDIO_MATH_NEON
#include <arm_neon.h>

// No vcvtnq_s32_f32 on ARM32, use vcvtq_s32_f32, close enough
#ifdef AUDIO_MATH_ARM64
#define vcvtnq_s32_f32_wrap vcvtnq_s32_f32
#else
#define vcvtnq_s32_f32_wrap vcvtq_s32_f32
#endif

#endif

#if defined(AUDIO_MATH_ARM64) && !defined(__ANDROID__)
// Don't do Neon float64 on Android, crashes clang from NDK 25
#define AUDIO_MATH_NEON_FLOAT64
#endif

#define PROJECT_HOST_REPO "https://github.com/pnck/foo_out_avfoundation"
