#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch_headers.sh
#
# Detect the Electron version QQ NT embeds (from QQNT.dll on Windows / the `qq`
# ELF on Linux - the "Electron/<x.y.z>" user-agent string is in both), download
# the MATCHING node/V8 headers, and lay them out so users include them as:
#     #include <QQNT/node.h>
#     #include <QQNT/node_api.h>
#     #include <QQNT/v8.h>           ... etc.
#
# QQNT's V8 is electron-patched (e.g. 13.8.258.18-electron.0), so we ship
# ELECTRON's node headers (whose v8.h matches QQNT.dll's exported V8 symbols),
# NOT stock nodejs.org headers. The bundled Node version (e.g. 22.16.0) is
# recorded in the manifest.
#
# Usage:  fetch_headers.sh <binary-to-scan> <sdk-out-dir>
#   -> writes <sdk-out-dir>/include/QQNT/...  and appends versions to manifest.txt
#
# Honors $CURL_OPTS (e.g. for local testing behind a TLS-revocation proxy).
# ---------------------------------------------------------------------------
set -euo pipefail

BIN="${1:?binary to scan required}"
OUT="${2:?sdk out dir required}"
WORK="${QQ_WORK:-./.qqwork}/hdr"

# 1) Detect Electron version (plain-ASCII user-agent string in the binary).
EV="$(grep -aoE 'Electron/[0-9]+\.[0-9]+\.[0-9]+' "$BIN" 2>/dev/null | head -n1 | cut -d/ -f2 || true)"
if [ -z "$EV" ] && command -v node >/dev/null 2>&1; then
  # UTF-16LE fallback (some PE strings are wide).
  EV="$(node -e 'const b=require("fs").readFileSync(process.argv[1]);for(const e of ["latin1","utf16le"]){const m=b.toString(e).match(/Electron\/([0-9]+\.[0-9]+\.[0-9]+)/);if(m){process.stdout.write(m[1]);break}}' "$BIN" 2>/dev/null || true)"
fi
[ -z "$EV" ] && { echo "::error::could not detect Electron version from $BIN" >&2; exit 1; }
echo "==> QQNT embeds Electron $EV"

# 2) Best-effort Electron -> node / v8 map (for the manifest only).
NODEV=""; V8V=""
if command -v node >/dev/null 2>&1; then
  info="$(curl -fsSL ${CURL_OPTS:-} --retry 3 --retry-all-errors --connect-timeout 20 "https://releases.electronjs.org/releases.json" 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const r=JSON.parse(s);const e=r.find(x=>x.version===process.argv[1]);process.stdout.write(e?(e.node+" "+e.v8):"")}catch{}})' "$EV" 2>/dev/null || true)"
  NODEV="${info%% *}"; V8V="${info##* }"
fi

# 3) Download Electron's node headers (v8.h matches QQNT's patched V8).
#    NOTE: this is intentionally FATAL on failure. Headers are a required part of
#    the SDK, and the release skip is per arch-slot - shipping a libs-only zip
#    would permanently mark an incomplete SDK as "done". Failing instead lets the
#    next scheduled run re-attempt the slot. Hence the aggressive retries here.
url="https://artifacts.electronjs.org/headers/dist/v${EV}/node-v${EV}-headers.tar.gz"
echo "==> $url"
rm -rf "$WORK"; mkdir -p "$WORK"
curl -fSL ${CURL_OPTS:-} --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 30 -o "$WORK/headers.tgz" "$url"
tar -xzf "$WORK/headers.tgz" -C "$WORK"

# 4) Remap include/node/* -> include/QQNT/* so <QQNT/node.h> resolves and the
#    headers' internal "v8.h" / "cppgc/..." / "libplatform/..." refs stay valid.
src="$(find "$WORK" -type d -path '*/include/node' | head -n1 || true)"
[ -z "$src" ] && { echo "::error::include/node not found in headers tarball" >&2; exit 1; }
mkdir -p "$OUT/include"
rm -rf "$OUT/include/QQNT"
cp -r "$src" "$OUT/include/QQNT"
nhdr="$(find "$OUT/include/QQNT" -name '*.h' | wc -l)"
echo "==> headers -> $OUT/include/QQNT ($nhdr .h files)"

# 5) Record versions in the manifest.
{
  echo "electron=$EV"
  echo "node=${NODEV:-unknown}"
  echo "v8=${V8V:-unknown}"
  echo "headers=include/QQNT (use as <QQNT/node.h>, <QQNT/node_api.h>, <QQNT/v8.h>, ...)"
} >> "$OUT/manifest.txt"
