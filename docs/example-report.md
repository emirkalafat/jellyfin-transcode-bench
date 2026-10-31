> **Example report.** Output of `windows\media-test.ps1 -Quick -Anonymize` on a Ryzen 7 7800X3D with an RTX 5070 Ti and a Radeon iGPU, run on four short clips (4K HDR10, 4K Dolby Vision P8, 1080p H.264, 1080p HEVC). Quick mode uses 10 s clips, so figures are conservative; the clip names are anonymised and the host name replaced.

# Jellyfin transcode benchmark - EXAMPLE-PC

Run: 2026-10-31T16:49:51 | clips of 10 s | timeout 120 s per run | quick mode | clip names anonymised

**How to read the numbers:** speeds are *times real time*. 1.0x keeps up with exactly one viewer; 4.0x is roughly four simultaneous transcodes if nothing else is running. Verdict: >= 2.0x comfortable, 1.0-2.0x borderline, < 1.0x too slow.

## Summary

**Bottom line:** 10 source/target combinations tested: **10 comfortable** (2x real time or more), **0 borderline** (1-2x), **0 too slow** (below real time).

For each source type and target, the fastest path found on this machine (mean over the clips of that type).

| Source | Target | Verdict | Best path | Speed | CPU only | Gain vs CPU |
|---|---|---|---|---:|---:|---:|
| 4K HEVC HDR10 | 1080p HDR->SDR | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 10.4x | 4.0x | 2.6x faster |
| 4K HEVC HDR10 | 720p HDR->SDR | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 10.7x | 6.0x | 1.8x faster |
| 4K HEVC HDR10 | 4K HDR->SDR | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 5.5x | 1.5x | 3.7x faster |
| 1080p H.264 SDR | 720p | Comfortable | CPU decode + AMD AMF encode | 16.5x | 11.4x | 1.4x faster |
| 1080p H.264 SDR | 1080p (bitrate only) | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 11.8x | 7.1x | 1.7x faster |
| 4K HEVC Dolby Vision P8 | 1080p HDR->SDR | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 10.4x | 3.8x | 2.7x faster |
| 4K HEVC Dolby Vision P8 | 720p HDR->SDR | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 10.6x | 5.2x | 2.1x faster |
| 4K HEVC Dolby Vision P8 | 4K HDR->SDR | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 5.6x | 1.4x | 4.0x faster |
| 1080p HEVC SDR | 720p | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 15.8x | 9.1x | 1.7x faster |
| 1080p HEVC SDR | 1080p (bitrate only) | Comfortable | NVIDIA all on GPU (NVDEC + NVENC) | 12.2x | 6.4x | 1.9x faster |

## Findings and recommendations

- **Best hardware acceleration for this machine: NVIDIA NVENC.** It is the fastest path in 9 of 10 source/target combinations. In Jellyfin: Dashboard > Playback > Transcoding > Hardware acceleration.
- **4K HEVC HDR10: GPU tone-mapping works.** Hardest case (4K HDR->SDR) runs at 5.5x real time with 'NVIDIA all on GPU (NVDEC + NVENC)' (CPU only: 1.5x).
- **4K HEVC Dolby Vision P8: GPU tone-mapping works.** Hardest case (4K HDR->SDR) runs at 5.6x real time with 'NVIDIA all on GPU (NVDEC + NVENC)' (CPU only: 1.4x).

## Parallel streams

How many copies of the same transcode run at real time or faster at once (the best non-CPU path of each source type).

| Source | Target | Path | Parallel streams at real time | Tested up to |
|---|---|---|---:|---:|
| 4K HEVC HDR10 | 720p HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | 3+ (test ceiling) | 3 |
| 1080p H.264 SDR | 720p | CPU decode + AMD AMF encode | 3+ (test ceiling) | 3 |
| 4K HEVC Dolby Vision P8 | 720p HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | 3+ (test ceiling) | 3 |
| 1080p HEVC SDR | 720p | NVIDIA all on GPU (NVDEC + NVENC) | 3+ (test ceiling) | 3 |

