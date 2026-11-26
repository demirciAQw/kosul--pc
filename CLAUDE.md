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
  - `core/database/` tablolar ve göçler (`schemaVersion` şu an 22)
  - `core/ledger/` değişiklik defteri: HLC, SQLite tetikleyicileri, uygulama/çakışma/geri alma
    (`LedgerService`). Her senkron tablosu tetikleyiciyle deftere yazılır; ayrıntı
    `docs/KABLOSUZ_AKTARIM.md`
  - `features/handwriting/` el yazısı -> metin (ML Kit Digital Ink, `tr-TR`, model ~20 MB ilk
    kullanımda indirilir, APK'ya gömülmez; yalnız Android, masaüstünde tanıyıcı `Unsupported`).
    Domain: satır gruplama (`line_grouping.dart`), tanıyıcı arayüzü, sayfa metni, `strokeSignature`.
    Metin `ink_page_text` tablosunda TÜREV veridir (id = sayfa kimliği); çizgilere dokunulmaz.
    Drift akış tuzağı: önbellek anahtarı yalnız SQL metni; düz `SELECT 1` akışları çakışır
  - `features/health/` sağlık verisi (şema 22; ayrıntı aşağıda "Sağlık verisi"): uyku/nabız/stres,
    Health Connect (Kotlin kanalı) + Huawei ZIP içe aktarma + elle stres. HASSAS: deftere ve
    kablosuz eşitlemeye girmez
  - `features/notes/` (v23, şema 23): defter klasörleri (`ink_folders`, defterde `folderId`), sayfa
    başlığı/`konuId` (MEB konu eşleme)/`parentPageId` (alt sayfa)/Pano konumu (`boardX|Y|W|H`),
    sayfa bağlantıları (`ink_page_links`: link|child|konu), sayfa öğeleri (`ink_page_items`: metin
    kutusu, görsel; görsel yolu AYRI `mediaPath` sütunu: JSON içinde kaçışlı kalırsa kablosuz aktarım
    fotoğrafı fark etmez). Depolar `notes/data/ink_{folder,board,page_item}_repository.dart`,
    `curriculum_notebook_service.dart`, `page_image_store.dart`; saf Dart `domain/board_layout.dart`,
    `page_item_geometry.dart`, `page_board.dart`. Görsel dosyası ASLA silinmez (öğe silinince de).
    Klasör silinince defter/alt klasör ebeveyne çıkar (gizlenmez). Ayrıntı `docs/TABLET_RAPORU.md` "T7 veri".
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
- Kısıtlar: bir alıcıya en çok 4 cihaz (`SyncLimits.maxDevices`), bir istemci en çok 4 eşle (`SyncLimits.maxPeers`);
  yalnızca Android telefon/tablet İSTEMCİ olarak eşleşir; ALICI Linux bilgisayar ya da (v9.23) EKRANI AÇIKKEN
  Android telefon/tablet olabilir (`acceptedComputerPlatforms = {linux, android}`; Windows yok). Gerekçe: her cihaz
  ayrı ayrı eşleşebilsin (telefon↔tablet, tablet↔bilgisayar, telefon↔bilgisayar); güvenlik kuralları aynı kalır
  (aynı `SyncServer`, aynı kod/imza/Host/yerel ağ denetimleri). Android alıcının ek sınırları: arka plan servisi YOK
  (`ReceiveController` ön plandayken dinler, `paused/hidden`da durur, eşleşmeler kalır), tam yedek ZIP'i almaz (404,
  `importBackup == null`); yalnızca yerel ağ adresleri
  (100.64/10 ve 127.0.0.1 hayır); tarayıcı başlıkları ve alan adıyla Host
  reddedilir; yalnızca `questions|solutions|notes/yyyy/mm/ad.uzantı`
  fotoğrafları yazılır. Genel okuma/listeleme isteği yoktur; yalnızca üç dar istisna
  var: `fotograf-al` (bilgisayarın defterinde ya da tam durum sayfalarında geçen, kurala
  uyan tek fotoğraf), imzalı gövdesiz "bu PDF özeti var mı?" sorusu (tek özet, imza şart)
  ve `pdf-al` (imzalı; ad `^[0-9a-f]{64}\.pdf$`; yalnızca bilgisayarın `pdf_documents`
  satırında geçen özet; 300 MB; symlink reddi). Gerekçe: üçü de istemcinin ZATEN bildiği
  tek bir kimliği ister (yol/özet), liste vermez, kimlik bilgisayarın kendi kaydında
  geçmiyorsa 404 (varlık sızmaz); `pdf-al` ayrıca adın SHA-256'sı ile istemcide doğrulanır.
