# jellyfin-transcode-bench

**Jellyfin sunucunuzun gerçekte neyi transcode edebildiğini, kullanıcılarınız fark etmeden önce öğrenin.**

[jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg) (bir Jellyfin sunucusunun kullandığı ffmpeg) ile gerçek 4K / HDR10 / Dolby Vision / HEVC / AV1 kliplerini dönüştüren bir test paketi. Her kaynak türü ve hedef için (4K→1080p, 1080p HDR→SDR, ...) donanımınızın gerçek zamanın kaç katı hızla çalıştığını, CPU'ya ne kadar yük bindirdiğini ve aynı anda kaç akışı kaldırdığını gösterir.

Makinedeki her motoru yan yana karşılaştırır:

| Motor | Donanım | Kullanılan yol |
|---|---|---|
| CPU | herhangi | libx264 / libx265, `zscale` + `tonemap` |
| Intel QuickSync | iGPU (Arc: denenmedi) | `h264_qsv`, `vpp_qsv` |
| VAAPI | Intel ve AMD (Linux) | `h264_vaapi`, `scale_vaapi`, `tonemap_vaapi` |
| NVIDIA | GeForce / Quadro / Tesla | NVDEC, `scale_cuda`, `tonemap_cuda`, NVENC |
| AMD AMF | Radeon (Windows) | `h264_amf` |
| GPU tone-map | OpenCL / Vulkan destekli her GPU | `tonemap_opencl`, `libplacebo` |

Testlerden **önce** her şey yoklanır: tüm ekran kartları listelenir, her donanım yolu bir saniyelik bir çalıştırmayla denenir. Çalışamayan motorlar yarıda patlamak yerine, nedeni raporda yazılı olarak atlanır.

> Jellyfin projesiyle bağlantılı değildir. "Jellyfin", sonuçların hangi sunucu için anlamlı olduğunu söylemek için kullanılır.

## Neden teknik özellik tablosuna bakmak yetmez?

Donanımın transcode yeteneği, özellik tablosunda yazmayan şeylere bağlıdır: sürücünüz motoru açıyor mu, ffmpeg'inizde doğru filtre var mı, HDR tone-map GPU'da mı yoksa sessizce CPU'da mı çalışıyor, 40 Mbps 4K HEVC'de ne oluyor. Gerçek makinelerde bulunanlardan örnekler:

| Makine | Klip → hedef | CPU | En iyi yol | Paralel akış |
|---|---|---:|---|---:|
| Intel i3-4150 / HD 4400 | H.264 1080p → 720p | 2,0x | QuickSync 10,7x | 4+ |
| Intel i3-4150 / HD 4400 | HEVC 4K HDR10 → 1080p SDR | 0,7x | CPU + QSV encode 0,9x (donanımda HEVC decode yok) | 0 |
| Ryzen 7800X3D + RTX 5070 Ti | HEVC 4K Dolby Vision (P8) → 4K SDR | 1,4x | NVDEC + `tonemap_cuda` + NVENC 5,1x | - |

(`x` = gerçek zamanın katı; 1,0x tam gerçek zaman demektir.)

## Hızlı başlangıç

### 1. ffmpeg'i alın

Test paketi `ffmpeg-jellyfin/` içindeki **jellyfin-ffmpeg** taşınabilir sürümünü tercih eder: bir Jellyfin sunucusunun çalıştırdığı budur ve `tonemap_cuda` içeren tek derlemedir. Yardımcı araç en güncel sürümü indirir ve SHA256 özetini doğrular:

```powershell
# Windows
.\tools\get-ffmpeg.ps1
```
```bash
# Linux
bash tools/get-ffmpeg.sh
```

(`PATH`'teki başka bir ffmpeg de çalışır ama bazı GPU yolları atlanır. Linux'ta kurulu `jellyfin-ffmpeg` paketi `/usr/lib/jellyfin-ffmpeg/` altında otomatik bulunur.)

### 2. Test kliplerini hazırlayın

İlgilendiğiniz formatlarda kısa kliplere ihtiyaç var. İki yol, ayrıntılar **[docs/media-clips.tr.md](docs/media-clips.tr.md)** içinde:

```powershell
# a) Jellyfin'in resmi test videoları (kişisel medya gerekmez, ~1,1 GB, SHA256 doğrulamalı)
.\tools\get-test-videos.ps1 -Set starter

# b) kendi kütüphanenizden klip çıkarma (yeniden encode yok, yalnızca video akışı)
.\windows\make-clips.ps1 -Source "D:\Filmler","D:\Diziler"
```