<details><summary>Parallel-stream measurements</summary>

| Source | Path | Streams | Total fps | Slowest stream fps | Slowest x realtime | CPU % | GPU dec/enc/vpp % |
|---|---|---:|---:|---:|---:|---:|---|
| 4K HEVC HDR10 | NVIDIA all on GPU (NVDEC + NVENC) | 1 | 272.7 | 272.7 | 11.37 | 25 | 26/4/0 |
| 4K HEVC HDR10 | NVIDIA all on GPU (NVDEC + NVENC) | 2 | 385.9 | 190.7 | 7.95 | 29 | 2/0/0 |
| 4K HEVC HDR10 | NVIDIA all on GPU (NVDEC + NVENC) | 3 | 412.7 | 136.4 | 5.69 | 32 | 6/0/0 |
| 1080p H.264 SDR | CPU decode + AMD AMF encode | 1 | 393.7 | 393.7 | 16.42 | 28 | 2/0/0 |
| 1080p H.264 SDR | CPU decode + AMD AMF encode | 2 | 500.2 | 249.3 | 10.39 | 50 | 3/0/0 |
| 1080p H.264 SDR | CPU decode + AMD AMF encode | 3 | 546.6 | 180.1 | 7.51 | 48 | 3/0/0 |
| 4K HEVC Dolby Vision P8 | NVIDIA all on GPU (NVDEC + NVENC) | 1 | 258.5 | 258.5 | 10.78 | 34 | 21/2/0 |
| 4K HEVC Dolby Vision P8 | NVIDIA all on GPU (NVDEC + NVENC) | 2 | 364.2 | 179.6 | 7.49 | 28 | 8/0/0 |
| 4K HEVC Dolby Vision P8 | NVIDIA all on GPU (NVDEC + NVENC) | 3 | 396.2 | 131.6 | 5.49 | 37 | 11/0/0 |
| 1080p HEVC SDR | NVIDIA all on GPU (NVDEC + NVENC) | 1 | 335 | 335 | 13.97 | 25 | 39/24/0 |
| 1080p HEVC SDR | NVIDIA all on GPU (NVDEC + NVENC) | 2 | 572.2 | 285.3 | 11.9 | 32 | 47/29/0 |
| 1080p HEVC SDR | NVIDIA all on GPU (NVDEC + NVENC) | 3 | 712.9 | 235.8 | 9.83 | 39 | 33/13/0 |

</details>

## Your hardware

- **CPU:** AMD Ryzen 7 7800X3D 8-Core Processor (8 cores / 16 threads), 31.2 GB RAM
- **GPUs:** AMD Radeon(TM) Graphics (driver 32.0.21042.62); NVIDIA GeForce RTX 5070 Ti (driver 32.0.16.3020)
- **OS:** Microsoft Windows 11 Pro Insider Preview (build 26340) | **Power plan:** Yüksek performans
- **ffmpeg:** ffmpeg version 8.1.3-Jellyfin Copyright (c) 2000-2026 the FFmpeg developers
- **CPU load before the test:** 19 %

| Engine | Status | Details |
|---|---|---|
| CPU (libx264) | OK | software transcoding, always available |
| Intel QuickSync | No Intel GPU | |
| NVIDIA NVENC | OK, full GPU path | encode preset '-preset p4', scale_cuda True, tonemap_cuda True |
| AMD AMF | OK, encode | decode is done by the CPU in these tests |
| OpenCL tone-map | OK | opencl=ocl |
| libplacebo (Vulkan) tone-map | OK | vulkan=vk |
| CPU tone-map (zscale) | OK | used by the CPU and hybrid variants |

## Clips tested

