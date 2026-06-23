//
//  main.cpp
//  foo_out_avfoundation
//
//  Created by pnck on 2025/8/7.
//

/*
  Change Log

  Version 0.0.1
  - Initial version
  - Buggy but working, with spatialized stereo available

*/

#include "predef.h"

#define FALLBACK_VERSION "@@"

#ifdef CURRENT_VERSION
#define VER_STR(X) #X
#define EXTRACT(X) VER_STR(X)
#define COMPONENT_VERSION EXTRACT(CURRENT_VERSION)
#else
#define COMPONENT_VERSION FALLBACK_VERSION
static_assert(false, "CURRENT_VERSION was not defined by the build system (CMake's FB2K_VERSION); "
                     "the component version mechanism is broken — refusing to build with the "
                     "placeholder fallback. Build via CMake / build.sh.");
#endif

constexpr auto About = "Get your SpatialAudio work with the newer AVFoundation APIs.\n" PROJECT_HOST_REPO "\n";

DECLARE_COMPONENT_VERSION("AVFoundation Output", COMPONENT_VERSION, About);

FOOBAR2000_IMPLEMENT_CFG_VAR_DOWNGRADE;
