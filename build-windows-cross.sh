#!/usr/bin/env bash
#
# FFmpeg Windows x86_64 CROSS-build script (run on Linux)
#   Toolchain : mingw-w64 (x86_64-w64-mingw32-)
#   Video     : H.266/VVC (vvenc encode + vvdec decode), H.264 (x264), H.265 (x265)
#   Audio     : MP3 (lame), AAC (native, optional fdk-aac), Opus (libopus)
#   Protocols : SRT (libsrt + cross-built OpenSSL), RTMP/RTMPS, WHIP/WHEP (native, FFmpeg >= 8.0)
#               TLS backend: schannel (native Windows, no external lib)
#   HW accel  : NVENC/NVDEC/CUVID, AMD AMF, Intel QSV (libvpl), D3D11VA/DXVA2
#
# Usage:
#   ./build-windows-cross.sh            # sysdeps -> libraries -> ffmpeg -> verify -> package
#   ./build-windows-cross.sh deps       # only build cross dependency libraries
#   ./build-windows-cross.sh ffmpeg     # only (re)configure & build ffmpeg
#   ./build-windows-cross.sh verify     # verify via wine (if installed)
#   ./build-windows-cross.sh clean      # remove cross build tree (keeps dist/)
#
# Environment overrides (same spirit as build.sh):
#   JOBS=8 FORCE=1 SKIP_SYSDEPS=1 ENABLE_FDK=1 ENABLE_QSV=0 ENABLE_NVIDIA=0
#   ENABLE_AMF=0 WINDOWS_FULLY_STATIC=0 FFMPEG_REF=master
#   GITHUB_MIRROR=https://ghproxy.net/https://github.com
#
# Notes:
#   - ffplay is NOT built (no cross SDL2 by default).
#   - `wine` is optional; when present it is used to run feature checks on the exe.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FFMPEG_GIT="${FFMPEG_GIT:-https://git.ffmpeg.org/ffmpeg.git}"
FFMPEG_REF="${FFMPEG_REF:-release/8.0}"
GITHUB="${GITHUB_MIRROR:-https://github.com}"

CROSS="${CROSS:-x86_64-w64-mingw32-}"
HOST_TRIPLE="x86_64-w64-mingw32"

LAME_VERSION="${LAME_VERSION:-3.100}"
LAME_URL="${LAME_URL:-https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz}"
LAME_SHA256="${LAME_SHA256:-ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e}"
OPUS_REPO="${OPUS_REPO:-$GITHUB/xiph/opus}"
OPUS_REF="${OPUS_REF:-v1.6.1}"
X264_REPO="${X264_REPO:-https://code.videolan.org/videolan/x264.git}"
X264_REF="${X264_REF:-stable}"
X265_REPO="${X265_REPO:-https://bitbucket.org/multicoreware/x265_git.git}"
X265_REF="${X265_REF:-4.2}"
SRT_REPO="${SRT_REPO:-$GITHUB/Haivision/srt}"
SRT_REF="${SRT_REF:-v1.5.7}"
OPENSSL_REPO="${OPENSSL_REPO:-$GITHUB/openssl/openssl}"
OPENSSL_REF="${OPENSSL_REF:-openssl-3.5.9}"
VVENC_REPO="${VVENC_REPO:-$GITHUB/fraunhoferhhi/vvenc}"
VVENC_REF="${VVENC_REF:-v1.14.0}"
VVDEC_REPO="${VVDEC_REPO:-$GITHUB/fraunhoferhhi/vvdec}"
VVDEC_REF="${VVDEC_REF:-v3.2.1}"
FFNVENCODER_REPO="${FFNVENCODER_REPO:-https://git.videolan.org/git/ffmpeg/nv-codec-headers.git}"
FFNVENCODER_REF="${FFNVENCODER_REF:-}"
AMF_REPO="${AMF_REPO:-$GITHUB/GPUOpen-LibrariesAndSDKs/AMF}"
AMF_REF="${AMF_REF:-}"
LIBVPL_REPO="${LIBVPL_REPO:-$GITHUB/intel/libvpl}"
LIBVPL_REF="${LIBVPL_REF:-}"

