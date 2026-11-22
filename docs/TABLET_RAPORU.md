# Tablet + PDF raporu

Dal: `tablet-1`. Her adım: saat, sonuç, ölçüm, "Ahmet elle denesin".

## T0: Ortam (22.11.2026)
- Android SDK zaten kurulu (`~/Android/Sdk`, platform 36, build-tools 36.0.0); `flutter doctor` Android için temiz.
- `tool/gece_patch.dart`: debug derleme `.gece` son ekiyle ve "Koçum (deneme)" adıyla çıkar; release `com.kocum.kocum` / "Koçum" kalır. Testli (4 test). `flutter build apk --debug` gerçekten derlendi; `aapt2` ile doğrulandı: `com.kocum.kocum.gece`, "Koçum (deneme)".
- 340 test geçti. `flutter analyze` hata vermiyor (eski bilgi/uyarılar duruyor).
- Not: `flutter build --profile` son ek almaz (Flutter profile'ı kendi kopyalar); kullanılmıyor, derlenmedi.
- **Tablet `unauthorized`:** `adb devices` PADH10005831 için yetki istiyor. Tablete ölçüm yapılamadı.

### Ahmet elle denesin
- Tablette USB hata ayıklama iznini onayla (açılan "bu bilgisayara izin ver" penceresi), sonra `adb devices` "device" göstermeli.
- Sonra `flutter build apk --debug` ve `adb install -r build/app/outputs/flutter-apk/app-debug.apk`; "Koçum (deneme)" gerçek Koçum'un yanında ayrı simge olarak açılmalı.

## Araştırma notları (T1, T3)
- `androidx.ink` 1.0.0 (Apache-2.0, minSdk 24, Kotlin 2.2.20 ister, JNI → R8 kuralı gerekebilir). Hareket tahmini ve ön tampon çizimi içinde.
- Hybrid composition'da dokunuşlar Flutter'a yönlenir; kalem verisi (tarihsel noktalar, eğim) yerel view'e kayıpsız geçmeyebilir → InkSurface yerel view'e dokunuşu kendisi aldıracak şekilde denenecek.
- `perfect_freehand` 2.5.2+1 (MIT) B uygulaması için.
- `pdfrx` 3.1.0 (MIT; PDFium ikilisi derlemede indirilir, SHA-256 doğrulamalı; APK'ya ~+3-6 MB tahmini). Çakışmasız çözülüyor, `sdk ^3.14.0` ister. Uygulamaya PDFium lisans notu eklenecek.

## T1: Kalem gecikmesi prototipi (22.11.2026)
- `InkSurface` arayüzü (`lib/features/ink/domain`), saf Dart domain, kanal sözleşmesi ayrıştırıcısı testli.
- **A (Android yerel):** `androidx.ink` 1.0.0 + MotionEventPredictor, PlatformView `kocum/ink_surface`; yalnız kalem çizer, parmak/avuç çizmez; `tool/ink_patch.dart` ile üretilir (testli, idempotent). Gerçek debug derlemesi geçti (`libink.so` arm64 içinde).
- **B (saf Flutter):** `perfect_freehand` 2.5.2+1 + CustomPainter; biten çizgiler ayrı RepaintBoundary, süren çizgi 96 noktada bir parçaya donuyor (O(n²) yok). Kalem çizer, parmak kaydırır/yakınlaştırır, ters kalem siler.
- Deneme ekranı: Ayarlar → Araçlar → "Kalem denemesi (tablet için)" (yalnız Android). A/B düğmesi, araç, renk, kalınlık, "yalnız kalem".
- İnceleyici ciddi bulgular verdi (avuç/ikinci temas durum makinesi, `recycle`, A/B ölçüm uyumsuzluğu, silgi), hepsi düzeltildi.
- Ölçüm: **tablet yetkisiz, hiç ölçülmedi.** Günlük adları: `KocumInk A giris->vsync`, `KocumInk B giris->vsync`, `KocumInk B giris->raster`. Karşılaştırma için A ile B'nin `giris->vsync` değerlerine bak; A'da ön tampon çizimi ölçülmüyor (Ink doğrudan ekrana yazar, gerçek algı A lehine daha iyi olabilir).
- Seçim: ölçüm olmadığı için şimdilik **Android'de A, diğer platformlarda B** (görev dosyasının kuralı; kanıtsız ama varsayılan).
- Bilinen sınır: A'da parmak kaydırma/yakınlaştırma yok (dokunuşu yerel görünüm alıyor), A'da silgi devre dışı. AndroidView dokunuşu Dart üzerinden yerele sentetik iletiyor; ek gidiş-dönüş gecikmesi olabilir, bu ölçülmeli.

### Ahmet elle denesin (T1)
- Ayarlar → Araçlar → Kalem denemesi. A ve B'yi kalemle çiz: hangisi daha az geriden geliyor? Hızlı daireler/yazı dene.
- Çizerken avucunu ekrana koy: çizgi bozulmamalı, görünüm kaymamalı.
- Parmakla iki parmak yakınlaştır/kaydır (B'de çalışmalı).
- `adb logcat -s KocumInk` çıktısını bana ver.

## T2: Çizgi verisi (22.11.2026)
- `ink_strokes` tablosu (şema 14→15, göç testli 13→15 ve 14→15), nokta ikilisi: delta + zigzag + varint (1000 nokta < 6 bayt/nokta), round-trip ve hata sınırı testli.
- Değişiklik defterine bağlı. Defterin `json_object` BLOB taşıyamadığı hatası bulundu ve düzeltildi (BLOB `hex()` ile yazılıyor); eski tablolar etkilenmedi. Masaüstü birleştirici BLOB'u bayt bayta alıyor (testli).
- Depo: ekle, sayfaya göre oku/izle, yumuşak sil/geri al.
- Dikkat: defterde çizgi başına ~2x yer (hex). Çok çizgi birikirse defter boyutunu izle. `kocum fix` BLOB sütununu düzenleyemez.
- Göç testi gerçek eski dosyayla değil, güncel şemadan taklitle yapıldı.

## T3a: PDF motoru, içe aktarma, kitaplık eşleme (22.11.2026)
- `pdfrx` 3.1.0 (MIT) eklendi; `environment sdk` `^3.14.0`. Geçişli paketlerin lisansı tek tek doğrulandı, GPL yok. Debug APK'da arm64 `libpdfium.so` 6,6 MB (release boyutu ölçülmedi).
- `PdfEngine` arayüzü saf Dart; pdfrx yalnız `data/pdfrx_engine.dart`'ta. Gerçek PDFium Linux'ta çalıştı (aç, boyut, çiz, kutudaki metin, bozuk dosya).
- `pdf_documents` tablosu (şema 16, `id` = sha256 → iki cihazda aynı PDF aynı satır). Dosya senkron edilmez, yalnız satır. İçe aktarma `pdfs/<sha256>.pdf`, tekrar kopyalamaz; kitap önerisi döner, otomatik bağlanmaz.
- `flutter build apk --debug` ve `flutter build linux --debug` geçti. 408 test.
- Doğrulanmadı: döndürülmüş PDF'te metin kutusu koordinatı, 300+ sayfa bellek, release (R8) derlemesi.

### T3a inceleme düzeltmeleri (v9.3.2)
- `sha256` unique yerine `CHECK (id = sha256)`; bozuk satır Çakışmalar'a düşer, senkron takılmaz.
- Yol çıkışı engellendi (64 haneli hex doğrulaması), başlık kırpılır, yarım kalan dosya geri alınır, eşzamanlı içe aktarma tek satır/tek dosya (testli).
- Render üst sınırı 16 MP (aşılırsa hata); piksel BGRA dönüşümsüz taşınır (`PdfRenderedImage.format`).
- Testler gerçekleşti: renkli dikdörtgen (R/B kanalı), `/Rotate 90` sayfada boyut ve kutu metni.
- CI iş akışlarında Flutter 3.50.0 sabitlendi.
- **Açık:** iki cihaz aynı PDF'i ayrı içe aktarırsa kitap bağı/ofset için alan alan birleştirme yok; kaybeden sürüm Çakışmalar ekranından geri alınır.

## T3b: PDF okuyucu + kalem katmanı (v9.4)
- Okuyucu `/pdf/:id`: pdfrx PdfViewer, dikey kaydırma, parmakla yakınlaştırma, küçük resim şeridi, tek satır araç çubuğu (kalem/fosforlu/silgi, renk, kalınlık, geri al/yinele). Kitaplık `/pdf` (içe aktar, liste, kitap önerisi onayı, onaylı yumuşak silme). Ayarlar → "PDF'ler (tablet için)" (yalnız Android) ve masaüstünde "PDF'ler".
- Kalem katmanı B (saf Flutter) ile. A (yerel Ink) okuyucuya bağlanmadı: A'da parmakla kaydırma/yakınlaştırma yok. Karar T1 ölçümünden sonra değişebilir.
- Çizgiler sayfa birimi (sol-üst, y aşağı) ile saklanır; zum ve `/Rotate 90`'da kaymaz (saf fonksiyon testli). Kalem çizer, parmak PDF'i kaydırır, kalem çizerken ikinci temas yutulur (avuç).
- Gerçek PdfViewer + gerçek PDFium ile widget testi: parmak kaydırır, kalem kaydırmaz, çizgi doğru sayfaya düşer. 449 test; APK ve Linux debug derlendi.
- Doğrulanmadı: kalem hissi/gecikme, gerçek avuç, uzun belge ve çok çizgi performansı, release (R8).

### Ahmet elle denesin (T3)
- Ayarlar → PDF'ler → bir YKS PDF'i içe aktar; aç, kalemle yaz, parmakla kaydır/yakınlaştır. Avucunu koyarak yaz.
- 300+ sayfalık bir PDF aç: kaydırma akıcı mı, uygulama belleği? (`adb shell dumpsys meminfo com.kocum.kocum.gece`)
- Uygulamayı kapat-aç: çizgiler yerinde mi (zum farklıyken de)?
