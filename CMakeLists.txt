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

# ---------------------------------------------------------------------------
# Version — ONE declared base, with overrides layered on top.
#   * Bump BASE_VERSION (this single line) when you start a new version locally.
#     A local Debug build appends the commit hash + dirty flag (see FB2K_VERSION below);
#     a local Release build shows BASE_VERSION as-is.
#   * On a tagged release CI passes -DVERSION_OVERRIDE=<tag>, which wins over BASE_VERSION,
#     so the published build always matches its tag even if BASE_VERSION wasn't bumped.
# Everything downstream — Info.plist's CFBundle*Version and the About-box string — derives
# from this. There is no second place that hard-codes a version number.
# ---------------------------------------------------------------------------
set(BASE_VERSION "0.1.1")
if(VERSION_OVERRIDE)
    set(BASE_VERSION "${VERSION_OVERRIDE}")
endif()

project(foo_out_avfoundation
    VERSION ${BASE_VERSION}
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

# About-box string for DECLARE_COMPONENT_VERSION (main.cpp's CURRENT_VERSION). Starts from
# PROJECT_VERSION (= BASE_VERSION, or the tag when overridden) and, for Debug, appends the commit
# hash + dirty flag so a dev build is traceable to a commit + state. A clean Release / tagged build
# shows just the version. Never cached, so the hash / dirty flag can't go stale.
unset(FB2K_VERSION CACHE)
set(FB2K_VERSION "${PROJECT_VERSION}")
find_package(Git QUIET)
if(GIT_FOUND AND CMAKE_BUILD_TYPE STREQUAL "Debug")
    execute_process(COMMAND "${GIT_EXECUTABLE}" rev-parse --short HEAD
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE _git_hash OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    execute_process(COMMAND "${GIT_EXECUTABLE}" status --porcelain --untracked-files=no
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE _git_dirty OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_git_hash)
        set(FB2K_VERSION "${PROJECT_VERSION}-${_git_hash}")
        if(_git_dirty)
            string(APPEND FB2K_VERSION "-dirty")
        endif()
    endif()
endif()
message(STATUS "Component version: ${FB2K_VERSION}")

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
# Whole directory: pfc's win-*/nix-* files self-gate with #ifdef, so all compile.
file(GLOB PFC_SOURCES CONFIGURE_DEPENDS "${SDK}/pfc/*.cpp" "${SDK}/pfc/*.mm")
add_library(pfc STATIC ${PFC_SOURCES})
fb2k_sdk_lib(pfc 17 "${SDK}/pfc/pfc-lite.h")

# --- foobar2000_SDK --------------------------------------------------------
file(GLOB FB2K_SDK_SOURCES CONFIGURE_DEPENDS
    "${SDK}/foobar2000/SDK/*.cpp" "${SDK}/foobar2000/SDK/*.mm")
add_library(foobar2000_SDK STATIC ${FB2K_SDK_SOURCES})
fb2k_sdk_lib(foobar2000_SDK 17 "${SDK}/foobar2000/SDK/foobar2000-sdk-pch.h")
target_link_libraries(foobar2000_SDK PRIVATE pfc)

# --- foobar2000_SDK_helpers ------------------------------------------------
# Glob the directory, then drop the Win32/UI-only sources that aren't in the SDK's
# Apple Sources build phase (they #include <windows.h> etc. and don't build on macOS).
# A new cross-platform helper is picked up automatically; a new Windows-only one will
# fail to compile, flagging that it needs adding to this exclude list. (Note: win-systemtime,
# win32_misc, file_win32_wrapper DO build on macOS — they self-gate — so they're kept.)
file(GLOB FB2K_HELPERS_SOURCES CONFIGURE_DEPENDS
    "${SDK}/foobar2000/helpers/*.cpp" "${SDK}/foobar2000/helpers/*.mm")
list(FILTER FB2K_HELPERS_SOURCES EXCLUDE REGEX
    "/(AutoComplete|CTableEditHelper-Legacy|DarkMode|WindowPositionUtils|image_load_save|inplace_edit|ui_element_helpers|win32_dialog|window_placement_helper)\\.cpp$")
add_library(foobar2000_SDK_helpers STATIC ${FB2K_HELPERS_SOURCES})
fb2k_sdk_lib(foobar2000_SDK_helpers 17 "${SDK}/foobar2000/helpers/StdAfx.h")
target_link_libraries(foobar2000_SDK_helpers PRIVATE pfc foobar2000_SDK)

# --- foobar2000_component_client ------------------------------------------
add_library(foobar2000_component_client STATIC
    ${SDK}/foobar2000/foobar2000_component_client/component_client.cpp)
fb2k_sdk_lib(foobar2000_component_client 20 "")
target_link_libraries(foobar2000_component_client PRIVATE pfc foobar2000_SDK)

# --- shared (built from source on Apple; the .lib files are Windows-only) ---
# Same glob-then-exclude pattern: drop the Win32 UI / crash-reporting sources that
# aren't in the SDK's Apple build (filedialogs, systray, minidump, …).
file(GLOB SHARED_SOURCES CONFIGURE_DEPENDS
    "${SDK}/foobar2000/shared/*.cpp" "${SDK}/foobar2000/shared/*.mm")
list(FILTER SHARED_SOURCES EXCLUDE REGEX
    "/(Utility|crash_info|filedialogs|filedialogs_vista|font_description|minidump|modal_dialog|systray|text_drawing|utf8api)\\.cpp$")
add_library(shared STATIC ${SHARED_SOURCES})
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
