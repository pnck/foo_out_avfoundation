//
//  main.cpp
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/7.
//

#include "predef.h"

#define FALLBACK_VERSION "0.1.0"

#ifdef CURRENT_VERSION
#define VER_STR(X) #X
#define EXTRACT(X) VER_STR(X)
#define EXTRACT(CURRENT_VERSION)
#else
#define COMPONENT_VERSION FALLBACK_VERSION
#endif

constexpr auto About = "Get your SpatialAudio work with the newer AVFoundation APIs.\n" PROJECT_HOST_REPO "\n";

DECLARE_COMPONENT_VERSION("AVFoundation Output", COMPONENT_VERSION, About);

FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;