### 3. Çalıştırın

```powershell
# Windows: .\media içindeki her şey üzerinde gerçek içerik testi (windows\run-media.bat'a çift tıklamak da olur)
.\windows\media-test.ps1 -Quick           # kısa ilk deneme
.\windows\media-test.ps1                  # tam çalıştırma
.\windows\synthetic-test.ps1              # sentetik kaynaklar: ham decode/encode/transcode hızı + paralel akış
```
```bash
# Linux
bash linux/media-test.sh --quick
bash linux/media-test.sh
bash linux/synthetic-test.sh
```

Faydalı seçenekler:

```powershell
.\windows\media-test.ps1 -Filter "*hdr*" -Variants cpu,nv,plc,cl     # yalnızca HDR klipleri, seçili motorlar
.\windows\media-test.ps1 -Scenarios to1080,same -NoConcurrency        # 720p'yi ve paralel akış testini atla
```
```bash
bash linux/media-test.sh --filter '*hdr*' --variants "cpu vaapi nv plc"
bash linux/media-test.sh --device /dev/dri/renderD129                 # yalnızca belirli bir GPU'yu test et
```

### 4. Raporu okuyun

Sonuçlar `results/<tür>_<makine>_<zaman>/` altına yazılır: `report.md` (okunabilir rapor), `results.json` / `results.tsv` (veri) ve `logs/` (her çalıştırmanın ham ffmpeg çıktısı, her FAIL satırının nedenini görebilmek için).

## Ne ölçülüyor?

Her klip için, ona uygun senaryolar seçilir:

| Senaryo | Ne yapar |
|---|---|
| `to1080` | 1920x1080 içine sığdır (4K kaynaklar) |
| `to720` | 1280x720 içine sığdır (4K ve 1080p kaynaklar) |
| `same` | çözünürlüğü koru (yalnızca bitrate düşürme; ya da kendi çözünürlüğünde HDR → SDR) |

HDR kaynaklar (HDR10, HLG, Dolby Vision) SDR'a tone-map edilir. Çıktı, tipik bir Jellyfin transcode'u gibi H.264'tür: 4K / 1080p / 720p / SD için 20 / 8 / 4 / 2 Mbps.

Her senaryo birkaç **varyanttan** geçer. Makinede çalışamayan varyant nedeniyle birlikte atlanır:

| Windows | Linux | Anlamı |
|---|---|---|
| `cpu` | `cpu` | yazılımda decode, filtre ve libx264 |
| `hw` | `qsv`, `vaapi-<gpu>` | tam donanım: donanım decode + donanım ölçekleme/tone-map + donanım encode (QuickSync / VAAPI) |
| `nv` | `nv` | NVDEC + `scale_cuda` + `tonemap_cuda` + NVENC |
| `hyb`, `hybn`, `hyba` | `hybq`, `hybv-<gpu>`, `hybn` | CPU decode ve filtre, donanım **encode** (QSV / NVENC / AMF / VAAPI) |
| `nvd` | `nvd`, `vad-<gpu>` | donanım decode, **CPU** tone-map, donanım encode (yalnızca HDR) |
| `cl` | `cl` | CPU decode, **OpenCL** tone-map, encode |
| `plc` | `plc` | CPU decode, **libplacebo (Vulkan)** tone-map ve ölçekleme, encode; Dolby Vision profil 5'i de doğru işler |

Matristen sonra, her kaynak sınıfının en iyi CPU dışı varyantı **N kez paralel** çalıştırılır ve kaç eşzamanlı akışın gerçek zamanda kaldığı bulunur.

### Sayıları okumak

- **x realtime** = verim / kaynak kare hızı. `1,0x` tam bir izleyiciyi yetiştirir; `4,0x` makine başka işle meşgul değilse kabaca dört eşzamanlı transcode demektir.
- **CPU %** çalıştırma boyunca makinenin ortalama CPU yüküdür. CPU'yu yine de zorlayan bir GPU yolu yarım kazançtır.
- **GPU vcs/vecs/rcs** (Linux, Intel, `intel_gpu_top` ve root gerekir) veya **GPU dec/enc/vpp** (Windows sayaçları) hangi motorun darboğaz olduğunu gösterir. NVIDIA/AMD yükü toplanmaz; yanında `nvidia-smi dmon` veya `radeontop` izleyin.
- `*` işaretli değer süre aşımına uğramıştır; kısmi verimdir.

