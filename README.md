# FFmpeg VVC Full Build

One-script FFmpeg build for **Linux (x86_64)** and **Windows (x86_64, MSYS2)** with H.266/VVC, WebRTC (WHIP push), SRT, RTMP and hardware acceleration. A **Linux → Windows mingw-w64 cross-build** script is included as well.

[中文说明](README.zh-CN.md)

| Category | Features |
|---|---|
| Video encode | H.266/VVC ([vvenc](https://github.com/fraunhoferhhi/vvenc)), H.264 (x264), H.265 (x265) |
| Video decode | H.266/VVC (FFmpeg **native** decoder), H.264, H.265 — plus bundled **`vvdecapp`** standalone VVC decoder from the [vvdec](https://github.com/fraunhoferhhi/vvdec) project |
| Audio | MP3 (lame), AAC (native encoder, optional fdk-aac), Opus (libopus) |
| Streaming protocols | SRT (libsrt), RTMP/RTMPS (native), **WHIP (WebRTC push)** |
| HW acceleration | NVIDIA NVENC/NVDEC/CUVID, Intel QSV (libvpl), AMD AMF (Windows), D3D11VA/DXVA2 (Windows), VA-API/VDPAU (Linux) |
| Quality analysis | **VMAF** ([Netflix/vmaf](https://github.com/Netflix/vmaf)) via the `libvmaf` filter — official model `.json` files (incl. the new **VMAF v1**) bundled under `share/vmaf/` |

> **WebRTC note:** FFmpeg ships a **native WHIP muxer (push) since 8.0** — no third-party libdatachannel fork required. There is **no WHEP demuxer (pull) in any FFmpeg release yet** (8.0 / 8.1 / 9.0 / master all register only `ff_whip_muxer`); it remains an unmerged patch ([FFmpeg PR #21603](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/21603)). For low-latency **pull**, use SRT or RTMP instead. This script builds `release/8.0` by default.
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

- `dist/ffmpeg-<version>-linux-x86_64.tar.gz` (contains `bin/ffmpeg`, `bin/ffprobe`, `bin/ffplay`, `bin/vvdecapp`)
- `dist/ffmpeg-<version>-windows-x86_64.tar.gz` / `.zip` (`ffmpeg.exe`, `ffprobe.exe`, `ffplay.exe` etc.; a fully static single-file exe is attempted by default)

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
ENABLE_VMAF=0 ./build.sh         # skip libvmaf (VMAF video-quality filter; built by default)
ENABLE_FFPLAY=0 ./build.sh       # disable ffplay (built by default on native builds; requires SDL2)
WINDOWS_FULLY_STATIC=0 ./build.sh# do not attempt a fully static Windows exe
FFMPEG_SHARED=1 ./build.sh       # build FFmpeg's OWN libs as shared (avcodec-*.dll/.so) + headers + import libs — an SDK for AI/inference tooling (PyAV, torchcodec, bindings). Default 0 = self-contained static exe
FFMPEG_REF=master ./build.sh     # build ffmpeg master instead of release/8.0
GITHUB_MIRROR=https://ghproxy.net/https://github.com ./build.sh   # GitHub mirror prefix
```

Stages: `./build.sh sysdeps | deps | ffmpeg | verify | package | clean` (the same sub-commands work with `build-windows-cross.sh`)

### Static (default) vs shared FFmpeg libraries

`WINDOWS_FULLY_STATIC` and `--disable-shared/--enable-static` are two different
things — do not confuse them:

- `--disable-shared --enable-static` (always on by default) controls how
  **FFmpeg's own libraries** (libavcodec/libavformat/…) are built. Static means
  they are linked *into* `ffmpeg.exe`, so you get a self-contained binary and no
  `avcodec-*.dll`. This is what you want for a normal CLI build.
- `WINDOWS_FULLY_STATIC` only toggles whether the **final exe link** also forces
  third-party/runtime libs to be static (`-static`). With `=0` the exe imports
  MSYS2 DLLs (`libbz2-1.dll`, `libcurl-4.dll`, `libvmaf.dll`, …), which the
  `package` stage auto-detects (transitively) and bundles into `dist/bin`.

Set **`FFMPEG_SHARED=1`** when you need FFmpeg **as shared libraries** — e.g. an
AI/inference program or language binding (PyAV, torchcodec, decord, custom
C/C++/Python code) that links against `libav*` at build time or loads the DLLs at
runtime. It switches FFmpeg to `--enable-shared --disable-static` and changes the
`dist/` layout to a full SDK (name gets a `-shared` suffix):

```
dist/ffmpeg-<ver>-<platform>-x86_64-shared/
├── bin/     ffmpeg(.exe), ffprobe, ffplay + avcodec-*.dll, avformat-*.dll,
│            avutil-*.dll, avfilter-*.dll, swscale-*.dll, swresample-*.dll,
│            avdevice-*.dll  (+ bundled third-party runtime DLLs on Windows)
├── include/ libavcodec/ libavformat/ libavutil/ … (C headers)
├── lib/     import libs (libav*.dll.a / *.lib), *.so on Linux, and *.pc
│            pkg-config files — point PKG_CONFIG_PATH here to compile against it
└── share/   vmaf/ model files (when ENABLE_VMAF=1)
```

Notes: in shared mode the exe depends on the FFmpeg DLLs, so keep `bin/` together
(the loader finds DLLs next to the exe). On **Linux**, run the packaged binaries
with `LD_LIBRARY_PATH=<dist>/lib` (or install `lib/` into a system path) since the
copied exe's rpath still points at the build tree. `FFMPEG_SHARED=1` implies a
non-static exe link (`WINDOWS_FULLY_STATIC` is ignored). `vvdecapp`/`vvencapp`
always import the MinGW runtime DLLs regardless.

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

### 2.4 WebRTC (WHIP push)

WHIP uses HTTP(S) signaling + SRTP media and is natively supported in FFmpeg >= 8.0. **WHEP (pull) is not in FFmpeg yet** — no release (8.0/8.1/9.0) or master registers a WHEP demuxer; it is still an unmerged patch ([PR #21603](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/21603)). Use SRT/RTMP for low-latency pull until then.

```bash
# WHIP push (video must be H.264/VP8/AV1, audio Opus — WebRTC does not support H.265/H.266)
ffmpeg -re -i input.mp4 \
  -c:v libx264 -profile:v baseline -tune zerolatency -g 60 -b:v 2M \
  -c:a libopus -b:a 64k \
  -f whip "http://SERVER:8080/whip/live"
# Auth example: -headers $'Authorization: Bearer <token>\r\n'

# Low-latency pull alternatives (until WHEP lands upstream):
ffmpeg -i "srt://SERVER:9000?mode=caller" -c copy output.mp4      # SRT pull
ffmpeg -i "rtmp://SERVER/live/stream" -c copy output.mp4          # RTMP pull
```

> Run `ffmpeg -h muxer=whip` for all WHIP options (ICE servers, DTLS, etc.).

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

### 2.6 Video quality analysis (VMAF)

The `libvmaf` filter scores a distorted clip against its reference (VMAF 0–100; higher is better).

> The MSYS2/distro libvmaf packages embed **no built-in models**, so this build downloads the official model files into **`share/vmaf/`** and you select one with `model=path=<file>`. In FFmpeg 8.0 the option is `model=path=...` (there is no `model_path`).

```bash
# Score with the bundled default model (run from the dist folder, or use a full path)
ffmpeg -i distorted.mp4 -i reference.mp4 \
  -lavfi "[0:v][1:v]libvmaf=model=path=share/vmaf/vmaf_v0.6.1.json" -f null -

# VMAF v1 model (new in libvmaf 3.2.x) + JSON log
ffmpeg -i distorted.mp4 -i reference.mp4 \
  -lavfi "[0:v][1:v]libvmaf=model=path=share/vmaf/vmaf_v1.0.16_3d0h.json:log_fmt=json:log_path=vmaf.json" \
  -f null -

# Also report PSNR/SSIM alongside VMAF
ffmpeg -i distorted.mp4 -i reference.mp4 \
  -lavfi "[0:v][1:v]libvmaf=model=path=share/vmaf/vmaf_v0.6.1.json:feature=name=psnr|name=ssim" \
  -f null -
```

Bundled models (`share/vmaf/`):

| File | Use |
|---|---|
| `vmaf_v0.6.1.json` | default HD model (1080p, 3H viewing distance) |
| `vmaf_4k_v0.6.1.json` | 4K/UHD content |
| `vmaf_v0.6.1neg.json` | "no enhancement gain" — penalizes sharpening/contrast tricks |
| `vmaf_v1.0.16_3d0h.json` | **VMAF v1**, standard HD viewing condition |
| `vmaf_v1.0.16_5d0h.json` | VMAF v1, farther viewing distance (needs a reasonably large frame) |
| `vmaf_v1.0.16_1d5h_2160.json`, `vmaf_v1.0.16_3d0h_2160.json` | VMAF v1, 4K |

> **Windows path note:** inside `-lavfi`, a drive-letter path such as `E:/...` contains `:`, which collides with the filter's option separator. Either `cd` into the folder and use a **relative** path (as above), or escape the colon: `model=path=E\:/full/path/vmaf_v0.6.1.json`.
>
> The **first** input is the distorted clip, the **second** the reference; both must share resolution, frame rate and pixel format (add `scale`/`fps`/`format` before `libvmaf` if not). Run `ffmpeg -h filter=libvmaf` for all options. Set `ENABLE_VMAF=0` to skip libvmaf. On Windows the prebuilt MSYS2 package (`mingw-w64-ucrt-x86_64-vmaf`) is used; on Linux the script builds libvmaf from source with meson. Model files are fetched either way.

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
