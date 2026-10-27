cmake_minimum_required(VERSION 3.20)
# Must match MACOSX_DEPLOYMENT_TARGET in mac/project.yml.
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version")
project(viracm_core LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

option(VIRACM_BUILD_TESTS "Build core tests" ON)
option(VIRACM_BUILD_TOOLS "Build the viracm_cli image tool" ON)

# Fetched by scripts/fetch_deps.sh.
set(VIRACM_THIRD_PARTY "${CMAKE_CURRENT_SOURCE_DIR}/../third_party" CACHE PATH "Third-party dependencies")
set(VIRACM_MODEL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../models" CACHE PATH "Model directory")
set(ORT_DIR "${VIRACM_THIRD_PARTY}/onnxruntime")
if(NOT EXISTS "${ORT_DIR}/include/onnxruntime_cxx_api.h")
  message(FATAL_ERROR "ONNX Runtime not found in ${ORT_DIR}. Run scripts/fetch_deps.sh first.")
endif()

add_library(onnxruntime SHARED IMPORTED)
set_target_properties(onnxruntime PROPERTIES
  IMPORTED_LOCATION "${ORT_DIR}/lib/${CMAKE_SHARED_LIBRARY_PREFIX}onnxruntime${CMAKE_SHARED_LIBRARY_SUFFIX}"
  INTERFACE_INCLUDE_DIRECTORIES "${ORT_DIR}/include")

add_library(viracm_core STATIC
  src/compositor.cpp
  src/engine.cpp
  src/face_detector.cpp
  src/face_tracker.cpp
  src/primary_region.cpp
  src/privacy_blur.cpp
  src/privacy_policy.cpp
)
target_include_directories(viracm_core PUBLIC include PRIVATE src)
target_link_libraries(viracm_core PUBLIC onnxruntime)
target_compile_options(viracm_core PRIVATE -Wall -Wextra)

if(VIRACM_BUILD_TOOLS)
  add_executable(viracm_cli tools/viracm_cli.cpp tools/stb_impl.cpp)
  target_include_directories(viracm_cli PRIVATE "${VIRACM_THIRD_PARTY}/stb")
  target_link_libraries(viracm_cli PRIVATE viracm_core)
  set_target_properties(viracm_cli PROPERTIES BUILD_RPATH "${ORT_DIR}/lib")
endif()

if(VIRACM_BUILD_TESTS)
  enable_testing()
  add_executable(viracm_core_tests tests/core_tests.cpp)
  target_include_directories(viracm_core_tests PRIVATE src)
  target_compile_definitions(viracm_core_tests PRIVATE VIRACM_MODEL_DIR="${VIRACM_MODEL_DIR}")
  target_link_libraries(viracm_core_tests PRIVATE viracm_core)
  set_target_properties(viracm_core_tests PROPERTIES BUILD_RPATH "${ORT_DIR}/lib")
  add_test(NAME viracm_core_tests COMMAND viracm_core_tests)
endif()

if(VIRACM_BUILD_TOOLS)
  # Third-party code; its unused HDR writer calls sprintf.
  set_source_files_properties(tools/stb_impl.cpp PROPERTIES COMPILE_OPTIONS "-Wno-deprecated-declarations")
endif()
