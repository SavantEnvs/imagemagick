#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ImageMagick's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Direct known-answer probes through the freshly built (dynamically linked) `magick`: bash does the
# comparison, so a neutered program cannot hide behind an exit-code-only runner.
TEST="$SRC/mayhem/build/test"
MAGICK="$TEST/utilities/magick"
[ -x "$MAGICK" ] || { echo "missing $MAGICK (mayhem/build.sh builds it)" >&2; exit 2; }
export MAGICK_CONFIGURE_PATH="$SRC/config:$TEST/config" MAGICK_HOME=
export MAGICK_CODER_MODULE_PATH= MAGICK_FILTER_MODULE_PATH=

KAT_PASS=0; KAT_FAIL=0
kat() {  # kat <name> <expected> <command...>
  local name="$1" want="$2"; shift 2
  local got; got="$("$@" 2>&1)" || true
  if [ "$got" = "$want" ]; then KAT_PASS=$((KAT_PASS+1)); echo "ok   kat $name"
  else KAT_FAIL=$((KAT_FAIL+1)); echo "FAIL kat $name: want '$want' got '$got'"; fi
}
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
kat pixel-value   "srgb(255,128,0)" "$MAGICK" -size 3x2 xc:'#ff8000' -format '%[pixel:p{1,1}]' info:
kat rose-geometry "70 46"           "$MAGICK" rose: -format '%w %h' info:
kat resize        "5x5"             "$MAGICK" -size 10x10 xc:red -resize 5x5! -format '%wx%h' info:
kat draw-point    "srgba(255,255,255,1)" "$MAGICK" -size 4x4 xc:black -fill white -draw 'point 1,1' -format '%[pixel:p{1,1}]' info:
"$MAGICK" rose: "$W/rose.png" >/dev/null 2>&1 || true
kat png-roundtrip "PNG 70x46"       "$MAGICK" identify -format '%m %wx%h' "$W/rose.png"
"$MAGICK" rose: -colorspace Gray "$W/rose.bmp" >/dev/null 2>&1 || true
kat bmp-roundtrip "BMP 70x46"       "$MAGICK" identify -format '%m %wx%h' "$W/rose.bmp"
kat compare-same  "0 (0)"               "$MAGICK" compare -metric AE rose: rose: null:
kat sig-nonempty  "64"              bash -c "$MAGICK rose: -format '%#' info: | tr -d '\n' | wc -c"

# Upstream's own TAP suite (validate/wand/draw tests + CLI tests), built by build.sh.
TAPS="tests/cli-colorspace.tap tests/cli-exif.tap tests/cli-mogrify.tap tests/cli-pcx.tap tests/cli-pipe.tap
 tests/cli-statistic.tap tests/cli-svg.tap tests/cli-tiff.tap tests/validate-colorspace.tap tests/validate-compare.tap
 tests/validate-composite.tap tests/validate-convert.tap tests/validate-formats-disk.tap tests/validate-formats-map.tap
 tests/validate-formats-memory.tap tests/validate-identify.tap tests/validate-import.tap tests/validate-magick.tap
 tests/validate-montage.tap tests/validate-stream.tap tests/drawtest.tap tests/wandtest.tap"
# shellcheck disable=SC2086
OUT="$(make -C "$TEST" check TESTS="$(echo $TAPS)" 2>&1)"; echo "$OUT" | tail -40
num() { echo "$OUT" | sed -n "s/^# $1: *\([0-9][0-9]*\).*/\1/p" | tail -1; }
P="$(num PASS)"; F="$(num FAIL)"; E="$(num ERROR)"; S="$(num SKIP)"; X="$(num XFAIL)"; XP="$(num XPASS)"
P=${P:-0}; F=${F:-0}; E=${E:-0}; S=${S:-0}; X=${X:-0}; XP=${XP:-0}
# a suite that ran nothing (neutered / missing) is a failure, not a pass
TOTAL_TAP="$(num TOTAL)"; [ "${TOTAL_TAP:-0}" -ge 1 ] || E=$((E+1))

emit_ctrf "imagemagick-tap+kat" $((P+X+KAT_PASS)) $((F+E+XP+KAT_FAIL)) "$S"
