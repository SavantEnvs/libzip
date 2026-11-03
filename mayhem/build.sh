#!/usr/bin/env bash
#
# mayhem/build.sh — build libzip's six OSS-Fuzz harnesses (libFuzzer + standalone reproducer each)
# and the project's own regression suite (nihtest, normal flags). Re-runnable and air-gapped.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

HARNESSES="zip_read_file_fuzzer zip_read_fuzzer zip_read_metadata_fuzzer \
zip_write_encrypt_aes256_file_fuzzer zip_write_encrypt_pkware_file_fuzzer zip_write_roundtrip_fuzzer"

# 1) Sanitized static libzip (same switches as OSS-Fuzz: no tools/regress, OpenSSL crypto, bounded LZMA window).
#    -fsanitize=fuzzer-no-link puts SanCov in the library so Mayhem records edges.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B build \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS" \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_GNUTLS=OFF -DENABLE_OPENSSL=ON \
    -DBUILD_TOOLS=OFF -DBUILD_REGRESS=OFF -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
    -DLIBZIP_DO_INSTALL=OFF -DLIMIT_LZMA_WINDOW=1073741824
cmake --build build -j"$MAYHEM_JOBS"

# 2) Harnesses: libFuzzer binary + standalone reproducer, each with the LSan-off hook.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
LIBS="build/lib/libzip.a -lbz2 -llzma -lz -lzstd -lssl -lcrypto"
for h in $HARNESSES; do
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -Ibuild -Ilib \
        "ossfuzz/$h.c" build/lsan_off.o $LIBS -o "$SRC/$h"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -Ibuild -Ilib \
        "ossfuzz/$h.c" build/standalone_main.o build/lsan_off.o $LIBS -o "$SRC/$h-standalone"
done

# 3) Regression suite with the project's NORMAL flags (no sanitizers, no -gdwarf-3); test.sh only runs it.
#    nihtest comes from the image (/usr/local/bin/nihtest) — cmake disables regress without it.
command -v nihtest >/dev/null || { echo "nihtest missing from the image" >&2; exit 1; }
cmake -S . -B build-tests \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_GNUTLS=OFF -DENABLE_OPENSSL=ON \
    -DBUILD_TOOLS=ON -DBUILD_REGRESS=ON -DBUILD_OSSFUZZ=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF \
    -DLIBZIP_DO_INSTALL=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
