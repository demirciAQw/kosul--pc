# Koçum: proje notları (Claude Code için)

YKS'ye hazırlanan bir öğrencinin kişisel çalışma uygulaması. Flutter, Android.
Veriler yalnızca telefonda (sunucu yok). Arayüz, yorumlar ve commit mesajları
**Türkçe**. Kullanıcı (geliştirici aynı zamanda öğrenci) kısa, sade Türkçe ister.

**Sıradaki büyük iş:** tablet + PDF modu. Ayrıntılı tarif:
[`docs/TABLET_PDF.md`](docs/TABLET_PDF.md). Telefon akışı bozulmadan eklenir.
Aynı belgede **I. Benzer sorularda gelişim** ("bu hatayı öğrendim mi?") hem
telefon (konu düzeyi) hem tablet (soru düzeyi) için tarif edilmiştir.

## Mimari

- Riverpod (durum), Drift/SQLite (veritabanı), go_router (gezinme).
- Özellik klasörleri `lib/features/<özellik>/{domain,data,presentation}`.
  Domain saf Dart: test edilebilir, Flutter'a bağlı değil.
- Ortak: `lib/core/` (database, media, export, text, notifications, di).
- Önemli yerler:
  - `core/database/` tablolar ve göçler (`schemaVersion` şu an 19)
  - `core/ledger/` değişiklik defteri: HLC, SQLite tetikleyicileri, uygulama/çakışma/geri alma
    (`LedgerService`). Her senkron tablosu tetikleyiciyle deftere yazılır; ayrıntı
    `docs/KABLOSUZ_AKTARIM.md`
  - `features/anlik/` anlık notlar, ortak etiketler, kişiler (`((etiket))`, `@kişi`)
  - `features/ledger/` Claude'un değişiklikleri, çakışmalar, silme önerileri ekranları
  - `lib/cli/` + `bin/kocum.dart`: Claude'un veriye eli (`docs/KOCUM_ARACI.md`)
  - `lib/desktop/entry/` bilgisayarda veri girişi sayfaları (soru, kitaplar, optik,
    denemeler, oturumlar, planlar)
  - `features/question_bank/` soru kartları, defter, optik, akıllı arama
  - `features/ocr/` fotoğraftan okuma (ML Kit), sayfa okuyucu
    (`domain/reader/page_reader.dart`: soru, kök, öncül, şık; konuma göre),
    şekil bulucu (`figure_detector.dart`), otomatik etiket (`auto_tags.dart`,
    sözlük `assets/meb/konu_sozlugu.json`)
  - `features/dashboard/` derin analiz, soru kökü analizi, Claude raporu
  - `features/library/` kitaplar ve kitap haritası (şablonlar `assets/templates/`)
  - `features/mock_exam/` denemeler, karne PDF içe aktarma
  - `core/media/` fotoğraf akışı: çekim, kırpma, arka planda sıkıştırma,
    uygulama içi hızlı kamera (performans modu)
- Android projesi depoda **yok**; derlemede `flutter create` ile üretilir ve
  `tool/patch_android.dart` ile ayarlanır (imza, R8 kuralları, izinler, GenAI
  köprüsü). Android'e ait her değişiklik bu betikten yapılır, testli saf
  fonksiyonlar `tool/*_patch.dart` içinde.

## Komutlar

```bash
flutter pub get
# Android iskeleti yoksa (bir kez):
flutter create --org com.kocum --project-name kocum --platforms android /tmp/iskelet
cp -r /tmp/iskelet/android ./android
dart tool/patch_android.dart
dart run build_runner build --delete-conflicting-outputs   # Drift kodu
flutter analyze
flutter test                                              # derlemeyi kapılar
flutter build apk --release --target-platform android-arm64
```

CI (`.github/workflows`) aynı adımları izler; **testler geçmezse APK üretilmez**.

### Bilgisayar uygulaması (Linux)

Aynı depo, Flutter Linux hedefi. `lib/main.dart` tek dalla `lib/desktop/`
köküne geçer; platform kontrolü YALNIZCA `lib/app/platform.dart`'ta.

Kısa yol: `tool/setup_linux.sh` (iskelet + paketler + kod), `tool/install_linux.sh`
(menüye kurar). CI: `.github/workflows/build-linux.yml`. Ayrıntı: `docs/MASAUSTU.md`.