JOBS="${JOBS:-$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null) || echo 4)}"
FORCE="${FORCE:-0}"
SKIP_SYSDEPS="${SKIP_SYSDEPS:-0}"
ENABLE_FDK="${ENABLE_FDK:-0}"
ENABLE_QSV="${ENABLE_QSV:-1}"
ENABLE_NVIDIA="${ENABLE_NVIDIA:-1}"
ENABLE_AMF="${ENABLE_AMF:-1}"
WINDOWS_FULLY_STATIC="${WINDOWS_FULLY_STATIC:-1}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$BASE_DIR/build/cross-windows-x86_64"
SRC="$WORK/src"
PREFIX="$WORK/prefix"
OUT="$WORK/install"
STAMPS="$WORK/stamps"
DIST="$BASE_DIR/dist"

mkdir -p "$SRC" "$PREFIX" "$OUT" "$STAMPS" "$DIST"

# Cross environment: pkg-config must ONLY see cross-built libraries
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"
unset PKG_CONFIG_PATH || true
export CFLAGS="${CFLAGS:-} -I$PREFIX/include"
export CXXFLAGS="${CXXFLAGS:-} -I$PREFIX/include"
export LDFLAGS="${LDFLAGS:-} -L$PREFIX/lib -L$PREFIX/lib64"
export CC="${CROSS}gcc"
export CXX="${CROSS}g++"
export AR="${CROSS}ar"
export RANLIB="${CROSS}ranlib"
export STRIP="${CROSS}strip"
export WINDRES="${CROSS}windres"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

stamp_done() { [ "$FORCE" != "1" ] && [ -f "$STAMPS/$1.done" ]; }
mark_done()  { touch "$STAMPS/$1.done"; }

git_clone() {
  local dir="$1" url="$2" ref="${3:-}"
  [ -d "$SRC/$dir" ] && return 0
  log "Cloning $url (${ref:-default branch}) -> $dir"
  if [ -n "$ref" ]; then
    if git clone --depth 1 --branch "$ref" "$url" "$SRC/$dir" 2>/dev/null; then
      return 0
    fi
    warn "ref '$ref' not found for $url, falling back to default branch"
  fi
  git clone --depth 1 "$url" "$SRC/$dir"
}

CMAKE_GEN="Unix Makefiles"
command -v ninja >/dev/null 2>&1 && CMAKE_GEN="Ninja"

# CMake toolchain file for mingw cross builds
TOOLCHAIN_FILE="$WORK/mingw-w64-x86_64.cmake"
cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER ${CROSS}gcc)
set(CMAKE_CXX_COMPILER ${CROSS}g++)
set(CMAKE_RC_COMPILER ${CROSS}windres)
set(CMAKE_FIND_ROOT_PATH $PREFIX)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(PKG_CONFIG_USE_CMAKE_PREFIX_PATH ON)
set(CMAKE_CROSSCOMPILING_EMULATOR "")
EOF

cmake_dep() {
  local dir="$1"; shift
  cmake -S "$SRC/$dir" -B "$SRC/$dir/_build" -G "$CMAKE_GEN" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "$@"
  cmake --build "$SRC/$dir/_build" -j "$JOBS"
  cmake --install "$SRC/$dir/_build"
}

pkg_exists() { pkg-config --exists "$1" 2>/dev/null; }

# download_tarball <url> <output-file>
download_tarball() {
  local url="$1" out="$2"
  [ -f "$out" ] && return 0
  log "Downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 30 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    die "need curl or wget to download sources"
  fi
}