| Clip | Source type | Resolution | fps | Mbps | HDR | Size MB | Hardware decode |
|---|---|---|---:|---:|---|---:|---|
| clip-01 | 4K HEVC HDR10 | 3840x1608 | 23.98 | 8.7 | hdr10 | 47.8 | NVDEC |
| clip-02 | 1080p H.264 SDR | 1920x1080 | 23.98 | 2.9 | sdr | 16.2 | NVDEC |
| clip-03 | 4K HEVC Dolby Vision P8 | 3840x1600 | 23.98 | 25.6 | dv-p8 | 144.2 | NVDEC |
| clip-04 | 1080p HEVC SDR | 1920x1080 | 23.98 | 7.6 | sdr | 43.9 | NVDEC |

## All paths side by side (x real time, per clip)

| Clip | Target | CPU | OpenCL tone-map | libplacebo | NVIDIA full GPU | CPU + NVENC | NVDEC + CPU tone-map | CPU + AMF | Best |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| clip-01 | 4K -> 1080p HDR->SDR | 3.95x | 5.23x | 4.81x | 10.37x | 4.49x | 4.63x | 4.51x | NVIDIA full GPU (10.37x) |
| clip-01 | 4K -> 720p HDR->SDR | 6.01x | 5.79x | 4.75x | 10.66x | 5.81x | 5.93x | 6.15x | NVIDIA full GPU (10.66x) |
| clip-01 | 4K -> 4K HDR->SDR | 1.48x | 5.11x | 4.13x | 5.53x | 1.63x | 1.56x | 1.53x | NVIDIA full GPU (5.53x) |
| clip-02 | 1080p -> 720p | 11.44x | - | - | 12.10x | 15.20x | - | 16.51x | CPU + AMF (16.51x) |
| clip-02 | 1080p -> 1080p (bitrate only) | 7.11x | - | - | 11.84x | 11.54x | - | 10.59x | NVIDIA full GPU (11.84x) |
| clip-03 | 4K -> 1080p HDR->SDR | 3.81x | 4.74x | 4.41x | 10.39x | 3.98x | 4.58x | 4.21x | NVIDIA full GPU (10.39x) |
| clip-03 | 4K -> 720p HDR->SDR | 5.16x | 5.19x | 4.45x | 10.58x | 5.12x | 5.87x | 5.37x | NVIDIA full GPU (10.58x) |
| clip-03 | 4K -> 4K HDR->SDR | 1.41x | 4.72x | 4.13x | 5.61x | 1.58x | 1.61x | 1.54x | NVIDIA full GPU (5.61x) |
| clip-04 | 1080p -> 720p | 9.09x | - | - | 15.83x | 10.36x | - | 11.60x | NVIDIA full GPU (15.83x) |
| clip-04 | 1080p -> 1080p (bitrate only) | 6.37x | - | - | 12.20x | 10.25x | - | 9.85x | NVIDIA full GPU (12.20x) |

* = the run hit the timeout; the value is partial throughput. SKIP / FAIL: the reason is in the table below.

## Every run

<details><summary>Show all runs</summary>

