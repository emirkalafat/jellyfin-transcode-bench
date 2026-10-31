# Test kliplerini hazırlama

Gerçek içerik testi (`media-test.ps1` / `media-test.sh`), deponun kökündeki **`media/`** klasöründeki kısa klipleri dönüştürür. Bu rehber o klasörü nasıl dolduracağınızı anlatır. Klipler asla commit edilmez: `media/` git tarafından yok sayılır.

**Hangi kliplere ihtiyaç var?** İlgilendiğiniz her sınıf için bir ya da iki kısa klip (30-60 sn). Paket her dosyayı gerçekte içinde ne olduğuna göre `<codec>-<çözünürlük>-<dinamik aralık>` olarak sınıflandırır:

| Sınıf | Hangi soruyu yanıtlar |
|---|---|
| `h264-1080p-sdr` | gündelik durum: sunucu N tane 1080p H.264 izleyiciyi karşılar mı? |
| `h264-4k-sdr` | 4K H.264 SDR |
| `hevc-1080p-sdr` | 1080p HEVC (8 veya 10 bit), donanım decode desteği |
| `hevc-1080p-hdr10` | 1080p HDR → SDR (tone-map) |
| `hevc-4k-sdr` | 4K HEVC SDR → 1080p / 720p |
| `hevc-4k-hdr10` | 4K HDR10 → SDR (en zoru) |
| `hevc-4k-hlg` | 4K HLG |
| `dv-p5`, `dv-p8` (klasör `dolby-vision`) | Dolby Vision profil 5 / 8 |
| `av1-*`, `mpeg2-*`, `vc1-*`, `*-sd-*` | geri kalan her şey, `other` klasöründe toplanır |

Sınıflandırma kuralları: genişlik ≥ 3000 veya yükseklik ≥ 2000 ise çözünürlük `4k`; genişlik ≥ 1800 veya yükseklik ≥ 1000 ise `1080p`; genişlik ≥ 1200 veya yükseklik ≥ 680 ise `720p`; aksi halde `sd`. Dinamik aralık `hdr10` (PQ), `hlg`, `dv-pN` (Dolby Vision profil N) ya da `sdr` olur. Dosyanın bulunduğu klasör yalnızca sizin düzeniniz içindir: yanlış klasördeki dosya yine doğru sınıflandırılır. Adı `_` ile başlayan dosya ve klasörler yok sayılır.

**Gerçek hareket** içeren klipler seçin (aksiyon sahnesi; başlık ekranı veya siyah ekran değil): durağan sahneler gerçekçi olmayan biçimde hızlı encode edilir ve her motoru olduğundan iyi gösterir.

## A seçeneği: Jellyfin'in resmi test videoları (kişisel medya gerekmez)

Jellyfin projesi <https://repo.jellyfin.org/test-videos/> adresinde test videoları yayınlar (Gnattu'nun katkısıyla, CC BY-SA 4.0): SDR AVC / HEVC 8-bit / HEVC 10-bit / AV1, HDR10 HEVC / AV1, Dolby Vision P5 / P8.1 / P8.4; 1080p'den 8K'ya, birçok bitrate'te. Tekrarlanabilir ve paylaşılabilir bir set için en kolay yoldur.

```powershell
# Windows
.\tools\get-test-videos.ps1 -Set mini -DryRun      # indirilecekleri listele (7 dosya, ~270 MB), hiçbir şey indirme
.\tools\get-test-videos.ps1 -Set mini              # yalnızca 1080p
.\tools\get-test-videos.ps1 -Set starter           # + 4K: 13 dosya, ~1,1 GB
```
```bash
# Linux
bash tools/get-test-videos.sh --set mini --dry-run
bash tools/get-test-videos.sh --set starter
```

Her dosya, yanında yayınlanan `.sha256sum` ile doğrulanır ve ilgili `media/<sınıf>/` klasörüne konur. Başka dosyalar (8K, daha yüksek bitrate, DV P8.4) isterseniz yukarıdaki sayfadan elle indirip `media/` altında herhangi bir klasöre koyabilirsiniz.

## B seçeneği: kendi kütüphanenizden klip çıkarma

`make-clips`, medya klasörlerinizi alt klasörleriyle birlikte tarar, her dosyayı inceler ve **yeniden encode etmeden** kısa bir klip keser (yalnızca ilk video akışının kopyası; ses, altyazı ve veri akışları atılır). HDR ve Dolby Vision verisi korunur. Adı `sample`, `trailer` veya `featurette` gibi olan dosyalar atlanır. Klipler otomatik olarak doğru `media/<sınıf>/` klasörüne gider; varsayılan olarak sınıf başına en fazla 2 tane, böylece USB bellek ya da depo klasörü dolmaz.