- Çok eş (v9.23): bilgisayar tek merkez olmak zorunda değil. Her cihaz hem istemci hem alıcı olabilir
  ve en çok 4 eşe bağlanır (`PhoneSyncStore.computers()`, `esitleme.json` `esler:`; eski `bilgisayar:` kaydı
  göçer, `eskiImlec` bayrağı). Sunucu `features/sync/data/sync_server.dart` + `server_sync_store.dart` (ortak;
  `desktop/sync/data/*` yalnız `export`); Android alıcı deposu `alici.json` (istemci `esitleme.json`'dan ayrı,
  ikisi de veritabanı DIŞI). İmleçler EŞ BAŞINA (`gonderilen_sira:<eşKimliği>`, `alinan_sira:…`, tam durum
  anahtarları, `es_defter_kimligi:…`); istemci de ARACI olur (`LedgerSync(scope: eşKimliği)`: eşin kendi satırları
  hariç hepsi aktarılır, `relayExcept`). Yankı/döngü: kimlikten tekilleştirme (`degisiklikler.id`) + eşin kendi
  satırı süzgeci + uygulanan aralık `(from,to]` o eşe geri verilmez (`applyRemoteRanged`, aynı işlemde okunur;
  `pendingFor(skipAfter/skipUpTo)`); üçüncü yoldan gelen kopya yalnız bir kez "zaten vardı" olur. Android alıcıya
  tam durum iki yönlüdür (çek: `anlik`; ver: `anlikGonder` → `applySnapshot`, yalnız eksik satır, deftere işlenmez);
  tam durumla gelen satırlar deftere girmediği için başka eşe aktarılmaz. Yeni eş: `LedgerSync.markNewPeer`.
  Testler `test/sync_p2p_test.dart`, `test/sync_receive_controller_test.dart`.
