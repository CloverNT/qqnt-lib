# ===========================================================================
# qqnt_sdk.cmake — download & configure the QQNT SDK from this repo's Releases.
#
# Resolves the matching qqnt-sdk-<ver>-<system>-<arch>.zip asset, downloads and
# extracts it into a persistent cache (so re-running CMake does NOT re-download),
# and defines an imported target plus result variables.
#
# Quick start (in your CMakeLists.txt):
#
#   set(QQNT_SDK_REPO   "owner/repo")     # the GitHub repo that hosts the releases
#   set(QQNT_SDK_VERSION "latest")        # or "49738" / "qq-49738" / "9.9.31-49738"
#   include(${CMAKE_CURRENT_LIST_DIR}/cmake/qqnt_sdk.cmake)
#
#   add_executable(app main.cpp)
#   target_link_libraries(app PRIVATE QQNT::QQNT)   # adds include/ (+ libs)
#   # then:  #include <QQNT/node.h>   /   <QQNT/node_api.h>   /   <QQNT/v8.h>
#
# Options / cache variables (set before include()):
#   QQNT_SDK_REPO         owner/repo (required; auto-detected from this checkout's
#                         git 'origin' remote if unset)
#   QQNT_SDK_VERSION      "latest" (default) or a build number / tag / full version
#   QQNT_SDK_ARCH         x64 | arm64        (default: from CMAKE_SYSTEM_PROCESSOR)
#   QQNT_SDK_CACHE_DIR    download/extract cache (default: per-user cache dir)
#   QQNT_SDK_GITHUB_TOKEN token for the releases API / private repos (optional)
#   QQNT_SDK_LINK_LIBS    ON (default) to also link the libs; OFF for headers-only
#                         (e.g. an N-API addon whose host resolves symbols)
#   QQNT_SDK_OFFLINE      ON to never hit the network (fail if not already cached)
#   QQNT_SDK_UPDATE       ON to re-resolve "latest" even if something is cached
#
# Result variables (set in the including scope):
#   QQNT_SDK_DIR, QQNT_SDK_INCLUDE_DIR, QQNT_SDK_LIB_DIR
#   QQNT_SDK_VERSION_RESOLVED, QQNT_NODE_VERSION, QQNT_ELECTRON_VERSION, QQNT_V8_VERSION
# ===========================================================================

if(CMAKE_VERSION VERSION_LESS 3.19)
  message(FATAL_ERROR "qqnt_sdk: CMake >= 3.19 required (string(JSON), file(ARCHIVE_EXTRACT)).")
endif()

# ---- inputs / defaults ----------------------------------------------------
if(NOT DEFINED QQNT_SDK_VERSION)
  set(QQNT_SDK_VERSION "latest")
endif()
if(NOT DEFINED QQNT_SDK_LINK_LIBS)
  set(QQNT_SDK_LINK_LIBS ON)
endif()
if(NOT DEFINED QQNT_SDK_OFFLINE)
  set(QQNT_SDK_OFFLINE OFF)
endif()
if(NOT DEFINED QQNT_SDK_UPDATE)
  set(QQNT_SDK_UPDATE OFF)
endif()

# ---- system / arch --------------------------------------------------------
if(WIN32)
  set(_qq_sys "windows")
elseif(UNIX AND NOT APPLE)
  set(_qq_sys "linux")
else()
  message(FATAL_ERROR "qqnt_sdk: only windows/linux SDK packages are published.")
endif()

if(NOT QQNT_SDK_ARCH)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "[Aa][Rr][Mm]64|aarch64")
    set(QQNT_SDK_ARCH "arm64")
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64|x64")
    set(QQNT_SDK_ARCH "x64")
  elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(QQNT_SDK_ARCH "x64")
  else()
    message(FATAL_ERROR "qqnt_sdk: cannot infer arch from '${CMAKE_SYSTEM_PROCESSOR}'; set QQNT_SDK_ARCH.")
  endif()
endif()
set(_qq_slot "${_qq_sys}-${QQNT_SDK_ARCH}")