```powershell
# Windows: bir ya da birkaç kaynak klasör (her biri alt klasörleriyle taranır)
.\windows\make-clips.ps1 -Source "D:\Filmler"
.\windows\make-clips.ps1 -Source "D:\Filmler","E:\Diziler"
.\windows\make-clips.ps1 -Source "\\nas\medya\filmler" -DryRun         # yalnızca neyin kesileceğini listele
.\windows\make-clips.ps1 -Source "D:\Filmler" -Seconds 60 -Start 900 -PerClass 3
.\windows\make-clips.ps1 -Source "D:\Filmler" -Exhaustive -Seed 7     # her şeyi tara, tekrarlanabilir rastgele seçim
```

```bash
# Linux:  make-clips.sh <kaynak_klasör> [çıkış_klasörü] [saniye] [başlangıç] [sınıf_başına]
bash linux/make-clips.sh /srv/medya/filmler
bash linux/make-clips.sh /srv/medya/diziler "$PWD/media" 60 900 3
```

Sizin için yaptıkları (Windows betiği hepsini yapar; bash sürümü daha basittir: tek kaynak klasör, karıştırma yok, erken durma yok, `sample`/`trailer` filtresi yok):

- Dosyaları **karıştırır**; klipler alfabetik olarak ilk klasörden değil, kütüphanenin her yerinden gelir (`-NoShuffle` kapatır, `-Seed N` tekrarlanabilir seçim yapar).
- Yedi yaygın sınıfın hepsinde yeterli klip olunca **erken durur** (`-Exhaustive` her şeyi tarar, `-MaxProbe N` taramayı sınırlar). Ağ paylaşımındaki büyük kütüphanelerin taranması dakikalar sürer; yalnızca dosya başlıkları ve kestiğiniz 45 sn okunur.
- Klibi dosyanın 10. dakikasından başlatır (`-Start`, saniye), kısa dosyalarda %25'inden; böylece açılış logoları gelmez.
- Sonunda **bulamadığı** sınıfları yazar, böylece kütüphanenizde neyin olmadığını görürsünüz.

Medyanın bulunduğu yerde çalıştırın (medya sunucusu ya da ona erişebilen bir bilgisayar), sonra çıkan `media/` klasörünü test edeceğiniz makineye kopyalayın.

## C seçeneği: ffmpeg ile elle

Aynı iş, tek klip için:

```bash
# 10. dakikadan 45 sn, yalnızca video akışı, yeniden encode yok
ffmpeg -ss 00:10:00 -t 45 -i "Bir Film (2023) 2160p HDR.mkv" -map 0:v:0 -c:v copy -an -sn -dn media/hevc-4k-hdr10/bir-film-klip.mkv
```

Notlar:

- `-ss`'i `-i`'den **önce** yazın (hızlı arama). Akış kopyası yalnızca anahtar karede başlayabilir, yani klip birkaç saniye erken başlayabilir; sorun değil.
- Klibi **`.mkv`** olarak yazın: HDR üst verisini ve Dolby Vision yapılandırmasını güvenilir biçimde taşır, `.mp4` Dolby Vision kaydını düşürebilir.
- Bir klibin içeriğini `ffmpeg -hide_banner -i klip.mkv` ile görün ya da testi yalnızca onun üzerinde çalıştırın: `.\windows\media-test.ps1 -Filter "*bir-film*" -Quick`.

## Düzen örneği

```
media/
├─ h264-1080p-sdr/    Test Jellyfin 1080p AVC 10M.mp4
├─ hevc-1080p-hdr10/  Test Jellyfin 1080p HEVC HDR10 10M.mp4
├─ hevc-4k-hdr10/     Test Jellyfin 4K HEVC HDR10 40M.mp4   bir-film-klip.mkv
├─ dolby-vision/      Test Jellyfin 4K DV P5.mp4   Test Jellyfin 4K DV P8.1.mp4
└─ other/             Test Jellyfin 1080p AV1 10bit 10M.mp4
```

## Lütfen unutmayın

- Yalnızca kullanma hakkınız olan medyayı kullanın; telifli film ya da dizi kliplerini asla commit etmeyin veya paylaşmayın. Deponun `.gitignore` dosyası tam bu yüzden `media/` klasörünü Git dışında tutar; oradaki dosyaları zorla eklemeyin.
- Sonuç klasörleri kliplerin dosya adlarını içerir (`report.md`, `results.tsv` ve `logs/` içinde). Bir sonucu paylaşmadan önce bu adların herkese açık olmasında sakınca olmadığından emin olun, ya da adları nötr olan Jellyfin test videolarını kullanın.
