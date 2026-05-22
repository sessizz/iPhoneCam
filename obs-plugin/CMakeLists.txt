cmake_minimum_required(VERSION 3.25)

if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "macOS architectures" FORCE)
endif()

project(iPhoneCamOBSPlugin VERSION 0.1.0 LANGUAGES C CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

option(IPHONECAM_BUILD_OBS_PLUGIN "Build the OBS source plugin bundle" ON)
option(IPHONECAM_BUILD_TESTS "Build iPhoneCam OBS plugin unit tests" ON)

set(IPHONECAM_CORE_SOURCES
    src/protocol.cpp
    src/frame_reassembler.cpp
)

add_library(iphonecam_obs_core STATIC ${IPHONECAM_CORE_SOURCES})
target_include_directories(iphonecam_obs_core PUBLIC src)
target_compile_features(iphonecam_obs_core PUBLIC cxx_std_17)

if(APPLE AND IPHONECAM_BUILD_OBS_PLUGIN)
    set(OBS_APP_PATH "/Applications/OBS.app" CACHE PATH "Path to OBS.app")
    set(OBS_SOURCE_DIR "" CACHE PATH "Path to an OBS Studio source checkout for libobs headers")
    set(SIMDE_INCLUDE_DIR "" CACHE PATH "Path to SIMDe include directory containing simde/x86/sse2.h")

    if(NOT OBS_SOURCE_DIR AND EXISTS "/tmp/obs-studio-32.1.2/libobs/obs-module.h")
        set(OBS_SOURCE_DIR "/tmp/obs-studio-32.1.2")
    endif()
    if(NOT SIMDE_INCLUDE_DIR AND EXISTS "/tmp/simde/simde/x86/sse2.h")
        set(SIMDE_INCLUDE_DIR "/tmp/simde")
    endif()

    find_library(LIBOBS_FRAMEWORK libobs
        PATHS "${OBS_APP_PATH}/Contents/Frameworks"
        NO_DEFAULT_PATH
    )

    find_path(OBS_INCLUDE_DIR obs-module.h
        HINTS "${OBS_SOURCE_DIR}/libobs"
        NO_DEFAULT_PATH
    )
    find_path(SIMDE_RESOLVED_INCLUDE_DIR simde/x86/sse2.h
        HINTS "${SIMDE_INCLUDE_DIR}"
        NO_DEFAULT_PATH
    )

    if(NOT LIBOBS_FRAMEWORK)
        message(FATAL_ERROR "libobs.framework was not found. Set OBS_APP_PATH to a valid OBS.app.")
    endif()
    if(NOT OBS_INCLUDE_DIR)
        message(FATAL_ERROR "OBS headers were not found. Clone obs-studio and set OBS_SOURCE_DIR, e.g. -DOBS_SOURCE_DIR=/tmp/obs-studio-32.1.2")
    endif()
    if(NOT SIMDE_RESOLVED_INCLUDE_DIR)
        message(FATAL_ERROR "SIMDe headers were not found. Clone simde and set SIMDE_INCLUDE_DIR, e.g. -DSIMDE_INCLUDE_DIR=/tmp/simde")
    endif()

    add_library(iphonecam-obs MODULE
        src/plugin-main.mm
        src/obs_source.mm
        src/network_receiver.mm
        src/video_decoder.mm
    )
    target_include_directories(iphonecam-obs PRIVATE
        src
        "${OBS_SOURCE_DIR}/libobs"
        "${SIMDE_RESOLVED_INCLUDE_DIR}"
    )
    target_link_libraries(iphonecam-obs PRIVATE
        iphonecam_obs_core
        "${LIBOBS_FRAMEWORK}"
        "-framework Foundation"
        "-framework VideoToolbox"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework CoreFoundation"
    )
    target_compile_options(iphonecam-obs PRIVATE
        "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>"
    )
    set_target_properties(iphonecam-obs PROPERTIES
        BUNDLE TRUE
        BUNDLE_EXTENSION plugin
        OUTPUT_NAME "iphonecam-obs"
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/resources/Info.plist.in"
        BUILD_WITH_INSTALL_RPATH TRUE
        INSTALL_RPATH "@loader_path/../../../Frameworks;${OBS_APP_PATH}/Contents/Frameworks"
    )
endif()

if(IPHONECAM_BUILD_TESTS)
    enable_testing()
    add_executable(iphonecam_obs_protocol_tests tests/protocol_tests.cpp)
    target_link_libraries(iphonecam_obs_protocol_tests PRIVATE iphonecam_obs_core)
    add_test(NAME iphonecam_obs_protocol_tests COMMAND iphonecam_obs_protocol_tests)
endif()
