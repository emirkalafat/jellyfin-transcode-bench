# jellyfin-transcode-bench

**Find out what your Jellyfin server can really transcode, before your users find out for you.**

A benchmark suite that runs the same ffmpeg that Jellyfin runs ([jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg)) on real 4K / HDR10 / Dolby Vision / HEVC / AV1 clips and tells you, per source type and per target (4K→1080p, 1080p HDR→SDR, ...), how many times faster than real time your hardware goes, how much CPU it costs, and how many streams you can run in parallel.

It compares every engine on the machine side by side:

| Engine | Hardware | Used through |
|---|---|---|
| CPU | any | libx264 / libx265, `zscale` + `tonemap` |
| Intel QuickSync | iGPU (Arc: untested) | `h264_qsv`, `vpp_qsv` |
| VAAPI | Intel and AMD (Linux) | `h264_vaapi`, `scale_vaapi`, `tonemap_vaapi` |
| NVIDIA | GeForce / Quadro / Tesla | NVDEC, `scale_cuda`, `tonemap_cuda`, NVENC |
| AMD AMF | Radeon (Windows) | `h264_amf` |
| GPU tone-mapping | any OpenCL / Vulkan GPU | `tonemap_opencl`, `libplacebo` |

Everything is probed **before** the first test: every GPU is inventoried, every hardware path is tried with a one-second run, and engines that cannot work are skipped with the exact reason in the report instead of failing halfway.

> Not affiliated with the Jellyfin project. "Jellyfin" is used to say which server the numbers are meant for.

## Why not just look at a spec sheet?

Hardware transcoding capability depends on things a spec sheet does not tell you: whether *your* driver exposes the engine, whether your ffmpeg has the right filter, whether HDR tone-mapping runs on the GPU or silently falls back to the CPU, and what happens at 4K with 40 Mbps HEVC. Example of what this suite found on real machines:

| Machine | Clip → target | CPU | Best path | Parallel streams |
|---|---|---:|---|---:|
| Intel i3-4150 / HD 4400 | H.264 1080p → 720p | 2.0x | QuickSync 10.7x | 4+ |
| Intel i3-4150 / HD 4400 | HEVC 4K HDR10 → 1080p SDR | 0.7x | CPU+QSV encode 0.9x (no HEVC decode in HW) | 0 |
| Ryzen 7800X3D + RTX 5070 Ti | HEVC 4K Dolby Vision (P8) → 4K SDR | 1.4x | NVDEC + `tonemap_cuda` + NVENC 5.1x | - |

(`x` = times real time; 1.0x is exactly real time.)

## Quick start

### 1. Get ffmpeg

The benchmark prefers a **jellyfin-ffmpeg** portable build in `ffmpeg-jellyfin/` because it is what a Jellyfin server runs and the only build that has `tonemap_cuda`. The helper downloads the latest release and verifies its SHA256:

```powershell
# Windows
.\tools\get-ffmpeg.ps1
```
```bash
# Linux
bash tools/get-ffmpeg.sh
```

(Any other ffmpeg on `PATH` works too, but some GPU paths will be skipped. On Linux an installed `jellyfin-ffmpeg` package in `/usr/lib/jellyfin-ffmpeg/` is picked up automatically.)

### 2. Get test clips

You need short clips of the formats you care about. Two ways, details in **[docs/media-clips.md](docs/media-clips.md)**:

```powershell
# a) the official Jellyfin test videos (no personal media needed, ~1.1 GB, SHA256-verified)
.\tools\get-test-videos.ps1 -Set starter

# b) clips cut from your own library (no re-encoding, video stream only)
.\windows\make-clips.ps1 -Source "D:\Movies","D:\TV"
```

### 3. Run

```powershell
# Windows: real-content benchmark on everything in .\media (double-click windows\run-media.bat also works)
.\windows\media-test.ps1 -Quick           # short first run
.\windows\media-test.ps1                  # full run
.\windows\synthetic-test.ps1              # synthetic sources: raw decode/encode/transcode speed + parallel streams
```
```bash
# Linux
bash linux/media-test.sh --quick
bash linux/media-test.sh
bash linux/synthetic-test.sh
```

Useful options (both platforms accept the same ideas):

```powershell
.\windows\media-test.ps1 -Filter "*hdr*" -Variants cpu,nv,plc,cl     # only HDR clips, chosen engines
.\windows\media-test.ps1 -Scenarios to1080,same -NoConcurrency        # skip 720p and the parallel-stream test
```
```bash
bash linux/media-test.sh --filter '*hdr*' --variants "cpu vaapi nv plc"
bash linux/media-test.sh --device /dev/dri/renderD129                 # test one specific GPU
```

### 4. Read the report

Results land in `results/<kind>_<host>_<timestamp>/`: `report.md` (human readable), `results.json` / `results.tsv` (data) and `logs/` (raw ffmpeg output of every run, so any FAIL can be diagnosed).

## What is measured

For every clip the suite picks the scenarios that make sense for it:

| Scenario | What it does |
|---|---|
| `to1080` | fit inside 1920x1080 (4K sources) |
| `to720` | fit inside 1280x720 (4K and 1080p sources) |
| `same` | keep the resolution (bitrate-only transcode; or HDR → SDR at native resolution) |

