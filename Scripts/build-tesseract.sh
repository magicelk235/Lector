#!/bin/bash
# Builds the OCR engine LectorKit links, and fetches the models it ships, so that
# nothing the app loads at runtime comes from the machine that built it.
#
# Produces, both commit-ready:
#   Vendor/Tesseract.xcframework                        static Leptonica + Tesseract,
#                                                        one arm64 + x86_64 library
#   LectorKit/Sources/LectorKit/Resources/tessdata pinned tessdata_fast models
#
# Homebrew (or anything else) supplies cmake and ninja to *run* the build and nothing
# that ends up *in* it: every optional dependency — libcurl, libarchive, libtiff, the
# image codecs, OpenMP — is switched off, and /opt/homebrew and /usr/local are hidden
# from CMake and pkg-config. The result links only against the macOS SDK (libc++ and
# libSystem), which is why the app can run on any Mac. Pixels reach Tesseract raw
# through TessBaseAPISetImage, so no codec is ever needed.
#
# Sources, per-arch build trees and downloads live in Vendor/build/, which is ignored.
#
# Usage:  Scripts/build-tesseract.sh [all|libs|models]      (default: all)
# Needs:  Xcode, cmake >= 3.25, ninja, curl
set -euo pipefail

LEPTONICA_VERSION=1.87.0
LEPTONICA_SHA256=c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7
TESSERACT_VERSION=5.5.3
TESSERACT_SHA256=9218e62793116d42a9f6d14cd9348518b27f382096eea3d0f2d1a24616bb5884

# tessdata_fast has had no release since 4.1.0 (2019). This is the head of main, which
# carries the same models; pinning the commit (and every file's hash below) means a
# rewritten branch cannot silently change what ships.
TESSDATA_COMMIT=87416418657359cb625c412a48b6e1d6d41c29bd

DEPLOYMENT_TARGET=15.0
ARCHS=(arm64 x86_64)

