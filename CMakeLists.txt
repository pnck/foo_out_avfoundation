# ---------------------------------------------------------------------------
# foo_out_avfoundation — CMake build
#
# Goal: build the foobar2000 component WITHOUT the Xcode IDE / .xcodeproj.
# You still need Apple's clang toolchain + macOS SDK (Command Line Tools are
# enough: `xcode-select --install`) — that is unavoidable for any macOS build
# that links system frameworks. What you do NOT need is Xcode.app or pbxproj
# project management.
#
# Quick start:
#   cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#   # -> build/foo_out_avfoundation.component  (also copied to dist/mac/)
#
# If you still want an IDE project, CMake can emit one on demand:
#   cmake -S . -B build-xcode -G Xcode
# ---------------------------------------------------------------------------
cmake_minimum_required(VERSION 3.24)

project(foo_out_avfoundation
    VERSION 0.1.0
    LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "foo_out_avfoundation is a macOS-only foobar2000 component.")
endif()

# Match the Info.plist's LSMinimumSystemVersion. >= the SDK's own 11.0 floor.
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "13.3" CACHE STRING "Minimum macOS version")
endif()

# arm64 only: macOS Spatial Audio / "Spatialize Stereo" is supported solely on
# Apple-silicon Macs, so an Intel slice would serve no purpose for this component.
# Override with -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" if you want a fat binary anyway.
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Target architectures")
endif()

set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Mirror the old Xcode Debug config (DEBUG=1 / _DEBUG=1). pfc decides whether it
# is a debug build from these macros (pfc-lite.h: `#if defined(_DEBUG) || defined(DEBUG)`);
# without them a Debug build keeps PFC_DEBUG=0 — asserts compiled out and a
# "release build without NDEBUG" #pragma warning. Release/RelWithDebInfo/MinSizeRel
# already receive -DNDEBUG from CMake's own per-config flags.
add_compile_definitions($<$<CONFIG:Debug>:_DEBUG> $<$<CONFIG:Debug>:DEBUG>)

# Ad-hoc signing ("-") by default; pass a real identity for distribution, or
# "" to skip signing entirely.
set(CODESIGN_IDENTITY "-" CACHE STRING "codesign identity ('-' = ad-hoc, '' = none)")

# Free-form version string shown in the About box (main.cpp's CURRENT_VERSION).
# CI passes the `git describe` output here; the numeric PROJECT_VERSION above is
# kept separate because it feeds the Info.plist which requires x.y.z.
set(FB2K_VERSION "${PROJECT_VERSION}" CACHE STRING "About-box version string")

# ---------------------------------------------------------------------------
# foobar2000 SDK (vendored as a git submodule under vendor/sdk).
# The SDK ships as Xcode/VS projects; here we compile the same source sets as
# the SDK's own *.xcodeproj Sources build phases into static libraries.
# ---------------------------------------------------------------------------
set(SDK "${CMAKE_CURRENT_SOURCE_DIR}/vendor/sdk")

if(NOT EXISTS "${SDK}/pfc/pfc-lite.h")
    message(FATAL_ERROR
        "foobar2000 SDK not found at ${SDK}. Run: git submodule update --init --recursive")
endif()

# Shared include roots so quoted and <SDK/...> / <pfc/...> includes both resolve.
add_library(fb2k_sdk_includes INTERFACE)
target_include_directories(fb2k_sdk_includes INTERFACE
    "${SDK}"
    "${SDK}/foobar2000"
    "${SDK}/foobar2000/SDK"
    "${SDK}/foobar2000/shared"
    "${SDK}/foobar2000/helpers"
    "${SDK}/pfc")

# Helper: force-include a prefix header into every TU of a target (mirrors the
# SDK xcodeprojs' GCC_PREFIX_HEADER), enable ObjC ARC for ObjC++ sources, and
# wire up the shared include roots + C++ standard.
function(fb2k_sdk_lib name std prefix_header)
    target_link_libraries(${name} PRIVATE fb2k_sdk_includes)
    set_target_properties(${name} PROPERTIES CXX_STANDARD ${std} C_STANDARD 11)
    target_compile_options(${name} PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
        $<$<COMPILE_LANGUAGE:OBJC>:-fobjc-arc>)
    if(NOT prefix_header STREQUAL "")
        target_compile_options(${name} PRIVATE -include "${prefix_header}")
    endif()
endfunction()

