cmake_minimum_required(VERSION 3.20)
# Must match MACOSX_DEPLOYMENT_TARGET in mac/project.yml.
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
project(vircam_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(VIRCAM_BUILD_TESTS "Build core tests" ON)
option(VIRCAM_BUILD_TOOLS "Build the vircam_cli image tool" ON)

# Fetched by scripts/fetch_deps.sh.
set(VIRCAM_THIRD_PARTY "${CMAKE_CURRENT_SOURCE_DIR}/../third_party" CACHE PATH "Third-party dependencies")
set(VIRCAM_MODEL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../models" CACHE PATH "Model directory")
set(ORT_DIR "${VIRCAM_THIRD_PARTY}/onnxruntime")
if(NOT EXISTS "${ORT_DIR}/include/onnxruntime_cxx_api.h")
  message(FATAL_ERROR "ONNX Runtime not found in ${ORT_DIR}. Run scripts/fetch_deps.sh first.")
endif()

add_library(onnxruntime SHARED IMPORTED)
set_target_properties(onnxruntime PROPERTIES
  IMPORTED_LOCATION "${ORT_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}onnxruntime${CMAKE_SHARED_LIBRARY_SUFFIX}"
  INTERFACE_INCLUDE_DIRECTORIES "${ORT_DIR}/include")

add_library(vircam_core STATIC
  src/compositor.cpp
  src/engine.cpp
  src/face_detector.cpp
  src/face_tracker.cpp
  src/primary_region.cpp
  src/privacy_blur.cpp
  src/privacy_policy.cpp
)
target_include_directories(vircam_core PUBLIC include PRIVATE src)
target_link_libraries(vircam_core PUBLIC onnxruntime)
target_compile_options(vircam_core PRIVATE -Wall -Wextra)

if(VIRCAM_BUILD_TOOLS)
  add_executable(vircam_cli tools/vircam_cli.cpp tools/stb_impl.cpp)
  target_include_directories(vircam_cli PRIVATE "${VIRCAM_THIRD_PARTY}/stb")
  target_link_libraries(vircam_cli PRIVATE vircam_core)
  set_target_properties(vircam_cli PROPERTIES BUILD_RPATH "${ORT_DIR}/lib")
endif()

if(VIRCAM_BUILD_TESTS)
  enable_testing()
  add_executable(vircam_core_tests tests/core_tests.cpp)
  target_include_directories(vircam_core_tests PRIVATE src)
  target_compile_definitions(vircam_core_tests PRIVATE VIRCAM_MODEL_DIR="${VIRCAM_MODEL_DIR}")
  target_link_libraries(vircam_core_tests PRIVATE vircam_core)
  set_target_properties(vircam_core_tests PROPERTIES BUILD_RPATH "${ORT_DIR}/lib")
  add_test(NAME vircam_core_tests COMMAND vircam_core_tests)
endif()

if(VIRCAM_BUILD_TOOLS)
  # Third-party code; its unused HDR writer calls sprintf.
  set_source_files_properties(tools/stb_impl.cpp PROPERTIES COMPILE_OPTIONS "-Wno-deprecated-declarations")
endif()