# Script-level models for every script Apple's Vision cannot read (or reads only for
# some of its languages — Vision's Cyrillic, Arabic and Thai support depends on the
# OS, which ScreenTextReader checks at runtime).
# Script models rather than per-language ones: the user's language is unknown, and a
# script model reads every language written in that script.
MODELS=(
    "script/Arabic              47c262ac4e843c024df87ffa1363b77a821a843c069c71ef7650f4d2ecfea1e8"
    "script/Armenian            e94e3cfcb79dc6bc24b819ce01340b690f2aabe4c5ac295545ae1bca5d7472f4"
    "script/Bengali             d04c2064bd0ffcd18488c4048d40d88ab056185f3462c2337b52f9e6c51158e5"
    "script/Canadian_Aboriginal ec11e31e65541a2040982ee8a08514278f850127908df71553f0958cd02609f8"
    "script/Cherokee            76df30145426bde13c7ab07a2cb9a27b415a7d703472424801b35c3c3da3aab7"
    "script/Cyrillic            a80325ebb1c7aa2dca5002ec05b15052a51dcb2e9e65373c264a3df7ac284358"
    "script/Devanagari          3bbb87c1de2a6a2ef0a97dc041e6eea2723a1c22d638f5e38157a5cd441c12b7"
    "script/Ethiopic            4856c53285f9dd28dd130228316cdd506a5172505c99f367d63d84e6467c15f4"
    "script/Georgian            8da5cc7e2af2c8da04d126ab1f2604904305e548bc3fc20d3c0bae6d519ca013"
    "script/Greek               52e201e4a22336d89ee202b579aca04f15ffd6e5e6af1fe164498f2c7de898e6"
    "script/Gujarati            94643022c1dc06a6b1a96f7dbc3bcc77f455b38e6843cc115a4c9c460b0b32aa"
    "script/Gurmukhi            34c36da0fc59198f009ebbe8646708255fa3ca2553e62645a7b584cbceca8b24"
    "script/Hebrew              4f4f3405404a61e21e5c16316ed5c3052ddb3572a75e0b3dc3fe118b12dea76e"
    "script/Kannada             1252172cbbe99d27e5e52009a0e79444d555329b82e0b88d6e1f2a601a1b7d86"
    "script/Khmer               330366535d1155974af0f99630df3060c9a98c657b1e4b29f458125f1d10e44a"
    "script/Lao                 6bdca344c3ed9ecf405e2f8b5eb0af9832c1de7d92af2f4891867549c1d1fb63"
    "script/Malayalam           822ad7ed9fb2eba0b0da5c788ed8710eba651d91777fc659ce0d700cfb99be06"
    "script/Myanmar             78f95e6033824b7c197a099e9fdef55e0742146619d822c9b8d81f933f2b27df"
    "script/Oriya               39fc17f9e30eee261ac08b2d9d3c82bf28e69cff7c38d0a3aea19f1023410ade"
    "script/Sinhala             ce202bfbdc65e677abd76f5349f4765296b3d2b01c87608f49154ad7fa12ec4a"
    "script/Syriac              a89964433928a74de707e6fb61df1e933660de19c969f5301e8195e0219ea9bc"
    "script/Tamil               6857e222c6977986915bd073f669c2cde33039dedde26603ed6be87b0a8d62bb"
    "script/Telugu              615dd18355098058d77a45ee3bacc5d36aca574880c1b6099011f2aca09f2d1c"
    "script/Thaana              aae14e808cc783e00fe37af8afa67ff09c8d01b454065b7633e014eb2b5b6e2d"
    "script/Thai                d9e34be94556ddb65fd7e04892ff606e1a5b696d0eb422b5a7efc6859943702d"
    "script/Tibetan             0c869d52597d5b03eb6f52c5d0c217514e883259ead05765c0329e5a536538ae"
)
TESSDATA_LICENSE_SHA256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
WORK="$VENDOR/build"
DOWNLOADS="$WORK/downloads"
XCFRAMEWORK="$VENDOR/Tesseract.xcframework"
LICENSES="$VENDOR/licenses"
TESSDATA="$ROOT/LectorKit/Sources/LectorKit/Resources/tessdata"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# Downloads $1 to $2 unless a file with the pinned hash $3 is already there.
fetch() {
    local url="$1" dest="$2" expected="$3"
    if [ -f "$dest" ] && [ "$(sha256 "$dest")" = "$expected" ]; then
        return
    fi
    mkdir -p "$(dirname "$dest")"
    curl --fail --location --silent --show-error --retry 3 -o "$dest.part" "$url"
    local actual
    actual="$(sha256 "$dest.part")"
    if [ "$actual" != "$expected" ]; then
        rm -f "$dest.part"
        die "checksum mismatch for $url: expected $expected, got $actual"
    fi
    mv "$dest.part" "$dest"
}

# ---------------------------------------------------------------------------------
# Libraries
# ---------------------------------------------------------------------------------

isolate_environment() {
    # Anything that would let the compiler or pkg-config see Homebrew. Tesseract's
    # CMakeLists even points pkg-config at $HOMEBREW_PREFIX on its own when that is set.
    unset HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY
    unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
    unset LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_SYSROOT_DIR
    export PKG_CONFIG_PATH=""
}

cmake_common_args() {
    local arch="$1" prefix="$2"
    # CMAKE_SYSTEM_NAME makes this a cross build even for the host arch, so that
    # CMAKE_SYSTEM_PROCESSOR is taken from here rather than from the build machine:
    # Tesseract picks its SIMD kernels (NEON vs SSE/AVX) from it.
    printf '%s\n' \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Darwin \
        -DCMAKE_SYSTEM_PROCESSOR="$arch" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_C_COMPILER="$CC_PATH" \
        -DCMAKE_CXX_COMPILER="$CXX_PATH" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local" \
        -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DBUILD_SHARED_LIBS=OFF
}

