#!/usr/bin/env bash
# Sync a pinned transcribe.cpp checkout into src/transcribe-cpp/.
#
# Usage: tools/vendor.sh <git-url-or-local-path> <ref>
#   tools/vendor.sh https://github.com/handy-computer/transcribe.cpp v0.2.0
#   tools/vendor.sh ../transcribe.cpp HEAD
#
# Copies only what the CPU-only static build compiles, prunes every GPU
# backend, and records provenance (upstream sha + ABI hash) in VENDOR.
set -euo pipefail

SRC="${1:?source repo url or path}"
REF="${2:?git ref/tag/sha}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/src/transcribe-cpp"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Get the source at the requested ref.
if [ -d "$SRC/.git" ]; then
  mkdir -p "$WORK/repo"
  git -C "$SRC" archive "$REF" | tar -x -C "$WORK/repo"
  SHA="$(git -C "$SRC" rev-parse "$REF")"
  # Record where the code actually came from, not the local scratch path, so
  # VENDOR stays meaningful to someone else reading it.
  URL="$(git -C "$SRC" remote get-url origin 2>/dev/null || echo "$SRC")"
  DESC="$(git -C "$SRC" describe --tags --always "$REF" 2>/dev/null || echo "$REF")"
else
  git clone --depth 1 --branch "$REF" "$SRC" "$WORK/repo"
  SHA="$(git -C "$WORK/repo" rev-parse HEAD)"
  URL="$SRC"
  DESC="$REF"
fi
R="$WORK/repo"

# 2. Copy the pieces we compile / include.
rm -rf "$DEST"
mkdir -p "$DEST"
cp    "$R/CMakeLists.txt" "$R/CMakePresets.json" "$DEST/"
cp -R "$R/cmake"    "$DEST/cmake"
cp -R "$R/include"  "$DEST/include"   # transcribe.h, transcribe.abihash, transcribe/*.h
cp -R "$R/src"      "$DEST/src"       # transcribe's own code incl. src/third_party/miniz

# ggml: core + build glue + headers, plus every backend directory. The prune
# in step 3 is what decides which backends actually ship.
mkdir -p "$DEST/ggml/src"
cp    "$R/ggml/CMakeLists.txt" "$R/ggml/LICENSE" "$R/ggml/AUTHORS" "$R/ggml/UPSTREAM" "$DEST/ggml/"
cp -R "$R/ggml/cmake"   "$DEST/ggml/cmake"
cp -R "$R/ggml/include" "$DEST/ggml/include"
cp    "$R/ggml/src/CMakeLists.txt" "$DEST/ggml/src/"
for f in "$R"/ggml/src/*.c "$R"/ggml/src/*.cpp "$R"/ggml/src/*.h; do
  [ -e "$f" ] && cp "$f" "$DEST/ggml/src/"
done
for d in "$R"/ggml/src/ggml-*; do
  [ -d "$d" ] && cp -R "$d" "$DEST/ggml/src/"
done

# License bundle.
cp "$R/LICENSE" "$R/THIRD-PARTY-LICENSES.md" "$DEST/"

# 3. Prune backends. Allowlist rather than denylist: a backend ships only if it
#    is named here, so a new upstream backend cannot silently slip in.
#
#      ggml-cpu     always compiled.
#      ggml-vulkan  |
#      ggml-cuda    | opt-in at install time (TRANSCRIBE_R_VULKAN / _CUDA /
#      ggml-metal   | _METAL, see configure). The sources must be in the
#                     tarball for those flags to be usable at all, but nothing
#                     here is compiled unless the flag is set.
#
#    Everything else stays out. That includes ggml-sycl and ggml-openvino,
#    which carry the only Apache-2.0 code in the upstream tree — keeping them
#    out is what makes the compiled path uniformly MIT (see LICENSE.note).
for d in "$DEST"/ggml/src/ggml-*; do
  [ -d "$d" ] || continue
  case "$(basename "$d")" in
    ggml-cpu|ggml-vulkan|ggml-cuda|ggml-metal) ;;   # ggml-cpu holds llamafile/sgemm.cpp
    *) rm -rf "$d" ;;
  esac
done
rm -rf "$DEST/ggml/examples" "$DEST/ggml/tests" "$DEST/ggml/docs" "$DEST/ggml/ci" "$DEST/ggml/scripts"

# 4. Record provenance (this is the ABI pin).
{
  echo "url: $URL"
  echo "ref: $REF"
  echo "describe: $DESC"
  echo "sha: $SHA"
  echo "abihash: $(cat "$DEST/include/transcribe.abihash")"
  echo "vendored: $(date -u +%FT%TZ)"
} > "$DEST/VENDOR"

echo "Vendored $REF ($SHA) into src/transcribe-cpp"
echo "  abihash: $(cat "$DEST/include/transcribe.abihash")"
echo "  size:    $(du -sh "$DEST" | cut -f1)"
