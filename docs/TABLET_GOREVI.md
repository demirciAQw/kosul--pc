# Tablet + PDF görevi

Hedef: Koçum, Casper PAD H10 tablette (Android 15, Dimensity 7050, 8 GB RAM, 2560×1600, 4096 seviye baskılı kalem) çalışan sade bir YKS PDF ve not uygulaması olsun. Telefon ve bilgisayarla senkron çalışsın. Ayrıntılı ürün tarifi: `docs/TABLET_PDF.md` (A–I bölümleri). Bu dosya onu nasıl ve hangi sırayla yapacağını söyler.

## Çalışma süreci (her adımda aynı döngü)

1. **Planla.** Adımı en fazla 3–5 alt göreve böl. Belirsiz bir kütüphane varsa önce `arastirmaci`'yı çağır.
2. **Uygula.** Her alt görev için `kodcu`'yu çağır. Birbirinden bağımsız görevleri paralel çağırabilirsin.
3. **Doğrula.** `flutter analyze` ve `flutter test` temiz olmalı. Arayüzle ilgili bir adımsa `tablet-testci` ile tablete kur, ekran görüntüsü ve ölçüm al.
4. **İncele.** `inceleyici`'yi çağır, ciddi bulguları düzelt.
5. **Kaydet.** Commit at (mesaj biçimi `v9.x: …`), sonra `docs/TABLET_RAPORU.md`'ye ekle: saat, adım, sonuç, ölçümler ve "Ahmet elle denesin" maddeleri.
6. Sonraki adıma geç. **Durma.**

## Kurallar

- Dal: `gece-1` dalından `tablet-1` aç. `git push` yasak.
- Sadece deneme paketi `com.kocum.kocum.gece`. Gerçek uygulamaya ve verisine dokunulmaz.
- Telefonun mevcut akışları (fotoğraf, optik, ML Kit, deneme) bozulmaz. Her adımda tüm testler geçmeli.
- **Modülerlik:** platforma özgü her şey arayüz arkasında durur (`InkSurface`, `PdfEngine`). Domain saf Dart olmalı. İleride iOS ve HarmonyOS için sadece bu uygulamalar değişecek.
- **Hafiflik:** model dosyası yok, gereksiz paket yok. Yeni paket ancak `arastirmaci` lisansı doğruladıktan sonra girer (MIT/BSD/Apache).
- 3 ciddi denemede çözülmeyen bir iş rapora yazılır, `git stash` ile saklanır ve sonraki adıma geçilir.
- Bağlam sıkıştırılırsa kaldığın yeri `TABLET_RAPORU.md` ve `git log`'dan bul.

## Adımlar

### T0: Ortam (YAPILDI: v9.0)
- Android SDK yoksa `~/Android/Sdk` altına komut satırı araçlarını kur (sudo kullanmadan), sonra `flutter doctor --android-licenses`.
- `tool/patch_android.dart`: debug derlemeye `applicationIdSuffix ".gece"` ekle, uygulama adı "Koçum (deneme)". Testiyle birlikte.
- Tableti doğrula: `adb devices`, `adb shell getprop ro.build.version.sdk`, `adb shell wm size`.
- Tablette deneme sürümü açılsın. Ekran görüntüsü al.

### T1: Kalem gecikmesi prototipi (en önemli adım) (YAPILDI: v9.1)
- Dart arayüzü: `InkSurface`. Çizgi başladı, nokta eklendi, çizgi bitti olayları; araç, renk, kalınlık ayarı.
- **A uygulaması (Android yerel):** Jetpack Ink (`androidx.ink`), düşük gecikmeli çizim (`androidx.graphics` front buffer) ve hareket tahmini (`androidx.input` MotionEventPredictor). Flutter'a PlatformView olarak gömülür. Kod `tool/patch_android.dart` düzenine uygun eklenir.
- **B uygulaması (saf Flutter):** `perfect_freehand` ve CustomPainter, biten çizgiler resim olarak önbellekte.
- Her iki uygulama giriş anından kareye geçen süreyi `KocumInk` etiketiyle logcat'e yazar.
- Bir deneme ekranı: A ve B arasında geçiş düğmesi olsun.
- `tablet-testci` ile ölç. Seçimi şuna göre yap: A belirgin şekilde daha iyiyse Android'de A, diğer platformlarda B. Ahmet'in hissi son karardır: rapora "A/B elle karşılaştır" yaz, şimdilik ölçüme göre devam et.
- Kalem çizer, parmak kaydırır ve yakınlaştırır. Avuç içi yok sayılır.