build_leptonica() {
    local arch="$1" prefix="$2"
    local build="$WORK/$arch/leptonica"
    log "Leptonica $LEPTONICA_VERSION ($arch)"
    rm -rf "$build"
    local args=()
    while IFS= read -r line; do args+=("$line"); done < <(cmake_common_args "$arch" "$prefix")
    # NO_CONSOLE_IO: Leptonica would otherwise write to the app's stderr on every
    # model load — it probes for TIFF and PNG support this build deliberately lacks.
    cmake -S "$WORK/src/leptonica-$LEPTONICA_VERSION" -B "$build" "${args[@]}" \
        -DCMAKE_C_FLAGS=-DNO_CONSOLE_IO \
        -DSW_BUILD=OFF -DBUILD_PROG=OFF -DSTRICT_CONF=OFF \
        -DENABLE_ZLIB=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF -DENABLE_JPEG=OFF \
        -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF \
        >"$build.configure.log" 2>&1 || { cat "$build.configure.log"; die "Leptonica configure failed"; }
    cmake --build "$build" >"$build.build.log" 2>&1 || { tail -50 "$build.build.log"; die "Leptonica build failed"; }
    cmake --install "$build" >/dev/null
}

build_tesseract() {
    local arch="$1" prefix="$2"
    local build="$WORK/$arch/tesseract"
    log "Tesseract $TESSERACT_VERSION ($arch)"
    rm -rf "$build"
    local args=()
    while IFS= read -r line; do args+=("$line"); done < <(cmake_common_args "$arch" "$prefix")
    # LEPT_TIFF_RESULT answers a try_run that cannot execute in a cross build; any
    # nonzero value means "Leptonica has no TIFF", which is true.
    # TESSERACT_DISABLE_DEBUG_FONTS skips building caption fonts for debug images,
    # which Leptonica can only decode with the TIFF support left out here.
    cmake -S "$WORK/src/tesseract-$TESSERACT_VERSION" -B "$build" "${args[@]}" \
        -DCMAKE_CXX_FLAGS=-DTESSERACT_DISABLE_DEBUG_FONTS \
        -DLeptonica_DIR="$prefix/lib/cmake/leptonica" \
        -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF \
        -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON -DDISABLE_TIFF=ON \
        -DGRAPHICS_DISABLED=ON -DOPENMP_BUILD=OFF -DENABLE_NATIVE=OFF \
        -DENABLE_LTO=OFF -DENABLE_CCACHE=OFF -DINSTALL_CONFIGS=OFF \
        -DLEPT_TIFF_RESULT=1 \
        >"$build.configure.log" 2>&1 || { cat "$build.configure.log"; die "Tesseract configure failed"; }
    cmake --build "$build" >"$build.build.log" 2>&1 || { tail -50 "$build.build.log"; die "Tesseract build failed"; }
    cmake --install "$build" >/dev/null
}

# Fails the build if any compile command reached outside the SDK and the sources.
check_hermetic() {
    local arch="$1" leaked=""
    for db in "$WORK/$arch/leptonica/compile_commands.json" "$WORK/$arch/tesseract/compile_commands.json"; do
        if grep -E -q '/opt/homebrew|/usr/local' "$db"; then
            leaked+=" $db"
        fi
    done
    [ -z "$leaked" ] || die "Homebrew or /usr/local paths leaked into:$leaked"

    # Undefined symbols that would need a library we did not build. Everything
    # Tesseract and Leptonica call must come from libSystem or libc++.
    local foreign
    foreign="$(nm -u -j "$WORK/$arch/prefix/lib/libtesseract.a" "$WORK/$arch/prefix/lib/libleptonica.a" 2>/dev/null \
        | grep -E '^_(curl_|archive_|TIFF|png_|jpeg_|DGif|EGif|WebP|opj_|omp_|__kmpc_|deflate|inflate)' \
        | sort -u || true)"
    [ -z "$foreign" ] || die "unexpected external dependencies ($arch):
$foreign"
}

