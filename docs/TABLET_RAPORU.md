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

### T3b inceleme düzeltmeleri (v9.4.1)
- Avuç: `radiusMajor >= 24` temas baştan yutulur; kalem havada sayfaya yaklaşınca ya da çizerken viewer pan/zoom kilitlenir ("önce avuç sonra kalem" testli).
- Kayıt hatası: yeniden deneme (300 ms/1 s/3 s), kalıcı hatada çizgi ekranda kalır ve SnackBar çıkar; geri al/yinele hatada yığına döner.
- Uygulama arka plana gidince/kapanırken kuyruk boşaltılır (`AppLifecycleListener`).
- Sayfa önbelleği sayfa kapanınca boşalır; küçük resim şeridi görünümün belgesini paylaşır.
- Masaüstünde fare de çizer (telefon/tabletde yalnız kalem). Silgi sürerken geri al/yinele kapalı.
- Kalem sayfalar arası boşluktayken çizmez, kalem/parmak görünümü kaydırır.
- **Elle bakılacak:** kalem değdiği anda `panEnabled` değişimi görüntüyü zıplatıyor mu? Cihaz `radiusMajor` bildirmiyorsa avuç önce + kalem havada algılanmadan inerse kayma olabilir.

## T4: Soru = PDF koordinatı (v9.5)
- `question_cards`: `pdf_document_id`, `pdf_page`, `pdf_box_left/top/right/bottom` (şema 17; sütunlar `from < 17` + PRAGMA kontrolüyle, 12/14/16→17 testli). Ledger, masaüstü birleştirici, CLI kendiliğinden kapsıyor.
- Okuyucuda "Soru seç" aracı: sürükle, çerçeve, Doğru/Yanlış/Boş, ders/konu önerisi, kaydet/iptal. Metin varsa `textInBox` → `readPage` + `autoTag`; yoksa Android'de sayfa resmi + ML Kit (Linux'ta metinsiz kayıt). Eşik: ≥20 harf/rakam ve ≥3 sözcük.
- Önizleme `questionImage` olarak saklanır, defterde fotoğraflı kartla aynı görünür. Android'de WebP (mevcut hat), Linux/testte 480 px PNG.
- Defterde PDF kartına dokununca okuyucu sayfaya atlar, kutuyu vurgular; PDF yoksa ayrıntı sayfası.
- Doğrulanmadı: Android'de gerçek WebP çıktısı, ML Kit yolu gerçek cihazda (yalnız sahte motorla), okuyucudan karta dönüş yok, soru türü ayrı alan değil (OcrRecord'dan türetilir).