| Clip | Target | Path | Status | fps | x realtime | CPU % | GPU dec/enc/vpp % | Note |
|---|---|---|---|---:|---:|---:|---|---|
| clip-01 | 4K -> 1080p HDR->SDR | CPU only | OK | 94.6 | 3.95 | 77 | 2/0/0 |  |
| clip-01 | 4K -> 1080p HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | OK | 248.7 | 10.37 | 40 | 7/0/0 |  |
| clip-01 | 4K -> 1080p HDR->SDR | CPU decode + NVENC encode | OK | 107.7 | 4.49 | 61 | 2/9/0 |  |
| clip-01 | 4K -> 1080p HDR->SDR | NVDEC decode + CPU tone-map + NVENC | OK | 110.9 | 4.63 | 61 | 18/9/0 |  |
| clip-01 | 4K -> 1080p HDR->SDR | CPU decode + AMD AMF encode | OK | 108.1 | 4.51 | 68 | 2/0/0 |  |
| clip-01 | 4K -> 1080p HDR->SDR | OpenCL GPU tone-map | OK | 125.5 | 5.23 | 65 | 2/0/0 |  |
| clip-01 | 4K -> 1080p HDR->SDR | libplacebo (Vulkan) GPU tone-map | OK | 115.3 | 4.81 | 51 | 2/0/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | CPU only | OK | 144.1 | 6.01 | 28 | 3/0/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | OK | 255.7 | 10.66 | 31 | 14/1/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | CPU decode + NVENC encode | OK | 139.3 | 5.81 | 43 | 3/1/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | NVDEC decode + CPU tone-map + NVENC | OK | 142.3 | 5.93 | 21 | 23/3/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | CPU decode + AMD AMF encode | OK | 147.6 | 6.15 | 25 | 3/0/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | OpenCL GPU tone-map | OK | 138.7 | 5.79 | 25 | 2/0/0 |  |
| clip-01 | 4K -> 720p HDR->SDR | libplacebo (Vulkan) GPU tone-map | OK | 113.8 | 4.75 | 53 | 3/0/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | CPU only | OK | 35.4 | 1.48 | 74 | 4/0/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | OK | 132.6 | 5.53 | 34 | 4/0/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | CPU decode + NVENC encode | OK | 39.0 | 1.63 | 80 | 3/14/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | NVDEC decode + CPU tone-map + NVENC | OK | 37.5 | 1.56 | 65 | 10/15/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | CPU decode + AMD AMF encode | OK | 36.8 | 1.53 | 76 | 5/0/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | OpenCL GPU tone-map | OK | 122.6 | 5.11 | 48 | 2/0/0 |  |
| clip-01 | 4K -> 4K HDR->SDR | libplacebo (Vulkan) GPU tone-map | OK | 99.2 | 4.13 | 49 | 2/51/0 |  |
| clip-02 | 1080p -> 720p | CPU only | OK | 274.4 | 11.44 | 51 | 3/0/0 |  |
| clip-02 | 1080p -> 720p | NVIDIA all on GPU (NVDEC + NVENC) | OK | 290.2 | 12.10 | 31 | 19/16/0 |  |
| clip-02 | 1080p -> 720p | CPU decode + NVENC encode | OK | 364.5 | 15.20 | 31 | 2/29/0 |  |
| clip-02 | 1080p -> 720p | CPU decode + AMD AMF encode | OK | 395.9 | 16.51 | 35 | 2/0/0 |  |
| clip-02 | 1080p -> 1080p (bitrate only) | CPU only | OK | 170.4 | 7.11 | 60 | 3/0/0 |  |
| clip-02 | 1080p -> 1080p (bitrate only) | NVIDIA all on GPU (NVDEC + NVENC) | OK | 284.0 | 11.84 | 24 | 20/34/0 |  |
| clip-02 | 1080p -> 1080p (bitrate only) | CPU decode + NVENC encode | OK | 276.6 | 11.54 | 28 | 2/34/0 |  |
| clip-02 | 1080p -> 1080p (bitrate only) | CPU decode + AMD AMF encode | OK | 254.0 | 10.59 | 27 | 3/0/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | CPU only | OK | 91.3 | 3.81 | 66 | 3/0/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | OK | 249.2 | 10.39 | 22 | 24/5/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | CPU decode + NVENC encode | OK | 95.4 | 3.98 | 63 | 3/9/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | NVDEC decode + CPU tone-map + NVENC | OK | 109.8 | 4.58 | 58 | 24/9/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | CPU decode + AMD AMF encode | OK | 100.9 | 4.21 | 66 | 3/0/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | OpenCL GPU tone-map | OK | 113.7 | 4.74 | 68 | 3/0/0 |  |
| clip-03 | 4K -> 1080p HDR->SDR | libplacebo (Vulkan) GPU tone-map | OK | 105.8 | 4.41 | 59 | 2/5/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | CPU only | OK | 123.6 | 5.16 | 63 | 3/0/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | OK | 253.7 | 10.58 | 24 | 25/3/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | CPU decode + NVENC encode | OK | 122.8 | 5.12 | 67 | 3/0/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | NVDEC decode + CPU tone-map + NVENC | OK | 140.8 | 5.87 | 30 | 28/3/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | CPU decode + AMD AMF encode | OK | 128.8 | 5.37 | 62 | 3/0/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | OpenCL GPU tone-map | OK | 124.4 | 5.19 | 56 | 3/0/0 |  |
| clip-03 | 4K -> 720p HDR->SDR | libplacebo (Vulkan) GPU tone-map | OK | 106.8 | 4.45 | 59 | 3/0/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | CPU only | OK | 33.7 | 1.41 | 86 | 3/0/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | NVIDIA all on GPU (NVDEC + NVENC) | OK | 134.5 | 5.61 | 46 | 15/5/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | CPU decode + NVENC encode | OK | 37.8 | 1.58 | 77 | 3/15/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | NVDEC decode + CPU tone-map + NVENC | OK | 38.5 | 1.61 | 78 | 14/15/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | CPU decode + AMD AMF encode | OK | 36.9 | 1.54 | 81 | 4/0/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | OpenCL GPU tone-map | OK | 113.3 | 4.72 | 64 | 3/0/0 |  |
| clip-03 | 4K -> 4K HDR->SDR | libplacebo (Vulkan) GPU tone-map | OK | 99.1 | 4.13 | 61 | 3/50/0 |  |
| clip-04 | 1080p -> 720p | CPU only | OK | 218.0 | 9.09 | 45 | 3/0/0 |  |
| clip-04 | 1080p -> 720p | NVIDIA all on GPU (NVDEC + NVENC) | OK | 379.6 | 15.83 | 35 | 51/33/0 |  |
| clip-04 | 1080p -> 720p | CPU decode + NVENC encode | OK | 248.4 | 10.36 | 22 | 2/13/0 |  |
| clip-04 | 1080p -> 720p | CPU decode + AMD AMF encode | OK | 278.1 | 11.60 | 17 | 2/0/0 |  |
| clip-04 | 1080p -> 1080p (bitrate only) | CPU only | OK | 152.8 | 6.37 | 42 | 3/0/0 |  |
| clip-04 | 1080p -> 1080p (bitrate only) | NVIDIA all on GPU (NVDEC + NVENC) | OK | 292.5 | 12.20 | 22 | 30/40/0 |  |
| clip-04 | 1080p -> 1080p (bitrate only) | CPU decode + NVENC encode | OK | 245.7 | 10.25 | 20 | 2/26/0 |  |
| clip-04 | 1080p -> 1080p (bitrate only) | CPU decode + AMD AMF encode | OK | 236.3 | 9.85 | 22 | 3/0/0 |  |

</details>

## Notes

- Only the **video** stream is transcoded; audio is ignored. Output is H.264 at 20 / 8 / 4 / 2 Mbps for 4K / 1080p / 720p / SD.
- HDR sources (HDR10, HLG, Dolby Vision) are tone-mapped to SDR. 'CPU tone-map' uses zscale + hable; the GPU variants use QuickSync VPP, tonemap_cuda, OpenCL or libplacebo.
- Every run includes process start-up. OpenCL and libplacebo compile their kernels on each start, so they are slightly understated on short clips. The first run of each GPU path is preceded by a 2 s warm-up.
- GPU dec/enc/vpp % are Windows GPU engine counters summed over all adapters; they read 0 when the counters are unavailable.
- Raw ffmpeg output of every run is in the logs folder next to this report. It contains the clip file names and paths: delete it before sharing results publicly (this report itself uses anonymised clip names).