### Bilinmesi gerekenler

- Yalnızca **video** akışı dönüştürülür, ses yok sayılır (videoya kıyasla ucuzdur).
- Her çalıştırma işlemin başlangıç süresini de içerir. OpenCL ve libplacebo her başlangıçta kernel derler, bu yüzden *çok* kısa klipler bunları olduğundan yavaş gösterir; varsayılan klip süresi 30 sn'dir. Her GPU varyantının ilk çalıştırmasından önce 2 saniyelik bir ısınma yapılır, böylece tek seferlik maliyetler (CUDA JIT, sürücü başlatma) sayılmaz.
- Dolby Vision profil 5'in HDR10 uyumlu bir tabanı yoktur ve `zscale` ile tone-map edilemez; `plc` varyantı dışında tone-map **uygulanmadan** ölçülür. Profil 8, HDR10 gibi ele alınır.
- Interlaced kaynaklar deinterlace edilmez.
- Gerçek sonuçlar bitrate'e ve içeriğe bağlıdır. Hareketli sahneler önemlidir: durağan bir başlık ekranı gerçekçi olmayan biçimde hızlı encode edilir.

## Depo yapısı

```
jellyfin-transcode-bench/
├─ windows/            PowerShell betikleri (+ .bat başlatıcılar)
│  ├─ media-test.ps1       gerçek içerik testi
│  ├─ synthetic-test.ps1   sentetik test + paralel akış
│  └─ make-clips.ps1       kütüphanenizden test klibi çıkarma
├─ linux/              aynıları bash ile (ortak kod lib-common.sh içinde)
├─ tools/              get-ffmpeg.*  ve  get-test-videos.*
├─ container/          podman / Docker için Containerfile (Bazzite, Fedora Atomic, ...)
├─ docs/               media-clips.md, linux-and-podman.md (+ Türkçe)
├─ media/              KLİPLERİNİZ buraya gelir (git'e eklenmez)
└─ results/            raporlar (git'e eklenmez)
```

## Gereksinimler

- **Windows:** Windows PowerShell 5.1+ (hazır gelir) veya PowerShell 7. Test etmek istediğiniz motorlar için güncel GPU sürücüleri.
- **Linux:** bash 4+, GNU awk ve coreutils; VAAPI için Mesa / intel-media / i965 sürücüsü, NVIDIA için özel sürücü (kapsayıcıda NVIDIA container toolkit). Bazzite / podman dahil [docs/linux-and-podman.md](docs/linux-and-podman.md) dosyasına bakın (İngilizce).
- Üretilen kaynaklar için geçici klasörde birkaç GB boş alan; starter klip setini indirirseniz ayrıca yaklaşık 1-1,5 GB.

## Durum

Şunlarda geliştirildi ve denendi: Intel Haswell iGPU (HD Graphics 4400, Windows), Radeon iGPU ve RTX 5070 Ti'lı Ryzen 7 7800X3D (Windows, ayrıca bash betikleri WSL üzerinden) ve Intel Tiger Lake + RTX 3060'lı bir dizüstü (Linux kapsayıcısı, ilk sürüm). Linux VAAPI ve QSV yolları en az sahada denenen kısımlardır: donanımınızda bir yoklama ya da varyant başarısız olursa, çalıştırmanın `logs/` klasörüyle birlikte bir issue açın.

## Katkı

Issue ve pull request'ler memnuniyetle karşılanır; özellikle henüz kapsanmayan donanımlar için sonuçlar ve düzeltmeler (Intel Arc, yeni Radeon'lar, Jetson, ...). Mümkün olduğunca iki platformu birlikte güncel tutun. Medya kliplerini ya da sonuç klasörlerini asla commit etmeyin.

## Lisans

[MIT](LICENSE). `tools/get-test-videos.*` tarafından kullanılan Jellyfin test videoları Jellyfin projesi tarafından, Gnattu'nun katkısıyla, CC BY-SA 4.0 altında sağlanır; indirilir, burada yeniden dağıtılmaz. jellyfin-ffmpeg GPL'dir ve kendi sürüm sayfasından indirilir.

English: [README.md](README.md)
