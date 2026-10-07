#!/usr/bin/env bash
#
# FFmpeg full-featured build script
#   Platforms : Linux x86_64 (native) / Windows x86_64 (MSYS2 MINGW64 or UCRT64 shell)
#   Video     : H.266/VVC (vvenc encode + vvdec decode), H.264 (x264), H.265 (x265)
#   Audio     : MP3 (lame), AAC (native, optional fdk-aac), Opus (libopus)
#   Protocols : SRT (libsrt), RTMP/RTMPS (native), WHIP/WHEP WebRTC (native, FFmpeg >= 8.0)
#   HW accel  : NVIDIA NVENC/NVDEC/CUVID, Intel QSV (libvpl), AMD AMF (Windows),
#               D3D11VA/DXVA2 (Windows), VA-API/VDPAU (Linux)
#
# Usage:
#   ./build.sh            # build everything (system deps -> libraries -> ffmpeg -> verify)
#   ./build.sh deps       # only build dependency libraries
#   ./build.sh ffmpeg     # only (re)configure & build ffmpeg
#   ./build.sh verify     # only run feature checks on the built binary
#   ./build.sh clean      # remove build tree (keeps dist/)
#
# Common environment overrides:
#   JOBS=8                parallel jobs (default: nproc)
#   FORCE=1               rebuild deps even if already done
#   SKIP_SYSDEPS=1        do not try to install system packages
#   ENABLE_FDK=1          build & link libfdk-aac (GPL-incompatible, personal use)
#   ENABLE_QSV=0          skip Intel QSV / libvpl
#   ENABLE_NVIDIA=0       skip NVENC/NVDEC (ffnvcodec headers)
#   ENABLE_AMF=0          skip AMD AMF (Windows only)
#   ENABLE_FFPLAY=0       disable ffplay (default: 1, requires SDL2)
#   WINDOWS_FULLY_STATIC=0  do not attempt a fully static Windows exe
#   FFMPEG_REF=master     ffmpeg git ref (default: release/8.0)
#   GITHUB_MIRROR=https://ghproxy.net/https://github.com
#                         mirror prefix used for github.com clones
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FFMPEG_GIT="${FFMPEG_GIT:-https://git.ffmpeg.org/ffmpeg.git}"
FFMPEG_REF="${FFMPEG_REF:-release/8.0}"

GITHUB="${GITHUB_MIRROR:-https://github.com}"

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
ENABLE_FFPLAY="${ENABLE_FFPLAY:-1}"
WINDOWS_FULLY_STATIC="${WINDOWS_FULLY_STATIC:-1}"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
KERNEL="$(uname -s)"
case "$KERNEL" in
  Linux*)
    PLATFORM="linux"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    PLATFORM="windows"
    if [ -z "${MSYSTEM:-}" ]; then
      echo "ERROR: On Windows run this script from an MSYS2 MINGW64 or UCRT64 shell." >&2
      exit 1
    fi
    case "$MSYSTEM" in
      MINGW64) MSYS_PKG_PFX="mingw-w64-x86_64" ;;
      UCRT64)  MSYS_PKG_PFX="mingw-w64-ucrt-x86_64" ;;
      CLANG64) MSYS_PKG_PFX="mingw-w64-clang-x86_64" ;;
      *) echo "ERROR: unsupported MSYSTEM=$MSYSTEM (use MINGW64/UCRT64)" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "ERROR: unsupported platform: $KERNEL" >&2
    exit 1
    ;;
esac
ARCH="x86_64"

WORK="$BASE_DIR/build/$PLATFORM-$ARCH"
SRC="$WORK/src"
PREFIX="$WORK/prefix"          # where dependency libs are installed
OUT="$WORK/install"            # ffmpeg install prefix
STAMPS="$WORK/stamps"
DIST="$BASE_DIR/dist"

