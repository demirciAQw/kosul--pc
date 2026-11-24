# Koçum: devir raporu (tablet + PDF + defter çalışması)

> **Bu belge kime?** Depoya dışarıdan bakan bir mühendis ya da yapay zekâ ajanına. Amaç: ne yapıldığını, **neden**
> öyle yapıldığını, nelerin **tamamlandığını**, nelerin **yarım ya da doğrulanmamış** kaldığını ve nereye bakarsanız
> kaliteyi en iyi değerlendireceğinizi tek yerde vermek.
>
> Dal: **`tablet-1`** (varsayılan dal `main` bu çalışmayı içermez). Son kararlı etiket: `v9.21` (commit `6d30d78`);
> üstüne bu belgenin eklendiği "WIP" commit'i gelir. Sürüm: `pubspec.yaml` → 9.21.x.
>
> Dürüstlük notu: çalışma büyük ölçüde **yapay zekâ alt ajanlarıyla** (kodcu / inceleyici / araştırmacı rolleri) ve
> **gerçek kalemli tabletle çok az doğrulamayla** yürüdü. "Test geçiyor" ≠ "tablette iyi çalışıyor". Aşağıda her
> özelliğin doğrulama düzeyi ayrıca belirtilmiştir (bkz. §3 ve §9).

---

## 1. Ürün ve kısıtlar

**Koçum**: YKS'ye hazırlanan bir öğrencinin **çevrimdışı** kişisel çalışma uygulaması. Flutter; Android (telefon ve
**tablet**) + Linux masaüstü. Sunucu, hesap ve bulut **yoktur**; veri cihazdadır. Arayüz, yorum ve commit mesajları
**Türkçe**.

Bu çalışmanın hedefi (görev dosyası `docs/TABLET_GOREVI.md`, tarif `docs/TABLET_PDF.md`): **Casper PAD H10** tablette
(Android 16/SDK 36, Dimensity 7050, 8 GB, 1600×2560, 4096 seviye basınçlı kalem, kalem aygıtı `goodix_ts.0,pen`)
çalışan sade bir **PDF + el yazısı not** uygulaması; telefon ve bilgisayarla senkron; telefon akışı bozulmadan.

Sabit kısıtlar (`CLAUDE.md`): domain saf Dart; yeni paket lisansı MIT/BSD/Apache (**GPL/AGPL alınmaz**); uygulama boyutu
önemli (model gömülmez); kullanıcı verisi sessizce silinmez; Android iskeleti depoda yok, **yalnız `tool/*_patch.dart`
ile** üretilir/yamalanır.

---

## 2. Nasıl çalıştırılır / doğrulanır

```bash
flutter pub get
# Android iskeleti yoksa: flutter create --org com.kocum --project-name kocum --platforms android /tmp/iskelet && cp -r /tmp/iskelet/android ./android
dart tool/patch_android.dart            # idempotent; imza, R8, izinler, ink, health, abi, gece
dart run build_runner build --delete-conflicting-outputs   # Drift kodu
flutter analyze                          # ~300 bilgi/uyarı var (çoğu deprecated material.dart); ERROR olmamalı
flutter test                             # ~1315 test; bkz. §8 "kararsız test"
flutter build apk --profile --target-platform android-arm64   # tablet deneme sürümü (AOT, paket com.kocum.kocum.gece)
flutter build apk --release --target-platform android-arm64  # gerçek paket com.kocum.kocum (tablete KURULMAZ)
flutter build linux --debug              # masaüstü
```

- **Deneme paketi**: debug ve **profile** derlemeleri `com.kocum.kocum.gece` ("Koçum (deneme)") kimliğiyle çıkar
  (`tool/gece_patch.dart`); gerçek uygulama/verisi (`com.kocum.kocum`) **hiç bozulmaz**. Tablette şimdiye dek debug
  (JIT, yavaş) denenmişti; hız için **profile** (AOT) kullanıldı (soğuk açılış 1,05 sn ölçüldü).
- APK yalnız **arm64-v8a** (`tool/abi_patch.dart`): ML Kit eklentileri x86_64/armeabi-v7a kitaplıklarını da getirdiği
  için profile 131→94 MB, release **63,5 MB**.
- CI: `.github/workflows/build-apk.yml`, `build-linux.yml` (Flutter **3.50.0** sabit; `pdfium` derlemede indirilir,
  ağ gerekir).

