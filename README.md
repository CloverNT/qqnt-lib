# qq_lib_autogen

A scheduled GitHub Actions pipeline that tracks the **latest QQ NT release** and
publishes a **QQNT SDK** for it as a GitHub Release — four `.zip` packages
(**Windows x64/arm64**, **Linux x64/arm64**), each containing the linkable libs
**and** the matching Node/Electron headers.

- **Windows libs** → `gendef` dumps the exports and `llvm-dlltool` builds an
  import library: `<name>.def` + `lib<name>.a`, for `QQ.exe`, `QQNT.dll`,
  `wrapper.node`. Toolchain: [llvm-mingw](https://github.com/mstorsjo/llvm-mingw)
  (one bundle covers x64 and arm64).
- **Linux libs** → native ELF objects that link directly, so the job just copies
  `qq`, `wrapper.node`, `major.node`.
- **Headers** → QQNT is Electron; the embedded Electron version is detected from
  the binary, and **that Electron's Node headers** are bundled (its `v8.h`
  matches `QQNT.dll`'s electron-patched V8 — stock nodejs.org headers would not).

## Package contents & naming

Release **tag `qq-<winver3>-<date>-<hash>`** (e.g. `qq-9.9.31-260528-092069d7`), four assets:

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
  lib/                 win: *.def + lib*.a   ·   linux: qq, wrapper.node, major.node
  manifest.txt         version, arch, sources, and electron/node/v8 versions
```

The asset's `<x.x.xx-xxxxx>` is the platform's own version + the shared build
number (`9.9.31-49738` on Windows, `3.2.29-49738` on Linux for the same release),
detected from the binaries. The release **tag** is keyed by the Windows 3-part
version + the download date code (both read straight from the frontend), so it's
robust without partial-downloading anything.

## Using the headers

Add the package's `include/` to your include path and use the `QQNT/` prefix:

```cpp
#include <QQNT/node.h>
#include <QQNT/node_api.h>
#include <QQNT/v8.h>
```

```sh
# Windows (MinGW/clang): link against the import lib
clang++ my.cpp -I path/to/sdk/include -L path/to/sdk/lib -l:libQQNT.a -o my.exe
# Linux: link directly against the ELF objects
clang++ my.cpp -I path/to/sdk/include path/to/sdk/lib/wrapper.node -o my
```

## Consuming the SDK from CMake

`cmake/qqnt_sdk.cmake` downloads the right package from this repo's Releases,
caches it, and gives you a ready target:

```cmake
cmake_minimum_required(VERSION 3.19)
project(myapp CXX)

set(QQNT_SDK_REPO    "CloverNT/qqnt-sdk")   # the repo hosting the releases
set(QQNT_SDK_VERSION "latest")       # or a release tag, e.g. "qq-9.9.31-260528-092069d7"
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

On MSVC the module synthesises `.lib` import libraries from the shipped `.def`
files (the packaged `lib*.a` are MinGW/clang import libs); with clang/MinGW the
`.a` are linked directly. On Linux the `.node`/`.so` are linked directly.

## How it works

- **Schedule:** every 12 h (cron) it parses the official QQ download pages for
  the **latest** download URLs. **Manual:** Actions → *Build QQ NT libs (latest)*
  → *Run workflow* (tick **force** to rebuild a release that already exists).
- If the release `qq-<winver3>-<date>-<hash>` already has a `.zip` for each of the four
  arch slots, the run is a **no-op**.
- Otherwise: `prepare-release` creates the release once, then four matrix jobs
  build in parallel, each `gh release upload --clobber` its package.
- **Header/version detection:** each build job scans its binary (`QQNT.dll` on
  Windows, `qq` on Linux) for the `Electron/<x.y.z>` string, downloads
  `https://artifacts.electronjs.org/headers/dist/v<E>/node-v<E>-headers.tar.gz`,
  and remaps `include/node/*` → `include/QQNT/*`. The Node and V8 versions
  (mapped from the Electron version) are recorded in `manifest.txt`.

### Resolution: always the latest, parsed from the frontend

QQ's CDN prunes old builds, so the pipeline never pins or guesses a build — it
takes whatever the official site currently serves. `resolve.mjs` fetches the
download page (`im.qq.com/pcqq/index.shtml`, `…/linuxqq/index.shtml`), reads its
`rainbowConfigUrl`, fetches that config, and pulls the four download URLs (all on
`gtimg.cn`, which works worldwide from CI). It keys the release on the Windows
3-part version + date code + the per-build content hash from the `…/release/<hash>/`
URL segment (so same-day rebuilds get a distinct release) — no partial-download.

To guard against the rare case where `cdn-go`'s `/latest/` edge serves a *stale*
config to a runner (pointing at versions QQ's CDN has already pruned), the
resolver `HEAD`s the four download URLs **directly against QQ's CDN** — no
third-party version list — and fails the run if any 404, so it never builds an
ancient version; the next scheduled run lands on a fresh edge.
The exact `x.x.xx-xxxxx` build is detected from the binaries themselves (Windows
`versions/<ver>` folder, Linux `resources/app/package.json`) and goes into the
asset names + `manifest.txt`.

## Target mapping

| Concept | Windows | Linux equivalent |
|---|---|---|
| Main executable | `QQ.exe` → `QQ.def` + `libQQ.a` | `qq` (ELF) |
| Core wrapper addon | `wrapper.node` → `wrapper.def` + `libwrapper.a` | `wrapper.node` (ELF) |
| QQNT core native | `QQNT.dll` → `QQNT.def` + `libQQNT.a` | `major.node` (no `libQQNT.so`; logic is in the `.node` addons) |

## Repository layout

```
.github/workflows/build_qq_libs.yml   resolve → prepare-release → build-windows / build-linux (matrix)
scripts/resolve.mjs                   latest release → URLs + shared build + release-skip
scripts/gen_import_libs.sh            Windows: 7z extract + gendef + llvm-dlltool + headers
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
- `LLVM_MINGW_TAG` in the workflow pins the toolchain (cached); bump to update.
- Tune the cadence via the `cron` line.

## Caveats / limitations

- **Electron headers, not stock Node:** the V8 is electron-patched, so the
  bundled `v8.h` is Electron's. N-API (`node_api.h`) is ABI-stable across both.
  `manifest.txt` records the exact electron / node / v8 versions.
- **`QQNT.dll` may be absent in some builds** (logic can move into the `.node`
  addons). The Windows job warns and records it in `manifest.txt`, still building
  the targets it found (it only fails if none are found).
- **`QQ.exe` exports:** an EXE may export few/no symbols; its `.def`/`.a` can be
  small — expected.
- **arm64 Windows import libs** are produced cross-host with `llvm-dlltool`.
- **`skip`** treats a release as done once it has a `.zip` for each arch slot
  under tag `qq-<winver3>-<date>-<hash>`; uploads use `--clobber`, so re-runs never
  duplicate or corrupt assets. Use **force** to rebuild.
- **Latest only:** the pipeline tracks the current release (QQ's CDN prunes old
  builds, so only the latest is reliably downloadable).

## Local testing

```bash
GITHUB_OUTPUT=/dev/stdout node scripts/resolve.mjs   # resolved latest + tag + asset names
```