### T2: Çizgi verisi (YAPILDI: v15 göçü, `ink_strokes`, `stroke_codec.dart`, `InkStrokeRepository`)
- Çizgi tablosu (`ink_strokes`): her nokta x, y (sayfa ya da not koordinatı), baskı, eğim, zaman farkı (ms). Çizginin başlangıç zamanı ve süresi. Ayrıca katman, deneme no, araç, renk, kalınlık.
- Noktalar sıkıştırılmış ikili olarak saklanır (delta + varint). Kodlayıcı ve çözücü saf Dart, round-trip testli.
- Tablo değişiklik defterine (senkron) girsin. Şema göçü eski sürümlerden test edilsin.

### T3: PDF kitaplığı ve okuyucu (YAPILDI: v9.3 + v9.4)
- `pdfrx` (lisansı ve API'si `arastirmaci` ile doğrulanacak). PDF içe aktarma, sha256 ile tanıma, kitaplıktaki kitapla eşleme, sayfa ofseti.
- Okuyucu: sayfa kaydırma, yakınlaştırma, küçük resimler. Üstünde InkSurface katmanı. Koordinatlar sayfa koordinatında tutulur, yakınlaştırma ve döndürmede kaymaz (testli).
- 300+ sayfalık PDF'te bellek ve kaydırma akıcı olsun (`tablet-testci` ölçsün).

### T4: Soru = PDF koordinatı (YAPILDI: v9.5)
- "Soru seç" aracı: kalemle dikdörtgen çiz, soru kutusu kaydedilir (sayfa + kutu). Yanlış, boş ya da doğru olarak işaretlenir.
- Metin katmanı varsa kutudaki metin alınır, mevcut `page_reader` ve `auto_tags` ile ders, konu ve soru türü kendiliğinden dolar. Metin yoksa sayfa resme çizilip ML Kit ile okunur.
- Kart: `pdfDocumentId`, `pdfPage`, `pdfBox` alanları, ayrıca küçük bir WebP önizleme. Önizleme, PDF'i olmayan cihazlar (telefon) için.
- Defterde PDF kartı, fotoğraflı kartla aynı görünür.

### T5: Çözüm katmanları
- Her çözüm denemesi ayrı katman (attempt 1, 2, …). Soru temiz açılır.
- "Eski çözümü göster" seçeneği: saydamlık ayarlı ve istenen denemeyi seçerek. Ayrıca "yeniden çöz" ve "iki denemeyi üst üste bindir".
- Soru başına süre çizgi zamanlarından hesaplanır (saf fonksiyon, testli).

### T6: Not uygulaması (Samsung Notes temelleri)
- Defter → sayfa yapısı. Sayfa şablonu: düz, çizgili, kareli.
- Kalem türleri: tükenmez, dolma, kurşun, fosforlu. Baskı eğrisi (sertlik ayarı), renk paleti, kalınlık.
- Silgi: çizgi ve alan. Kement seçim, taşıma, boyut değiştirme. Geri al / yinele.
- Şekil düzeltme: çizip basılı tutunca düz çizgi, daire, elips, dörtgen ve üçgene dönüşür (saf geometri, model yok).
- Notlar Anlık etiketleri ve kişileriyle bağlanabilsin.

### T7: Senkron ve sade arayüz
- Çizgiler, PDF soruları ve notlar değişiklik defteriyle telefon ve bilgisayara gider. PDF dosyası sha256 ile bir kez aktarılır, isteğe bağlıdır.
- Tablet yerleşimi: sol kenarda kitaplık / defter / notlar, ortada içerik, üstte tek satırlık araç çubuğu. YKS öğrencisi için sade, gereksiz düğme yok.

## Sonraki sürümler (şimdi yapma)
El yazısında arama, yapay zekâ ile işaretlenen şıkkı ve çözüm yöntemini tahmin etme, iOS ve HarmonyOS uygulamaları.