export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CFLAGS="${CFLAGS:-} -I$PREFIX/include"
export CXXFLAGS="${CXXFLAGS:-} -I$PREFIX/include"
export LDFLAGS="${LDFLAGS:-} -L$PREFIX/lib -L$PREFIX/lib64"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$SRC" "$PREFIX" "$OUT" "$STAMPS" "$DIST"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
stamp_done() { [ "$FORCE" != "1" ] && [ -f "$STAMPS/$1.done" ]; }
mark_done()  { touch "$STAMPS/$1.done"; }

# git_clone <dir> <url> [ref]
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
if command -v ninja >/dev/null 2>&1; then CMAKE_GEN="Ninja"; fi

# cmake_dep <dir> [extra cmake args...]
cmake_dep() {
  local dir="$1"; shift
  cmake -S "$SRC/$dir" -B "$SRC/$dir/_build" -G "$CMAKE_GEN" \
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
# System packages
# ---------------------------------------------------------------------------
install_sysdeps() {
  [ "$SKIP_SYSDEPS" = "1" ] && { warn "SKIP_SYSDEPS=1, assuming toolchain & dev packages installed"; return 0; }
  log "Installing system packages ($PLATFORM)"
  if [ "$PLATFORM" = "windows" ]; then
    pacman -S --needed --noconfirm \
      base-devel git cmake ninja nasm pkgconf diffutils patch python3 \
      "$MSYS_PKG_PFX-toolchain" "$MSYS_PKG_PFX-nasm" "$MSYS_PKG_PFX-cmake" \
      "$MSYS_PKG_PFX-pkgconf" "$MSYS_PKG_PFX-openssl" || die "pacman install failed"
    if [ "$ENABLE_FFPLAY" = "1" ]; then
      pacman -S --needed --noconfirm "$MSYS_PKG_PFX-SDL2" || true
    fi
  else
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
        libgnutls28-dev libssl-dev libva-dev libdrm-dev libvdpau-dev
      [ "$ENABLE_FFPLAY" = "1" ] && $SUDO apt-get install -y libsdl2-dev
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y gcc-c++ make
      $SUDO dnf install -y git cmake ninja-build nasm pkgconf-pkg-config python3 patch \
        gnutls-devel openssl-devel libva-devel libdrm-devel libvdpau-devel
      [ "$ENABLE_FFPLAY" = "1" ] && $SUDO dnf install -y SDL2-devel
    elif command -v pacman >/dev/null 2>&1; then
      $SUDO pacman -S --needed --noconfirm base-devel git cmake ninja nasm pkgconf python3 \
        gnutls openssl libva libdrm libvdpau
      [ "$ENABLE_FFPLAY" = "1" ] && $SUDO pacman -S --needed --noconfirm sdl2
    elif command -v zypper >/dev/null 2>&1; then
      $SUDO zypper install -y gcc-c++ make git cmake ninja nasm pkg-config python3 patch \
        libgnutls-devel libopenssl-devel libva-devel libdrm-devel vdpau-devel
      [ "$ENABLE_FFPLAY" = "1" ] && $SUDO zypper install -y libSDL2-devel
    else
      warn "No supported package manager found; install manually: gcc/g++ make cmake(>=3.19) nasm pkg-config git + gnutls/openssl dev headers"
    fi
  fi

  for t in git make cmake nasm pkg-config; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
  done
  local cmver
  cmver="$(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  if [ "$(printf '%s\n' 3.19 "$cmver" | sort -V | head -1)" != "3.19" ]; then
    die "cmake >= 3.19 required (found $cmver). Try: pip install cmake"
  fi
}

# ---------------------------------------------------------------------------
# Dependency builds
# ---------------------------------------------------------------------------
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
       ./configure --prefix="$PREFIX" --disable-shared --enable-static --enable-nasm \
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
    && ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli --disable-opencl \
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
  local enc="openssl"
  if [ "$PLATFORM" = "linux" ] && pkg_exists gnutls; then enc="gnutls"; fi
  cmake_dep srt -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
    -DENABLE_STDCXX_SYNC=ON -DUSE_ENCLIB="$enc"
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
  [ "$PLATFORM" = "windows" ] && [ "$ENABLE_AMF" = "1" ] || return 0
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
  # use a system libvpl if the distro already ships one
  if pkg_exists vpl; then
    log "Using system libvpl ($(pkg-config --modversion vpl)) for Intel QSV"
    mark_done libvpl
    return 0
  fi
  log "Building libvpl (Intel QSV dispatcher)"
  if ! git_clone libvpl "$LIBVPL_REPO" "$LIBVPL_REF" \
     || ! cmake_dep libvpl -DBUILD_SHARED_LIBS=OFF -DBUILD_DISPATCHER_STATIC_ONLY=ON \
                           -DBUILD_TOOLS=OFF -DINSTALL_DEV=ON; then
    warn "libvpl build failed - Intel QSV will be disabled"
    return 1
  fi
  mark_done libvpl
}