# --- pfc -------------------------------------------------------------------
add_library(pfc STATIC
    ${SDK}/pfc/SmartStrStr.cpp        ${SDK}/pfc/audio_math.cpp
    ${SDK}/pfc/audio_sample.cpp       ${SDK}/pfc/base64.cpp
    ${SDK}/pfc/bigmem.cpp             ${SDK}/pfc/bit_array.cpp
    ${SDK}/pfc/bsearch.cpp            ${SDK}/pfc/charDownConvert.cpp
    ${SDK}/pfc/cpuid.cpp              ${SDK}/pfc/crashWithMessage.cpp
    ${SDK}/pfc/filehandle.cpp         ${SDK}/pfc/filetimetools.cpp
    ${SDK}/pfc/guid.cpp               ${SDK}/pfc/nix-objects.cpp
    ${SDK}/pfc/obj-c.mm               ${SDK}/pfc/other.cpp
    ${SDK}/pfc/pathUtils.cpp          ${SDK}/pfc/pfc-fb2k-hooks.cpp
    ${SDK}/pfc/printf.cpp             ${SDK}/pfc/selftest.cpp
    ${SDK}/pfc/sort.cpp               ${SDK}/pfc/splitString2.cpp
    ${SDK}/pfc/stdafx.cpp             ${SDK}/pfc/string-compare.cpp
    ${SDK}/pfc/string-conv-lite.cpp   ${SDK}/pfc/string-lite.cpp
    ${SDK}/pfc/string_base.cpp        ${SDK}/pfc/string_conv.cpp
    ${SDK}/pfc/synchro_nix.cpp        ${SDK}/pfc/threads.cpp
    ${SDK}/pfc/timers.cpp             ${SDK}/pfc/unicode-normalize.cpp
    ${SDK}/pfc/utf8.cpp               ${SDK}/pfc/wildcard.cpp
    ${SDK}/pfc/win-objects.cpp)
fb2k_sdk_lib(pfc 17 "${SDK}/pfc/pfc-lite.h")

# --- foobar2000_SDK --------------------------------------------------------
file(GLOB FB2K_SDK_SOURCES CONFIGURE_DEPENDS
    "${SDK}/foobar2000/SDK/*.cpp" "${SDK}/foobar2000/SDK/*.mm")
add_library(foobar2000_SDK STATIC ${FB2K_SDK_SOURCES})
fb2k_sdk_lib(foobar2000_SDK 17 "${SDK}/foobar2000/SDK/foobar2000-sdk-pch.h")
target_link_libraries(foobar2000_SDK PRIVATE pfc)

# --- foobar2000_SDK_helpers ------------------------------------------------
# NOT a glob: the helpers/ directory also contains Win32/UI-only sources
# (DarkMode.cpp, win32_dialog.cpp, image_load_save.cpp, ...) that are excluded
# from the SDK's Apple Sources build phase and do not compile on macOS.
add_library(foobar2000_SDK_helpers STATIC
    ${SDK}/foobar2000/helpers/StdAfx.cpp
    ${SDK}/foobar2000/helpers/ThreadUtils.cpp
    ${SDK}/foobar2000/helpers/VisUtils.cpp
    ${SDK}/foobar2000/helpers/VolumeMap.cpp
    ${SDK}/foobar2000/helpers/album_art_helpers.cpp
    ${SDK}/foobar2000/helpers/cfg_guidlist.cpp
    ${SDK}/foobar2000/helpers/cfg_var_import.cpp
    ${SDK}/foobar2000/helpers/create_directory_helper.cpp
    ${SDK}/foobar2000/helpers/cue_creator.cpp
    ${SDK}/foobar2000/helpers/cue_parser.cpp
    ${SDK}/foobar2000/helpers/cue_parser_embedding.cpp
    ${SDK}/foobar2000/helpers/cuesheet_index_list.cpp
    ${SDK}/foobar2000/helpers/dialog_resize_helper.cpp
    ${SDK}/foobar2000/helpers/dropdown_helper.cpp
    ${SDK}/foobar2000/helpers/dynamic_bitrate_helper.cpp
    ${SDK}/foobar2000/helpers/file_list_helper.cpp
    ${SDK}/foobar2000/helpers/file_move_helper.cpp
    ${SDK}/foobar2000/helpers/file_win32_wrapper.cpp
    ${SDK}/foobar2000/helpers/filetimetools.cpp
    ${SDK}/foobar2000/helpers/input_helper_cue.cpp
    ${SDK}/foobar2000/helpers/input_helpers.cpp
    ${SDK}/foobar2000/helpers/mp3_utils.cpp
    ${SDK}/foobar2000/helpers/packet_decoder_aac_common.cpp
    ${SDK}/foobar2000/helpers/packet_decoder_mp3_common.cpp
    ${SDK}/foobar2000/helpers/readers.cpp
    ${SDK}/foobar2000/helpers/seekabilizer.cpp
    ${SDK}/foobar2000/helpers/stream_buffer_helper.cpp
    ${SDK}/foobar2000/helpers/text_file_loader.cpp
    ${SDK}/foobar2000/helpers/text_file_loader_v2.cpp
    ${SDK}/foobar2000/helpers/track_property_callback_impl.cpp
    ${SDK}/foobar2000/helpers/win-systemtime.cpp
    ${SDK}/foobar2000/helpers/win32_misc.cpp
    ${SDK}/foobar2000/helpers/writer_wav.cpp)
