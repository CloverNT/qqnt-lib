cmake_minimum_required(VERSION 3.19)
project(qqnt_sdk_example CXX)

# Which repo/release to pull the SDK from, and which version.
set(QQNT_SDK_REPO    "owner/repo" CACHE STRING "GitHub owner/repo hosting the QQNT SDK releases")
set(QQNT_SDK_VERSION "latest"     CACHE STRING "latest | <build> | qq-<build> | <ver>-<build>")

# For a pure N-API addon (the host process resolves the symbols at load time),
# set this OFF before including the module to get headers-only:
#   set(QQNT_SDK_LINK_LIBS OFF)

include(${CMAKE_CURRENT_LIST_DIR}/../../cmake/qqnt_sdk.cmake)

add_executable(qqnt_example main.cpp)
target_link_libraries(qqnt_example PRIVATE QQNT::QQNT)

message(STATUS "Example using QQNT SDK ${QQNT_SDK_VERSION_RESOLVED} "
               "(node ${QQNT_NODE_VERSION}, electron ${QQNT_ELECTRON_VERSION}) at ${QQNT_SDK_DIR}")
