# Preparing test clips

The real-content benchmark (`media-test.ps1` / `media-test.sh`) transcodes short clips from the **`media/`** folder at the repository root. This guide shows how to fill it. The clips are never committed: `media/` is git-ignored.

**Which clips do you need?** One or two short clips (30-60 s) per class you care about. The suite classifies every file by what is really inside it, as `<codec>-<resolution>-<dynamic range>`:

| Class | Typical question it answers |
|---|---|
| `h264-1080p-sdr` | the everyday case: can the server serve N 1080p H.264 viewers? |
| `h264-4k-sdr` | 4K H.264 SDR |
| `hevc-1080p-sdr` | 1080p HEVC (8 or 10 bit), HW decode support |
| `hevc-1080p-hdr10` | 1080p HDR → SDR (tone-mapping) |
| `hevc-4k-sdr` | 4K HEVC SDR → 1080p / 720p |
| `hevc-4k-hdr10` | 4K HDR10 → SDR (the hard one) |
| `hevc-4k-hlg` | 4K HLG |
| `dv-p5`, `dv-p8` (folder `dolby-vision`) | Dolby Vision profile 5 / 8 |
| `av1-*`, `mpeg2-*`, `vc1-*`, `*-sd-*` | everything else, collected in `other` |

Classification rules: resolution is `4k` if width ≥ 3000 or height ≥ 2000, `1080p` if width ≥ 1800 or height ≥ 1000, `720p` if width ≥ 1200 or height ≥ 680, otherwise `sd`. Dynamic range is `hdr10` (PQ), `hlg`, `dv-pN` (Dolby Vision profile N) or `sdr`. The folder a file lives in is only for your own tidiness: a file in the wrong folder is still classified correctly. Files and folders whose name starts with `_` are ignored.

Pick clips with **real motion** (an action scene, not a title card or black screen): static scenes encode unrealistically fast and make every engine look better than it is.

## Option A: the official Jellyfin test videos (no personal media needed)

The Jellyfin project publishes test videos at <https://repo.jellyfin.org/test-videos/> (courtesy of Gnattu, CC BY-SA 4.0): SDR AVC / HEVC 8-bit / HEVC 10-bit / AV1, HDR10 HEVC / AV1, Dolby Vision P5 / P8.1 / P8.4, from 1080p to 8K, at many bitrates. They are the easiest way to get a reproducible, shareable set.

```powershell
# Windows
.\tools\get-test-videos.ps1 -Set mini -DryRun      # list what would be downloaded (7 files, ~270 MB), download nothing
.\tools\get-test-videos.ps1 -Set mini              # 1080p only
.\tools\get-test-videos.ps1 -Set starter           # + 4K: 13 files, ~1.1 GB
```
```bash
# Linux
bash tools/get-test-videos.sh --set mini --dry-run
bash tools/get-test-videos.sh --set starter
```

Every file is verified against the `.sha256sum` published next to it and put in the matching `media/<class>/` folder. Want other files (8K, higher bitrates, DV P8.4)? Download them by hand from the page above into any folder under `media/`.

## Option B: clips cut from your own library

`make-clips` scans your media folders recursively, probes each file, and cuts a short clip **without re-encoding** (stream copy of the first video stream only; audio, subtitles and data are dropped). HDR and Dolby Vision data stay intact. Files named like `sample`, `trailer` or `featurette` are skipped. Clips go to the right `media/<class>/` folder automatically, at most 2 per class by default, so a USB stick or the repo folder does not fill up.

```powershell
# Windows: one or several source folders (each is scanned recursively)
.\windows\make-clips.ps1 -Source "D:\Movies"
.\windows\make-clips.ps1 -Source "D:\Movies","E:\TV"
.\windows\make-clips.ps1 -Source "\\nas\media\movies" -DryRun          # only list what would be cut
.\windows\make-clips.ps1 -Source "D:\Movies" -Seconds 60 -Start 900 -PerClass 3
.\windows\make-clips.ps1 -Source "D:\Movies" -Exhaustive -Seed 7      # scan everything, repeatable random pick
```

```bash
# Linux:  make-clips.sh <source_dir> [out_dir] [seconds] [start] [per_class]
bash linux/make-clips.sh /srv/media/movies
bash linux/make-clips.sh /srv/media/tv "$PWD/media" 60 900 3
```

What it does for you (the Windows script does all of this; the bash version is simpler: one source folder, no shuffle, no early stop, no `sample`/`trailer` filter):

- **Shuffles** the files so clips come from all over the library, not only from the first folder alphabetically (`-NoShuffle` to disable, `-Seed N` for a repeatable pick).
- **Stops early** once all seven common classes have enough clips (`-Exhaustive` scans everything, `-MaxProbe N` caps the scan). Big libraries on a network share take minutes to scan; only file headers and the 45 s you cut are read.
- Starts the clip 10 minutes into a file (`-Start`, seconds), or 25 % in for short files, so you do not get the opening logos.
- Prints at the end which classes it could **not** find, so you know what your library lacks.

Run it where the media is (the media server, or a PC that can reach it), then copy the resulting `media/` folder to the machine you are benchmarking.

## Option C: by hand with ffmpeg

The same thing, one clip at a time:

```bash
# 45 s starting 10 minutes in, video stream only, no re-encode
ffmpeg -ss 00:10:00 -t 45 -i "Some Movie (2023) 2160p HDR.mkv" -map 0:v:0 -c:v copy -an -sn -dn media/hevc-4k-hdr10/some-movie-clip.mkv
```

Notes:

- Put `-ss` **before** `-i` (fast seek). A stream copy can only start on a keyframe, so the clip may begin up to a few seconds early; that is fine.
- Write the clip as **`.mkv`**: it carries HDR metadata and Dolby Vision configuration reliably, `.mp4` may drop the Dolby Vision record.
- Check what a clip contains with `ffmpeg -hide_banner -i clip.mkv`, or run the benchmark on it alone: `.\windows\media-test.ps1 -Filter "*some-movie*" -Quick`.

## Layout example

```
media/
├─ h264-1080p-sdr/    Test Jellyfin 1080p AVC 10M.mp4
├─ hevc-1080p-hdr10/  Test Jellyfin 1080p HEVC HDR10 10M.mp4
├─ hevc-4k-hdr10/     Test Jellyfin 4K HEVC HDR10 40M.mp4   some-movie-clip.mkv
├─ dolby-vision/      Test Jellyfin 4K DV P5.mp4   Test Jellyfin 4K DV P8.1.mp4
└─ other/             Test Jellyfin 1080p AV1 10bit 10M.mp4
```

## Please keep in mind

- Only use media you are allowed to use, and never commit or share clips of copyrighted films or shows. The repository's `.gitignore` keeps `media/` out of Git for exactly this reason; do not force-add files from it.
- Result folders contain the file names of the clips (in `report.md`, `results.tsv` and `logs/`). Before sharing a result, check that you are fine with those names being public, or use the Jellyfin test videos, whose names are neutral.