```bash
flutter config --no-enable-android --no-enable-web --enable-linux-desktop
flutter create --org com.kocum --project-name kocum --platforms linux /tmp/iskelet  # linux/ yoksa
cp -r /tmp/iskelet/linux ./linux
flutter run -d linux
flutter build linux --release      # build/linux/x64/release/bundle/kocum
```

- Veriler `~/.local/share/<uygulama kimliği>/` altında (Belgeler'e yazılmaz).
- Telefon verisi yedek ZIP'indeki `kocum.db` ile satır satır birleşir
  (`lib/desktop/import/`): telefon kazanır, hiçbir şey sessizce silinmez,
  `app_meta` alınmaz. Bilgisayarın kendi ayarları `app_meta`'da `masaustu.`
  önekiyle.
- Masaüstünde telefonun arka plan işleri (metin okuma, kamera, hatırlatıcı)
  başlamaz; masaüstü ekranları `sessionChronometerProvider` ve
  `reminderServiceProvider` okumamalı (override edilmezler).
- Yeni paket eklerken Android derlemesini de düşün: `pubspec.yaml` ortaktır.

### Kablosuz aktarım (telefon → bilgisayar, yerel ağ)

- Ortak sözleşme ve kurallar `lib/features/sync/domain/` (saf Dart);
  telefon istemcisi `lib/features/sync/data/`, bilgisayar sunucusu
  `lib/desktop/sync/data/sync_server.dart`. Yeni paket yok; `crypto`
  (HMAC/SHA-256) zaten `uuid` üzerinden gelir.
- Eşleştirme: bilgisayar ekranında 6 haneli tek seferlik kod (5 dk, 5 hak).
  Anahtar Diffie-Hellman (RFC 7919 ffdhe2048) + kodla iki tarafta ayrı
  hesaplanır, ağdan geçmez. Her istek HMAC imzalı ve sıra numaralı.
- Kısıtlar: en fazla bir telefon (ya da tablet) ve bir bilgisayar; yalnızca Android telefon/tablet
  eşleşir, yalnızca Linux bilgisayar alır; yalnızca yerel ağ adresleri
  (100.64/10 ve 127.0.0.1 hayır); tarayıcı başlıkları ve alan adıyla Host
  reddedilir; yalnızca `questions|solutions|notes/yyyy/mm/ad.uzantı`
  fotoğrafları yazılır. Genel okuma/listeleme isteği yoktur; yalnızca iki dar istisna
  var: `fotograf-al` (bilgisayarın defterinde geçen, kurala uyan tek fotoğraf) ve
  imzalı, gövdesiz "bu PDF özeti var mı?" sorusu (tek özet, imza şart).
- Merkez: bilgisayar telefon ve tablet arasında aracıdır (doğrudan telefon↔tablet
  eşleşme YOK). Tek eşleşme yuvası: cihazlar sırayla gezer; bilgisayar aldığı
  satırları özgün kimlikle öbürüne de verir (`pendingFor(relayExcept:)`).
  Testi `test/sync_hub_test.dart`. Sınır: ilk tam yedekle gelen eski veri deftere
  girmediği için sonradan eşleşen öbür cihaza gitmez.
- PDF dosyası (isteğe bağlı, ayar varsayılan KAPALI, yalnızca telefon/tablet → bilgisayar):
  `PUT /kocum/v1/pdf`, ad `^[0-9a-f]{64}\.pdf$`, `pdfs/<sha256>.pdf`, sha256 iki uçta,
  300 MB sınırı, `.part`+atomik ad, gövdesiz PUT = "bu özet var mı". Test `test/sync_pdf_test.dart`.
- Anahtarlar veritabanında değil ayrı dosyada (`esitleme.json`): telefonun
  veritabanı kopyası bilgisayara ve yedeklere gider, anahtar gitmemeli.
- Veri içeriği şifrelenmez (yalnızca imzalı); ortak Wi-Fi için uyarı var.
- Testler `test/sync_*_test.dart`: gerçek sunucu ve istemci 127.0.0.1'de;
  geri döngü yalnızca `allowLoopback: true` ile açılır.
- Android'de INTERNET izni `tool/network_patch.dart` ile eklenir.

## Kurallar

- Her özellik testle gelir; domain mantığı saf fonksiyonlarda.
- Değişiklikten sonra `flutter analyze` ve `flutter test` temiz olmalı.
- Sürüm: `pubspec.yaml` `version` artırılır; commit mesajı sürüm notudur
  (ör. `v8.2: …` ve altında maddeler).
- Veritabanı göçü: `schemaVersion` artır; eski sürümden gelen her yol düşünülür
  (ör. tablo `from < 10`'da yeni sütunlarla oluşur, sütun ekleme yalnızca
  `from == 10` için).
- Türkçe metin karşılaştırma ve arama için `core/text/turkish_text.dart`
  (`normalizeTr`, `titleCaseTr`); `toLowerCase()` "İ" için yanlış sonuç verir.
- Kullanıcı verisi asla sessizce silinmez; geçici dosyalar iş bitince silinir.
- Yeni bağımlılıklarda lisans kontrolü: MIT/BSD/Apache uygun; **GPL kod
  alınmaz** (ör. Saber uygulaması GPL; yalnızca fikir alınabilir).
- Uygulama boyutu önemli: model dosyası gömmekten kaçın.

## Bu projede yaşanmış tuzaklar

- **Drift `references(...)` kuralını SQL'e YAZMIYOR** (bu sürümde; üretimde 0 `REFERENCES`).
  Eski tablolarda `ON DELETE CASCADE/SET NULL` çalışmaz; silmeyi kod yapmalı.
  Yeni tablolarda `customConstraint('... REFERENCES t(id) ON DELETE CASCADE')` kullan.
- Senkron tablosu tek sütunlu birincil anahtar ister (`SnapshotMerger` ve defter `satirId`);
  bileşik anahtar yerine `id` sütunu + `uniqueKeys`.
- Tetikleyicinin yazdığı satırı ve `customStatement` ile yazılan tabloyu Drift'in akışları
  görmez: sonra `notifyUpdates` çağır (`LedgerService._flushTouched`).
- Dış araç ya da süreç yazacaksa `LedgerService.withSource(...)` içinde yaz (kaynak ve oturum).
- `AppDatabase(executor, [ledgerSource])`: masaüstü `'pc'`, telefon varsayılan `'telefon'`.
  `lib/core/database/` saf Dart kalmalı (`drift_flutter` içe aktarma; yoksa `dart run bin/kocum.dart` çalışmaz).
- Riverpod 3: dinleyicisi olmayan sağlayıcının akışı duraklar; testte `ProviderContainer.read(p.future)`
  takılabilir, widget ya da `listen` ile test et.
- Widget testinde Drift akışları gerçek zaman ister: `tester.runAsync(() => Future.delayed(...))`.

- `var y = math.max(0, …)` `num` çıkarabilir; tamsayı bağlamında
  `math.max<int>` / `math.min<int>` yaz.
- Koleksiyonlarda `?ifade` (null-aware element) yazımı kullanılmaz;
  `[a, b].whereType<T>()` ya da `if (x != null) x` kullan.
- Chip yazı rengi: `labelStyle` için durum stili değil, durum rengi
  (`WidgetStateColor`) ver; yoksa açık temada yazı kaybolur.
- R8: ML Kit bileşenleri yansıma ile bulunur; `tool/r8_patch.dart` koruma
  kurallarını yazar. Yeni ML Kit paketi eklenirse kurala eklenmeli.
- Dart `'''` dizgesi ilk boş satırı atar (şablon testlerinde dikkat).
- `Navigator.push` ile açılmış bir ekranın üstüne go_router sayfası itme;
  altında kalabilir. Optik gibi zorunlu ekranlarda `Navigator` kullan.
- Ekranda gezinme olmadan sağlayıcı izleyen kodda `ref.listenManual`
  ilk değeri kaçırabilir; gerekirse `fireImmediately: true`.

## Telefon uygulamasında olanlar (korunmalı)

Kitap haritası ve test bazlı optik; deneme ve karne PDF içe aktarma; yanlış
defteri (galeri/gruplu, akıllı arama, geçmiş); tekrar (aralıklı, benzer hatalar
öne); fotoğraftan okuma (yön, sütun, soru blokları, şıklar, şekil/grafik/
fotoğraf bölgeleri); otomatik konu ve soru türü etiketi; soru kökü analizi;
derin analiz; Claude raporu ve paketleri; dışa aktarma (PDF, xlsx, ZIP, yedek);
notlar; hatırlatıcılar; hızlı kamera; Gemini Nano köprüsü (cihaz desteklerse).
