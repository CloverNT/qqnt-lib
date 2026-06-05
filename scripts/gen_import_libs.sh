#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gen_import_libs.sh  (bash; CI runs it with `shell: bash` = Git Bash on Windows)
#
# Extract a QQ NT Windows installer, detect its real x.x.xx-xxxxx version, build a
# genuine MSVC import library (+ its .def) for each requested PE target, and
# bundle the matching Node/Electron headers - producing an SDK folder:
#     qqnt-sdk-<version>-windows-<arch>/
#       lib/<name>.def , lib/<name>.lib          (PE exports -> MSVC lib.exe)
#       include/QQNT/...                          (via fetch_headers.sh)
#       manifest.txt
#   e.g. QQNT.dll -> QQNT.lib, QQ.exe -> QQ.lib, wrapper.node -> wrapper.lib
#
# Usage:  gen_import_libs.sh <installer.exe> <outroot> <arch:x64|arm64> <t1,t2,...>
#
# Requires MSVC lib.exe on PATH (add the 'ilammy/msvc-dev-cmd' step) and node;
# find/sort/grep/tar from Git Bash; 7-Zip from the Windows install. `file` optional.
# ---------------------------------------------------------------------------
set -euo pipefail

INSTALLER="${1:?installer path required}"
OUTROOT="${2:?output root required}"
ARCH="${3:-x64}"
TARGETS="${4:-QQ.exe,QQNT.dll,wrapper.node}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="${QQ_WORK:-./.qqwork}/extract"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT" "$OUTROOT"

find_7z() {
  for c in "/c/Program Files/7-Zip/7z.exe" "/c/Program Files (x86)/7-Zip/7z.exe"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  command -v 7z 2>/dev/null && return
  command -v 7za 2>/dev/null && return
  echo "::error::7-Zip not found" >&2; exit 1
}
SEVENZIP="$(find_7z)"
echo "Using 7-Zip: $SEVENZIP"

echo "==> Extracting $INSTALLER"
"$SEVENZIP" x -y -bd "-o${EXTRACT}" "$INSTALLER" >/dev/null 2>&1 || \
  "$SEVENZIP" x -y -bd "-o${EXTRACT}" "$INSTALLER" || true
while IFS= read -r -d '' inner; do
  echo "    nested archive: $inner"
  "$SEVENZIP" x -y -bd "-o${inner}.d" "$inner" >/dev/null 2>&1 || true
done < <(find "$EXTRACT" -type f \( -iname '*.7z' -o -iname '*.zip' \) -print0 2>/dev/null)

# --- detect the real x.x.xx-xxxxx version ----------------------------------
detect_version() {
  local v
  v="$(find "$EXTRACT" -type d -regextype posix-extended \
        -regex '.*/versions/[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' -printf '%f\n' 2>/dev/null \
        | sort -V | tail -n1)"
  if [ -z "$v" ]; then
    local pj; pj="$(find "$EXTRACT" -type f -path '*/resources/app/package.json' 2>/dev/null | head -n1 || true)"
    [ -n "$pj" ] && v="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$pj" \
        | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' | head -n1 || true)"
  fi
  echo "$v"
}
VER="$(detect_version)"
if [ -z "$VER" ]; then
  echo "::error::could not detect QQ version from the installer. Extracted dirs:" >&2
  find "$EXTRACT" -maxdepth 4 -type d | head -n 60 >&2
  exit 1
fi
FOLDER="qqnt-sdk-${VER}-windows-${ARCH}"
OUTDIR="$OUTROOT/$FOLDER"
LIBDIR="$OUTDIR/lib"
mkdir -p "$LIBDIR"
echo "==> Detected version $VER  ->  $FOLDER"

# --- MSVC import-lib toolchain (lib.exe + node to read PE exports) ----------
case "$ARCH" in
  x64)   MACHINE=X64 ;;
  arm64) MACHINE=ARM64 ;;
  *)     echo "::error::unsupported arch: $ARCH" >&2; exit 1 ;;
esac
LIB_EXE="$(command -v lib.exe || command -v lib || true)"
[ -z "$LIB_EXE" ] && { echo "::error::MSVC lib.exe not on PATH — add the 'ilammy/msvc-dev-cmd' step" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "::error::node not on PATH (needed to read PE exports)" >&2; exit 1; }

find_target() {
  local name="$1"
  find "$EXTRACT" -type f -iname "$name" -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -n1 | cut -f2- || true
}

MANIFEST="$OUTDIR/manifest.txt"
{ echo "version=$VER"; echo "system=windows"; echo "arch=$ARCH"; echo "tool=msvc-lib"; } > "$MANIFEST"
made=0; missing=()

IFS=',' read -ra LIST <<< "$TARGETS"
for raw in "${LIST[@]}"; do
  target="$(echo "$raw" | xargs)"; [ -z "$target" ] && continue
  file_path="$(find_target "$target")"
  if [ -z "$file_path" ]; then
    echo "::warning::target not found in installer: $target"; missing+=("$target"); continue
  fi
  base="${target%.*}"
  echo "==> $target  ->  $file_path"; file "$file_path" || true
  def="$LIBDIR/${base}.def"; lib="$LIBDIR/${base}.lib"
  node "$SCRIPT_DIR/pe_to_def.mjs" "$file_path" "$target" "$def"
  # MSYS2_ARG_CONV_EXCL: stop Git Bash from mangling lib.exe's /flag arguments.
  MSYS2_ARG_CONV_EXCL='*' "$LIB_EXE" /nologo "/def:$def" "/out:$lib" "/machine:$MACHINE"
  rm -f "$LIBDIR/${base}.exp"   # lib.exe /def byproduct, not needed by consumers
  sz=$(stat -c '%s' "$lib" 2>/dev/null || echo '?')
  echo "    -> lib/$(basename "$lib") (${sz} bytes), lib/$(basename "$def")"
  echo "target=$target source=$file_path def=lib/$(basename "$def") importlib=lib/$(basename "$lib") (${sz}B)" >> "$MANIFEST"
  made=$((made+1))
done

if [ "$made" -eq 0 ]; then
  echo "::error::No targets found in the installer. Tree:" >&2
  find "$EXTRACT" -maxdepth 4 -type f | head -n 100 >&2
  exit 1
fi
if [ "${#missing[@]}" -gt 0 ]; then
  echo "MISSING (no PE found): ${missing[*]}" >> "$MANIFEST"
  echo "::warning::Requested targets not found: ${missing[*]}"
fi

# --- bundle the matching Node/Electron headers -----------------------------
# Electron version lives in QQNT.dll (the framework module). If a future build
# renames it, fall back to the largest .dll (the framework). NOT QQ.exe - that
# is only a small launcher stub and carries no "Electron/<ver>" string.
hdrbin="$(find "$EXTRACT" -iname QQNT.dll | head -n1 || true)"
[ -z "$hdrbin" ] && hdrbin="$(find "$EXTRACT" -type f -iname '*.dll' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true)"
[ -z "$hdrbin" ] && { echo "::error::no binary found to detect Electron version" >&2; exit 1; }
bash "$SCRIPT_DIR/fetch_headers.sh" "$hdrbin" "$OUTDIR"

echo "==> SDK ready: $OUTDIR"
# `|| true`: head closes the pipe early -> ls gets SIGPIPE; don't let that fail
# the step (pipefail+set -e) after the SDK is already built.
ls -lR "$OUTDIR" | head -n 40 || true
