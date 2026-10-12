# FFmpeg H.266(VVC) 全功能编译脚本

在 **Linux (x86_64)** 或 **Windows (x86_64, MSYS2)** 上一键编译 FFmpeg，产物特性如下；另附 **Linux → Windows mingw-w64 交叉编译**脚本。

[English](README.md)

| 类别 | 支持内容 |
|---|---|
| 视频编码 | H.266/VVC ([vvenc](https://github.com/fraunhoferhhi/vvenc))、H.264 (x264)、H.265 (x265) |
| 视频解码 | H.266/VVC（FFmpeg **原生**解码器）、H.264、H.265 —— 另附带 [vvdec](https://github.com/fraunhoferhhi/vvdec) 项目的独立解码工具 **`vvdecapp`** |
| 音频 | MP3 (lame)、AAC (原生编码器，可选 fdk-aac)、Opus (libopus) |
| 推拉流协议 | SRT (libsrt)、RTMP/RTMPS (原生)、**WHIP (WebRTC 推流)** |
| 硬件加速 | NVIDIA NVENC/NVDEC/CUVID、Intel QSV (libvpl)、AMD AMF (Windows)、D3D11VA/DXVA2 (Windows)、VA-API/VDPAU (Linux) |
| 画质分析 | **VMAF**（[Netflix/vmaf](https://github.com/Netflix/vmaf)），通过 `libvmaf` 滤镜 —— 官方模型 `.json` 文件（含全新 **VMAF v1**）打包在 `share/vmaf/` 下 |

> WebRTC 说明：FFmpeg **8.0 起原生内置 WHIP muxer（推流）**，无需第三方 libdatachannel 分支。
> 但**任何 FFmpeg 版本都还没有 WHEP demuxer（拉流）**——8.0 / 8.1 / 9.0 / master 均只注册了
> `ff_whip_muxer`，WHEP 仍是未合入的补丁（[FFmpeg PR #21603](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/21603)）。
> 低延迟**拉流**请暂用 SRT 或 RTMP。脚本默认使用 `release/8.0` 分支。
>
> VVC 解码说明：FFmpeg 主线**没有 libvvdec 包装器**（master 也没有），`ffmpeg` 解码 H.266 用的是内置
> 原生解码器（`-c:v vvc`）。速度更快的 Fraunhofer vvdec 以独立工具 `vvdecapp` 的形式随包发布，见 2.1 节。

---

## 1. 使用方法

### Linux（Ubuntu 22.04+/Debian 12+/Fedora/Arch）

```bash
chmod +x build.sh
./build.sh                 # 自动安装系统依赖 -> 编译依赖库 -> 编译 ffmpeg -> 校验 -> 打包
```

### Windows

1. 安装 [MSYS2](https://www.msys2.org/)；
2. 从开始菜单打开 **“MSYS2 UCRT64”**（或 MINGW64）shell；
3. 执行：

```bash
cd /d/path/to/this/folder   # 进入脚本目录
./build.sh
```

### 在 Linux 上交叉编译 Windows 版

```bash
./build-windows-cross.sh   # 自动安装 mingw-w64 工具链，交叉编译全部依赖 + ffmpeg
```

- 产物与 MSYS2 方式相同：`dist/ffmpeg-<版本>-windows-x86_64.tar.gz` / `.zip`（默认尝试全静态链接单文件 exe）；
- 全部依赖（x264/x265/lame/opus/srt/vvenc/vvdec/OpenSSL/libvpl/AMF/ffnvcodec）都交叉编译到独立 prefix，不会混入宿主机 Linux 库；
- TLS 使用 `schannel`（Windows 原生 API），exe 无外部 TLS/DLL 依赖；
- 若安装了 `wine`，会自动用 wine 运行 exe 做特性校验；未安装则跳过校验；
- 交叉编译模式下不构建 ffplay（没有交叉编译的 SDL2）。

### 产物

- `dist/ffmpeg-<版本>-linux-x86_64.tar.gz`（含 `bin/ffmpeg`、`bin/ffprobe`、`bin/ffplay`、`bin/vvdecapp`）
- `dist/ffmpeg-<版本>-windows-x86_64.tar.gz` / `.zip`（`ffmpeg.exe`、`ffprobe.exe`、`ffplay.exe` 等，默认尝试全静态链接，单文件即可运行）

> Windows 产物有两种获得方式：在 Windows 的 MSYS2 里运行 `build.sh`，或在 Linux 上运行
> `build-windows-cross.sh`（mingw-w64 交叉编译）。

### 常用开关（环境变量）

```bash
JOBS=16 ./build.sh               # 指定并行数
FORCE=1 ./build.sh deps          # 强制重建依赖库
SKIP_SYSDEPS=1 ./build.sh        # 不安装系统包（自行保证依赖）
ENABLE_FDK=1 ./build.sh          # 额外编入 libfdk-aac（与 GPL 不兼容，仅自用）
ENABLE_QSV=0 ./build.sh          # 跳过 Intel QSV
ENABLE_NVIDIA=0 ./build.sh       # 跳过 NVENC/NVDEC
ENABLE_VMAF=0 ./build.sh         # 跳过 libvmaf（VMAF 画质分析滤镜，默认开启）
ENABLE_FFPLAY=0 ./build.sh       # 关闭 ffplay（本机构建默认开启，需要 SDL2）
WINDOWS_FULLY_STATIC=0 ./build.sh# Windows 不做全静态链接
FFMPEG_REF=master ./build.sh     # 使用 ffmpeg master 分支
GITHUB_MIRROR=https://ghproxy.net/https://github.com ./build.sh   # 国内加速 github 克隆
```

分步执行：`./build.sh sysdeps | deps | ffmpeg | verify | package | clean`（`build-windows-cross.sh` 支持相同的分步子命令）

---

## 2. 使用示例

### 2.1 H.266/VVC 转码（软件编解码，VVC 目前无消费级硬件编解码）

```bash
# 转码为 H.266 (libvvenc 编码, opus 音频)
ffmpeg -i input.mp4 -c:v libvvenc -preset medium -b:v 2M -c:a libopus -b:a 128k output.mkv

# 更快的预设: faster/fast/medium/slow (vvenc), 压缩率与速度成反比
ffmpeg -i input.mp4 -c:v libvvenc -preset fast -qp 32 output.mkv

# 用 FFmpeg 原生 VVC 解码器解码 H.266 并转回 H.264
ffmpeg -i output.mkv -c:v libx264 -crf 20 -c:a aac back.mp4
# 原生解码器会自动被选中（也可显式 -c:v vvc）；速度比 vvdec 慢

# 用附带的 vvdecapp 快速解码 VVC（vvdec 项目的独立工具）
vvdecapp -b bitstream.266 -o decoded.y4m -t 8
ffmpeg -i decoded.y4m -c:v libx264 -crf 20 back.mp4
```

### 2.2 SRT 实时推拉流

```bash
# 推流（caller 模式），H.264 + AAC，低延迟参数
ffmpeg -re -stream_loop -1 -i input.mp4 \
  -c:v libx264 -preset veryfast -tune zerolatency -g 60 -b:v 3M \
  -c:a aac -b:a 128k \
  -f mpegts "srt://SERVER:9000?mode=caller&streamid=live/stream1&latency=120"

# 作为 SRT 服务端监听拉流
ffmpeg -i "srt://:9000?mode=listener" -c copy -f mpegts output.ts

# H.266 走 SRT（注意：SRT 容器用 mpegts 时，多数播放器尚不支持 VVC，建议自用/中转场景）
ffmpeg -re -i input.mp4 -c:v libvvenc -preset faster -b:v 1500k -c:a libmp3lame \
  -f mpegts "srt://SERVER:9000?mode=caller"
```

### 2.3 RTMP 推流

```bash
ffmpeg -re -i input.mp4 -c:v libx264 -tune zerolatency -b:v 2500k -c:a aac -ar 44100 \
  -f flv rtmp://SERVER/live/streamkey
# RTMPS 同理: rtmps://...（依赖内置 TLS）
```

### 2.4 WebRTC（WHIP 推流）

WHIP 使用 HTTP(S) 信令 + SRTP 媒体，FFmpeg ≥ 8.0 原生支持。**WHEP（拉流）目前 FFmpeg 还没有**——任何发行版（8.0/8.1/9.0）和 master 都没有注册 WHEP demuxer，它仍是未合入的补丁（[PR #21603](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/21603)）。在其合入前，低延迟拉流请改用 SRT/RTMP。

```bash
# WHIP 推流（视频只能 H.264/VP8/AV1，音频 Opus —— WebRTC 规范不支持 H.265/H.266）
ffmpeg -re -i input.mp4 \
  -c:v libx264 -profile:v baseline -tune zerolatency -g 60 -b:v 2M \
  -c:a libopus -b:a 64k \
  -f whip "http://SERVER:8080/whip/live"
# 如需鉴权: -headers $'Authorization: Bearer <token>\r\n' 或按服务端要求传 -ice_server 等参数

# 低延迟拉流的替代方案（在 WHEP 合入主线之前）：
ffmpeg -i "srt://SERVER:9000?mode=caller" -c copy output.mp4      # SRT 拉流
ffmpeg -i "rtmp://SERVER/live/stream" -c copy output.mp4          # RTMP 拉流
```

> 可用 `ffmpeg -h muxer=whip` 查看全部 WHIP 参数（ICE server、DTLS 等）。

### 2.5 硬件编解码

```bash
# 查看可用硬件加速器
ffmpeg -hwaccels

# NVIDIA（NVENC/NVDEC/CUVID）
ffmpeg -hwaccel cuda -hwaccel_output_format cuda -i in.mp4 -c:v h264_nvenc -preset p5 -b:v 4M out.mp4
ffmpeg -i in.mp4 -c:v hevc_nvenc -rc vbr -cq 24 out.mp4
ffmpeg -c:v h264_cuvid -i in.mp4 ...            # NVDEC 解码

# Intel QSV（libvpl）
ffmpeg -init_hw_device qsv=hw -hwaccel qsv -i in.mp4 -c:v h264_qsv -preset veryfast -b:v 4M out.mp4
ffmpeg -i in.mp4 -c:v hevc_qsv -global_quality 24 out.mp4

# AMD AMF（Windows）
ffmpeg -i in.mp4 -c:v h264_amf -quality speed -rc cqp -qp_i 20 -qp_p 22 out.mp4

# Linux VA-API
ffmpeg -init_hw_device vaapi=hw:/dev/dri/renderD128 -hwaccel vaapi \
  -hwaccel_output_format vaapi -i in.mp4 -c:v h264_vaapi -b:v 4M out.mp4

# Windows D3D11VA（解码）
ffmpeg -hwaccel d3d11va -i in.mp4 -c:v libx264 out.mp4
```

硬件加速运行条件：
- **NVIDIA**：装好官方显卡驱动即可（编译期只需 nv-codec-headers，已自动处理）；
- **Intel QSV**：Linux 需 `intel-media-driver`（iHD）或 `intel-vaapi-driver`；Windows 需 Intel 显卡驱动；
- **AMD AMF**：Windows + AMD 显卡驱动；
- **VA-API**：Linux 需对应 `/dev/dri/renderD128` 驱动。

### 2.6 视频画质分析（VMAF）

`libvmaf` 滤镜把失真视频与参考原片对比打分（VMAF 0–100，越高越好）。

> MSYS2/发行版的 libvmaf 包**不内置任何模型**，因此本构建会把官方模型文件下载到 **`share/vmaf/`**，用 `model=path=<文件>` 指定。FFmpeg 8.0 里选项是 `model=path=...`（没有 `model_path`）。

```bash
# 用打包的默认模型打分（在 dist 目录下运行，或改用完整路径）
ffmpeg -i distorted.mp4 -i reference.mp4 \
  -lavfi "[0:v][1:v]libvmaf=model=path=share/vmaf/vmaf_v0.6.1.json" -f null -

# VMAF v1 模型（libvmaf 3.2.x 新增）+ 输出 JSON 日志
ffmpeg -i distorted.mp4 -i reference.mp4 \
  -lavfi "[0:v][1:v]libvmaf=model=path=share/vmaf/vmaf_v1.0.16_3d0h.json:log_fmt=json:log_path=vmaf.json" \
  -f null -

# 同时输出 PSNR/SSIM
ffmpeg -i distorted.mp4 -i reference.mp4 \
  -lavfi "[0:v][1:v]libvmaf=model=path=share/vmaf/vmaf_v0.6.1.json:feature=name=psnr|name=ssim" \
  -f null -
```

打包的模型（`share/vmaf/`）：

| 文件 | 用途 |
|---|---|
| `vmaf_v0.6.1.json` | 默认高清模型（1080p，3H 观看距离） |
| `vmaf_4k_v0.6.1.json` | 4K/超高清内容 |
| `vmaf_v0.6.1neg.json` | “无增强增益”版本 —— 惩罚锐化/对比度之类的取巧处理 |
| `vmaf_v1.0.16_3d0h.json` | **VMAF v1**，标准高清观看条件 |
| `vmaf_v1.0.16_5d0h.json` | VMAF v1，更远观看距离（需要足够大的画面） |
| `vmaf_v1.0.16_1d5h_2160.json`、`vmaf_v1.0.16_3d0h_2160.json` | VMAF v1，4K |

> **Windows 路径提示：** 在 `-lavfi` 里，形如 `E:/...` 的盘符路径含有 `:`，会和滤镜的选项分隔符冲突。解决办法：`cd` 进该目录用**相对路径**（如上），或把冒号转义：`model=path=E\:/full/path/vmaf_v0.6.1.json`。
>
> **第一个**输入是失真视频，**第二个**是参考原片；两者分辨率、帧率、像素格式必须一致（不一致时在 `libvmaf` 前加 `scale`/`fps`/`format`）。全部参数见 `ffmpeg -h filter=libvmaf`。设 `ENABLE_VMAF=0` 可跳过 libvmaf。Windows 下使用 MSYS2 预编译包（`mingw-w64-ucrt-x86_64-vmaf`）；Linux 下脚本用 meson 从源码编译。两种情况都会自动下载模型文件。

---

## 3. 许可与专利注意事项

- 本脚本默认以 **GPL**（x264/x265）方式编译，最终二进制以 GPL 分发；
- 默认 TLS 使用 **gnutls**（Linux）/ **schannel**（Windows），避免 `--enable-nonfree`；
  若 Linux 上没有 gnutls 而回退到 openssl，脚本会自动加 `--enable-nonfree`，此时产物**不可再分发**；
- `ENABLE_FDK=1` 引入的 fdk-aac 与 GPL 不兼容，仅限自用；
- **VVC/H.266 专利**：vvenc/vvdec 代码为 BSD-3-Clause-Clear，但 VVC 编解码涉及专利池
  （Access Advance VVC 池等），商用部署需自行评估专利授权。

## 4. 常见问题

| 问题 | 解决 |
|---|---|
| GitHub 克隆慢/失败 | `GITHUB_MIRROR=https://ghproxy.net/https://github.com ./build.sh` |
| lame 源码包下载失败（SourceForge） | 用镜像覆盖：`LAME_URL=<镜像地址> ./build.sh`（文件一致时无需改 `LAME_SHA256`） |
| cmake 版本过低 (<3.19) | `pip install cmake` 或使用更新的发行版 |
| Windows 全静态链接失败 | 脚本会自动回退为非全静态重试；或手动 `WINDOWS_FULLY_STATIC=0 ./build.sh ffmpeg` |
| 某依赖编译失败后重跑 | 修好后 `./build.sh deps` 会自动跳过已成功的库（stamps 机制），`FORCE=1` 强制全部重建 |
| 想在 Linux 交叉编译 Windows 版 | 使用 `./build-windows-cross.sh`（mingw-w64）；建议安装 `wine` 以便自动校验 exe 特性 |
| H.266 没有硬件编解码？ | **编码**目前只有软件 vvenc（无 GPU 支持）。**解码**方面 FFmpeg 8.0+ 已出现 VA-API/QSV 硬件路径，但需要 GPU 本身支持 VVC 硬解（如 Intel 较新核显）；否则走原生软解（附带的 `vvdecapp` 速度更快） |
