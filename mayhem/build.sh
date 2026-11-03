#!/usr/bin/env bash
#
# mayhem/build.sh — build ImageMagick's OSS-Fuzz harnesses (oss-fuzz/*_fuzzer.cc) and the project's
# own test suite. Runs in the commit image as `mayhem` in /mayhem; safe to re-run offline.
#
#   $BUILD/fuzz  — sanitized + SanCov-instrumented ImageMagick (static libs), installed to $BUILD/prefix
#   $BUILD/test  — a separate NORMAL-flags build that mayhem/test.sh runs (`make check`)
#   /mayhem/<harness>, /mayhem/<harness>-standalone — fuzzer and run-once reproducer per target
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
BUILD="$SRC/mayhem/build"
FUZZ="$BUILD/fuzz"
TEST="$BUILD/test"
PREFIX="$BUILD/prefix"
HARNESS_SRC="$SRC/oss-fuzz"
mkdir -p "$FUZZ" "$TEST"

# Per-format encoder harnesses we ship (one binary per ImageMagick coder, exactly how OSS-Fuzz's
# build_fuzzers.sh derives encoder_<coder>_fuzzer from encoder_fuzzer.cc).
FORMATS="bmp dds fits gif hdr heic icon jp2 jpeg jxl miff msvg mvg pcx pict png pnm psd qoi sgi sun svg tga tiff wbmp webp xbm xpm"
# Harnesses that are their own source file in oss-fuzz/.
STANDALONE_SRCS="ping profile huffman_decode encoder_gradient encoder_label encoder_pattern encoder_plasma encoder_radial-gradient encoder_xc"

# ---- 1) sanitized, coverage-instrumented library (the code under test) -------------------------------
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
if [ ! -f "$FUZZ/Makefile" ]; then
  (cd "$FUZZ" && ASAN_OPTIONS=detect_leaks=0 "$SRC/configure" \
      --prefix="$PREFIX" --disable-shared --enable-static --disable-docs --disable-dpc \
      --disable-openmp --disable-opencl --without-perl --without-x --with-jxl \
      CC="$CC" CXX="$CXX" CFLAGS="$FUZZ_CFLAGS" CXXFLAGS="$FUZZ_CFLAGS" \
      LDFLAGS="$SANITIZER_FLAGS" )
fi
make -C "$FUZZ" -j"$MAYHEM_JOBS"
make -C "$FUZZ" install

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
MAGICK_PC=Magick++-7.Q16HDRI
MAGICK_CFLAGS="$(pkg-config --cflags $MAGICK_PC)"
MAGICK_LIBS="$(pkg-config --static --libs $MAGICK_PC)"

# ---- 2) harnesses: fuzzer + standalone, ASan/UBSan on, LSan off ----------------------------------------
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# encoder_list.cc prints "<+|->NAME:initializer" for every coder; it picks each format's name/flags.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++11 $MAGICK_CFLAGS "$HARNESS_SRC/encoder_list.cc" \
    "$BUILD/lsan_off.o" -o "$BUILD/encoder_list" $MAGICK_LIBS
"$BUILD/encoder_list" > "$BUILD/encoder_list.txt"

build_harness() {  # <out-name> <source.cc> [extra -D flags...]
  local name="$1" src="$2"; shift 2
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++11 $MAGICK_CFLAGS "$@" "$src" \
      "$BUILD/lsan_off.o" $LIB_FUZZING_ENGINE -o "$SRC/$name" $MAGICK_LIBS
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++11 $MAGICK_CFLAGS "$@" "$src" \
      "$BUILD/lsan_off.o" "$BUILD/standalone_main.o" -o "$SRC/$name-standalone" $MAGICK_LIBS
}

PIDS=()
throttle() { while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do sleep 0.2; done; }

for h in $STANDALONE_SRCS; do
  throttle
  build_harness "${h}_fuzzer" "$HARNESS_SRC/${h}_fuzzer.cc" &
  PIDS+=($!)
done

for fmt in $FORMATS; do
  item="$(grep -i -m1 "^[+-]${fmt}:" "$BUILD/encoder_list.txt")" || { echo "coder '$fmt' missing from encoder_list" >&2; exit 1; }
  info="${item:1}"; encoder="${info%:*}"; initializer="${info##*:}"
  flags="-DFUZZ_IMAGEMAGICK_ENCODER=$encoder"
  [ -z "$initializer" ] || flags="$flags -DFUZZ_IMAGEMAGICK_ENCODER_INITIALIZER=$initializer"
  [ "${item:0:1}" != "+" ] || flags="$flags -DFUZZ_IMAGEMAGICK_ENCODER_WRITE=1"
  throttle
  # shellcheck disable=SC2086
  build_harness "encoder_${fmt}_fuzzer" "$HARNESS_SRC/encoder_fuzzer.cc" $flags &
  PIDS+=($!)
done

for p in "${PIDS[@]}"; do wait "$p"; done

# ---- 3) the project's own suite, NORMAL flags, built out-of-tree in its own gitignored dir ------------
if [ ! -f "$TEST/Makefile" ]; then
  (cd "$TEST" && env -u CFLAGS -u CXXFLAGS -u LDFLAGS "$SRC/configure" \
      --disable-shared --enable-static --disable-docs --disable-dpc --disable-openmp \
      --disable-opencl --without-perl --without-x --with-jxl \
      CC="$CC" CXX="$CXX" CFLAGS="-g -O2 $COVERAGE_FLAGS" CXXFLAGS="-g -O2 $COVERAGE_FLAGS" \
      LDFLAGS="$COVERAGE_FLAGS" )
fi
make -C "$TEST" -j"$MAYHEM_JOBS"
make -C "$TEST" -j"$MAYHEM_JOBS" check TESTS=