# FFmpeg's configure probes libvpl with `#include <mfxvideo.h>` (no vpl/ prefix)
# and links MFXLoad; source-built vpl.pc misses the header subdir and the
# system libs required by the static dispatcher. Patch it (idempotent).
fix_vpl_pc() {
  local pc="$PREFIX/lib/pkgconfig/vpl.pc"
  [ -f "$pc" ] || return 0
  log "Patching vpl.pc for FFmpeg compatibility"
  grep -q 'includedir}/vpl' "$pc" || sed -i 's|^Cflags:.*|& -I${includedir}/vpl|' "$pc"
  local need
  if [ "$PLATFORM" = "windows" ]; then
    need="-lstdc++ -ldxgi -ld3d11 -lole32 -luuid -ladvapi32 -lversion"
  else
    need="-lstdc++ -ldl -lpthread"
  fi
  if ! grep -qF -- "$(echo "$need" | awk '{print $1}')" "$pc"; then
    if grep -q '^Libs.private:' "$pc"; then
      sed -i "s|^Libs.private:.*|& $need|" "$pc"
    else
      echo "Libs.private: $need" >> "$pc"
    fi
  fi
}

build_fdk() {
  [ "$ENABLE_FDK" = "1" ] || return 0
  stamp_done fdk-aac && return 0
  log "Building fdk-aac"
  git_clone fdk-aac "$GITHUB/mstorsjo/fdk-aac" "${FDK_REF:-v2.0.3}"
  ( cd "$SRC/fdk-aac" \
    && { [ -f configure ] || autoreconf -fiv; } \
    && ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    && make -j "$JOBS" && make install )
  mark_done fdk-aac
}

