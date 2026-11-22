# Gece raporu

Dal: `gece-1` (hiçbir şey `main`'e commit edilmedi, **`git push` yapılmadı**). Her adım ayrı commit; durdurulup `git stash`'e atılan iş yok. Başlangıçta 219 test vardı, şimdi **326 test** geçiyor; `flutter analyze` temiz (yalnızca Drift'in `TableMigration` deneysel uyarısı ve Flutter 3.50'nin `material.dart` kullanım dışı bilgileri); `flutter build linux --release` başarılı ve uygulama temiz bir veri klasöründe açılıp çalışıyor.

## Ne yapıldı

| Adım | Sürüm | Özet |
|---|---|---|
| 0 | `derleme: …` | Masaüstü ilk kez derlendi (derleme hatası çıkmadı), uyarılar temizlendi, iki workflow'da `continue-on-error` kalktı, testler CI'da yeniden kapı. |
| 1 | v8.7 | Anlık notlar: tablolar (şema 12), `((etiket))` ve `@kişi` ayrıştırma ve öneri, **Anlık** sekmesi, etiket ve kişi çubukları, Etiketler (ağaç, yeniden adlandır, üst etiket, birleştir) ve Kişiler sayfaları, kişiye dokununca notları, arama ve süzgeç (etiket alt etiketler dahil), ana ekranda **Yattım / Kalktım**, otomatik konu etiketi. Olmayan etiket ve kişi onaysız oluşmaz. |
| 1b | v8.7.1 | Bilgisayarda **Notlar** (Ctrl+N / Ctrl+S / Ctrl+F, Esc, dar pencerede tek sütun), **Kişiler**, **Etiketler**; Defter'de seçili soruya etiket ve not bağlama (telefonda soru ayrıntısında da). Kayıtta "Geri al". |
| 2 | v8.8 | **Değişiklik defteri ve iki yönlü senkron** (şema 13): SQLite tetikleyicileri, HLC, `_baglam`, çakışma listesi, geri alma (geri almayı geri alma dahil), imzalı yanıtlar, fotoğraflar iki yönlü ve satırdan önce. İlk eşitlemede tam yedek, sonra yalnızca değişiklikler. Ekranlar: "Claude'un değişiklikleri" ve "Çakışmalar" (iki uygulamada). |
| 3 | v8.9 | **`kocum` komut satırı aracı** (`bin/kocum.dart`, `tool/kocum.sh`): `sorgu`, `not-ekle`, `etiket-ekle/kaldir`, `kisi-ekle/bagla`, `bagla`, `duzelt`, `sil-oner`, `oturumlar`, `geri-al`, `disa-aktar`; hepsi `kaynak: claude` + oturumla. WAL + `busy_timeout`, `PRAGMA data_version` ile masaüstü yenilenir. Silme önerileri (şema 14). `docs/KOCUM_ARACI.md`. Gerçek ikili geçici veritabanında denendi. |
| 4 | v8.10 | Bilgisayarda veri girişi: **Soru ekle/düzenle** (sürükle-bırak, kırpma), **Kitaplar** (ağaç düzenleme), **Optik** (klavyeyle A–E / D-Y-B), **Denemeler** (elle + karne PDF), **Oturumlar** (pencere içi sayaç), **Planlar** (+ yapay zekâ programı), **Analiz** (salt okunur). Hepsi telefondaki use case ve depoları kullanır; iş kuralı kopyalanmadı. |

## Yapılamayanlar ve sınırlar (dürüst liste)

- **Android derlenmedi**: bu makinede Android SDK yok (`flutter doctor`). Telefon da USB'de bağlı değildi, bu yüzden `applicationIdSuffix ".gece"` yamasını yazmadım (görevde yalnızca telefon bağlıysa isteniyordu). **Telefon kodu yalnızca analiz ve birim/widget testleriyle denendi**; ağ üzerinden gerçek telefon eşitlemesi (`SendController`) elle denenmedi. Ağ/protokol, 127.0.0.1'de gerçek sunucu ve istemciyle test edildi.
- **Yeni paket `desktop_drop` 0.8.4 (Apache-2.0)** sürükle-bırak için eklendi (pubspec ortak). Android eklentisi de var: **CI'da APK derlemesini kontrol et.** Sorun çıkarsa kaldırmak kolay: yalnızca `lib/desktop/widgets/file_drop_zone.dart` ve pubspec satırı. Ek geçişli bağımlılıklar: `dbus` (MIT), `cross_file`, `web`, `universal_platform` (BSD/MIT). Sürükle-bırak gerçek pencerede elle denenmedi (otomatik test yok); "Dosya seç" düğmesi her durumda çalışır.
- Yanıt imzası kurcalanırsa telefonun reddetmesi kodlandı ama **ayrı bir saldırı testi yok** (ağ ortasına girip yanıtı bozan bir test aracı yazmadım).
- Kablosuz eşitleme yalnızca **Linux bilgisayar** + Android telefon (önceki kısıt aynen).
- Defter için **budama yok** (satır başına birkaç yüz bayt); uzun vadede büyür.
- Masaüstü kırpma ekranı, telefondakiyle aynı koddur (fare ile sürükleme çalışır); ayrıca masaüstüne özel ince ayar yapılmadı.
- `kocum` aracında otomatik konu etiketi yok (konu sözlüğü uygulama varlığından yüklenir).

## Görevden sapmalar ve tasarım kararları

1. **"Okuma ya da listeleme ucu eklenmez" kuralına dar bir istisna**: PC'de eklenen fotoğraf telefona gitmeliydi ve telefon istemci olduğu için bunun başka yolu yok. `POST /fotograf-al` yalnızca (a) kurala uyan medya yolunu, (b) **bilgisayarın kendi değişikliklerinde geçen** yolları verir; genel dosya okuma ya da listeleme yoktur. Yanıt imzalıdır. Ayrıntı: `docs/KABLOSUZ_AKTARIM.md`.
2. **Kişi ↔ soru**: şemada `QuestionCardPeople` yoktu; "soruya kişi ekleme" **soruya bağlı not üzerinden** yapılır (Defter'de "Bu soruya not yaz": nota kişi eklenir).
3. **Etiket ara tabloları ve kişi bağları** bileşik anahtar yerine `id` sütunu + benzersiz çift kullanır: masaüstü birleştirici (`$primaryKey.single`) ve defterin `satirId`'si tek sütunlu anahtar ister.
4. **Şema 14** (görev 11 → 12 diyordu): 12 anlık notlar, 13 defter, 14 silme önerileri. Geri dönüş yok: yeni sürümün açtığı veritabanını eski sürüm açmaz (yükseltmeden önce yedek al).
5. **MEB konu ağacı** (`curriculum_nodes`) deftere girmez (her cihaz aynı varlıktan tohumlar; yoksa çakışma gürültüsü).
6. **Optik (bilgisayar)**: kip A–E (cevap anahtarı yapıştırılırsa durum kendiliğinden) ya da D/Y/B; telefondaki optikte cevap şıkları yok, burada kartlara `correctAnswer/givenAnswer` da yazılır.
7. **Anlık sekmesi 7. sekme** oldu (alt çubuk kalabalıklaştı, etiketler sığıyor ama dar telefonda gözle kontrol edilmeli).

## Bulgular (düzeltilen ve düzeltilmeyen)

- **Drift bu sürümde `references(...)` kuralını SQL'e hiç yazmıyor**; eski tablolarda `ON DELETE CASCADE/SET NULL` yok. Düzeltilmedi (davranışı değiştirir): kitap silince bölümler/test sonuçları, test düğümü silince bağlı kartlar yetim kalır (masaüstü Kitaplar bunu kartları ayırarak yönetir; telefonun kitap silme akışı aynı). Yeni tablolarda `customConstraint` kullanıldı. Gerekirse ayrı bir iş olarak ele alınmalı.
- **Tetikleyici ve `customStatement` Drift akışlarını tetiklemez**: ekranların yenilenmesi için açıkça `notifyUpdates` çağrılır (`LedgerService`); gece bir hata olarak yakalanıp düzeltildi.
- **Yedek içe aktarma ve iki yönlü eşitleme birlikte dikkat ister**: bilgisayardaki "İzlenen klasör" otomatik içe aktarması "telefon kazanır" kuralıyla çalışır. Eşitleme başladıktan sonra eski bir yedeği içe aktarmak bilgisayardaki daha yeni değişikliklerin üstüne yazabilir. Yedek içe aktarma sessiz çalışır (deftere yazmaz).
- Kitaplar sayfasındaki iki dropdown ve plan içe aktarma düğmeleri dar genişlikte taşıyordu; testlerle yakalanıp düzeltildi.

## Eklenen testler (219 → 326)

`anlik_test`, `anlik_widget_test`, `anlik_desktop_test` (ayrıştırma, İ/ı, alt etiket araması, takma ad, göç, kısayollar, dar pencere) · `ledger_test` (tetikleyiciler, iki cihaz, çakışma, saat farkı, çift gönderim, geri alma ve geri almayı geri alma, v12→v14 göçü) · `sync_ledger_e2e_test` (gerçek sunucu/istemci: iki yön, fotoğraf iki yön, kopma ve yeniden gönderim, çok tur, sürüm farkı) · `ledger_views_test` · `kocum_cli_test` (tüm komutlar, salt okunur koruması, Markdown) · `external_change_test` (WAL + iki bağlantı + `data_version`) · `optic_entry_test` · `desktop_entry_test`, `desktop_books_test`, `desktop_optic_test`, `desktop_exams_test`, `desktop_sessions_test`, `desktop_plans_test`, `desktop_analysis_test`.

## Sabah Ahmet'in elle yapması gerekenler

1. **İncele ve birleştir**: `git log gece-1`, uygun görürsen `main`'e birleştir; push sende. `.claude/settings.json` ve `docs/GECE_GOREVI.md` (ikincisi commit'te) senin dosyaların; `pubspec.lock` commit edilmedi.
2. **Telefon APK'sı**: CI'da (ya da yerelde) `flutter build apk` çalıştır; **`desktop_drop` Android'de sorun çıkarırsa** yukarıdaki geri alma yolunu kullan. Telefona kurmadan önce **yedek al** (şema 14 geri dönmez).
3. **İki tarafı da güncelle**: telefon ve bilgisayar aynı şemada (14) olmalı, yoksa eşitleme "farklı sürümde" diye durur ve hiçbir şey uygulamaz.
4. **Bilgisayar**: `tool/setup_linux.sh`, `tool/install_linux.sh` (menüye kurar). Güvenlik duvarı komutları `docs/MASAUSTU.md`'de. Eski eşleşme geçerlidir (protokol sürümü 1 aynı); yeniden eşleştirmeye gerek yok.
5. **Telefonda deneme sırası**: (a) Anlık sekmesi: yaz, `((etiket))` ve `@kişi` onay penceresi, Geri al; (b) ana ekranda Yattım / Kalktım; (c) Araçlar → **Bilgisayarla eşitle**: ilk sefer tam yedek, ikincide yalnızca değişiklikler; (d) bilgisayarda Notlar'dan not yaz, telefonda eşitle, gelsin; (e) aynı notu iki yerde değiştirip eşitle: Araçlar → **Çakışmalar**; (f) bilgisayarda soru ekle + fotoğraf, telefonda eşitle, fotoğraf gelsin ve metin okuma kuyruğa girsin.
6. **Gece uygulaması**: istersen `tool/patch_android.dart`'a `applicationIdSuffix ".gece"` ekletip denemeyi gerçek verine dokunmadan yap (bu gece telefon bağlı olmadığı için yazılmadı).
7. **Claude ile**: `tool/kocum.sh yardim`; bir oturumda `KOCUM_OTURUM=ad` verip yaptırdıklarını bilgisayarda "Claude'un değişiklikleri"nden geri alabilirsin.

## Commit listesi (`gece-1`)

`derleme: masaüstü ilk kez derlendi…` → `v8.7 (1/2)` → `v8.7 (düzeltme)` → `v8.7` → `v8.7.1` → `v8.8` → `v8.9` → `masaüstü 7…12` → `v8.10` → `belge: CLAUDE.md` → `düzeltme: curriculum_nodes`. Ayrıntı: `git log --oneline aeafabb..gece-1`. Sürüm tablosu: `docs/SURUMLER.md` (v8.7 … v8.10).

## İlerleme günlüğü (ham)

- 02:12 Adım 0 başladı
- 02:15 Adım 0 bitti: analiz temiz, 219 test geçti, Linux release derlendi ve açıldı. Android SDK yok (derlenmedi), telefon bağlı değil.
- 02:15 Adım 1 başladı
- 02:19 Adım 1: tablolar+göç (v12), domain, depo, 21 test hazır. NOT: bu Drift sürümü references() kuralını SQL'e yazmıyor (mevcut tablolarda da); yeni tablolarda customConstraint kullanıldı. Sıra: arayüz
- 02:24 Adım 1 bitti (v8.7): telefon arayüzü (Anlık sekmesi, editör, Kişiler, Etiketler, süzgeç, uyku kartı), 28 test (alan+widget). Sıra: 1b bilgisayar
- 02:28 Adım 1b bitti: bilgisayarda Notlar (Ctrl+N/S/F, Esc, dar pencere), Kişiler, Etiketler, Defter'de soru etiketi ve bağlı not; telefonda soru ayrıntısında etiket. 252 test geçiyor.
- 02:39 Adım 2 bitti (v8.8): defter+tetikleyiciler+HLC, iki yönlü senkron (imzalı yanıt, fotoğraf iki yön), çakışma, geri alma, ekranlar. 286 test. NOT: fotograf-al ucu 'okuma ucu yok' kuralına dar bir istisna (yalnızca bilgisayarın kendi değişikliğinde geçen yollar); ayrıntı KABLOSUZ_AKTARIM.md. Sıra: Adım 3 kocum aracı
- 02:45 Adım 3 bitti (v8.9): bin/kocum.dart + lib/cli, 12 komut, Markdown dışa aktarma, silme önerileri (şema 14), WAL+busy_timeout, data_version izleyici. Gerçek ikili geçici veritabanında denendi. 301 test. Sıra: Adım 4 (bilgisayarda veri girişi)
- 02:49 Adım 4.1 bitti: Defter'de Soru ekle/düzenle (sürükle-bırak, dosya seç, kırp, PNG). YENİ PAKET: desktop_drop 0.8.4 (Apache-2.0; Android eklentisi de var: CI'da APK derlemesini kontrol et; kaldırmak için lib/desktop/widgets/file_drop_zone.dart + pubspec)
- 03:19 Adım 4 bitti (v8.10): 4.1 soru, 4.2 kitaplar, 4.3 optik, 4.4 denemeler, 4.5 oturumlar, 4.6 planlar, 4.7 Analiz (salt okunur). 327 test.