build_libs() {
    command -v cmake >/dev/null || die "cmake not found (build-time only: brew install cmake)"
    command -v ninja >/dev/null || die "ninja not found (build-time only: brew install ninja)"

    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    CC_PATH="$(xcrun --sdk macosx --find clang)"
    CXX_PATH="$(xcrun --sdk macosx --find clang++)"
    isolate_environment

    log "Sources"
    fetch "https://github.com/DanBloomberg/leptonica/releases/download/$LEPTONICA_VERSION/leptonica-$LEPTONICA_VERSION.tar.gz" \
        "$DOWNLOADS/leptonica-$LEPTONICA_VERSION.tar.gz" "$LEPTONICA_SHA256"
    fetch "https://github.com/tesseract-ocr/tesseract/archive/refs/tags/$TESSERACT_VERSION.tar.gz" \
        "$DOWNLOADS/tesseract-$TESSERACT_VERSION.tar.gz" "$TESSERACT_SHA256"
    rm -rf "$WORK/src"
    mkdir -p "$WORK/src"
    tar -xzf "$DOWNLOADS/leptonica-$LEPTONICA_VERSION.tar.gz" -C "$WORK/src"
    tar -xzf "$DOWNLOADS/tesseract-$TESSERACT_VERSION.tar.gz" -C "$WORK/src"

    local archives=()
    for arch in "${ARCHS[@]}"; do
        local prefix="$WORK/$arch/prefix"
        rm -rf "$prefix"
        mkdir -p "$WORK/$arch"
        # pkg-config may only ever see the Leptonica built here.
        export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
        build_leptonica "$arch" "$prefix"
        build_tesseract "$arch" "$prefix"
        check_hermetic "$arch"
        # One archive per arch, so the Kit links a single library.
        libtool -static -no_warning_for_no_symbols -o "$WORK/$arch/libtesseract.a" \
            "$prefix/lib/libtesseract.a" "$prefix/lib/libleptonica.a"
        archives+=("$WORK/$arch/libtesseract.a")
    done

    log "Universal library"
    local universal="$WORK/universal"
    rm -rf "$universal"
    mkdir -p "$universal/Headers/CTesseract"
    lipo -create "${archives[@]}" -output "$universal/libtesseract.a"
    lipo -info "$universal/libtesseract.a"

    # Only the C API is exposed; its C++ includes sit behind __cplusplus. The module
    # map lives in a subdirectory named after the module so Xcode, which copies every
    # static xcframework's headers into one include directory, cannot collide it with
    # another package's top-level module.modulemap.
    local headers="$WORK/${ARCHS[0]}/prefix/include/tesseract"
    cp "$headers/capi.h" "$headers/export.h" "$universal/Headers/CTesseract/"
    cat >"$universal/Headers/CTesseract/module.modulemap" <<'EOF'
module CTesseract {
    header "capi.h"
    link "c++"
    export *
}
EOF

    rm -rf "$XCFRAMEWORK"
    xcodebuild -create-xcframework \
        -library "$universal/libtesseract.a" -headers "$universal/Headers" \
        -output "$XCFRAMEWORK" >/dev/null

    # Apache-2.0 (Tesseract) and BSD-2 (Leptonica) both require the notice to travel
    # with the binary.
    mkdir -p "$LICENSES"
    cp "$WORK/src/tesseract-$TESSERACT_VERSION/LICENSE" "$LICENSES/tesseract-LICENSE.txt"
    cp "$WORK/src/leptonica-$LEPTONICA_VERSION/leptonica-license.txt" "$LICENSES/leptonica-LICENSE.txt"
}

# ---------------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------------

fetch_models() {
    log "tessdata_fast models ($TESSDATA_COMMIT)"
    local base="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/$TESSDATA_COMMIT"
    mkdir -p "$TESSDATA"

    local wanted=()
    for entry in "${MODELS[@]}"; do
        read -r path hash <<<"$entry"
        local name
        name="$(basename "$path").traineddata"
        fetch "$base/$path.traineddata" "$TESSDATA/$name" "$hash"
        wanted+=("$name")
    done
    fetch "$base/LICENSE" "$TESSDATA/LICENSE" "$TESSDATA_LICENSE_SHA256"

    # Drop models no longer listed, so the bundle holds exactly what is pinned above.
    for file in "$TESSDATA"/*.traineddata; do
        local name
        name="$(basename "$file")"
        [[ " ${wanted[*]} " == *" $name "* ]] || { echo "removing stale $name"; rm -f "$file"; }
    done
    du -sh "$TESSDATA"
}

case "${1:-all}" in
    all) build_libs; fetch_models ;;
    libs) build_libs ;;
    models) fetch_models ;;
    *) die "usage: $0 [all|libs|models]" ;;
esac
log "Done"