build_deps() {
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
# FFmpeg
# ---------------------------------------------------------------------------
build_ffmpeg() {
  log "Building FFmpeg ($FFMPEG_REF)"
  git_clone ffmpeg "$FFMPEG_GIT" "$FFMPEG_REF"
  fix_vpl_pc

  local FLAGS=()
  FLAGS+=(
    --prefix="$OUT"
    --arch="$ARCH"
    --pkg-config-flags=--static
    --extra-cflags="-I$PREFIX/include"
    --extra-cxxflags="-I$PREFIX/include"
    --extra-ldflags="-L$PREFIX/lib -L$PREFIX/lib64"
    --enable-gpl
    --enable-version3
    --disable-doc
    --disable-shared
    --enable-static
    # video codecs
    # (VVC decode = FFmpeg native decoder; mainline has no libvvdec wrapper)
    --enable-libx264
    --enable-libx265
    --enable-libvvenc
    # audio codecs
    --enable-libmp3lame
    --enable-libopus
    # protocols: SRT + TLS (needed for rtmps/https/srts and WHIP/WHEP signaling)
    --enable-libsrt
  )

  # ---- TLS backend ----
  if [ "$PLATFORM" = "windows" ]; then
    FLAGS+=(--enable-schannel)
  elif pkg_exists gnutls; then
    FLAGS+=(--enable-gnutls)
  elif pkg_exists openssl; then
    warn "gnutls not found; using openssl (implies --enable-nonfree, binary is NOT redistributable)"
    FLAGS+=(--enable-openssl --enable-nonfree)
  else
    die "No TLS library found (need gnutls or openssl dev packages)"
  fi

  # ---- optional audio ----
  if pkg_exists fdk-aac; then FLAGS+=(--enable-libfdk-aac); fi

  # ---- NVIDIA ----
  if [ "$ENABLE_NVIDIA" = "1" ] && [ -f "$PREFIX/include/ffnvcodec/nvEncodeAPI.h" ]; then
    FLAGS+=(--enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-cuvid)
  fi

  # ---- Intel QSV ----
  if [ "$ENABLE_QSV" = "1" ] && pkg_exists vpl; then
    FLAGS+=(--enable-libvpl)
  else
    warn "Intel QSV disabled (libvpl not available)"
  fi

  # ---- platform specific hardware ----
  if [ "$PLATFORM" = "windows" ]; then
    if [ "$ENABLE_AMF" = "1" ] && [ -f "$PREFIX/include/AMF/core/Version.h" ]; then
      FLAGS+=(--enable-amf)
    fi
    FLAGS+=(--enable-d3d11va --enable-dxva2)
  else
    pkg_exists libva  && FLAGS+=(--enable-vaapi)
    pkg_exists libdrm && FLAGS+=(--enable-libdrm)
    [ -e /usr/include/vdpau/vdpau.h ] && FLAGS+=(--enable-vdpau)
  fi

  # ---- ffplay ----
  if [ "$ENABLE_FFPLAY" = "1" ] && pkg_exists sdl2; then
    FLAGS+=(--enable-ffplay)
  else
    FLAGS+=(--disable-ffplay)
  fi

  local LDEXEFLAGS=()
  if [ "$PLATFORM" = "windows" ] && [ "$WINDOWS_FULLY_STATIC" = "1" ]; then
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
    if [ "$PLATFORM" = "windows" ] && [ "$WINDOWS_FULLY_STATIC" = "1" ]; then
      warn "Fully static link failed; retrying with dynamic CRT/system libs (WINDOWS_FULLY_STATIC=0)"
      rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
      (
        cd "$BUILD_DIR"
        "$SRC/ffmpeg/configure" "${FLAGS[@]}"
        make -j "$JOBS"
        make install
      ) || die "FFmpeg build failed"
    else
      die "FFmpeg build failed"
    fi
  }
  mark_done ffmpeg
}

# ---------------------------------------------------------------------------
# Verify & package
# ---------------------------------------------------------------------------
ffmpeg_bin() {
  if [ "$PLATFORM" = "windows" ]; then echo "$OUT/bin/ffmpeg.exe"; else echo "$OUT/bin/ffmpeg"; fi
}

