# FFmpeg VVC Full Build

One-script FFmpeg build for **Linux (x86_64)** and **Windows (x86_64, MSYS2)** with H.266/VVC, WebRTC (WHIP/WHEP), SRT, RTMP and hardware acceleration. A **Linux → Windows mingw-w64 cross-build** script is included as well.

[中文说明](README.zh-CN.md)

| Category | Features |
|---|---|
| Video encode | H.266/VVC ([vvenc](https://github.com/fraunhoferhhi/vvenc)), H.264 (x264), H.265 (x265) |
| Video decode | H.266/VVC (FFmpeg **native** decoder), H.264, H.265 — plus bundled **`vvdecapp`** standalone VVC decoder from the [vvdec](https://github.com/fraunhoferhhi/vvdec) project |
| Audio | MP3 (lame), AAC (native encoder, optional fdk-aac), Opus (libopus) |
| Streaming protocols | SRT (libsrt), RTMP/RTMPS (native), **WHIP/WHEP (WebRTC)** |
| HW acceleration | NVIDIA NVENC/NVDEC/CUVID, Intel QSV (libvpl), AMD AMF (Windows), D3D11VA/DXVA2 (Windows), VA-API/VDPAU (Linux) |

> **WebRTC note:** FFmpeg ships a **native WHIP muxer and WHEP demuxer since 8.0** (merged to master in June 2025) — no third-party libdatachannel fork required. This script builds `release/8.0` by default.
>
> **VVC decoding note:** FFmpeg mainline has **no libvvdec wrapper** — `ffmpeg` decodes H.266 with its built-in native decoder (`-c:v vvc`). The (considerably faster) Fraunhofer vvdec is packaged alongside as the standalone tool `vvdecapp`, see section 2.1.

---

## 1. Usage

### Linux (Ubuntu 22.04+ / Debian 12+ / Fedora / Arch)

```bash
chmod +x build.sh
./build.sh     # installs system deps -> builds libraries -> builds ffmpeg -> verifies -> packages
```

### Windows

1. Install [MSYS2](https://www.msys2.org/).
2. Open an **MSYS2 UCRT64** (or MINGW64) shell.
3. Run:

```bash
cd /d/path/to/this/folder
./build.sh
```

### Cross-compile Windows binaries from Linux

```bash
./build-windows-cross.sh   # installs the mingw-w64 toolchain, cross-builds all deps + ffmpeg
```

- Produces the same `dist/ffmpeg-<version>-windows-x86_64.tar.gz` / `.zip` (fully static exe attempted by default);
- All dependencies (x264/x265/lame/opus/srt/vvenc/vvdec/OpenSSL/libvpl/AMF/ffnvcodec) are cross-compiled into a separate prefix — no host libraries leak into the exe;
- TLS backend is `schannel` (native Windows API), so the exe has no external TLS/DLL dependencies;
- If `wine` is installed, the resulting exe is feature-verified automatically; otherwise verification is skipped;
- `ffplay` is not built in cross mode (no cross SDL2).

### Artifacts

- `dist/ffmpeg-<version>-linux-x86_64.tar.gz` (contains `bin/ffmpeg`, `bin/ffprobe`, `bin/vvdecapp`)
- `dist/ffmpeg-<version>-windows-x86_64.tar.gz` / `.zip` (`ffmpeg.exe` etc.; a fully static single-file exe is attempted by default)

> Two ways to get the Windows artifacts: run `build.sh` inside MSYS2 on Windows, or run
> `build-windows-cross.sh` on Linux (mingw-w64 cross-compilation).

### Environment overrides

```bash
JOBS=16 ./build.sh               # parallel jobs
FORCE=1 ./build.sh deps          # rebuild dependencies even if stamps exist
SKIP_SYSDEPS=1 ./build.sh        # do not install system packages (bring your own)
ENABLE_FDK=1 ./build.sh          # also build/link libfdk-aac (GPL-incompatible, personal use only)
ENABLE_QSV=0 ./build.sh          # skip Intel QSV
ENABLE_NVIDIA=0 ./build.sh       # skip NVENC/NVDEC
ENABLE_FFPLAY=1 ./build.sh       # also build ffplay (requires SDL2)
WINDOWS_FULLY_STATIC=0 ./build.sh# do not attempt a fully static Windows exe
FFMPEG_REF=master ./build.sh     # build ffmpeg master instead of release/8.0
GITHUB_MIRROR=https://ghproxy.net/https://github.com ./build.sh   # GitHub mirror prefix
```

Stages: `./build.sh sysdeps | deps | ffmpeg | verify | package | clean` (the same sub-commands work with `build-windows-cross.sh`)

---

## 2. Examples

### 2.1 H.266/VVC transcoding (software only — no consumer GPU supports VVC yet)

```bash
# Encode to H.266 (libvvenc + opus)
ffmpeg -i input.mp4 -c:v libvvenc -preset medium -b:v 2M -c:a libopus -b:a 128k output.mkv

# vvenc presets: faster/fast/medium/slow/slower — trade speed for compression
ffmpeg -i input.mp4 -c:v libvvenc -preset fast -qp 32 output.mkv

# Decode H.266 with FFmpeg's native VVC decoder and transcode back to H.264
ffmpeg -i output.mkv -c:v libx264 -crf 20 -c:a aac back.mp4
# The native decoder is selected automatically (or force with -c:v vvc); it is slower than vvdec

# Fast VVC decoding via the bundled vvdecapp (standalone tool from the vvdec project)
vvdecapp -b bitstream.266 -o decoded.y4m -t 8
ffmpeg -i decoded.y4m -c:v libx264 -crf 20 back.mp4
```

### 2.2 SRT live push/pull

```bash
# Push (caller mode), H.264 + AAC, low-latency settings
ffmpeg -re -stream_loop -1 -i input.mp4 \
  -c:v libx264 -preset veryfast -tune zerolatency -g 60 -b:v 3M \
  -c:a aac -b:a 128k \
  -f mpegts "srt://SERVER:9000?mode=caller&streamid=live/stream1&latency=120"

# Listen as an SRT server and record
ffmpeg -i "srt://:9000?mode=listener" -c copy -f mpegts output.ts

# H.266 over SRT (note: most players cannot handle VVC in MPEG-TS yet; fine for private links/relays)
ffmpeg -re -i input.mp4 -c:v libvvenc -preset faster -b:v 1500k -c:a libmp3lame \
  -f mpegts "srt://SERVER:9000?mode=caller"
```

### 2.3 RTMP push

```bash
ffmpeg -re -i input.mp4 -c:v libx264 -tune zerolatency -b:v 2500k -c:a aac -ar 44100 \
  -f flv rtmp://SERVER/live/streamkey
# RTMPS works the same way: rtmps://... (via the built-in TLS stack)
```

### 2.4 WebRTC (WHIP push / WHEP pull)

WHIP/WHEP use HTTP(S) signaling + SRTP media, natively supported in FFmpeg >= 8.0:

```bash
# WHIP push (video must be H.264/VP8/AV1, audio Opus — WebRTC does not support H.265/H.266)
ffmpeg -re -i input.mp4 \
  -c:v libx264 -profile:v baseline -tune zerolatency -g 60 -b:v 2M \
  -c:a libopus -b:a 64k \
  -f whip "http://SERVER:8080/whip/live"
# Auth example: -headers $'Authorization: Bearer <token>\r\n'

# WHEP pull and record/remux
ffmpeg -i "http://SERVER:8080/whep/live" -c copy output.mp4

# WHEP pull -> SRT forward (WebRTC to live streaming bridge)
ffmpeg -i "http://SERVER:8080/whep/live" -c copy -f mpegts "srt://SERVER:9000?mode=caller"
```

> Run `ffmpeg -h muxer=whip` / `ffmpeg -h demuxer=whep` for all options (ICE servers, DTLS, etc.).

### 2.5 Hardware acceleration

```bash
# List available hwaccels
ffmpeg -hwaccels

# NVIDIA (NVENC/NVDEC/CUVID)
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i in.mp4 -c:v h264_nvenc -preset p5 -b:v 4M out.mp4
ffmpeg -i in.mp4 -c:v hevc_nvenc -rc vbr -cq 24 out.mp4
ffmpeg -c:v h264_cuvid -i in.mp4 ...            # NVDEC decode

# Intel QSV (libvpl)
ffmpeg -init_hw_device qsv=hw -hwaccel qsv -i in.mp4 -c:v h264_qsv -preset veryfast -b:v 4M out.mp4
ffmpeg -i in.mp4 -c:v hevc_qsv -global_quality 24 out.mp4

# AMD AMF (Windows)
ffmpeg -i in.mp4 -c:v h264_amf -quality speed -rc cqp -qp_i 20 -qp_p 22 out.mp4

# Linux VA-API
ffmpeg -init_hw_device vaapi=hw:/dev/dri/renderD128 -hwaccel vaapi \
  -hwaccel_output_format vaapi -i in.mp4 -c:v h264_vaapi -b:v 4M out.mp4

# Windows D3D11VA (decode)
ffmpeg -hwaccel d3d11va -i in.mp4 -c:v libx264 out.mp4
```

Runtime requirements:
- **NVIDIA**: official GPU driver (build time only needs nv-codec-headers, handled automatically);
- **Intel QSV**: Linux needs `intel-media-driver` (iHD) or `intel-vaapi-driver`; Windows needs the Intel GPU driver;
- **AMD AMF**: Windows + AMD GPU driver;
- **VA-API**: Linux driver exposing `/dev/dri/renderD128`.

---

## 3. Licensing & patents

- The default build is **GPL** (x264/x265); distribute the resulting binaries under the GPL;
- TLS defaults to **gnutls** (Linux) / **schannel** (Windows), avoiding `--enable-nonfree`.
  If gnutls is missing on Linux and it falls back to openssl, the script adds `--enable-nonfree`
  automatically — the result is then **not redistributable**;
- `ENABLE_FDK=1` adds fdk-aac, which is GPL-incompatible — personal use only;
- **VVC/H.266 patents**: vvenc/vvdec are BSD-3-Clause-Clear licensed, but VVC coding tools are
  covered by patent pools (e.g. Access Advance VVC). Evaluate licensing for commercial use.

## 4. Troubleshooting

| Problem | Fix |
|---|---|
| Slow/failing GitHub clones | `GITHUB_MIRROR=https://ghproxy.net/https://github.com ./build.sh` |
| lame tarball download fails (SourceForge) | Override with a mirror: `LAME_URL=<mirror-url> ./build.sh` (keep `LAME_SHA256` unless the file differs) |
| cmake too old (< 3.19) | `pip install cmake` or use a newer distro |
| Fully static Windows link fails | The script automatically retries non-static; or rerun with `WINDOWS_FULLY_STATIC=0 ./build.sh ffmpeg` |
| Dependency failed, rerunning | `./build.sh deps` skips already-succeeded libraries (stamp files); `FORCE=1` rebuilds everything |
| Cross-compile Windows build on Linux | Use `./build-windows-cross.sh` (mingw-w64). Install `wine` to enable automatic verification of the exe |
| No VVC hardware codec? | VVC **encoding** is software-only (vvenc) — no GPU supports it yet. VVC **decoding** via VA-API/QSV is emerging in FFmpeg 8.0+, but requires a GPU with VVC decode support; otherwise the native software decoder is used (bundled `vvdecapp` is faster) |
