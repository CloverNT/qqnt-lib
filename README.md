# qq_lib_autogen

A GitHub Actions pipeline you trigger manually — give it a QQ version and an
official QQ download link — that publishes a **QQNT SDK** as a GitHub Release:
four `.zip` packages (**Windows x64/arm64**, **Linux x64/arm64**), each with the
linkable libs **and** the matching Node/Electron headers. (Manual because QQ
geo-gates its version config, so CI can't auto-discover the latest — see
[Why manual?](#why-manual).)

- **Windows libs** → reads each PE's exports into a `.def` and runs MSVC
  `lib.exe` to produce a genuine **MSVC import library** `<name>.lib` (+ `.def`):
  `QQ.exe`→`QQ.lib`, `QQNT.dll`→`QQNT.lib`, `wrapper.node`→`wrapper.lib`.
  Toolchain: MSVC via `ilammy/msvc-dev-cmd` — no extra download.
- **Linux libs** → native ELF objects that link directly, so the job just copies
  `qq` and `wrapper.node`.
- **Headers** → QQNT is Electron; the embedded Electron version is detected from
  the binary, and **that Electron's Node headers** are bundled (its `v8.h`
  matches `QQNT.dll`'s electron-patched V8 — stock nodejs.org headers would not).

## Package contents & naming

Release **tag `qq-<version>`** (e.g. `qq-9.9.31-49738` — the version you passed), four assets:

```
qqnt-sdk-9.9.31-49738-windows-x64.zip
qqnt-sdk-9.9.31-49738-windows-arm64.zip
qqnt-sdk-3.2.29-49738-linux-x64.zip
qqnt-sdk-3.2.29-49738-linux-arm64.zip
```

Each zip contains:

```
qqnt-sdk-<x.x.xx-xxxxx>-<system>-<arch>/
  include/QQNT/        node + v8 headers (node.h, node_api.h, v8.h, uv.h, cppgc/, ...)
  lib/                 win: *.def + *.lib   ·   linux: qq, wrapper.node
  manifest.txt         version, arch, sources, and electron/node/v8 versions
```

The asset's `<x.x.xx-xxxxx>` is the platform's own version + the shared build
number (`9.9.31-49738` on Windows, `3.2.29-49738` on Linux for the same release),
detected from the binaries. The release **tag** is `qq-<version>` from the version
you passed in — that's what CMake consumers request.

## Using the headers

Add the package's `include/` to your include path and use the `QQNT/` prefix:

```cpp
#include <QQNT/node.h>
#include <QQNT/node_api.h>
#include <QQNT/v8.h>
```

```sh
# Windows (MSVC): link against the import lib
cl my.cpp /I path\to\sdk\include  path\to\sdk\lib\QQNT.lib
# Linux: link directly against the ELF object
clang++ my.cpp -I path/to/sdk/include  path/to/sdk/lib/wrapper.node -o my
```

## Consuming the SDK from CMake

`cmake/qqnt_sdk.cmake` downloads the right package from this repo's Releases,
caches it, and gives you a ready target:

```cmake
cmake_minimum_required(VERSION 3.19)
project(myapp CXX)

set(QQNT_SDK_REPO    "CloverNT/qqnt-sdk")   # the repo hosting the releases
set(QQNT_SDK_VERSION "9.9.31-49738")  # the version you built; or "latest" for the newest release
include(/path/to/cmake/qqnt_sdk.cmake)

add_executable(myapp main.cpp)
target_link_libraries(myapp PRIVATE QQNT::QQNT)   # adds include/ (+ the libs)
# then:  #include <QQNT/node.h>   /   <QQNT/node_api.h>   /   <QQNT/v8.h>
```

It picks the `windows`/`linux` + `x64`/`arm64` package automatically, defines
`QQNT::QQNT`, and exports `QQNT_SDK_DIR`, `QQNT_NODE_VERSION`,
`QQNT_ELECTRON_VERSION`, `QQNT_V8_VERSION`, etc. See `examples/cmake_consumer/`.

**Caching (no repeated downloads).** The package is extracted into a per-user
cache (`%LOCALAPPDATA%\qqnt-sdk` / `~/.cache/qqnt-sdk`, override with
`QQNT_SDK_CACHE_DIR`). Re-running CMake reuses it with **no network**; a fresh
build dir reuses the same cache without re-downloading. Useful knobs:

- `QQNT_SDK_LINK_LIBS=OFF` — headers only (e.g. an N-API addon whose host
  resolves the symbols at load time).
- `QQNT_SDK_OFFLINE=ON` — never hit the network (fail unless already cached).
- `QQNT_SDK_UPDATE=ON` — re-resolve `latest` even if something is cached.
- `QQNT_SDK_GITHUB_TOKEN` — for the releases API / a private repo.

On Windows the package ships MSVC import libs (`*.lib`); the module links them
directly (MSVC or clang-cl). On Linux it links the `.node` shared object directly
(`qq` is the Electron executable — provided for reference, not linked).

## How it works

1. **You trigger it:** Actions → *Build QQ NT libs* → *Run workflow*, and fill in:
   - `version` — the QQ version this build is for, e.g. `9.9.31-49738` (becomes the
     release tag `qq-9.9.31-49738`, and what CMake consumers request).
   - `win_url` — an official QQ **Windows** installer link (any arch). Blank = skip Windows.
   - `linux_url` — an official QQ **Linux `.deb`** link (any arch). Blank = skip Linux.
   - `force` — rebuild even if the release already has the assets.

   Get the links from <https://im.qq.com> (download page → copy the link). One
   link per platform is enough — `resolve.mjs` derives the sibling arch by
   swapping the arch token (`_x64_`↔`_arm64_`, `_amd64_`↔`_arm64_`) and `HEAD`s
   each against QQ's CDN to drop any that are pruned/typo'd.
2. `prepare-release` creates the release `qq-<version>` once.
3. Matrix jobs (one per live arch) download the installer/`.deb`, build the libs,
   bundle the headers, and `gh release upload --clobber` their `.zip`.
4. **Header/version detection:** each build job scans its binary (`QQNT.dll` on
   Windows, `qq` on Linux) for the `Electron/<x.y.z>` string, downloads
   `https://artifacts.electronjs.org/headers/dist/v<E>/node-v<E>-headers.tar.gz`,
   and remaps `include/node/*` → `include/QQNT/*`. The exact `x.x.xx-xxxxx` build
   and the node/electron/v8 versions are detected from the binaries and recorded
   in the asset names + `manifest.txt`.

A run is a no-op (`skip`) if the release already has a `.zip` for every requested
arch slot (override with `force`).

### Why manual?

QQ's version config (`cdn-go.cn`) is **geo-gated**: only China IPs get the latest;
overseas/CI runners get a months-stale snapshot whose installer files QQ has
already pruned (404). The download URLs also carry an **unguessable per-build hash**
(`…/release/<hash>/…`), so a version number alone can't be turned into a URL. So a
CI runner genuinely *cannot* auto-discover the latest. The reliable, QQ-direct
path is: you (who can see the current version) paste the official link; CI
downloads it (the **bytes** download fine worldwide once the URL is known).

## Target mapping

| Concept | Windows | Linux equivalent |
|---|---|---|
| Main executable | `QQ.exe` → `QQ.def` + `QQ.lib` | `qq` (ELF) |
| Core wrapper addon | `wrapper.node` → `wrapper.def` + `wrapper.lib` | `wrapper.node` (ELF) |
| QQNT core native | `QQNT.dll` → `QQNT.def` + `QQNT.lib` | *(not collected on Linux)* |

## Repository layout

```
.github/workflows/build_qq_libs.yml   resolve → prepare-release → build-windows / build-linux (matrix)
scripts/resolve.mjs                   version + QQ link → per-arch URLs (HEAD-checked) + release-skip
scripts/gen_import_libs.sh            Windows: 7z extract + PE→.def + MSVC lib.exe + headers
scripts/pe_to_def.mjs                 read a PE export table → a .def for lib.exe
scripts/extract_linux.sh             Linux: dpkg-deb extract + copy ELF + headers
scripts/fetch_headers.sh             detect Electron ver → download node headers → include/QQNT
cmake/qqnt_sdk.cmake                   consumer module: download+cache the SDK, define QQNT::QQNT
examples/cmake_consumer/             minimal project that pulls and uses the SDK
```

Artifacts live on the **Releases** page, not in the repo (the Linux ELF objects
are hundreds of MB — they belong in releases, not git history).

## Setup notes

- Requires **Read and write** workflow permissions (Settings → Actions → General)
  so the jobs can create/upload the release with the built-in `GITHUB_TOKEN`.
- Windows uses MSVC `lib.exe` (set up by `ilammy/msvc-dev-cmd`); no toolchain download.

## Caveats / limitations

- **Electron headers, not stock Node:** the V8 is electron-patched, so the
  bundled `v8.h` is Electron's. N-API (`node_api.h`) is ABI-stable across both.
  `manifest.txt` records the exact electron / node / v8 versions.
- **`QQNT.dll` may be absent in some builds** (logic can move into the `.node`
  addons). The Windows job warns and records it in `manifest.txt`, still building
  the targets it found (it only fails if none are found).
- **`QQ.exe` exports:** an EXE may export few/no symbols; its `.def`/`.a` can be
  small — expected.
- **arm64 Windows import libs** are produced by the x64 `lib.exe` with
  `/machine:ARM64` (no arm64 code is run).
- **`skip`** treats a release as done once it has a `.zip` for each requested arch
  slot under tag `qq-<version>`; uploads use `--clobber`, so re-runs never
  duplicate or corrupt assets. Use **force** to rebuild.
- **Manual / you supply the link:** QQ geo-gates version discovery and its URLs
  carry an unguessable per-build hash, so CI can't auto-find the latest — you paste
  the official link (the bytes then download fine from any region).

## Local testing

```bash
GITHUB_OUTPUT=/dev/stdout node scripts/resolve.mjs   # resolved latest + tag + asset names
```