# ---------------------------------------------------------------------------
# System packages (cross toolchain + build tools)
# ---------------------------------------------------------------------------
install_sysdeps() {
  [ "$SKIP_SYSDEPS" = "1" ] && { warn "SKIP_SYSDEPS=1, assuming mingw-w64 toolchain installed"; return 0; }
  log "Installing cross toolchain & build tools"
  local SUDO=""
  if [ "$(id -u)" != "0" ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
      die "need root or sudo to install system packages (or rerun with SKIP_SYSDEPS=1)"
    fi
  fi
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update
    $SUDO apt-get install -y build-essential git cmake ninja-build nasm pkg-config \
      python3 diffutils patch wget \
      gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 mingw-w64-tools wine64 || \
    $SUDO apt-get install -y build-essential git cmake ninja-build nasm pkg-config \
      python3 diffutils patch wget gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y gcc-c++ make git cmake ninja-build nasm pkgconf-pkg-config \
      python3 patch mingw64-gcc mingw64-gcc-c++ wine || \
    $SUDO dnf install -y gcc-c++ make git cmake ninja-build nasm pkgconf-pkg-config \
      python3 patch mingw64-gcc mingw64-gcc-c++
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -S --needed --noconfirm base-devel git cmake ninja nasm pkgconf python3 \
      mingw-w64-gcc wine || \
    $SUDO pacman -S --needed --noconfirm base-devel git cmake ninja nasm pkgconf python3 mingw-w64-gcc
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y gcc-c++ make git cmake ninja nasm pkg-config python3 patch \
      crossmingw64-gcc crossmingw64-gcc-c++ || \
    $SUDO zypper install -y gcc-c++ make git cmake ninja nasm pkg-config python3 patch
  else
    warn "Unknown package manager; install manually: mingw-w64 gcc/g++, cmake(>=3.19), nasm, pkg-config, git"
  fi

  for t in "${CROSS}gcc" "${CROSS}g++" "${CROSS}windres" git make cmake nasm pkg-config; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
  done
  command -v wine >/dev/null 2>&1 || command -v wine64 >/dev/null 2>&1 \
    || warn "wine not installed - verification of the .exe will be skipped"
}

# ---------------------------------------------------------------------------
# Dependency builds (all cross-compiled into $PREFIX)
# ---------------------------------------------------------------------------
build_openssl() {
  stamp_done openssl && return 0
  log "Building OpenSSL (for libsrt)"
  git_clone openssl "$OPENSSL_REPO" "$OPENSSL_REF"
  ( cd "$SRC/openssl" \
    && ./Configure mingw64 \
         --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
         --cross-compile-prefix="$CROSS" \
         no-shared no-tests \
    && make -j "$JOBS" \
    && make install_sw ) || {
      warn "OpenSSL asm build failed, retrying with no-asm"
      ( cd "$SRC/openssl" \
        && { make clean || true; } \
        && ./Configure mingw64 --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
             --cross-compile-prefix="$CROSS" no-shared no-tests no-asm \
        && make -j "$JOBS" && make install_sw )
    }
  mark_done openssl
}

build_lame() {
  stamp_done lame && return 0
  log "Building lame $LAME_VERSION (MP3 encoder)"
  local tarball="$SRC/lame-$LAME_VERSION.tar.gz"
  download_tarball "$LAME_URL" "$tarball"
  echo "$LAME_SHA256  $tarball" | sha256sum -c - \
    || die "lame tarball checksum mismatch (override with LAME_SHA256=... if you use a custom LAME_URL)"
  [ -d "$SRC/lame-$LAME_VERSION" ] || tar -xzf "$tarball" -C "$SRC"
  ( cd "$SRC/lame-$LAME_VERSION" \
    && CFLAGS="$CFLAGS -Wno-implicit-function-declaration -Wno-implicit-int" \
       ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" \
         --disable-shared --enable-static --enable-nasm \
         --disable-frontend \
    && make -j "$JOBS" && make install )
  mark_done lame
}

build_opus() {
  stamp_done opus && return 0
  log "Building opus"
  git_clone opus "$OPUS_REPO" "$OPUS_REF"
  cmake_dep opus -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
  mark_done opus
}

build_x264() {
  stamp_done x264 && return 0
  log "Building x264 (H.264 encoder)"
  git_clone x264 "$X264_REPO" "$X264_REF"
  ( cd "$SRC/x264" \
    && ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" --cross-prefix="$CROSS" \
         --enable-static --enable-pic --disable-cli --disable-opencl \
    && make -j "$JOBS" && make install )
  mark_done x264
}

build_x265() {
  stamp_done x265 && return 0
  log "Building x265 (H.265 encoder)"
  git_clone x265 "$X265_REPO" "$X265_REF"
  # x265 derives its version via `git describe`; shallow clones carry no tags -> tag HEAD
  git -C "$SRC/x265" tag -f "${X265_REF##*/}" >/dev/null 2>&1 || true
  # CMake >= 4 dropped support for CMP0025/CMP0054 OLD behavior
  sed -i -E 's/cmake_policy\(SET (CMP0025|CMP0054) OLD\)/cmake_policy(SET \1 NEW)/' \
    "$SRC/x265/source/CMakeLists.txt"
  cmake_dep x265/source -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_PIC=ON
  mark_done x265
}

build_srt() {
  stamp_done srt && return 0
  log "Building srt (SRT protocol)"
  git_clone srt "$SRT_REPO" "$SRT_REF"
  cmake_dep srt -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
    -DENABLE_STDCXX_SYNC=ON -DUSE_ENCLIB=openssl -DOPENSSL_ROOT_DIR="$PREFIX"
  mark_done srt
}

build_vvenc() {
  stamp_done vvenc && return 0
  log "Building vvenc (H.266/VVC encoder)"
  git_clone vvenc "$VVENC_REPO" "$VVENC_REF"
  cmake_dep vvenc -DBUILD_SHARED_LIBS=OFF
  mark_done vvenc
}

build_vvdec() {
  stamp_done vvdec && return 0
  log "Building vvdec (H.266/VVC decoder + vvdecapp standalone tool)"
  git_clone vvdec "$VVDEC_REPO" "$VVDEC_REF"
  # NOTE: FFmpeg mainline has no libvvdec wrapper; ffmpeg decodes VVC with its
  # native decoder. vvdecapp is shipped alongside as a fast standalone decoder.
  cmake_dep vvdec -DBUILD_SHARED_LIBS=OFF -DVVDEC_INSTALL_VVDECAPP=ON
  mark_done vvdec
}

build_ffnvcodec() {
  [ "$ENABLE_NVIDIA" = "1" ] || return 0
  stamp_done ffnvcodec && return 0
  log "Building nv-codec-headers (NVIDIA NVENC/NVDEC/CUVID)"
  git_clone ffnvcodec "$FFNVENCODER_REPO" "$FFNVENCODER_REF"
  make -C "$SRC/ffnvcodec" PREFIX="$PREFIX" install
  mark_done ffnvcodec
}

build_amf() {
  [ "$ENABLE_AMF" = "1" ] || return 0
  stamp_done amf && return 0
  log "Installing AMF headers (AMD hardware codec)"
  git_clone amf "$AMF_REPO" "$AMF_REF"
  mkdir -p "$PREFIX/include/AMF"
  cp -r "$SRC/amf/amf/public/include/." "$PREFIX/include/AMF/"
  mark_done amf
}

build_libvpl() {
  [ "$ENABLE_QSV" = "1" ] || return 0
  stamp_done libvpl && return 0
  log "Building libvpl (Intel QSV dispatcher)"
  if ! git_clone libvpl "$LIBVPL_REPO" "$LIBVPL_REF" \
     || ! cmake_dep libvpl -DBUILD_SHARED_LIBS=OFF -DBUILD_DISPATCHER_STATIC_ONLY=ON \
                           -DBUILD_TOOLS=OFF -DINSTALL_DEV=ON; then
    warn "libvpl cross build failed - Intel QSV will be disabled"
    return 1
  fi
  mark_done libvpl
}

build_fdk() {
  [ "$ENABLE_FDK" = "1" ] || return 0
  stamp_done fdk-aac && return 0
  log "Building fdk-aac"
  git_clone fdk-aac "$GITHUB/mstorsjo/fdk-aac" "${FDK_REF:-v2.0.3}"
  ( cd "$SRC/fdk-aac" \
    && { [ -f configure ] || autoreconf -fiv; } \
    && ./configure --prefix="$PREFIX" --host="$HOST_TRIPLE" --disable-shared --enable-static \
    && make -j "$JOBS" && make install )
  mark_done fdk-aac
}

build_deps() {
  build_openssl
  build_lame
  build_opus
  build_x264
  build_x265
  build_srt
  build_vvenc
  build_vvdec
  build_ffnvcodec
  build_amf
  build_libvpl || true
  build_fdk || warn "fdk-aac failed, continuing without it"
}

# ---------------------------------------------------------------------------
# FFmpeg (cross)
# ---------------------------------------------------------------------------
build_ffmpeg() {
  log "Cross-building FFmpeg ($FFMPEG_REF) for Windows x86_64"
  git_clone ffmpeg "$FFMPEG_GIT" "$FFMPEG_REF"

  local FLAGS=()
  FLAGS+=(
    --prefix="$OUT"
    --arch=x86_64
    --target-os=mingw32
    --cross-prefix="$CROSS"
    --pkg-config-flags=--static
    --extra-cflags="-I$PREFIX/include"
    --extra-cxxflags="-I$PREFIX/include"
    --extra-ldflags="-L$PREFIX/lib -L$PREFIX/lib64"
    --enable-gpl
    --enable-version3
    --disable-doc
    --disable-shared
    --enable-static
    --disable-ffplay
    # video codecs
    # (VVC decode = FFmpeg native decoder; mainline has no libvvdec wrapper)
    --enable-libx264
    --enable-libx265
    --enable-libvvenc
    # audio codecs
    --enable-libmp3lame
    --enable-libopus
    # protocols
    --enable-libsrt
    # TLS: native Windows schannel (no external lib needed)
    --enable-schannel
    # hardware
    --enable-d3d11va
    --enable-dxva2
  )

  if pkg_exists fdk-aac; then FLAGS+=(--enable-libfdk-aac); fi

  if [ "$ENABLE_NVIDIA" = "1" ] && [ -f "$PREFIX/include/ffnvcodec/nvEncodeAPI.h" ]; then
    FLAGS+=(--enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuvid)
  fi
  if [ "$ENABLE_AMF" = "1" ] && [ -f "$PREFIX/include/AMF/core/Version.h" ]; then
    FLAGS+=(--enable-amf)
  fi
  if [ "$ENABLE_QSV" = "1" ] && pkg_exists vpl; then
    FLAGS+=(--enable-libvpl)
  else
    warn "Intel QSV disabled (libvpl not available)"
  fi

  local LDEXEFLAGS=()
  if [ "$WINDOWS_FULLY_STATIC" = "1" ]; then
    LDEXEFLAGS+=(--extra-ldexeflags="-static")
  fi

  local BUILD_DIR="$WORK/ffmpeg-build"
  rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
  (
    cd "$BUILD_DIR"
    "$SRC/ffmpeg/configure" "${FLAGS[@]}" "${LDEXEFLAGS[@]}"
    make -j "$JOBS"
    make install
  ) || {
    if [ "$WINDOWS_FULLY_STATIC" = "1" ]; then
      warn "Fully static link failed; retrying without -static (WINDOWS_FULLY_STATIC=0)"
      rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
      (
        cd "$BUILD_DIR"
        "$SRC/ffmpeg/configure" "${FLAGS[@]}"
        make -j "$JOBS"
        make install
      ) || die "FFmpeg cross build failed"
    else
      die "FFmpeg cross build failed"
    fi
  }
  mark_done ffmpeg
}

# ---------------------------------------------------------------------------
# Verify & package
# ---------------------------------------------------------------------------
WINE_BIN=""
if command -v wine >/dev/null 2>&1; then WINE_BIN="wine"
elif command -v wine64 >/dev/null 2>&1; then WINE_BIN="wine64"; fi

verify() {
  local BIN="$OUT/bin/ffmpeg.exe"
  [ -f "$BIN" ] || die "ffmpeg.exe not found: $BIN"
  if [ -z "$WINE_BIN" ]; then
    warn "wine not installed - skipping runtime verification of $BIN"
    log "Static feature check via build config"
    strings "$BIN" 2>/dev/null | grep -m1 -q "libvvenc" && echo "  [ OK ] libvvenc string found in binary" \
      || warn "could not confirm features statically; install wine to verify"
    return 0
  fi
  log "Verifying $BIN via $WINE_BIN"
  $WINE_BIN "$BIN" -hide_banner -version | head -3

  local failed=0
  check() {
    if eval "$2" >/dev/null 2>&1; then
      printf '  [ OK ] %s\n' "$1"
    else
      printf '  [MISS] %s\n' "$1"; failed=1
    fi
  }

  check "H.266/VVC encoder (libvvenc)"   "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q libvvenc"
  check "H.266/VVC decoder (native)"     "$WINE_BIN '$BIN' -hide_banner -decoders | grep -qE '^[[:space:]]*V[.A-Z]*[[:space:]]+vvc[[:space:]]'"
  check "vvdecapp standalone decoder"    "[ -f '$PREFIX/bin/vvdecapp.exe' ]"
  check "H.264 encoder (libx264)"        "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q libx264"
  check "H.265 encoder (libx265)"        "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q libx265"
  check "MP3 encoder (libmp3lame)"       "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q libmp3lame"
  check "AAC encoder (native)"           "$WINE_BIN '$BIN' -hide_banner -encoders | grep -qE '^[[:space:]]*A[.A-Z]*[[:space:]]+aac[[:space:]]'"
  check "Opus encoder (libopus)"         "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q libopus"
  check "SRT protocol"                   "$WINE_BIN '$BIN' -hide_banner -protocols | grep -q srt"
  check "RTMP protocol"                  "$WINE_BIN '$BIN' -hide_banner -protocols | grep -q rtmp"
  check "WHIP muxer (WebRTC push)"       "$WINE_BIN '$BIN' -hide_banner -muxers | grep -q whip"
  check "WHEP demuxer (WebRTC pull)"     "$WINE_BIN '$BIN' -hide_banner -demuxers | grep -q whep"
  [ "$ENABLE_NVIDIA" = "1" ] && check "NVENC (h264_nvenc)" "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q h264_nvenc"
  [ "$ENABLE_AMF" = "1" ]    && check "AMF (h264_amf)"     "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q h264_amf"
  [ "$ENABLE_QSV" = "1" ]    && check "QSV (h264_qsv)"     "$WINE_BIN '$BIN' -hide_banner -encoders | grep -q h264_qsv"

  if [ "$failed" = "1" ]; then
    warn "Some features are missing - check the build log above."
  else
    log "All requested features present."
  fi
}

package() {
  local BIN="$OUT/bin/ffmpeg.exe" VER NAME
  [ -f "$BIN" ] || die "ffmpeg.exe not found; run './build-windows-cross.sh ffmpeg' first"
  if [ -n "$WINE_BIN" ]; then
    VER="$($WINE_BIN "$BIN" -hide_banner -version | head -1 | awk '{print $3}')"
  else
    VER="${FFMPEG_REF#release/}"
    warn "wine not installed; using version label '$VER' from FFMPEG_REF"
  fi
  VER="${VER%%-*}"
  NAME="ffmpeg-$VER-windows-x86_64"

  local PKGDIR="$WORK/$NAME"
  rm -rf "$PKGDIR"; mkdir -p "$PKGDIR/bin"
  cp "$OUT/bin/"ffmpeg*.exe "$PKGDIR/bin/" 2>/dev/null || true
  cp "$OUT/bin/ffprobe*.exe" "$PKGDIR/bin/" 2>/dev/null || true
  cp "$PREFIX/bin/vvdecapp"* "$PKGDIR/bin/" 2>/dev/null || true
  cp "$PREFIX/bin/vvencapp"* "$PKGDIR/bin/" 2>/dev/null || true
  cp "$BASE_DIR/README.md" "$PKGDIR/" 2>/dev/null || true
  cp "$BASE_DIR/README.zh-CN.md" "$PKGDIR/" 2>/dev/null || true

  log "Packaging -> $DIST/$NAME.tar.gz"
  tar -czf "$DIST/$NAME.tar.gz" -C "$WORK" "$NAME"
  if command -v zip >/dev/null 2>&1; then
    ( cd "$WORK/$NAME" && zip -qr "$DIST/$NAME.zip" . ) && log "Packaging -> $DIST/$NAME.zip"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
STAGE="${1:-all}"
case "$STAGE" in
  all)
    install_sysdeps
    build_deps
    build_ffmpeg
    verify
    package
    ;;
  sysdeps) install_sysdeps ;;
  deps)    build_deps ;;
  ffmpeg)  build_ffmpeg ;;
  verify)  verify ;;
  package) package ;;
  clean)
    rm -rf "$WORK"
    log "Cross build tree removed. dist/ kept."
    ;;
  *)
    grep '^# ' "${BASH_SOURCE[0]}" | head -28
    exit 1
    ;;
esac

if [ "$STAGE" = "all" ]; then
  log "DONE. Windows x86_64 artifacts in: $DIST"
  ls -lh "$DIST" | tail -n +2
fi
