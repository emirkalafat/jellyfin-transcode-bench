# Linux, containers and Bazzite

The bash scripts (`linux/media-test.sh`, `linux/synthetic-test.sh`) measure up to four engines in one run: CPU, VAAPI (Intel and AMD, one engine per render node), Intel QuickSync and NVIDIA. Run them with `bash` (files on an SMB share usually have no exec bit):

```bash
bash linux/synthetic-test.sh --quick
bash linux/media-test.sh --quick
bash linux/media-test.sh --help          # all options
```

## What happens before any test

1. **GPU inventory.** Every render node (Intel / AMD / NVIDIA) is listed with its PCI name. GPUs that exist on the PCI bus but are *not usable from here* are reported separately; in a container this is the typical sign that a GPU was not passed in (e.g. "NVIDIA GPU on PCI bus but NOT usable here").
2. **Every hardware path is probed** with a one-second ffmpeg run, per GPU: VAAPI (rate-control quirks such as `-low_power 1` on Gen11+ Intel, or CQP-only drivers, are detected automatically), QSV, NVENC with the CUDA path, OpenCL and libplacebo tone-mapping.
3. Engines whose GPU does not exist produce no rows. Engines that exist but fail are listed with the exact reason under "System and hardware engines" in the report, and their tests are skipped with that reason.

## Packages

| Hardware | Debian / Ubuntu host |
|---|---|
| Intel Haswell / HD 4400 and older (VAAPI through i965) | `sudo apt install -y vainfo i965-va-driver intel-gpu-tools` |
| Intel Broadwell and newer (iHD, also needed for QSV) | `sudo apt install -y vainfo intel-media-va-driver libvpl2 libmfx-gen1.2 intel-gpu-tools` |
| AMD | `sudo apt install -y vainfo mesa-va-drivers` |
| NVIDIA | the proprietary driver |

Plus ffmpeg: run `bash tools/get-ffmpeg.sh` (recommended: jellyfin-ffmpeg, it has VAAPI, QSV, NVENC, OpenCL, libplacebo and `tonemap_cuda` compiled in), or install the `jellyfin-ffmpeg` package, which the scripts pick up from `/usr/lib/jellyfin-ffmpeg/`.

## Permissions and driver checks

```bash
sudo usermod -aG render,video $USER      # then log out and in again
ls -l /dev/dri                           # renderD128 (and renderD129 on dual-GPU machines) must exist
vainfo --display drm --device /dev/dri/renderD128
```

- Haswell: if `vainfo` picks the wrong driver, add `--libva-driver i965`.
- Restrict a run to one VAAPI GPU: `--device /dev/dri/renderD129`.
- Intel GPU engine load (the `vcs/vecs/rcs` columns) needs `intel_gpu_top` and root: `sudo bash linux/media-test.sh`. NVIDIA / AMD load is not collected; watch `nvidia-smi dmon` or `radeontop` next to the run.

## Running from a network share

```bash
sudo mount -t cifs //nas/share /mnt/nas -o username=<user>,uid=$(id -u)
cd /mnt/nas/jellyfin-transcode-bench && bash linux/media-test.sh
```

`media-test.sh` copies the clips from network filesystems (NFS / CIFS / SMB) to local disk first so network speed is not measured (`--no-local-copy` disables that). Temporary files go to `$TMPDIR` or `/tmp` and are removed afterwards (`--keep-work` keeps them).

## Podman / Docker (Bazzite, Fedora Atomic, Silverblue, ...)

Immutable distributions have no `apt`; use the container image from `container/Containerfile` (Ubuntu 24.04 with the Intel i965 + iHD VAAPI drivers, the oneVPL runtime for QSV, the Mesa driver for AMD and the Intel OpenCL runtime). Build it once, without a build context so the media folder is not sent to the builder:

```bash
podman build -t jellyfin-transcode-bench - < container/Containerfile
```

Intel and/or AMD GPU:

```bash
podman run --rm -it --device /dev/dri --group-add keep-groups --security-opt label=disable \
    -v "$PWD":/work jellyfin-transcode-bench bash linux/media-test.sh --quick
```

NVIDIA GPU (needs the NVIDIA container toolkit; it is preinstalled on the Bazzite NVIDIA images). The driver libraries are injected by CDI, they are not part of the image:

```bash
nvidia-ctk cdi list                      # should list nvidia.com/gpu=all
podman run --rm -it --device /dev/dri --device nvidia.com/gpu=all --group-add keep-groups \
    --security-opt label=disable -v "$PWD":/work jellyfin-transcode-bench bash linux/media-test.sh --quick
```

- `--security-opt label=disable` keeps SELinux from blocking `/dev/dri`; `--group-add keep-groups` passes your `render` / `video` groups into the container (rootless podman with crun).
- On **hybrid laptops** (Intel iGPU + NVIDIA dGPU) pass both devices as above: the inventory shows both and every engine is measured separately.
- The Ubuntu `ffmpeg` in the image has NVENC and `scale_cuda` but no `tonemap_cuda`. `tools/get-ffmpeg.sh` puts jellyfin-ffmpeg in `ffmpeg-jellyfin/linux/` (inside the mounted folder), and the scripts then use it automatically.

## Troubleshooting

| Symptom (in `report.md`) | Likely cause and fix |
|---|---|
| `Driver does not support any RC mode compatible with selected options (supported modes: CQP)` | Gen11+ Intel needs `-low_power 1` for H.264 encode. The probe detects this on its own; if you still see it, check `logs/sys_vaapi_*`. |
| `Error creating a MFX session: -9` | No oneVPL runtime or no iHD driver: install `libvpl2` and `libmfx-gen1.2` (QSV needs Gen8+; Haswell is VAAPI-only). |
| `on PCI bus but NOT usable here` | The GPU was not passed into the container / session. See the podman section. |
| OpenCL tone-map skipped, "no usable OpenCL device" | No OpenCL runtime for that GPU (`intel-opencl-icd`, NVIDIA driver, `rocm-opencl`). The scripts try `opencl=ocl`, `ocl:0.0`, `ocl:1.0`, ... automatically. |
| `tonemap_cuda missing` | Only jellyfin-ffmpeg has it: run `bash tools/get-ffmpeg.sh`. `plc` and `cl` do GPU tone-mapping without it. |
| `Cannot allocate memory` on the VAAPI full path | Seen on a container with an Intel Tiger Lake GPU; the probe now retries with an explicit device and `-extra_hw_frames`. If it persists, open an issue with `logs/sys_vaapi_*`. |