### Ahmet elle denesin (T4)
- PDF'te "Soru seç" ile bir soruyu çerçevele, Yanlış işaretle; Defter'de kart görünüyor mu, dokununca PDF'e gidiyor mu?
- Taranmış (metinsiz) PDF'te ders/konu önerisi ML Kit'ten geliyor mu?
- Telefon (PDF'siz): kart önizleme resmiyle görünüyor mu?

## T5: Çözüm katmanları (v9.6)
- `ink_strokes.question_id` (şema 18, `from < 18` + PRAGMA, indeks `ix_ink_question`); eski çizgilerde null. Okuyucu oturumu yalnız soruya bağlı olmayan çizgileri görür; çözüm çizgileri ayrı katman.
- Çözüm ekranı `/pdf/:id/soru/:questionId`: kırpılmış soru bölgesi + çizim payı; "Yeniden çöz" (yeni boş deneme), "Eski çözümü göster" (seçici + saydamlık), "İki denemeyi üst üste bindir"; deneme başına süre.
- Süre (`solveDuration`): çizgi aralıkları birleşir, 30 sn'den uzun boşluk sayılmaz, tek çizgi en çok 5 dk. Mevcut `avgSecondsPerQuestion` dokunulmadı.
- Giriş: okuyucuda "Çöz", kayıt snackbar'ında "Çöz", soru ayrıntısında "Çöz" ve "Çözüm süresi".
- Karar: ekran son denemede açılır (yanlışlıkla kapatınca çizim kaybolmasın); yeni deneme yalnız "Yeniden çöz" ile.
- Bilinen sınır: iki cihaz çevrimdışıyken aynı soruda "Yeniden çöz" derse ikisi de aynı deneme numarasını alır; çizgiler karışır, süre birleşir (veri kaybı yok). Kart silinirse çizgileri yumuşak silinir; kutu değişirse çizgiler sayfa koordinatında olduğundan yerinde kalır.
- 542 test, APK ve Linux debug derlendi. Kalem hissi tablette denenmedi.

### Ahmet elle denesin (T5)
- Bir soruda "Çöz": yaz, kapat, tekrar aç (çizim duruyor mu); "Yeniden çöz": temiz sayfa mı; eski çözümü saydam göster; iki denemeyi üst üste bindir.
- Süre makul mu (duraksayınca sayılmıyor)?

## T6 veri kısmı: Defter -> sayfa (şema 19)
- Tablolar: `ink_notebooks`, `ink_note_pages`, `ink_notebook_tags|people`, `ink_page_tags|people` (`from < 19`, `createTable` IF NOT EXISTS + indeksler). Ledger/birleştirici/CLI otomatik kapsadı.
- Karar: `ink_strokes.noteId` = SAYFA id'si; `notePage` = sayfanın DEĞİŞMEYEN `pageNo`'su (sıra `sortOrder`). Sözleşmedeki "notePage = sayfa sırası" böyle değişti: araya ekleme/taşıma BLOB'lu çizgileri yeniden yazıp defteri şişirmesin diye.
- Depo `features/notes/data/ink_notebook_repository.dart`; şablon çizgileri `domain/page_template.dart` (`templateLines`). Defterin son sayfası silinemez.

## T6a: Not uygulaması, geometri ve veri (v9.7; arayüz T6b'de)
- Saf geometri (`lib/features/ink/domain`): kalem profilleri (tükenmez/dolma/kurşun/fosforlu, baskı eğrisi `p^gamma`), 10 renk, çizgi ve alan silgisi, kement seçim/taşıma/boyutlandırma/döndürme, şekil düzeltme (çizgi, daire, elips, dörtgen, üçgen; güven eşiği 0.5, kıvrımlı yazı/sekiz/spiral reddedilir), komut yığını. Testler ±%3 gürültülü, 10 tohumlu.
- Veri (şema 19): `ink_notebooks`, `ink_note_pages`, defter/sayfa için etiket+kişi bağ tabloları; depo (defter/sayfa oluştur, sırala, çoğalt, yumuşak sil/geri al, şablon). Şablon çizgi geometrisi saf fonksiyon.
- Sözleşme kararı: `ink_strokes.noteId` = sayfa id'si, `notePage` = sayfanın DEĞİŞMEYEN `pageNo`'su (sıra `sortOrder`'da); araya ekleme/taşıma BLOB'lu çizgi satırlarını yeniden yazmaz. Sapma: sayfa→defter ve bağ→sahip yabancı anahtarları yok (sıra bozuk eşitlenince takılmasın), etiket/kişiye var. Defterin son sayfası silinemez.
- Eşikler rastgele gürültüyle ayarlı; gerçek tablet çiziminde yeniden ayar gerekebilir.

## T6b1: Defter arayüzü, kalem, silgi (v9.8)
- `/defter` (kapak rengi, başlık, sayfa sayısı; yeni, yeniden adlandır, sırala, onaylı yumuşak sil, geri al), `/defter/:id` (yan şeritte küçük resimler, sayfa ekle/araya/çoğalt/sırala/sil, şablon). Açılışta `ensureVisiblePage`. Giriş: Ayarlar → "Defterler (tablet için)" (Android), masaüstünde "Defterler".
- Sayfa editörü T3b oturum altyapısını yeniden kullanır (kalem çizer, parmak kaydırır/yakınlaştırır, avuç yutulur, kayıt hatası yeniden denenir). Kalem türleri (tükenmez/dolma/kurşun/fosforlu), renk, kalınlık, sertlik; çizgi ve alan silgisi; geri al/yinele.
- Alan silgisi: parçaları ekler + özgünü yumuşak siler tek işlemde; hatada özgünler geri konur.
- Sapmalar: geri al için `InkCommandStack` yerine mevcut `InkHistory` (kimlikle kalıcı); çizgi silgisi T3b'nin `eraseAt`'ı ile; sertlik yazarken baskıya uygulanır (saklanan baskı biçimlenmiş).
- Doğrulanmadı: gerçek kalem, avuç, Casper'da `InteractiveViewer` + stylus; fosforlu multiply yalnız çizgi katmanında; çok sayfada küçük resim performansı.

### Ahmet elle denesin (T6)
- Defterler → yeni defter → çizgili/kareli sayfa; dört kalem türü; sertlik ayarı baskıya göre kalınlığı değiştiriyor mu?
- Çizgi silgisi / alan silgisi / geri al / yinele; uygulamayı kapat-aç: çizgiler yerinde mi?
- Sayfa şeridi: sayfa ekle, çoğalt, sırala.

## T6b2: Kement, şekil düzeltme, etiket/kişi (v9.9 taslak)
- Kement (araç çubuğu `note-lasso`): kalemle kapalı yol → `selectByLasso`; 8 tutamak + döndürme. Köşe orantılı, kenar tek eksen, gövde taşır; ince kutuda (tek satır yazı) kenar tutamacı kapalı (gövdeyi örtmesin). Sil/kopyala/yapıştır (yapıştırma +24 birim kayık, seçili gelir).
- Karar: taşıma/boyutlandırma çizgileri YERİNDE günceller (`InkStrokeRepository.updatePoints`, tek işlem, aynı kimlik). Yumuşak sil + yeni satır yerine: BLOB her taşımada ikiye katlanmaz, kimlik/geri al/senkron satırı sabit kalır. Bedel: özgün noktalar yalnız bellekteki geri al kaydında (`InkAction.before`); uygulama kapanınca geri al zaten sıfırlanıyor. Hatada üç yeniden denemeden sonra ekran kayıtlı konuma döner.
- Şekil düzeltme: kalem 600 ms (`shapeHoldMs`) ve 6 px (`shapeHoldTolerancePx`) içinde hareketsiz → `recognizeShape`; tanınırsa önizleme düz şekil, kalem kalkınca KAYDEDİLİR; tanınmazsa serbest çizgi aynen. Geri al: özgün serbest çizgi hiç kaydedilmediği için geri al düzeltilmiş şekli tamamen kaldırır (serbest çizgiye dönmez). Araç çubuğunda "Şekil" anahtarı (varsayılan açık).
- Etiket/kişi: defter ekranında etiket simgesi → "Etiketler ve kişiler" paneli (defter + açık sayfa). Anlık'ın TagBar/PersonBar/seçicileri ve `parseTagMentions`/`matchPerson` kullanılır; yazarak (`((his > tiksinti)) @Ayşe`) eklemede yeni ad onay ister. Defter listesinde etiket çipleri ve etikete göre süzme (alt etiketler dahil, sayfa etiketi de sayılır).
- Araç çubuğunda geri al/yinele/şablon artık sağa sabit (araçlar kayar).
- Doğrulanmadı: gerçek kalemle his, 600 ms basılı tutma süresinin tablette rahat olup olmadığı, tutamak boyutu (16 px) parmakla/kalemle isabeti.

## T7: Senkron ve sade arayüz (v9.10 – v9.10.3)
**Senkron (T7a).** Tablet bir Android cihaz; telefonla aynı yoldan bilgisayarla eşleşir. Telefon↔tablet doğrudan eşleşme YOK, bilgisayar merkez. Keşfedilen hata: bilgisayar yalnız kendi yazdığı satırları veriyordu, telefondan aldığını tablete aktarmıyordu (yakınsama yoktu). Düzeltildi (`relayExcept`); 3 gerçek veritabanı + gerçek sunucu testiyle üç cihaz yakınsıyor. Eski sürümden kalan imleç boşluğu için ilk eşitlemede imleç bir kez sıfırlanır.
- PDF dosyası: `PUT /kocum/v1/pdf` (`<sha256>.pdf`), imzalı, sha256 iki uçta, 300 MB sınır, `.part` + atomik ad, symlink reddi. İsteğe bağlı, varsayılan KAPALI (eşitleme ekranında anahtar). "Bu özet var mı?" imzalı, adla sorulur; var olan dosya hiç okunmaz. Bilgisayar→telefon yönü yapılmadı (okuma ucu gerekir; "okuma yok" kuralı korundu).
- Bilinen sınırlar: tek eşleşme yuvası var, telefon ve tablet için her geçişte eşleşmeyi kaldırıp kod girmek gerekir; ilk tam yedekle gelen eski veri deftere girmediği için sonradan eşleşen cihaza gitmez; aynı `esitleme.json` ile iki cihaz kurmak çift kimlik verir. Gerçek Wi-Fi'de denenmedi (hepsi 127.0.0.1).

**Arayüz (T7b).** `isTabletLayout` (Android, kısa kenar ≥ 600 dp); tablette sol ray (Kitaplık, Defterler, Notlar, Soru defteri, Daha fazla, Ayarlar), telefonda alt çubuk aynen. Araç çubukları tek satır (dar tabletde "…"), odak modu (ray + sistem çubukları gizli). İnceleme düzeltmeleri: telefon↔tablet geçişinde State korunur, geri tuşu Kitaplık/Defterler'den ana sayfaya döner, odak sızıntısı kapandı.

## ÖZET (22.11.2026)
Sürümler v9.0 → v9.10.3, 8 şema artışı (14 → 19 + question_cards/ink_strokes sütunları = şema 19), tüm testler yeşil (752), debug ve release (R8) APK derlendi, Linux debug derlendi. Her adım bağımsız `inceleyici`'den geçti; bulunan veri kaybı yolları düzeltildi (alan silgisi, kement ekran/DB ayrışması, defter BLOB'u, kart silme).
- Release APK 78,9 MB (önceki release 66,0 MB): +12,9 MB. Ink (`libink.so` ≈ 1,3 MB/ABI) + PDFium (`libpdfium.so` 6,6 MB, arm64) ve geçişli paketler.
- **Yapılamayan: tablet ölçümleri.** `adb devices` PADH10005831 için hep `unauthorized` kaldı. Hiçbir şey gerçek kalemle/gerçek tablette denenmedi: kalem gecikmesi, avuç, `radiusMajor` eşiği, basılı tutma süresi, 2560×1600 görünüm, uzun PDF belleği.
- T1 seçimi: ölçüm olmadığı için Android'de A (yerel Ink), diğer platformlarda B. Ama okuyucu ve defter şimdilik B (saf Flutter) kullanıyor: A'da parmakla kaydırma/yakınlaştırma yok. A/B kararı elle karşılaştırmaya bağlı.

### Ahmet için sıralı yapılacaklar
1. Tablette "USB hata ayıklama" iznini onayla (`adb devices` → `device`).
2. `flutter build apk --debug` → `adb install -r build/app/outputs/flutter-apk/app-debug.apk` ("Koçum (deneme)", gerçek Koçum'dan ayrı).
3. Ayarlar → Araçlar → **Kalem denemesi**: A ve B'yi kalemle karşılaştır; `adb logcat -s KocumInk` çıktısını al (A: giris->vsync, B: giris->vsync ve giris->raster).
4. **PDF'ler**: bir YKS PDF'i içe aktar; yaz, kaydır, yakınlaştır, avucunu koy; "Soru seç" ile bir soruyu çerçevele (Yanlış), Defter'de kart, "Çöz", "Yeniden çöz", eski çözümü saydam göster.
5. 300+ sayfa PDF: akıcılık ve bellek (`adb shell dumpsys meminfo com.kocum.kocum.gece`).
6. **Defterler**: dört kalem, sertlik, silgi (çizgi/alan), kement, şekil düzeltme (çizip basılı tut), etiket/kişi bağla; kapat-aç, çizgiler yerinde mi.
7. Eşitleme: tableti bilgisayarla eşle, PDF gönderme anahtarını aç, bilgisayarda `pdfs/` klasörüne bak; sonra telefonu eşle, tablet verisi telefona (bilgisayar üzerinden) geliyor mu.
8. Şekil/basılı tutma eşikleri (600 ms, 6 px), kement tutamacı (16 px) rahat mı? Rahat değilse söyle, sabitler tek yerde.

### Açık işler (bu turda yapılmadı)
- Telefon↔tablet aynı anda eşleşme (tek yuva); bilgisayar→tablet PDF yönü; telefondaki eski verinin tablete taşınması.
- Çizgiler için defter boyutu: BLOB hex ile ~4x yer tutar (eski+yeni), budama yok.
- Ink A'nın okuyucu/defterde kullanımı (parmak kaydırma sorunu çözülünce).
- WebP önizleme Android'de üretiliyor ama cihazda doğrulanmadı; ML Kit yolu gerçek cihazda denenmedi.
- Soru türü (Şekilli, Hesap…) kartta ayrı alan değil, OcrRecord'dan türetiliyor.
- İki cihaz çevrimdışı "Yeniden çöz" derse aynı deneme numarası karışır (veri kaybı yok).

## Tablette ilk deneme sonrası düzeltmeler (v9.11, 22.11.2026)
Casper PAD H10'da (SDK 36, 1600×2560) deneme sürümü kuruldu ve gerçek kalemle denendi.
- **Ölçüm:** gerçek kalem Flutter'a `stylus` olarak, basınç 0–1 (çizerken ~0.1–0.55), eğimli, `radiusMajor=0` ve hover olaylarıyla geliyor; çizgi doğru sayfaya yönleniyor. Parmak teması `radiusMajor` 75–143 (iki parmak yakınlaştırma): avuç eşiği 24 doğru ayırıyor. Ahmet'in hissi: gecikme fark edilmiyor.
- **Ahmet'in eksik listesi ve karşılığı:** sınırlı zum (1–6x) → 0.1–30x, sonsuz kenar boşluğu, çift dokunuşla sığdır, zum göstergesi; yeni defterde şablon (düz/çizgili/kareli/noktalı) ve sayfa boyutu (A4 / ekrana tam / sınırsız-büyük tuval) seçimi; görünür "Yeni sayfa" düğmesi ve sayfa okları; sayfa varsayılan tam genişlik; kalem/fosforlu/silgi için ayrı boyut paneli ve silgi daire imleci; fosforlu için kendi paleti (saydam, multiply, kesik uç); Şekil paneli (otomatik düzelt anahtarı + çizgi, ok, daire, elips, dikdörtgen, üçgen araçları), basılı tutma eşiği 10 px / 600 ms (kalem titremesi için).
- Sınırsız tuval gerçek sonsuz DEĞİL: 1404 × 14040 sabit büyük sayfa (veri modeli sayfa boyutlu).
- Açık: boyutlar yalnız oturumda tutuluyor (`toSizes`/`restoreSizes` hazır, ekran bağlamadı); `recognizeShape` tam dikdörtgeni tanımıyor (elle dikdörtgen aracı var); fosforlu uç yönü yatay çizgide kalınlık kadar (metin vurgulamak için); 30x zumda keskinlik tablette bakılmalı.

## Defter arayüzü: araç yuvası (v9.11 sonrası)
- Üst çubuk yalın: geri, başlık, `‹ 2/5 ›`, `+` (bundan sonra sayfa ekle), odak, etiket, şerit düğmesi, sayfa menüsü (⋮). Araçlar çubukta değil.
- Araç yuvası (`note_tool_dock.dart`): ekranda yüzen, kalem / fosforlu / silgi / kement / şekil, iki yanda geri al / yinele, yanında "Sayfa" ve ⇅ (alta/üste). Seçili araca yeniden dokununca ayar penceresi (kalem türü + boyut + önizleme + renk + sertlik; silgi boyut + çizgi/alan; şekil seçici + otomatik düzelt). Kement ikinci dokunuşta kaleme döner. Yuva sayfanın üstünde yüzer, sayfa tam genişlik. Odak modunda küçülür (Sayfa ve ⇅ gizli). Telefonda düğmeler 40 dp, yuva yatay kayar; etiket ve şerit düğmesi ⋮ menüsüne iner.
- "Sayfa" penceresi (yuva ve ⋮ → "Şablon ve arka plan…"): şablon tek dokunuş, tüm sayfalara uygula, arka plan (beyaz/krem/koyu; sayfa kaydına yazılır), çizgi aralığı (sık/normal/seyrek). Çizgi aralığı YALNIZ oturumda tutulur (şema değişmesin diye); defter kapanınca normale döner.
- Sayfa şeridi varsayılan kapalı; üstteki düğme ya da ⋮ ile açılır.
- Kalıcı: kalem/fosforlu/silgi boyutu ve yuva konumu `app_meta`'da (`defter.arac_ayari`, masaüstünde `masaustu.` önekli); 0,5 sn gecikmeli yazılır, ekran kapanırken de yazılır.

## v9.12: tabletteki ikinci deneme sonrası (22.11.2026)
Ahmet: "parmakla büyütme/küçültme yok, PDF'te el ile hareket yok, silinen defter listeden kaybolmuyor, çizim arayüzü pratik değil, hâlâ sadece çizgili sayfa var, soru defterinde çizim olmalı".
- **Kök neden (parmak):** avuç süzgeci `radiusMajor >= 24`'ü avuç sayıyordu; tablette gerçek parmak teması 75–143. Her parmak yutuluyordu, kaydırma ve zum (defter + PDF) hiç çalışmıyordu. Eşik 260 yapıldı; asıl koruma kalem yakınlığı (hover) ve çizerken kilit. Gerçek avuç boyutu ÖLÇÜLMEDİ (260 tahmin).
- Silinen defter/PDF listeden anında gizlenir (iyimser gizleme; yazma hatasında geri gelir). Cihazdaki gecikmenin kök nedeni bulunamadı.
- Çizim arayüzü: ince üst çubuk, alta yüzen araç yuvası (≥52 dp), seçili araca tekrar dokununca ayar penceresi (boyut, renk, şekil, kalem türü, sertlik, silgi modu), ⇅ ile alta/üste, "Sayfa" penceresi (Düz/Çizgili/Kareli/Noktalı, arka plan, çizgi aralığı [yalnız oturumda]), sayfa şeridi varsayılan kapalı, kalem/silgi boyutları kalıcı (`defter.arac_ayari`).
- Soru defterinde çizim: her kart için çözüm ekranı (`/soru/:id/coz`): fotoğraflı kartta görüntü tam genişlikte, altında yazı payı; koordinat görüntü genişliği 1000 birim; deneme katmanları, eski çözüm, süre. Kartta "✎ 2 · 1 dk" işareti. Soru nasıl saklanır: `docs/TABLET_PDF.md`.
- 829 test. Açık: yuva kalemle sürüklenmiyor (yalnız ⇅); koyu arka planda varsayılan siyah kalem görünmez; ayar penceresi açıkken sayfaya çizilemez; fotoğraf başka oranlı resimle değiştirilirse eski çizgiler kayar.

## v9.13: sonsuz defter, 4 kenar yuva, silgi, PDF araçları, tam sol menü (22.11.2026)
Ahmet'in isteği: "sonsuz aşağı kayan defter; kalem menüsü yana/üste/alta kayabilsin; geri al/ileri al; silgi kalınlık modu; PDF'te aynı araçlar; tablette her şey, sol menüde hepsi, doğrudan sol menüde".
- **Sonsuz (aşağı kayan) sayfa:** genişlik 1404, yükseklik 4300+ ise sonsuz sayılır (şema değişmedi; eski 1404×14040 sayfalar da); kalem/çizgi alta 600 birim yaklaşınca +2000 uzar (üst sınır 200000), kalem basılıyken uzamaz, çizgi koordinatı değişmez, şablon yalnız görünen aralığa çizilir. Yeni sonsuz sayfa 1404×4400 başlar.
- **Yuva:** üst/alt/sol/sağ; "Konum" düğmesi (4 yönlü menü) ya da basılı tutup sürükleyerek en yakın kenara; dikey düzen; kalıcı. Defter, PDF okuyucu ve çözüm ekranı aynı `NoteToolDock`/`FloatingToolDock`u kullanır; ayarlar ortak (`defter.arac_ayari`).
- **Geri al/yinele:** yuvada hep görünür, büyük; basılı tutunca hızlı tekrar.
- **Silgi:** varsayılan "Kısmi silgi (kalınlık)" = alan silgisi, kalınlık sürgüsü ve önizleme her zaman görünür; "Çizgi silgisi (tamamını sil)" ayrı mod, kalıcı.
- **PDF okuyucu/çözüm:** eski araç çubuğu kalktı; tüm kalem türleri, fosforlu, silgi modları, kement, şekil, boyut, soru seç aynı yuvada.
- **Sol menü:** "Daha fazla" tıklanır, 340 dp sağ panelde 38 hedef gruplu (Çalışma, Sorular, Kitaplar ve denemeler, Notlar, Analiz, Tablet, Araçlar, Ayarlar); ray 96 dp, kayar, Ayarlar sabit; üst düzey ekranlar da tablette rayla sarılı (aktif oturum, tekrar, soru çözümü, PDF çözümü, kalem denemesi hariç).
- **Rotası olmayan, menüde ayrı satırı olmayanlar:** Optik, Hazır kitap ekle/JSON şablon (Kitaplar içinde), Silme önerileri, Claude raporu/dışa aktarma (`/tools` içinde).
- Açık: çok uzun düz tek çizgide çizim sırasında takılma riski (dış hat üretimi, ölçülmedi); sürüklerken kenar önizlemesi yok; alt yuvayı SnackBar kısa süre örter; "Soru defteri" etiketi gerçek fontta sığıyor mu bakılmadı. 903 test.
- **Soru nasıl saklanır:** PDF koordinatı (pdfDocumentId, pdfPage, pdfBox) kaynak gerçek; `questionImage` ~480 px önizleme PDF'siz cihazlar için.

## v9.14: Kitaplar kitap raf görünümü, "Daha fazla" kalktı, hepsi doğrudan sol menüde (22.11.2026)
- **Kitaplar:** düz liste yerine kapak kartları (dikey 2:3, ders etiketi, büyük ad, yayınevi, sırt gölgesi, ilerleme şeridi) ve sade ahşap raf çizgisi; kapak rengi dersten/addan kararlı seçilir (FNV-1a); 2–6 sütun. TYT/AYT/MEB sekmeleri duruyor. Eski kartın doğru/yanlış/boş çubuğu kapaktan kalktı (ayrıntıda). Masaüstü kitaplar sayfası dokunulmadı (`BookShelfView` oraya takılabilir).
- **Sol menü:** "Daha fazla" TAMAMEN kalktı (v9.13 raporundaki "Daha fazla" ifadeleri artık geçersiz). Kalıcı, kaydırılabilir 232 dp menü: 7 grup başlığı (Çalışma, Sorular, Kitaplar ve denemeler, Notlar, Analiz, Tablet, Araçlar) ve her öğe ikon + ad; Ayarlar altta sabit; daralt düğmesi ile 96 dp ikon rayı (Bugün, Kitaplık, Defterler, Notlar, Soru defteri, Kitaplar, Deneme, Analiz + Ayarlar); tercih `tablet.menu_dar`, varsayılan geniş. 924 test.
- Doğrulanmadı: gerçek ekranda kapak/raf görünümü; "Claude'un değişiklikleri" gibi uzun adlar 232 dp'de elips olabilir.

## v9.15 – v9.18 (23.11.2026): çoklu cihaz, hız, PDF kitap, filigran, analiz modu
Ahmet'in istekleri ve karşılıkları:
- **Aynı anda telefon + tablet + bilgisayar (v9.15):** bilgisayar en çok 4 cihazı AYNI ANDA eşleşik tutar (her birinin kendi anahtarı/oturumu/sıra sayacı; biri kalkınca öbürleri kopmaz; eski tek-cihaz `esitleme.json` göçlü). Yeni eşleşen cihaz bilgisayardaki tüm güncel satırları alır (tam durum; telefondaki eski veri tablete de gelir; imleç yalnız boş cihazda çekilir: ara değişiklikler kaybolmaz). PDF dosyaları iki yönlü: cihaz→bilgisayar (`PUT`), bilgisayar→cihaz (`pdf-al`, üçüncü dar istisna; iki ayar da varsayılan KAPALI). Telefon↔tablet doğrudan eşleşme yok (bilgisayar merkez). İnceleme düzeltmeleri: imleç veri kaybı, kilit bekleme sınırı (20 sn, 409 meşgul), kaldırılan cihazın akışı kesilir, silinmiş PDF verilmez, foto izni cihaza özel. Bilinen sınır: istekteki defter kimliği eşleşme kimliğine bağlı değil.
- **Açılış hızı (v9.15.1):** tablette şimdiye dek DEBUG (JIT) sürüm vardı. Hızlı deneme sürümü: `flutter build apk --profile --target-platform android-arm64` (AOT; `.gece` kimliği profile'a da verildi). Ağır başlatmalar ilk kareden sonraya ertelendi (bildirim init, MEB tohumu, OCR/GenAI/kamera dinleyicileri 1,5 sn sonra); `KocumStart` açılış izi (`adb logcat -s flutter | grep KocumStart`). Gerçek ölçüm yapılmadı (tablet yetkisizdi).
- **PDF içe aktarma + kitap (v9.16):** içe aktarma penceresi ("Kitap olarak da ekle", varsayılan açık); kitap formu otomatik dolar (başlık, sayfa sayısı, ders/sınav/yayınevi tahmini, şablon eşleşmesi), dolduramadıkları kırmızı "Doldur", Kaydet hepsi dolunca açılır; sayfa ofseti sorulur. PDF kitaplığı kapak rafı; kitap kapağında PDF rozeti ve "PDF'te aç". Doğrulanmadı: PDF metadata (Title/Author) motordan beslenmiyor.
- **Soru defteri (v9.16.1):** soru ekranlarında yazılı eylem çubuğu: Düzenle, PDF'te aç, Çiz / Çöz, Seç, Sil; uzun basış/⋮ menüsü. "PDF'ten yeniden seç" yapılmadı (okuyucudan kutu geri döndürme gerekir).
- **Filigran ve katmanlar (v9.17, şema 20):** `pdf_page_layers`; PDF dosyası ASLA değişmez, katmanlar görüntüleme + senkron. Otomatik ton tespitli yarı saydam filigran temizleme (koyu metin korunur), kapsam: bu sayfa / seçili bölge / tüm sayfalar; "2. katman ekle" (başka filigran ya da renkli örtü); ikisi de kaydedilir; Önce/Sonra karşılaştırma, Güç/Ton sürgüleri; çözüm ekranı arka planı ve soru önizleme kırpması da katmanı uygular. Doğrulanmadı: gerçek filigranlı PDF'te kalite ve tablet performansı.
- **Kitap analiz modu PDF ile (v9.18):** `/pdf/:id?page=&analiz=1`; PDF'li kitapta test/yanlış soru → PDF'te ilgili sayfa (kutu varsa kutu); okuyucuda "Analiz" anahtarı: "Yanlışlarım" paneli (test gruplu, Yanlış/Boş/Hepsi), küçük resimlerde yanlış sayısı, sayfada kırmızı/gri/yeşil çerçeve, sonraki/önceki yanlış. Soru kutusu olmayan sorularda test başlığına gider, kutulu sorularda tam yere.
- **Soru nasıl saklanır:** PDF koordinatı kaynak gerçek; `questionImage` önizleme PDF'siz cihaz içindir.
- **El yazısını metne çevirme (karar):** Casper'ın/Android'in sistem el yazısı motoru kayıtlı çizgiyi alamaz (yalnız canlı kalemle yazı kutusu); kullanılabilir yol Google ML Kit Digital Ink (MIT, `tr-TR`, ~20 MB model indirilir, APK'ya gömülmez). Yapıldı: aşağıdaki bölüm.
- Açık: eşitlemeyle gelen katman panel açılınca görünür (canlı değil); katman yeniden adlandırma arayüzü yok; yuva sağdayken analiz paneli üst üste binebilir; tam test 1051 geçti.

## El yazısını metne çevirme (şema 21)
Ahmet: "defterlerin el yazılı kopyasını (metin hâlini) oluşturmak için kullanılabiliyorsa ekle".
- **Paket:** `google_mlkit_digital_ink_recognition` 0.14.2 (MIT; `pub get` yalnız bu paketi ekledi, `google_mlkit_commons` zaten vardı). Yerel kitaplık `com.google.mlkit:digital-ink-recognition:19.0.0`. R8: `tool/r8_patch.dart` eklenti sınıfını korur (`r8InkRule`; eski yamalı dosyaya tek kural eklenir, testli).
- **Model:** Türkçe `tr-TR`, ~20 MB, ilk kullanımda indirilir (APK'ya gömülmez). Eklenti ilerleme ve iptal vermez: arayüz "ilerleme yüzdesi yok" der, "Beklemeyi bırak" yalnız beklemeyi bırakır (indirme arka planda bitebilir).
- **Satır gruplama (`line_grouping.dart`):** tanıyıcı tek satır varsayar. Gövde çizgileri y-merkezine göre kümelenir (eğik yazı için en yakın x komşusuna göre), nokta/virgül/aksan en yakın satıra bağlanır, yan yana kalan parçalar birleşir, üst üste satırlar birleşmez. Çok uzun düz çizgi, fosforlu, silinmiş atlanır; büyük kapalı şekil "[şekil]" satırı olur. Tanıyıcıya giden çizgiler satır sol-üstüne taşınır, soldan sağa sıralanır, zamanı artan yapılır; yazı alanı bir satır kadar yüksek; bağlam = önceki satırın son 20 karakteri.
- **Veri:** `ink_page_text` (id = sayfa kimliği; `body`, `linesJson`, `languageCode`, `strokeSig`, `recognizedAt`, `deleted`). Senkron tablosu (tetikleyici, birleştirici, `kocum` aracı otomatik). `strokeSig` sayfadaki görünür çizgi kimlikleri + güncelleme zamanlarının özeti; çizgi eklenir/taşınır/silinirse metin "güncel değil" görünür. Metin TÜREV veridir; çizgiler hiç silinmez.
- **Arayüz:** Ayarlar > El yazısı tanıma (durum, indir [onaylı, Wi-Fi seçeneği], modeli sil); defter ⋮ > "Sayfayı metne çevir" (model yoksa indirme önerilir; ilerleme/iptal; düzenlenebilir metin, Kopyala, Kaydet, Yeniden tanı), araç yuvası Sayfa penceresinde aynı düğme, kement seçiliyken "Seçimi metne çevir" (kaydedilmez, kopyalanır), şeritte "Aa" rozeti, ⋮ > "Defterin metin kopyası" (sayfa sayfa, Kopyala, .txt dışa aktar, "Tümünü tanı"), defter listesinde arama (ad + el yazısı metni, `normalizeTr`; sonuç sayfaya götürür). Masaüstünde tanıma düğmeleri yok, kayıtlı metin görünür ve aranır.
- **Doğrulanmadı:** gerçek Türkçe tanıma doğruluğu (özellikle bitişik yazı, matematik, şekil), modelin indirildikten sonra çevrimdışı çalışması, cihazda indirme/hata iletileri. Eşikler (`GroupingOptions`) sentetik çizgiyle ayarlı; gerçek el yazısında ayar gerekebilir.
- **Açık:** iki cihaz aynı sayfayı ayrı çevirirse alan alan birleşir (son yazan kazanır). Drift akış önbelleği anahtarı yalnız SQL metni olduğu için aynı `SELECT 1` kullanan eski akışlar (`watchNotebooks`, `watchPages`) birbirine karışabilir; bu iş yeni akışı benzersiz SQL ile yazdı, eskilere dokunmadı.

## v9.19 (23.11.2026): inceleme düzeltmeleri + el yazısı → metin (şema 21)
- **Filigran düzeltmeleri (incelemede bulunan içerik kaybı kapandı):** ağırlık artık `tone ± toneRange` bandının İKİ ucunda yumuşak eşikli; geniş açık dolgu alanları, ince ızgara çizgileri, soluk renkler (gri modda renkli pikseller, renkli modda hue+doygunluk) korunur; "Tüm sayfalar" kapsamında uyarı ve "başka sayfada önizle". Z sırası tek ortak fonksiyonla (okuyucu, çözüm ekranı, önizleme aynı). Tek iş kuyruğu, iptal belirteci, 96 MB bayt sınırlı önbellek. Soru kartı önizlemesi varsayılan KATMANSIZ (anahtar: "Katmanları önizlemeye uygula", varsayılan kapalı). Çizimler (kalem) filigran/örtü katmanlarının her zaman üstünde, "Orijinali göster"de de görünür; katman panelinde "Çizimler" satırı (göster/gizle, çizgi silinmez).
- **Analiz modu:** yuva panelle çakışmıyor (panel açıkken yuva soluna kayar), şerit kalemi/dokunuşu yutmaz.
- **PDF kitap ekleme ve soru eylemleri:** kitap+bağ+ofset tek işlemde (yetim kitap yok), çift dokunuş korumaları, silinmiş/başka cihaz PDF'in yeniden içe aktarımı, silinen kart görüntüleyicide/seçimde kalmaz, uzun basış = seçim (eylemler ⋮'te), raf `ListView.builder`, yayınevi yanlış pozitifleri, 48 dp dokunma alanı.
- **El yazısı → metin:** Casper/Android sistem motoru kayıtlı çizgiyi alamaz; ML Kit Digital Ink (`google_mlkit_digital_ink_recognition` 0.14.2, MIT, `tr-TR`, ~20 MB model İNDİRİLİR, APK'ya gömülmez). `ink_page_text` tablosu (şema 21, TÜREV veri, çizgilere dokunulmaz). Ayarlar'da model kartı (indir/sil), sayfa menüsünde "Sayfayı metne çevir", kementle "Seçimi metne çevir", şeritte "Aa" rozeti, "Defterin metin kopyası" (kopyala, .txt), defter listesinde adda VE metinde arama. Yalnız Android; masaüstünde kayıtlı metin görünür/aranır. 1142 test.
- **Doğrulanmadı:** gerçek Türkçe el yazısı doğruluğu; modelin indirildikten sonra çevrimdışı çalışması; gerçek filigranlı PDF'te kalite; release R8 derlemesi (yalnız debug). Eklenti indirme yüzdesi/iptal vermiyor.
- **Açık:** Drift akış önbelleği anahtarı yalnız SQL metni: eski `watchNotebooks`/`watchPages` aynı düz `SELECT` ile karışabilir (yeni akış benzersiz SQL kullanır).
- **APK boyutu (abi):** ML Kit eklentileri x86_64/armeabi-v7a `.so` dosyalarını da getiriyordu (profile 131,5 MB). `tool/abi_patch.dart` (`patch_android.dart` çağırır) `ndk.abiFilters`'ı yalnız `arm64-v8a`'ya indirir; test `test/abi_patch_test.dart`.
- Sonuç: profile 131,5 -> 94,0 MB (`lib/arm64-v8a/` tek), release 63,5 MB (R8 uyarısız, paket kimlikleri değişmedi: `.gece` / `com.kocum.kocum`).
- Release APK tablete KURULMADI (adb yok); Ahmet elle denesin: ML Kit el yazısı/OCR arm64'te çalışmalı.

## Sağlık verisi: uyku, nabız, stres (şema 22)
Ahmet: HUAWEI WATCH FIT 2 + Huawei Sağlık; "stres ve uyku verilerini Koçum'a almanın yolu".
- **Gerçekler (araştırma; ikincil kaynak):** Health Connect'te SleepSession (derin/hafif/REM/uyanık), HeartRate, RestingHeartRate, HRV, SpO2, Steps VAR; STRES türü YOK. Huawei Sağlık'ın Health Connect'e yazıp yazmadığı DOĞRULANAMADI (ikincil kaynaklar "yazmıyor" diyor). Bu yüzden önce TANI: Ayarlar > Sağlık verisi > "Son 14 günü tara" hangi paketlerin (ör. `com.huawei.health`) hangi türde kaç kayıt yazdığını listeler; Huawei yoksa açıkça ZIP yolunu önerir.
- **Karar (A):** `health` paketi yerine doğrudan Kotlin kanalı. `health` 14.x compileSdk 37 + AGP 9.1+ + FlutterFragmentActivity ister (bu makinede yalnız android-36; MainActivity genai/ink yamalı FlutterActivity). `pub add health --dry-run` çözülür ama derleme gereksinimi uymaz; denenmedi. Kanal: `tool/health_patch.dart` (+ `test/health_patch_test.dart`): `connect-client:1.1.0` bağımlılığı, 6 salt okuma izni, `<queries>`, rationale + `VIEW_PERMISSION_USAGE` alias, `KocumHealth.kt` (FlutterPlugin + ActivityAware; izin Intent'i `PermissionController.createRequestPermissionResultContract()`), MainActivity'ye `flutterEngine.plugins.add(KocumHealthPlugin())`. Debug ve release (arm64) derlemeleri geçti (aşağı bak).
- **Veri (C):** `saglik_gunluk`, `saglik_stres`, `saglik_uyku_oturum`; tekilleştirme (aynı kaynak + gün/zaman/başlangıç ikinci kez çift kayıt yapmaz). Defter/senkron DIŞI (`healthTables`), masaüstü birleştirmede alınmaz, Claude raporuna varsayılan KAPALI anahtarla küçük günlük özet. Yedek ZIP'e girer (kartta yazılı). Silme düğmesi onaylı.
- **Huawei ZIP (D1):** Ayarlar > "Huawei verisi içe aktar (ZIP)": önce Yapı raporu (dosya + alan adları, DEĞER YOK, kopyalanır), sonra tolerant ayrıştırma (ms/sn/ISO/yyyyMMdd/gg.aa.yyyy zamanları; iç içe/dizi/JSON-dizesi/JSONL/CSV; derin/hafif/REM/uyanık, toplam, stres), önizleme, onay. **Şema bilinmiyor**; hiçbir şey bulunamazsa nedeni yazılır. Şifreli ZIP desteklenmez (klasör seçeneği var).
- **Elle stres (D2):** Bugün'de "Stresim 1-5" kartı (`manuel`). **Görünüm (E):** Ayarlar'dan "Sağlık verisi (son 14 gün)" ekranı (uyku çubuğu aşamalı, nabız, HRV, adım, stres, kaynak rozeti); uyku kartında "Dün gece (saatten): 7s 12dk, derin 1s 30dk"; elle kayıtla fark varsa "Hangisini kullanayım?" (otomatik üzerine yazma yok, ikisi de silinmez). Analiz (çalışma/uyku ilişkisi) YAPILMADI. **Linux (F):** kartlar ve ekranlar yalnız Android'de; masaüstü `UnsupportedHealthSource`.
- **Doğrulanmadı:** gerçek Huawei verisi; Health Connect'te Huawei Sağlık kaynağının varlığı; gerçek ZIP şeması (ayrıştırıcı tahmin); Health Connect izin ekranı/okuma cihazda (adb yok); stres ölçek tahmini (en yüksek değer ≤5 ise 1..5 sayılır).
- **Açık:** `kocum` CLI aracı sağlık tablolarına özel komut sunmuyor; masaüstünde ZIP içe aktarma yapılmadı; `pubspec` sürümü artırılmadı.