fb2k_sdk_lib(foobar2000_SDK_helpers 17 "${SDK}/foobar2000/helpers/StdAfx.h")
target_link_libraries(foobar2000_SDK_helpers PRIVATE pfc foobar2000_SDK)

# --- foobar2000_component_client ------------------------------------------
add_library(foobar2000_component_client STATIC
    ${SDK}/foobar2000/foobar2000_component_client/component_client.cpp)
fb2k_sdk_lib(foobar2000_component_client 20 "")
target_link_libraries(foobar2000_component_client PRIVATE pfc foobar2000_SDK)

# --- shared (built from source on Apple; the .lib files are Windows-only) ---
add_library(shared STATIC
    ${SDK}/foobar2000/shared/audio_math.cpp
    ${SDK}/foobar2000/shared/shared-apple.mm
    ${SDK}/foobar2000/shared/shared-nix.cpp
    ${SDK}/foobar2000/shared/stdafx.cpp
    ${SDK}/foobar2000/shared/utf8.cpp)
fb2k_sdk_lib(shared 17 "${SDK}/foobar2000/shared/shared.h")
target_link_libraries(shared PRIVATE pfc)

# ---------------------------------------------------------------------------
# The component bundle itself.
# ---------------------------------------------------------------------------
file(GLOB COMPONENT_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.mm")

add_library(foo_out_avfoundation MODULE ${COMPONENT_SOURCES})

# Generate Info.plist at configure time (full control over CFBundlePackageType
# = BNDL and arbitrary substitutions, unlike the bundle-template mechanism).
set(MACOSX_BUNDLE_GUI_IDENTIFIER "pnck.foo-out-avfoundation")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/cmake/Info.plist.in"
               "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

set_target_properties(foo_out_avfoundation PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "component"
    OUTPUT_NAME "foo_out_avfoundation"
    CXX_STANDARD 20
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist")

# predef.h is the project prefix header (was GCC_PREFIX_HEADER = src/predef.h).
target_compile_options(foo_out_avfoundation PRIVATE
    -include "${CMAKE_CURRENT_SOURCE_DIR}/src/predef.h"
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

target_include_directories(foo_out_avfoundation PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")

# Version string baked into the About box (main.cpp reads CURRENT_VERSION).
target_compile_definitions(foo_out_avfoundation PRIVATE CURRENT_VERSION=${FB2K_VERSION})

target_link_libraries(foo_out_avfoundation PRIVATE
    fb2k_sdk_includes
    foobar2000_component_client
    foobar2000_SDK_helpers
    foobar2000_SDK
    shared
    pfc
    "-framework AVFoundation"
    "-framework AVFAudio"
    "-framework CoreAudio"
    "-framework CoreMedia"
    "-framework AudioToolbox"
    "-framework Cocoa")

# Re-sign the finished bundle (Xcode did CodeSignOnCopy). Skip if identity is "".
if(NOT CODESIGN_IDENTITY STREQUAL "")
    add_custom_command(TARGET foo_out_avfoundation POST_BUILD
        COMMAND codesign --force --timestamp=none
                --sign "${CODESIGN_IDENTITY}"
                "$<TARGET_BUNDLE_DIR:foo_out_avfoundation>"
        COMMENT "Codesigning foo_out_avfoundation.component (${CODESIGN_IDENTITY})"
        VERBATIM)
endif()

# Mirror the old build's artifact location: dist/mac/foo_out_avfoundation.component
add_custom_command(TARGET foo_out_avfoundation POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_SOURCE_DIR}/dist/mac"
    COMMAND ${CMAKE_COMMAND} -E rm -rf
            "${CMAKE_CURRENT_SOURCE_DIR}/dist/mac/foo_out_avfoundation.component"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            "$<TARGET_BUNDLE_DIR:foo_out_avfoundation>"
            "${CMAKE_CURRENT_SOURCE_DIR}/dist/mac/foo_out_avfoundation.component"
    COMMENT "Copying component to dist/mac/"
    VERBATIM)