- Merkez (v9.15 hâli, hâlâ geçerli kullanım): bilgisayar telefon ve tablet arasında aracı olabilir
  (doğrudan telefon↔tablet eşleşmesi v9.23'ten beri de mümkün, zorunlu değil). Çok cihaz (v9.15): en çok 4 cihaz AYNI ANDA eşleşik; her birinin kendi
  anahtarı, kimliği, oturumu (cihaz başına tek) ve sıra sayacı var (`SyncServer._sessions`,
  `DesktopSyncStore.devices()`); cihaz kaldırmak öbürlerini etkilemez, yeni cihaz eklemek
  kopartmaz. Eşzamanlı istekler sunucuda yalnızca veritabanı bölümünde sıraya girer
  (`_dbLock`). Eski tek cihaz `esitleme.json` (`telefon:`) okunurken `cihazlar:` listesine
  taşınır. Bilgisayar aldığı satırları özgün kimlikle öbürüne de verir
  (`pendingFor(relayExcept:)`). Testler `test/sync_hub_test.dart`, `test/sync_multi_device_test.dart`.
- Tam durum (v9.15): yeni eşleşen cihaz `LedgerRequest.snapshotCursor` ile bilgisayarın
  senkron tablolarındaki TÜM güncel satırları sayfa sayfa alır (`LedgerService.snapshotPage`,
  aynı imzalı `degisiklikler` alışverişi; yeni uç yok). Bu sırada defter geçmişi yeniden
  oynatılmaz; bitince `alinan_sira` bilgisayarın başlangıçtaki sırasına çekilir. Cihaz yalnızca
  EKSİK satırı ekler (`applySnapshot`: var olana dokunmaz, `sil` kaydı olan geri gelmez,
  deftere işlenmez). Bayrak: `keyNeedSnapshot`; yeni eşleşmede ve "Bilgisayardaki her şeyi
  yeniden al" düğmesinde kurulur. Eski (v9.14) eşleşmeler kendiliğinden almaz.
- PDF dosyası (isteğe bağlı, iki ayar da varsayılan KAPALI): cihaz → bilgisayar
  `PUT /kocum/v1/pdf` (ad `^[0-9a-f]{64}\.pdf$`, `pdfs/<sha256>.pdf`, sha256 iki uçta, 300 MB,
  `.part`+atomik ad, gövdesiz PUT = "bu özet var mı"; "PDF dosyalarını da gönder");
  bilgisayar → cihaz `POST /kocum/v1/pdf-al` ("PDF'leri bilgisayardan al"; `PdfPull`,
  kaldığı yerden devam, sha256 doğrulaması istemcide). Testler `test/sync_pdf_test.dart`,
  `test/sync_multi_device_test.dart` (`pdf-al` güvenlik testleri).
- Anahtarlar veritabanında değil ayrı dosyada (`esitleme.json`): telefonun
  veritabanı kopyası bilgisayara ve yedeklere gider, anahtar gitmemeli.
- Veri içeriği ŞİFRELİ (protokol sürüm 2, v9.23.1): ChaCha20-Poly1305 + HKDF, ileti başına anahtar, 64 KiB parçalı akış
  (`features/sync/domain/sync_cipher.dart`, `pointycastle` MIT); imza ve sıra korunur; eski sürümle şifresize düşülmez ("Diğer
  cihazı güncelleyin"). Düz kalanlar ve ayrıntı `docs/KABLOSUZ_AKTARIM.md` "Şifreleme (sürüm 2)". Ortak Wi-Fi'da üst veri görünür.
- Testler `test/sync_*_test.dart`: gerçek sunucu ve istemci 127.0.0.1'de;
  geri döngü yalnızca `allowLoopback: true` ile açılır.
- Android'de INTERNET izni `tool/network_patch.dart` ile eklenir.

### Sağlık verisi (v9.20, şema 22)

- Tablolar `saglik_gunluk` (gün+kaynak tekil), `saglik_stres` (kaynak+zaman tekil),
  `saglik_uyku_oturum` (kaynak+başlangıç tekil). Kümesi `core/database/health_tables.dart`
  (`healthTables`): `ledgerExcludedTables` (defter/senkron/tetikleyici yok) ve masaüstü
  `skippedTables` içinde (bilgisayara birleştirmede alınmaz). Yedek ZIP tüm veritabanı olduğundan
  sağlık verisi YEDEĞE girer (Ayarlar kartı bunu yazar). "Sağlık verisini sil" üç tabloyu + çakışma
  tercihlerini siler. Claude raporuna yalnız `saglik.rapora_dahil` (app_meta, varsayılan KAPALI) açıksa
  `healthSection` girer.
- Health Connect: `health` paketi KULLANILMADI (compileSdk 37 + AGP 9.1+ + FlutterFragmentActivity ister;
  burada yalnız android-36). Bunun yerine `tool/health_patch.dart` (saf, idempotent, testli) Kotlin kanalı
  `kocum/health` ekler (`androidx.health.connect:connect-client:1.1.0`, Apache-2.0; salt OKUMA izinleri,
  `<queries>`, rationale + `activity-alias`; `FlutterPlugin+ActivityAware`, MainActivity'ye tek satır).
  Dart tarafı soyut `HealthSource` (`HealthConnectSource`, `UnsupportedHealthSource` masaüstü,
  `FakeHealthSource` test). Health Connect'te STRES veri türü YOK.
- Huawei ZIP: şema BİLİNMİYOR. `domain/huawei_zip_parser.dart` önce yapı raporu (yalnız ad), sonra
  tahmine dayalı ayrıştırma; sentetik testlerle denendi, gerçek dosyayla DENENMEDİ. ZIP okuma
  `core/export/zip_reader.dart` (yeni paket yok); şifreli ZIP desteklenmez.
- Elle uyku ile saat uyku çakışırsa kullanıcıya sorulur (`saglik.uyku_tercih.<gün>`); hiçbir kayıt
  otomatik silinmez/üzerine yazılmaz.

## Claude entegrasyonu (v9.23)

İki ayrı yol; ikisinde de anahtar/veri sızmaz. Ayrıntı: `docs/CLAUDE_CODE.md`.

- **A. Bilgisayardaki Claude Code -> veri (yerel MCP):** `bin/kocum_mcp.dart` + `lib/mcp/` (saf Dart, yeni
  paket yok). STDIO, ağ yok, anahtar yok. Varsayılan SALT OKUMA (`query_only`); yazma araçları yalnız
  `--yaz` ile listelenir ve `LedgerService.withSource('claude')` içinden geçer (geri alınır). Ham SQL aracı
  YOK; sağlık tabloları hiçbir araçta okunmaz. Yeni araç eklerken: sabit parametreli sorgu, `saglik_*` yok.
- **B. Uygulama -> Claude API:** `features/claude_api/` (ham `dart:io` HTTP, SDK yok). İstek biçimi
  `domain/claude_request.dart` (thinking/temperature/top_p/top_k GÖNDERİLMEZ; reddetme yedeği varsayılan açık).
  SSE ayrıştırıcı saf (`domain/sse.dart`); `thinking` blokları yok sayılır; `refusal`/`max_tokens` kullanıcıya
  bildirilir. Rapor "Claude'a gönder": önce gönderilecek metnin AYNISI + açık onay.
- **Anahtar kuralları (ihlal etme):** anahtar YALNIZ `ApiKeyStore` ile saklanır (Android: Keystore AES/GCM +
  `noBackupFilesDir`, Kotlin kanalı `kocum/secure`, `tool/secure_store_patch.dart`; Linux: `~/.config/kocum/claude_anahtar`
  0600, geniş izinliyse okuma reddedilir). VERİTABANINDA, `app_meta`'da, yedek ZIP'te, kablosuz eşitlemede,
  Ayarlar durumunda YOK. Anahtar `ApiKey` sarmalayıcısındadır (`toString` = `ApiKey(***)`); ekranda yalnız
  `sk-ant-…` + son 4 hane. Hata/günlük satırına anahtar, istek gövdesi, yanıt metni YAZILMAZ (yalnız durum kodu +
  `request-id`); HTTP hata gövdesi hiç okunmaz; `print/debugPrint` yasak (`test/claude_api/claude_hygiene_test.dart`).
  Testte gerçek API'ye istek atılmaz (`ClaudeTransport` sahtesi).

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

## PDF katmanları

Katman = PDF sayfalarının üstünde kalemin yazdığı şeffaf çizim katmanı (PDF dosyası değişmez).
`pdf_page_layers.kind`: `full` (tüm sayfalar, `page=-1`) | `question` (sayfa + kutu); eski
`watermark`/`cover` satırları yok sayılır (silinmez). İKİ kimlik: GÖRÜNTÜ numarası (`number`,
silinmeyenler arasında `order` (params, yoksa z) sırasıyla 1..n; gezinme/numaralama) ve KALICI
anahtar (`key` = `z+1`; çizgiler `ink_strokes.layer` = key, 0 = ana çizim). Silme/sıra değişimi
anahtarı değiştirmez (`layerKeyForNumber`, `moveLayerOrders`). Silme YUMUŞAKTIR (`deleted`; çizgiler
silinmez, gizlenir; SnackBar "Geri al"). Tek durum: `PdfLayerState` (`pdfLayerStateProvider`).
YALNIZ AKTİF katmanın çizgileri görünür/silinir/seçilir (`PagePen._onlyLayer`, önbellekten süzülür;
ana çizim aktifken yalnız 0). UI: sol üst gezinme hapı `[◀][N][▶/+]` (`LayerNavPill`, N'ye uzun
basış: sil/öne/arkaya), yüzen yuvarlak bölge düğmesi (`RegionPickButton`; dokun = bölge seç, uzun bas
= taşı/sil; konum+gizli `app_meta` `pdf.bolge_dugmesi`, tüm PDF'lerde ortak; geri getirme Ayarlar'da),
soru katmanı küçük düğmesi (uzun bas = taşı/sil). Soru katmanı "ayrı pencere" çizgileri
`noteId='katman-pencere:<id>'` taşır; ana okuyucu bunları görmez (`InkStrokeRepository` `tag` süzgeci).
Kullanıcıya görünen metinde "filigran" geçmez, hep "katman".