---

## 3. Özellik durumu (özet tablo)

Doğrulama düzeyi: **T** = otomatik test var · **C** = gerçek cihazda (tablet) görüldü · **—** = hiç denenmedi.

| Alan | Durum | T | C | Not |
|---|---|---|---|---|
| Deneme paketi `.gece`, profile APK | tam | ✓ | ✓ | `tool/gece_patch.dart` |
| Kalem yüzeyi A (yerel `androidx.ink`) | **kısmen** | ✓ | ✓ (eski sürüm) | yalnız "Kalem denemesi" ekranında; defter/PDF'e **bağlı değil**; silgi yok |
| Kalem yüzeyi B (saf Flutter) | tam | ✓ | ✓ | defter ve PDF bunu kullanır; gecikme hissi sorunlu (kullanıcı) |
| Çizgi verisi + ikili kodlayıcı (şema 15) | tam | ✓ | ✓ | delta+zigzag+varint |
| PDF motoru (`pdfrx`), kitaplık, okuyucu | tam | ✓ | ✓ | `PdfEngine` arayüzü, pdfrx tek dosyada |
| Soru = PDF koordinatı + önizleme | tam | ✓ | kısmen | kart bir PDF sorusu olarak göründü |
| Çözüm katmanları, süre | tam | ✓ | — | deneme katmanları, `solveDuration` |
| Not defteri: kalemler, silgi, kement, şekil | tam | ✓ | kısmen | `pen_profiles`, `eraser`, `lasso`, `shape_recognizer` |
| Tablet yerleşimi, sol menü, odak modu | tam | ✓ | ✓ | `lib/app/tablet*.dart` |
| Çoklu cihaz eşitleme (hub), PDF aktarımı | tam | ✓ | **—** | yalnız 127.0.0.1 testleri; gerçek Wi-Fi yok |
| Kitaplar raf görünümü, PDF'ten kitap ekleme | tam | ✓ | kısmen | otomatik doldurma sentetik denendi |
| Soru defteri eylem çubuğu (Düzenle/PDF'te aç/Çiz) | tam | ✓ | — | |
| Filigran temizleme + katmanlar (şema 20) | tam* | ✓ | **—** | *gerçek filigranlı PDF'te kalite hiç görülmedi |
| Kitap analiz modu PDF'te | tam | ✓ | — | |
| El yazısı → metin (ML Kit, şema 21) | tam* | ✓ | **—** | *doğruluk/çevrimdışılık/indirme hiç denenmedi |
| Sağlık verisi (Health Connect, Huawei ZIP; şema 22) | **kısmen** | ✓ | **—** | Huawei kaynağı/ZIP şeması **doğrulanmadı** |
| Kalem/avuç koruması (mesafe, geriye dönük, iptal=bitir) | **kısmen** | ✓ | **—** | eşikler tahmin; tanı günlüğü var |
| Defter klasörleri + konu eşleme (şema 23) | tam | ✓ | — | arayüz testli, cihazda yok |
| Pano (zihin haritası) | tam | ✓ | — | cihazda yok |
| Sayfa editörü: metin kutusu, foto, alt sayfa, serbest yuva, zum %6000 | **YARIM** | kısmen | **—** | bkz. §7; ajan yarıda kesildi |

---

## 4. Mimari

- **Katmanlar**: `lib/features/<özellik>/{domain,data,presentation}`. Domain saf Dart. Riverpod 3 (durum), Drift/SQLite
  (veri), go_router (gezinme). Ortak: `lib/core/` (database, ledger, media, export, text, notifications, di).
- **Platform**: `lib/main.dart` tek dalla `lib/desktop/` köküne geçer; platform kontrolü yalnız `lib/app/platform.dart`.
  Tablet algısı: `lib/app/tablet.dart` (`isTabletLayout`: Android + kısa kenar ≥ 600 dp).
- **Veritabanı**: `lib/core/database/` (`tables.dart`, `app_database.dart`, `health_tables.dart`), **`schemaVersion = 23`**.
  Göç kuralı: yeni tablo `from < N`, yeni sütun `PRAGMA table_info` korumalı (eski tüm yollardan test: 14/17/19/20/22→23).
- **Değişiklik defteri (ledger)** `lib/core/ledger/`: her **senkron tablosu** SQLite tetikleyicileriyle deftere yazılır
  (HLC saati, kaynak etiketi, geri alma, çakışma). BLOB sütunları `hex()` ile taşınır. **Defter dışı** tablolar
  (`ledgerExcludedTables`): MEB konu ağacı (`curriculum_nodes`) ve **sağlık tabloları** (hassas).
- **Eşitleme** (`lib/features/sync/`, `lib/desktop/sync/`): bilgisayar **merkez**; en çok 4 telefon/tablet **aynı anda**
  eşleşir (kendi anahtar/oturum/sıra sayacı). HMAC imzalı, yerel ağ, Diffie-Hellman eşleşme. "Genel okuma yok";
  **üç dar istisna**: `fotograf-al`, imzalı gövdesiz "PDF özeti var mı?", `pdf-al`. Yeni cihaz bilgisayardaki tüm güncel
  satırları "tam durum" ile alır. Ayrıntı: `docs/KABLOSUZ_AKTARIM.md`, `CLAUDE.md` "Kablosuz aktarım".
- **Android yama sistemi**: `android/` depoda yok. `tool/patch_android.dart` şu saf/idempotent/testli yamaları çağırır:
  `gece_patch` (paket kimliği), `ink_patch` (androidx.ink + Kotlin `KocumInk`), `health_patch` (Health Connect kanalı),
  `abi_patch` (yalnız arm64), `genai_patch`, `camera_patch`, `network_patch`, `r8_patch`.
- **Masaüstü**: Linux hedefi; sağlık/el yazısı tanıma yoktur (`Unsupported*`), kayıtlı el yazısı metni görünür/aranır.

### 4.1 Veritabanı tabloları (bu çalışmayla eklenenler)

| Şema | Tablo / değişiklik | Amaç |
|---|---|---|
| 15 | `ink_strokes` | kalem çizgisi: nokta BLOB (delta+zigzag+varint), katman, deneme, araç, renk, kalınlık |
| 16 | `pdf_documents` | PDF kaydı; **id = sha256**; `bookId`, `pageOffset`; PDF dosyası senkron EDİLMEZ (yalnız satır) |
| 17 | `question_cards` + `pdf_document_id,pdf_page,pdf_box_*` | soru = PDF koordinatı (+ ~480 px önizleme `questionImage`) |
| 18 | `ink_strokes.question_id` | çözüm denemeleri |
| 19 | `ink_notebooks`, `ink_note_pages`, `ink_notebook_tags/people`, `ink_page_tags/people` | defter → sayfa |
| 20 | `pdf_page_layers` | yıkıcı olmayan filigran/örtü katmanları |
| 21 | `ink_page_text` | el yazısı → metin (**türev** veri; çizgiye dokunulmaz) |
| 22 | `saglik_gunluk`, `saglik_stres`, `saglik_uyku_oturum` | sağlık (defter dışı, hassas) |
| 23 | `ink_folders`, `ink_page_links`, `ink_page_items`; `ink_notebooks.folderId`; sayfada `title,konuId,parentPageId,boardX|Y|W|H` | klasör, pano, metin/görsel öğeleri |

Kullanılan kimlik/koordinat sözleşmeleri: PDF çizgisi/kutusu **PDF sayfa birimi**, sol-üst, y aşağı; not sayfası
**not birimi** (genişlik 1404). Fotoğraflı soru kartında çizgi koordinatı görüntü genişliği = 1000 birim.

---

## 5. Kronoloji: ne yapıldı, neden

Her adımda döngü: planla → `kodcu` ajanı uygular → test/analiz/derleme → **bağımsız `inceleyici` ajanı** → bulgular
düzeltilir → commit → `docs/TABLET_RAPORU.md`'ye not. (Ayrıntılı günlük ve "elle denesin" listeleri o dosyadadır.)

- **v9.0 (T0)**: `.gece` deneme paketi (gerçek uygulamaya dokunmamak için).
- **v9.1 (T1) kalem gecikmesi**: ortak `InkSurface` arayüzü; **A** = yerel `androidx.ink` (PlatformView), **B** = saf
  Flutter (`perfect_freehand`). Neden iki: gecikmeyi ölçerek seçmek. *Ölçüm hiç yapılamadı* (tablet çoğu zaman
  yetkisizdi); kullanıcı sonradan "A kullanılabilir değil, B'de de gecikme var; A'yı geliştirelim" dedi.
- **v9.2 (T2) çizgi verisi**: ikili kodlayıcı; **ledger BLOB hatası** bulundu/düzeltildi (`json_object` BLOB taşıyamıyordu).
- **v9.3 (T3a) PDF**: `pdfrx` 3.1.0 (MIT; PDFium derlemede indirilir). `id = sha256` kararı: iki cihazda aynı PDF aynı satır.
- **v9.4 (T3b) okuyucu**: kalem çizer / parmak kaydırır-yakınlaştırır / avuç yutulur; çizgiler sayfa koordinatında.
- **v9.5 (T4)**: "Soru seç" aracı; kutu metninden `page_reader` + `auto_tags` ile ders/konu önerisi; metin yoksa ML Kit.
- **v9.6 (T5)**: her çözüm denemesi ayrı katman; `solveDuration` (çizgi zamanlarından, 30 sn boşluk sayılmaz).
- **v9.7–9.9 (T6)**: saf geometri (kalem profilleri `p^gamma`, çizgi/alan silgisi, kement, şekil düzeltme), defter→sayfa
  verisi, arayüz, kement/şekil/etiket.
- **v9.10 (T7)**: çoklu cihaz hub, PDF aktarımı, tablet yerleşimi.
- **v9.11–9.14**: tabletten gelen kullanıcı geri bildirimiyle: zum, şablon/boyut seçimi, sonsuz sayfa, yuva 4 kenar, kısmi
  silgi, PDF'te aynı araçlar, tam sol menü ("Daha fazla" kaldırıldı), kitap rafı. **Kök neden bulgusu**: avuç süzgeci
  `radiusMajor >= 24` her **parmağı** (gerçek 75–143) avuç sayıp yutuyordu → parmakla zum hiç çalışmıyordu; eşik 260.
- **v9.15–9.19**: çoklu cihaz+tam durum+`pdf-al`; açılış hızı (ertelenen başlatmalar, `KocumStart` izi, profile `.gece`);
  PDF içe aktarma penceresi + kitap formu otomatik doldurma; soru defteri eylemleri; **filigran katmanları**; **kitap
  analiz modu PDF'te**; **el yazısı → metin** (ML Kit); arm64-only boyut yaması.
- **v9.20 sağlık**: Health Connect (Kotlin kanalı, `health` paketi *kullanılmadı*), Huawei ZIP içe aktarma, elle stres.
- **v9.21**: yerel kalem iyileştirmeleri; kalem/avuç dayanıklılığı; defter veri katmanı (şema 23).
- **WIP (bu commit)**: Pano, klasörler/konu eşleme (tamam+testli); sayfa editörü öğeleri (yarım, §7).

---

## 6. Önemli kararlar ve gerekçeleri

1. **İki kalem yüzeyi (A/B) arkasında `InkSurface`**: iOS/HarmonyOS için yalnız yeni uygulama yazılsın. Seçim ölçüme bırakıldı (yapılamadı).
2. **Hybrid composition kalemi bozar**: Flutter dokunuşu yerel görünüme sentetik iletir; bu yüzden defter/PDF'te **B** kullanılır
   ve A yalnız deneme ekranında. A'da ön tampon (`InProgressStrokesView`) **kaldırıldı** (devam eden çizgi "yukarıda
   çizilip yerine oturuyordu"); çizgi aynı görünümde `onDraw` ile çizilir (gecikme biraz artabilir, ölçülmedi).
3. **Tahmin (`MotionEventPredictor`) hıza göre sınırlanır** (`predict_limit.dart`, Kotlin'de aynı sınıf): durunca sıfır,
   üst sınır 24 dp.
4. **Avuç reddi** (`palm_rejector.dart`, `pdf_ink_input.dart`, `pdf_ink_session.dart`): (a) kalem aşağıdayken tüm
   dokunuşlar yutulur; (b) kalem havadayken yalnız **kaleme yakın** (≤350 px) ya da büyük (≥260) temas; uzaktaki parmak ve iki
   parmak zum serbest; (c) **geriye dönük**: avuç önce gelip sayfayı kaydırdıysa kalem hover/DOWN'da dönüşüm **geri alınır**;
   (d) **kalem `PointerCancel` çizgiyi ATMAZ, kaydeder** (Goodix avuçta iptal gönderiyor olabilir — *doğrulanmadı*).
   Tüm eşikler **tahmin**; `Ayarlar > Araçlar > Kalem giriş tanısı` açılıp `adb logcat -s flutter | grep KocumPen` ile veri toplanır.
5. **Filigran = yıkıcı olmayan görüntüleme katmanı**: PDF dosyası ve soru verisi değişmez. Algoritma `tone ± toneRange`
   bandında yumuşak eşik; geniş dolgu/ince ızgara/renkli içerik korunur (incelemede bulunan içerik kaybı düzeltildi);
   kalıcı soru önizlemesi **katmansız** (anahtarla katmanlı). Kalem çizgileri her zaman katmanların üstünde.
6. **Sağlık verisi hassas**: defter/eşitleme/masaüstü birleştirme **dışında**; Claude raporuna yalnız açık anahtarla;
   yedek ZIP tüm veritabanı olduğundan sağlık verisi yedeğe girer (arayüzde yazılı). `health` paketi yerine Kotlin kanalı:
   paket compileSdk 37/AGP 9.1+/FlutterFragmentActivity ister, burada SDK 36.
7. **El yazısı**: Casper/Android sistem el yazısı motoru yalnız **canlı** kalemle yazı kutusuna çalışır, kayıtlı çizgiyi
   alamaz. Seçilen: **ML Kit Digital Ink** (MIT, `tr-TR`, ~20 MB model **indirilir**, gömülmez). Metin türev veridir.
8. **PDF'te `id = sha256`**, dosya senkronu isteğe bağlı/varsayılan kapalı, "listeleme yok" kuralı korunarak üç dar istisna.
9. **Tablet menüsü**: "Daha fazla" kaldırıldı; kalıcı 232 dp gruplu menü (daraltılınca 96 dp ikon rayı).
10. **Çalışma disiplini**: `git stash/checkout/reset` ve toplu `dart format` ajanlara yasaklandı (birbirlerinin dosyalarını
    bozdular); dosya sahipliği ajan başına ayrıldı.

---

## 7. Eksikler, yarım kalanlar ve bilinen sorunlar (öncelik sırasıyla)

### 7.1 Yarım: sayfa editörü öğeleri (en kritik "tam olmayan" iş)
`NotePageEditor` için hedef (kullanıcı): serbest sürüklenen yuva, **%6000 zum**, oturumda şablon/arka plan anında,
**metin kutusu**, **fotoğraf**, **sayfa içinde istenen yerde alt sayfa**, editörde zum <%12'de "Panoya geç" çipi.
Kodda var olanlar: `NotePageEditor.maxZoom=60`, `dock_placement.dart` (serbest yuva), `page_items_controller.dart`,
`page_items_layer.dart`, `text_item_widget.dart`, `image_item_widget.dart`, `item_toolbar.dart`, `page_image_picker.dart`,
`domain/page_item_ops.dart`, editörde `createChildPage` çağrısı, `note-to-board` çipi. Uygulama derleniyor ve eski
testler geçiyor, **ama**: (a) bu özelliklere ait **widget/uçtan uca testler eksik** (yalnız `page_item_ops_test`);
(b) ajan "editörü yeniden yazarken" bir ağ (TLS) hatasıyla koptu — **tutarlılık için editör baştan gözden geçirilmeli**;
(c) metin klavye girişi, kamera/galeri seçimi, alt sayfa düğümü sürükleme/silme **hiç çalıştırılmadı**; (d) görsel
önbelleği/bellek yönetimi doğrulanmadı.

### 7.2 Hiç tablette doğrulanmadı (kod var, görülmedi)
Kalem hissi ve gecikme (A ve B); avuç eşikleri (260/350/600) ve Goodix'in avuçta ACTION_CANCEL gönderdiği varsayımı;
yerel (A) kalemde parmakla zum akıcılığı ve yukarı-kayma düzeltmesi; ML Kit Türkçe doğruluk, model indirme ve çevrimdışı
çalışma; Health Connect izin akışı; filigran kalitesi/performansı (gerçek filigranlı PDF); 300+ sayfalık PDF belleği;
Pano 100+ sayfa performansı; WebP önizleme (Android'de üretiliyor); release (R8) paketin çalışması (yalnız derlendi).

### 7.3 Bilinen eksikler
- **A (yerel kalem) defter/PDF'e bağlı değil**; silgi yok. Karar kullanıcıya/ölçüme bağlı.
- **Huawei Sağlık**: Health Connect'e yazdığı doğrulanamadı; **stres Health Connect'te yok**; Huawei ZIP **şeması bilinmiyor**
  (tahminli ayrıştırıcı, sentetik testlerle). `kocum` CLI'de sağlık komutu yok; masaüstünde ZIP içe aktarma yok.
- **Eşitleme**: istekteki defter kimliği (`req.device`) eşleşme kimliğine bağlı değil (belgelendi); `PRAGMA foreign_keys`
  bağlantı geneli (snapshot sırasında); telefon↔tablet doğrudan eşleşme yok (bilgisayar merkez); eski v9.14 eşleşmeler
  tam durumu kendiliğinden almaz.
- **El yazısı**: eklenti indirme yüzdesi/iptal vermiyor; matematik/şekil güvenilmez; satır gruplama eşikleri sentetik.
- **Filigran**: eşitlemeyle gelen katman panel açılınca/sayfa değişince görünür (canlı akış kilitlenme yaptığı için kapalı);
  çözüm ekranı katman değişimini canlı izlemez; ton aralığı yalnız alt sınırı belirler; soru önizlemesine çizgi işlenmez.
- **PDF**: PDF meta (Title/Author) motordan beslenmiyor (otomatik doldurma metinden); "PDF'ten yeniden seç" yok; döndürülmüş
  sayfada metin kutusu yalnız testle (`/Rotate 90`).
- **Defter**: Drift akış önbelleği anahtarı yalnız SQL metni (`watchNotebooks`/`watchPages` aynı düz `SELECT` → karışabilir);
  klasör sıralama arayüzü ve sürükle-bırak taşıma yok; "bu konunun defter sayfaları" soru kartı/kitap haritasında yok
  (yalnız Defterler "Konuya göre" sekmesi); **gerçek sonsuz tuval yok** (sayfa yüksekliği ≥4300 = "sonsuz", üst sınır 200000).
- **Tablet menüsü**: Optik, "Hazır kitap ekle/JSON şablon", "Silme önerileri", "Claude raporu" için **ayrı rota yok**
  (ilgili ekranların içinden ulaşılır).
- **Soru defteri**: gruplu liste görünümünde dokunma hâlâ ayrıntı ekranı açar (görüntüleyici değil).

### 7.4 Kod kalitesi / mühendislik borcu
- `flutter analyze`: ~300 bilgi/uyarı (deprecated `material.dart` → `material_ui`, `prefer_single_quotes`), 1 deneysel
  `TableMigration` uyarısı. **Hata yok.**
- Çok büyük dosyalar: `note_tool_dock.dart`, `pdf_ink_session.dart`, `pdf_reader_page.dart`, `note_page_editor.dart`,
  `add_question_screen.dart` (bölünmeli).
- **Kararsız test**: tam `flutter test` koşusunda `test/notes_ink/notes_ui_test.dart` "defter listesi" grubundan 4 test
  **nadiren takılır** ("did not complete"); aynı grup **tek başına geçer** (~7 sn). Neden: testler arası etkileşim / Drift
  akış kapanışı (`db.close` takılması). Çözüm olarak widget ağacını `pumpWidget(SizedBox)` ile boşaltıp `runAsync` ile
  beklemek kullanıldı; kök neden tam çözülmedi.
- `dart format` bazı dosyalarda satır gürültüsü bıraktı (anlamsal değişiklik yok).
- Test kapsamı kod satırının ~%25'i (28 bin test / 117 bin lib satırı); UI testleri sentetik olaylarla.

---

## 8. Testler ve kalite kapıları

~1315 test (141 dosya). Önemli gruplar: `test/ink*`, `test/pdf/**` (**gerçek PDFium** ile), `test/notes_ink/**`,
`test/sync_*` (gerçek sunucu+istemci, 127.0.0.1), `test/handwriting/**`, `test/health/**`, `test/tablet*_test.dart`,
`test/*_patch_test.dart` (Android yamaları). Göç testleri 14→23 yolları. Her adım sonrası `inceleyici` ajanı **veri kaybı**,
güvenlik ve gerileme açısından bağımsız inceledi; ciddi bulgular (ör. alan silgisi veri kaybı, eşitleme imleç kaybı,
filigran içerik silme, avuç eşiği) düzeltildi. **Bu incelemeler de model çıktısıdır**, insan incelemesi yerine geçmez.

---

## 9. Doğrulanmamış varsayımlar (dışarıdan bakan için en değerli liste)

1. Goodix dijitizer avuç değince kalem akışına `ACTION_CANCEL` gönderiyor (kalem iptali = bitir kararı bu şüpheye dayanır).
2. Gerçek avuç `radiusMajor` değeri (260 eşiği tahmin; parmak 75–143 ölçüldü).
3. ML Kit modelinin indirildikten sonra çevrimdışı çalıştığı.
4. Huawei Sağlık'ın Health Connect'e yazdığı (ikincil kaynaklar "yazmıyor" diyor; uygulamadaki "son 14 günü tara" tanısı gösterecek).
5. Huawei veri-isteği ZIP'inin içeriği (uyku/stres var mı, alan adları).
6. A'da ön tampon kaldırıldığında gecikmenin kabul edilebilir kalacağı.
7. `FlutterPageImageEncoder`'ın gerçek tablette çalıştığı (birim testte sahte).
8. Release (R8) paketin ML Kit digital ink/health connect ile çalıştığı (yalnız derleme doğrulandı).

---

## 10. Kod haritası (nereden başlamalı)

| Konu | Yer |
|---|---|
| Proje kuralları, tuzaklar | `CLAUDE.md` |
| Kronolojik günlük, "elle denesin" listeleri | `docs/TABLET_RAPORU.md` |
| Ürün tarifi (A–I) | `docs/TABLET_PDF.md` |
| Kablosuz aktarım ayrıntısı | `docs/KABLOSUZ_AKTARIM.md` |
| Kalem girişi (Flutter) | `lib/features/pdf/presentation/{pdf_ink_input,pdf_ink_session,pdf_page_ink_layer}.dart`, `lib/features/pdf/domain/palm_rejector.dart`, `lib/core/pen_diag*.dart` |
| Kalem yüzeyi A/B | `lib/features/ink/**`, `tool/ink_patch.dart` (Kotlin `KocumInk` şablonu) |
| Kalem/silgi/kement/şekil geometrisi | `lib/features/ink/domain/{pen_profiles,eraser,lasso,shape_recognizer,hold_detector,predict_limit}.dart` |
| PDF | `lib/features/pdf/**` (`data/pdfrx_engine.dart` tek pdfrx girişi; `domain/watermark.dart`, `book_analysis.dart`, `book_autofill.dart`) |
| Defter | `lib/features/notes/**` (`ink_board_screen.dart` Pano, `notebooks_screen.dart` klasörler, `note_page_editor.dart` editör) |
| El yazısı → metin | `lib/features/handwriting/**` |
| Sağlık | `lib/features/health/**`, `tool/health_patch.dart` |
| Eşitleme | `lib/features/sync/**`, `lib/desktop/sync/**`, `lib/core/ledger/**` |
| Tablet kabuğu/menü | `lib/app/{tablet,tablet_menu,app_shell,router}.dart` |
| Veritabanı | `lib/core/database/**` |
| Android yamaları | `tool/*_patch.dart`, `tool/patch_android.dart` |

---

## 11. Bir dış inceleyicinin önerilen ilk adımları

1. `docs/DEVIR_RAPORU.md` (bu) → `CLAUDE.md` → `docs/TABLET_RAPORU.md`.
2. `flutter test` çalıştırın; takılırsa §7.4'teki kararsız testi tek başına koşun.
3. **Önce §7.1'i (yarım editör)** gözden geçirin: öğe/alt sayfa/metin/foto akışı için widget testleri yazın, bellek ve geri al davranışını doğrulayın.
4. Veri kaybı riski için şunlara bakın: `pdf_ink_session.dart` (silgi/kement/geri al/kayıt yeniden denemesi), `ledger_*` (BLOB hex, `applySnapshot`), `pdf_book_flow.dart` (tek işlem), kullanıcı verisini silen her yol (`softDelete*` yalnız bayrak).
5. Güvenlik için: `lib/desktop/sync/data/sync_server.dart` (imza, `pdf-al`, `_dbLock`, cihaz kimliği), sağlık tablolarının dışarı sızmadığı (`ledgerExcludedTables`, `skippedTables`).
6. Tablete erişiminiz varsa: §9'daki varsayımları `Kalem giriş tanısı` ve `adb logcat` ile doğrulayın; profile APK ile ölçün.