verify() {
  local BIN; BIN="$(ffmpeg_bin)"
  [ -x "$BIN" ] || die "ffmpeg binary not found: $BIN"
  log "Verifying $BIN"
  "$BIN" -hide_banner -version | head -3

  local failed=0
  check() { # <description> <shell test cmd>
    if eval "$2" >/dev/null 2>&1; then
      printf '  [ OK ] %s\n' "$1"
    else
      printf '  [MISS] %s\n' "$1"; failed=1
    fi
  }

  check "H.266/VVC encoder (libvvenc)"   "'$BIN' -hide_banner -encoders | grep -q libvvenc"
  check "H.266/VVC decoder (native)"     "'$BIN' -hide_banner -decoders | grep -qE '^[[:space:]]*V[.A-Z]*[[:space:]]+vvc[[:space:]]'"
  check "vvdecapp standalone decoder"    "[ -f '$PREFIX/bin/vvdecapp' ] || [ -f '$PREFIX/bin/vvdecapp.exe' ]"
  check "H.264 encoder (libx264)"        "'$BIN' -hide_banner -encoders | grep -q libx264"
  check "H.265 encoder (libx265)"        "'$BIN' -hide_banner -encoders | grep -q libx265"
  check "MP3 encoder (libmp3lame)"       "'$BIN' -hide_banner -encoders | grep -q libmp3lame"
  check "AAC encoder (native)"           "'$BIN' -hide_banner -encoders | grep -qE '^[[:space:]]*A[.A-Z]*[[:space:]]+aac[[:space:]]'"
  check "Opus encoder (libopus)"         "'$BIN' -hide_banner -encoders | grep -q libopus"
  check "SRT protocol"                   "'$BIN' -hide_banner -protocols | grep -q srt"
  check "RTMP protocol"                  "'$BIN' -hide_banner -protocols | grep -q rtmp"
  check "WHIP muxer (WebRTC push)"       "'$BIN' -hide_banner -muxers | grep -q whip"
  check "WHEP demuxer (WebRTC pull)"     "'$BIN' -hide_banner -demuxers | grep -q whep"

  if [ "$PLATFORM" = "windows" ]; then
    [ "$ENABLE_NVIDIA" = "1" ] && check "NVENC (h264_nvenc)" "'$BIN' -hide_banner -encoders | grep -q h264_nvenc"
    [ "$ENABLE_AMF" = "1" ]    && check "AMF (h264_amf)"     "'$BIN' -hide_banner -encoders | grep -q h264_amf"
    [ "$ENABLE_QSV" = "1" ]    && check "QSV (h264_qsv)"     "'$BIN' -hide_banner -encoders | grep -q h264_qsv"
  else
    [ "$ENABLE_NVIDIA" = "1" ] && check "NVENC (h264_nvenc)" "'$BIN' -hide_banner -encoders | grep -q h264_nvenc"
    [ "$ENABLE_QSV" = "1" ]    && check "QSV (h264_qsv)"     "'$BIN' -hide_banner -encoders | grep -q h264_qsv"
    pkg_exists libva           && check "VA-API"             "'$BIN' -hide_banner -hwaccels | grep -q vaapi"
  fi
  [ "$ENABLE_FDK" = "1" ] && check "fdk-aac" "'$BIN' -hide_banner -encoders | grep -q libfdk_aac"

  if [ "$failed" = "1" ]; then
    warn "Some features are missing - check the build log above."
  else
    log "All requested features present."
  fi
}

package() {
  local BIN VER NAME
  BIN="$(ffmpeg_bin)"
  VER="$("$BIN" -hide_banner -version | head -1 | awk '{print $3}')"
  VER="${VER%%-*}"
  if [ "$PLATFORM" = "windows" ]; then NAME="ffmpeg-$VER-windows-x86_64"; else NAME="ffmpeg-$VER-linux-x86_64"; fi

  local PKGDIR="$WORK/$NAME"
  rm -rf "$PKGDIR"; mkdir -p "$PKGDIR/bin"
  cp "$OUT/bin/"ffmpeg* "$PKGDIR/bin/" 2>/dev/null || true
  cp "$OUT/bin/ffprobe"* "$PKGDIR/bin/" 2>/dev/null || true
  [ "$ENABLE_FFPLAY" = "1" ] && cp "$OUT/bin/ffplay"* "$PKGDIR/bin/" 2>/dev/null || true
  cp "$PREFIX/bin/vvdecapp"* "$PKGDIR/bin/" 2>/dev/null || true
  cp "$PREFIX/bin/vvencapp"* "$PKGDIR/bin/" 2>/dev/null || true
  cp "$BASE_DIR/README.md" "$PKGDIR/" 2>/dev/null || true
  cp "$BASE_DIR/README.zh-CN.md" "$PKGDIR/" 2>/dev/null || true

  log "Packaging -> $DIST/$NAME.tar.gz"
  tar -czf "$DIST/$NAME.tar.gz" -C "$WORK" "$NAME"
  if [ "$PLATFORM" = "windows" ] && command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command \
      "Compress-Archive -Force -Path '$(cygpath -w "$PKGDIR")\\*' -DestinationPath '$(cygpath -w "$DIST/$NAME.zip")'" \
      && log "Packaging -> $DIST/$NAME.zip" || warn "zip packaging failed (tar.gz still available)"
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
    log "Build tree removed. dist/ kept."
    ;;
  *)
    grep '^# ' "${BASH_SOURCE[0]}" | head -30
    exit 1
    ;;
esac

if [ "$STAGE" = "all" ]; then
  log "DONE. Artifacts in: $DIST"
  ls -lh "$DIST" | tail -n +2
fi