# ---- repo (explicit, else from this checkout's git origin) ----------------
if(NOT QQNT_SDK_REPO)
  find_program(_qq_git git)
  if(_qq_git)
    execute_process(COMMAND ${_qq_git} -C "${CMAKE_CURRENT_LIST_DIR}" remote get-url origin
      OUTPUT_VARIABLE _qq_origin OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
    if(_qq_origin MATCHES "github\\.com[:/]+([^/]+/[^/]+)")
      string(REGEX REPLACE "\\.git$" "" QQNT_SDK_REPO "${CMAKE_MATCH_1}")
    endif()
  endif()
endif()
if(NOT QQNT_SDK_REPO)
  set(QQNT_SDK_REPO "CloverNT/qqnt-sdk")   # default: this project's repo
endif()

# ---- cache dir ------------------------------------------------------------
if(NOT QQNT_SDK_CACHE_DIR)
  if(DEFINED ENV{QQNT_SDK_CACHE_DIR})
    set(QQNT_SDK_CACHE_DIR "$ENV{QQNT_SDK_CACHE_DIR}")
  elseif(WIN32 AND DEFINED ENV{LOCALAPPDATA})
    set(QQNT_SDK_CACHE_DIR "$ENV{LOCALAPPDATA}/qqnt-sdk")
  elseif(DEFINED ENV{XDG_CACHE_HOME})
    set(QQNT_SDK_CACHE_DIR "$ENV{XDG_CACHE_HOME}/qqnt-sdk")
  elseif(DEFINED ENV{HOME})
    set(QQNT_SDK_CACHE_DIR "$ENV{HOME}/.cache/qqnt-sdk")
  else()
    set(QQNT_SDK_CACHE_DIR "${CMAKE_BINARY_DIR}/qqnt-sdk")
  endif()
endif()
file(MAKE_DIRECTORY "${QQNT_SDK_CACHE_DIR}")

set(_qq_hdr "Accept: application/vnd.github+json")
if(QQNT_SDK_GITHUB_TOKEN)
  set(_qq_auth "Authorization: Bearer ${QQNT_SDK_GITHUB_TOKEN}")
else()
  set(_qq_auth "X-QQNT-NoAuth: 1")   # harmless placeholder header
endif()

# ---- helper: find an already-extracted SDK in the cache for this slot ------
function(_qq_find_cached out_dir)
  set(${out_dir} "" PARENT_SCOPE)
  file(GLOB _cands "${QQNT_SDK_CACHE_DIR}/qqnt-sdk-*-${_qq_slot}")
  list(SORT _cands)
  list(REVERSE _cands)   # newest version sorts last -> first after reverse
  foreach(_c ${_cands})
    if(IS_DIRECTORY "${_c}" AND EXISTS "${_c}/.qqnt-sdk-ok")
      set(${out_dir} "${_c}" PARENT_SCOPE)
      return()
    endif()
  endforeach()
endfunction()

# ---- fast path: reuse a previously resolved SDK with NO network ------------
set(_qq_req "${QQNT_SDK_VERSION}:${_qq_slot}")
set(_qq_dir "")
if(NOT QQNT_SDK_UPDATE
   AND DEFINED QQNT_SDK_CACHED_DIR
   AND QQNT_SDK_CACHED_REQ STREQUAL "${_qq_req}"
   AND EXISTS "${QQNT_SDK_CACHED_DIR}/.qqnt-sdk-ok")
  set(_qq_dir "${QQNT_SDK_CACHED_DIR}")
  message(STATUS "qqnt_sdk: using cached SDK ${_qq_dir}")
endif()

# ---- resolve + download (only if not already satisfied) -------------------
if(NOT _qq_dir)
  if(QQNT_SDK_OFFLINE)
    _qq_find_cached(_qq_dir)
    if(NOT _qq_dir)
      message(FATAL_ERROR "qqnt_sdk: OFFLINE and no cached ${_qq_slot} SDK in ${QQNT_SDK_CACHE_DIR}.")
    endif()
    message(STATUS "qqnt_sdk: OFFLINE, using cached ${_qq_dir}")
  else()
    # Build the releases API url: latest, or a specific tag qq-<build>.
    if(QQNT_SDK_VERSION STREQUAL "latest")
      set(_qq_api "https://api.github.com/repos/${QQNT_SDK_REPO}/releases/latest")
    else()
      string(REGEX MATCH "[0-9]+$" _qq_build "${QQNT_SDK_VERSION}")  # trailing build digits
      if(NOT _qq_build)
        message(FATAL_ERROR "qqnt_sdk: cannot parse a build number from '${QQNT_SDK_VERSION}'.")
      endif()
      set(_qq_api "https://api.github.com/repos/${QQNT_SDK_REPO}/releases/tags/qq-${_qq_build}")
    endif()

    set(_qq_json "${QQNT_SDK_CACHE_DIR}/.release-${QQNT_SDK_VERSION}-${_qq_slot}.json")
    message(STATUS "qqnt_sdk: querying ${_qq_api}")
    file(DOWNLOAD "${_qq_api}" "${_qq_json}"
      HTTPHEADER "${_qq_hdr}" HTTPHEADER "${_qq_auth}" TLS_VERIFY ON STATUS _qq_st)
    list(GET _qq_st 0 _qq_rc)
    if(NOT _qq_rc EQUAL 0)
      list(GET _qq_st 1 _qq_msg)
      message(FATAL_ERROR "qqnt_sdk: release query failed (${_qq_msg}). URL: ${_qq_api}")
    endif()

    # Parse the assets array for the qqnt-sdk-*-<slot>.zip asset.
    file(READ "${_qq_json}" _qq_body)
    string(JSON _qq_n ERROR_VARIABLE _qq_jerr LENGTH "${_qq_body}" assets)
    if(_qq_jerr OR NOT _qq_n)
      message(FATAL_ERROR "qqnt_sdk: no assets in release JSON (${_qq_jerr}).")
    endif()
    set(_qq_name "")
    set(_qq_url "")
    math(EXPR _qq_last "${_qq_n} - 1")
    foreach(_i RANGE 0 ${_qq_last})
      string(JSON _qq_a GET "${_qq_body}" assets ${_i})
      string(JSON _qq_an GET "${_qq_a}" name)
      if(_qq_an MATCHES "^qqnt-sdk-.*-${_qq_slot}\\.zip$")
        string(JSON _qq_url GET "${_qq_a}" browser_download_url)
        set(_qq_name "${_qq_an}")
        break()
      endif()
    endforeach()
    if(NOT _qq_name)
      message(FATAL_ERROR "qqnt_sdk: no qqnt-sdk-*-${_qq_slot}.zip asset in ${_qq_api}.")
    endif()

    string(REGEX REPLACE "\\.zip$" "" _qq_stem "${_qq_name}")
    set(_qq_dir "${QQNT_SDK_CACHE_DIR}/${_qq_stem}")
    set(_qq_zip "${QQNT_SDK_CACHE_DIR}/${_qq_name}")

    if(EXISTS "${_qq_dir}/.qqnt-sdk-ok")
      message(STATUS "qqnt_sdk: already cached ${_qq_stem}")
    else()
      if(NOT EXISTS "${_qq_zip}")
        message(STATUS "qqnt_sdk: downloading ${_qq_name}")
        file(DOWNLOAD "${_qq_url}" "${_qq_zip}.part"
          HTTPHEADER "${_qq_auth}" TLS_VERIFY ON SHOW_PROGRESS STATUS _qq_dst)
        list(GET _qq_dst 0 _qq_drc)
        if(NOT _qq_drc EQUAL 0)
          file(REMOVE "${_qq_zip}.part")
          list(GET _qq_dst 1 _qq_dmsg)
          message(FATAL_ERROR "qqnt_sdk: download failed (${_qq_dmsg}). URL: ${_qq_url}")
        endif()
        file(RENAME "${_qq_zip}.part" "${_qq_zip}")
      endif()
      message(STATUS "qqnt_sdk: extracting ${_qq_name}")
      file(REMOVE_RECURSE "${_qq_dir}")
      file(ARCHIVE_EXTRACT INPUT "${_qq_zip}" DESTINATION "${QQNT_SDK_CACHE_DIR}")
      if(NOT IS_DIRECTORY "${_qq_dir}/include/QQNT")
        message(FATAL_ERROR "qqnt_sdk: extracted SDK missing include/QQNT (${_qq_dir}).")
      endif()
      file(WRITE "${_qq_dir}/.qqnt-sdk-ok" "${_qq_name}\n")
    endif()
  endif()

  # Remember the resolution so reconfigures skip the network entirely.
  set(QQNT_SDK_CACHED_DIR "${_qq_dir}" CACHE INTERNAL "resolved QQNT SDK dir")
  set(QQNT_SDK_CACHED_REQ "${_qq_req}" CACHE INTERNAL "resolved QQNT SDK request key")
endif()

# ---- read versions from manifest.txt --------------------------------------
set(QQNT_SDK_VERSION_RESOLVED "")
set(QQNT_NODE_VERSION "")
set(QQNT_ELECTRON_VERSION "")
set(QQNT_V8_VERSION "")
if(EXISTS "${_qq_dir}/manifest.txt")
  file(STRINGS "${_qq_dir}/manifest.txt" _qq_man)
  foreach(_l ${_qq_man})
    if(_l MATCHES "^version=(.+)$")
      set(QQNT_SDK_VERSION_RESOLVED "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^node=(.+)$")
      set(QQNT_NODE_VERSION "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^electron=(.+)$")
      set(QQNT_ELECTRON_VERSION "${CMAKE_MATCH_1}")
    elseif(_l MATCHES "^v8=(.+)$")
      set(QQNT_V8_VERSION "${CMAKE_MATCH_1}")
    endif()
  endforeach()
endif()

set(QQNT_SDK_DIR         "${_qq_dir}")
set(QQNT_SDK_INCLUDE_DIR "${_qq_dir}/include")
set(QQNT_SDK_LIB_DIR     "${_qq_dir}/lib")

# ---- collect libraries ----------------------------------------------------
set(_qq_libs "")
if(QQNT_SDK_LINK_LIBS)
  if(_qq_sys STREQUAL "windows")
    if(MSVC)
      # MSVC can't consume the MinGW *.a import libs; synthesise *.lib from the
      # shipped *.def with the MSVC librarian (cached: only built once).
      find_program(QQNT_LIB_TOOL NAMES lib lib.exe)
      if(QQNT_SDK_ARCH STREQUAL "arm64")
        set(_qq_machine "ARM64")
      else()
        set(_qq_machine "X64")
      endif()
      if(QQNT_LIB_TOOL)
        file(GLOB _qq_defs "${_qq_dir}/lib/*.def")
        foreach(_def ${_qq_defs})
          get_filename_component(_b "${_def}" NAME_WE)
          set(_out "${_qq_dir}/lib/${_b}.lib")
          if(NOT EXISTS "${_out}")
            execute_process(COMMAND "${QQNT_LIB_TOOL}" "/nologo" "/def:${_def}"
              "/machine:${_qq_machine}" "/out:${_out}" RESULT_VARIABLE _qq_lrc ERROR_VARIABLE _qq_lerr)
            if(NOT _qq_lrc EQUAL 0)
              message(WARNING "qqnt_sdk: lib.exe failed for ${_b}.def: ${_qq_lerr}")
            endif()
          endif()
          if(EXISTS "${_out}")
            list(APPEND _qq_libs "${_out}")
          endif()
        endforeach()
      else()
        message(WARNING "qqnt_sdk: MSVC detected but lib.exe not found — headers are configured, "
                        "but import libs were not generated. Build in a VS dev environment, or "
                        "use clang/MinGW to link the shipped *.a directly.")
      endif()
    else()
      file(GLOB _qq_libs "${_qq_dir}/lib/*.a")   # MinGW/clang import libs
    endif()
  else()
    # Linux: link the native ELF shared objects directly. `qq` is the Electron
    # executable (provided for reference) and is intentionally not linked.
    file(GLOB _qq_libs "${_qq_dir}/lib/*.node" "${_qq_dir}/lib/*.so")
  endif()
endif()

# ---- imported target ------------------------------------------------------
if(NOT TARGET QQNT::QQNT)
  add_library(QQNT::QQNT INTERFACE IMPORTED)
endif()
set_property(TARGET QQNT::QQNT PROPERTY INTERFACE_INCLUDE_DIRECTORIES "${QQNT_SDK_INCLUDE_DIR}")
if(_qq_libs)
  set_property(TARGET QQNT::QQNT PROPERTY INTERFACE_LINK_LIBRARIES "${_qq_libs}")
endif()

message(STATUS "qqnt_sdk: ready ${QQNT_SDK_VERSION_RESOLVED} (${_qq_slot}) "
               "node ${QQNT_NODE_VERSION} / electron ${QQNT_ELECTRON_VERSION} @ ${QQNT_SDK_DIR}")