HDR sources (HDR10, HLG, Dolby Vision) are tone-mapped to SDR. The output is H.264 at 20 / 8 / 4 / 2 Mbps for 4K / 1080p / 720p / SD, like a typical Jellyfin transcode.

Each scenario runs through several **variants**. A variant is skipped, with the reason, when it cannot work on the machine:

| Windows | Linux | Meaning |
|---|---|---|
| `cpu` | `cpu` | software decode, filters and libx264 |
| `hw` | `qsv`, `vaapi-<gpu>` | full hardware: HW decode + HW scale/tone-map + HW encode (QuickSync / VAAPI) |
| `nv` | `nv` | NVDEC + `scale_cuda` + `tonemap_cuda` + NVENC |
| `hyb`, `hybn`, `hyba` | `hybq`, `hybv-<gpu>`, `hybn` | CPU decode and filters, hardware **encode** (QSV / NVENC / AMF / VAAPI) |
| `nvd` | `nvd`, `vad-<gpu>` | hardware decode, **CPU** tone-map, hardware encode (HDR only) |
| `cl` | `cl` | CPU decode, **OpenCL** tone-map, encode |
| `plc` | `plc` | CPU decode, **libplacebo (Vulkan)** tone-map and scale, encode; also copes with Dolby Vision profile 5 |

After the matrix, the best non-CPU variant of every source class is run **N times in parallel** to find how many simultaneous streams stay at or above real time.

### Reading the numbers

- **x realtime** = throughput / source frame rate. `1.0x` keeps up with exactly one viewer; `4.0x` means roughly four simultaneous transcodes if nothing else is running.
- **CPU %** is the average whole-machine CPU load during the run. A GPU path that still pins the CPU is only half a win.
- **GPU vcs/vecs/rcs** (Linux, Intel, needs `intel_gpu_top` and root) or **GPU dec/enc/vpp** (Windows counters) show which engine is the bottleneck. NVIDIA/AMD load is not collected, watch `nvidia-smi dmon` or `radeontop` next to the run.
- A value with `*` hit the timeout; it is the partial throughput.

### Caveats worth knowing

- Only the **video** stream is transcoded; audio is ignored (it is cheap compared to video).
- Every run includes process start-up. OpenCL and libplacebo compile kernels on each start, so *very* short clips understate them; the default clip length is 30 s. The first run of each GPU variant is preceded by a 2 s warm-up so one-off costs (CUDA JIT, driver init) are not counted.
- Dolby Vision profile 5 has no HDR10 base layer and cannot be tone-mapped by `zscale`; it is timed **without** tone-mapping except in the `plc` variant. Profile 8 is treated like HDR10.
- Interlaced sources are not deinterlaced.
- Real-world numbers depend on bitrate and content. Clips with real motion matter: a static title card encodes unrealistically fast.

## Repository layout

```
jellyfin-transcode-bench/
├─ windows/            PowerShell scripts (+ .bat launchers)
│  ├─ media-test.ps1       real-content benchmark
│  ├─ synthetic-test.ps1   synthetic benchmark + parallel streams
│  └─ make-clips.ps1       cut test clips out of your library
├─ linux/              the same, in bash (lib-common.sh holds the shared code)
├─ tools/              get-ffmpeg.*  and  get-test-videos.*
├─ container/          Containerfile for podman / Docker (Bazzite, Fedora Atomic, ...)
├─ docs/               media-clips.md, linux-and-podman.md (+ Turkish)
├─ media/              YOUR clips go here (git-ignored)
└─ results/            reports (git-ignored)
```

## Requirements

- **Windows:** Windows PowerShell 5.1+ (built in) or PowerShell 7. The newest GPU drivers for the engines you want to test.
- **Linux:** bash 4+, GNU awk and coreutils; for VAAPI the Mesa / intel-media / i965 driver, for NVIDIA the proprietary driver (and the NVIDIA container toolkit in containers). See [docs/linux-and-podman.md](docs/linux-and-podman.md), including Bazzite / podman.
- A few GB of free space in the temp folder for generated sources, and about 1-1.5 GB if you download the starter clip set.

## Status

Developed and exercised on: an Intel Haswell iGPU (HD Graphics 4400, Windows), a Ryzen 7 7800X3D with an RTX 5070 Ti and a Radeon iGPU (Windows, plus the bash scripts through WSL), and an Intel Tiger Lake + RTX 3060 laptop (Linux container, first iteration). The Linux VAAPI and QSV paths have had the least field testing: if a probe or a variant fails on your hardware, please open an issue with the `logs/` folder of the run.

## Contributing

Issues and pull requests are welcome, especially results and fixes for hardware that is not covered yet (Intel Arc, newer Radeon, Jetson, ...). Keep both platforms in step where possible. Never commit media clips or result folders.

## License

[MIT](LICENSE). The Jellyfin test videos used by `tools/get-test-videos.*` are provided by the Jellyfin project, courtesy of Gnattu, under CC BY-SA 4.0 and are downloaded, never redistributed here. jellyfin-ffmpeg is GPL and is downloaded from its own releases page.

Türkçe: [README.tr.md](README.tr.md)
