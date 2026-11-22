# Gece görevi (Claude Code, gözetimsiz)

Ahmet uyuyor. Ona soru sorma. Bu dosyadaki adımları sırayla uygula ve sabah `docs/GECE_RAPORU.md` yaz.
Önce `CLAUDE.md` ve `docs/` altındaki belgeleri oku.

## Çalışma kuralları

- `git switch -c gece-1` ile yeni bir dalda çalış. **`git push` yasak.** `main`'e commit atma.
- Her adım ayrı commit olsun. Mesaj biçimi CLAUDE.md'deki gibi (`v8.7: …` ve altında maddeler).
- Her commit'ten önce `flutter analyze` ve `flutter test` temiz olmalı. Testi silerek ya da gevşeterek "geçirme".
- Bir adımda 3 ciddi denemeden sonra hâlâ takılıysan: durumu rapora yaz, işi `git stash` ile sakla ve sonraki adıma geç.
- **Dokunma:** telefondaki veri girişi. Fotoğraf, kırpma, ML Kit okuma, optik, deneme ve karne içe aktarma, hesap ve analiz araçları olduğu gibi kalır. Uygulama hafif ve akıcı kalmalı.
- Kullanıcı verisi asla sessizce silinmez. Yeni paket ekleme. Gerçekten gerekirse adını ve lisansını rapora yaz.
- **İlerleme günlüğü:** her adımın başında ve sonunda `docs/GECE_RAPORU.md` dosyasına iki satır yaz (saat, adım, durum). Bağlamın sıkıştırılırsa nerede kaldığını oradan ve `git log`'dan bul. Baştan başlama.
- **Telefondaki gerçek Koçum'a ve verisine asla dokunma.** Telefon USB ile bağlıysa (`adb devices`) denemeyi ayrı bir uygulamayla yap:
  - `tool/patch_android.dart` içinde debug derlemeye `applicationIdSuffix ".gece"` ekle (testli, mevcut patch düzeniyle). Uygulama adı "Koçum (deneme)" olsun.
  - Bu deneme uygulaması gerçek uygulamanın yanına ayrı kurulur, verisi boş başlar.
  - Denemeyi `flutter run --debug` ile yap ve `adb logcat` / `flutter logs` ile hataları düzelt.
  - `adb uninstall`, `pm clear` ve gerçek uygulamaya (`com.kocum.kocum`) yönelik herhangi bir komut yasak.
  - Telefon bağlı değilse sadece derle.

---

## Adım 0: Çalışsın (önce bu)

1. `flutter doctor`. Eksik bir şey varsa ve sudo gerekiyorsa kurma, rapora yaz.
2. `bash tool/setup_linux.sh`, sonra `dart run build_runner build --delete-conflicting-outputs`, `flutter analyze`, `flutter test`.
3. Tüm derleme hatalarını ve kırık testleri düzelt. Masaüstü kodu hiç derlenmedi (`docs/MASAUSTU.md`).
4. `flutter build linux --release` başarılı olsun. `flutter run -d linux` ile açılıp açılmadığına bak.
5. Android SDK varsa `flutter build apk --release --target-platform android-arm64` (iskelet: CLAUDE.md'deki komutlar).
6. İki workflow'da `flutter test` adımındaki `continue-on-error: true` satırını kaldır.

Commit: `derleme: masaüstü ilk kez derlendi, testler CI'da yeniden kapı`

## Adım 1: Anlık notlar, soru kartları gibi etiketlensin (v8.7)

Ayrı bir özellik olacak: `lib/features/anlik/{domain,data,presentation}`. Mevcut `StudyNotes` (ders notu) olduğu gibi kalsın.

### Veri (`schemaVersion` 11 → 12, eski sürümlerden göç düşünülsün)

**`AnlikNotes`:**
- id
- createdAt: otomatik, düzenlenebilir.
- updatedAt
- body: bir kelimeden bir sayfaya kadar.
- kind: `anlik` | `uyku_yattim` | `uyku_kalktim`.
- mood: isteğe bağlı, 1–5.
- searchText: `normalizeTr`.
- Soru kartlarıyla aynı isteğe bağlı alanlar: `subject` (ders), `mebNodeId` (MEB konusu), `topicText` (serbest konu). Böylece notlar kartlarla aynı ders ve konu filtrelerine girer.

**`Tags`:** ortak etiket tablosu.
- id
- name: `normalizeTr` ile benzersiz anahtar, ayrıca görünen ad.
- parentId: etiketin üstündeki etiket, ör. `his > tiksinti`.
- kaynak: `ben` | `claude` | `otomatik`.
- createdAt

**`AnlikNoteTags`:** noteId, tagId, kaynak.

**`QuestionCardTags`:** cardId, tagId, kaynak. Soru kartlarına da serbest etiket eklenebilsin; mevcut ders, konu ve neden alanları aynen kalır.

**`People` (Kişiler):**
- id
- ad: takma ad da olabilir.
- aliases: aynı kişinin diğer adları, JSON listesi.
- not: kim olduğu, ör. "sınıf arkadaşı".
- kaynak: `ben` | `claude`.
- createdAt

**`AnlikNotePeople`:** noteId, personId, kaynak.

**`AnlikLinks`:** fromNoteId, toNoteId, toCardId (nota ya da soru kartına bağ), kaynak, createdAt.

### Otomatik etiket

Notu kaydedince mevcut `auto_tags.dart` / `TopicLexicon` metne de uygulansın. Bulunan konu `kaynak: otomatik` etiketiyle eklenir; kullanıcı silebilir. Yeni model ya da paket yok.

### Ekranlar

- Ana gezinmede **Anlık** sekmesi. Hızlı yazma alanı açılınca hemen klavye gelsin, kayıt tek dokunuş olsun.
- Metinde `((etiket))` yazımı, yazarken öneri. Olmayan etiket önce adı onaylanarak oluşturulur, sessizce oluşmaz.
- Etiket çubuğu: + düğmesi, birden çok etiket, silinebilir.
- `@kişi` yazımı ve kişi seçici. Yoksa "yeni kişi ekle".
- **Kişiler** sayfası: liste. Kişiye dokununca o kişiyle ilgili tüm notlar tarih sırasıyla görünür ("X hakkında ne yazmışım").
- Arama: kelime, etiket (alt etiketler dahil), kişi, tarih aralığı, ders.
- Ana ekranda tek dokunuşla **Yattım / Kalktım**.

Her kural saf Dart'ta ve testli olsun: `((etiket))` ve `@kişi` ayrıştırma, Türkçe harf sorunları (İ/ı), alt etiket araması, takma ad eşleşmesi.

Commit: `v8.7: Anlık notlar, ortak etiketler, Kişiler, uyku kaydı`

## Adım 1b: Veri girişi arayüzleri, telefonda ve bilgisayarda düzgün olsun (v8.7.1)

İki uygulamada da veri girişi düzgün olsun. Mevcut tasarım dili korunur: `app/theme.dart`, `palette.dart`, Google tarzı ve açık/koyu tema.

**Ortak kurallar:**
- Her giriş ekranı tek bir işi yapar. Zorunlu alanlar en üstte, isteğe bağlı alanlar "Daha fazla" altında.
- Kayıt tek dokunuşla ya da tek tuşla olur. Kaydedince kısa bir onay ve "Geri al" çıkar.
- Boş, yükleniyor ve hata durumları her ekranda olsun. Hiçbir ekran boş beyaz kalmasın.
- Uzun listeler sanal kaydırmalı olsun, takılmasın. Hafiflik öncelik: yeni animasyon kütüphanesi yok.
- Türkçe metinler kısa ve sade olsun. Çipte yazı kaybolma tuzağına dikkat (CLAUDE.md).

**Telefon:**
- Anlık, Kişiler ve etiket ekranları tek elle kullanılabilsin. Yazma alanı ekranın altında, klavyeyle birlikte yükselsin.
- Mevcut veri girişi ekranlarına (soru, optik, deneme, kitap) dokunma. Sadece yeni etiket ve kişi alanlarını, mevcut düzeni bozmadan ekle.

**Bilgisayar** (şu an sadece içe aktarma ve okuma var, veri girişi yok):
- **Notlar** sayfası: solda liste (filtre: etiket, kişi, ders, tarih), sağda düzenlenebilir not. Yeni not için `Ctrl+N`, kaydetmek için `Ctrl+S`, aramak için `Ctrl+F`. `((etiket))` ve `@kişi` önerileri telefondakiyle aynı mantıkta çalışsın.
- **Kişiler** sayfası: ekle, düzenle, takma ad ekle, kişinin notları.
- **Etiketler** sayfası: etiket ağacı. Yeniden adlandır, üst etiket değiştir, iki etiketi birleştir.
- **Defter**: seçili soruya etiket ve kişi ekleme, notu soruya bağlama.
- Fare ve klavyeyle rahat kullanılsın: sekme sırası doğru olsun, `Enter` ve `Esc` beklendiği gibi çalışsın, pencere küçülünce düzen bozulmasın.
- Bilgisayarda yapılan her giriş Adım 2'deki defterle telefona gider.

Widget testleri yazılsın: giriş ekranı açılıyor, kayıt yapılıyor, geri al çalışıyor.

Commit: `v8.7.1: telefonda ve bilgisayarda veri girişi arayüzleri`

## Adım 2: Değişiklik defteri ve iki yönlü senkron (v8.8)

Amaç: telefon ve bilgisayar birbirinin değişikliklerini alsın. Claude'un yaptığı her değişiklik geri alınabilsin.

- **`Degisiklikler` tablosu:**
  - id (uuid)
  - yerelSira (artan sayı)
  - cihazId
  - kaynak: `telefon` | `pc` | `claude` | `senkron` | `geri_al`
  - oturumId: Claude oturumu ya da boş.
  - tablo, satirId
  - islem: ekle | degistir | sil
  - eski, yeni: satırın tamamı, JSON.
  - saat: hibrit mantıksal saat (HLC), cihaz saatleri tutmasa da sıra bozulmasın.
- **Kayıt yöntemi:** her senkron tablosunda SQLite tetikleyicileri (`AFTER INSERT/UPDATE/DELETE`) satırı `json_object` ile deftere yazar. Böylece uygulamanın her yeri ve dışarıdan yazan araçlar otomatik kaydolur. Yazanın kim olduğu, işlemden önce tek satırlık bir `_baglam` tablosuna yazılan kaynak ve oturum bilgisinden alınır.
- **Senkron tabloları:** Adım 1'deki tüm tablolar, ayrıca `question_cards` ve diğer tüm kullanıcı verisi tabloları (kitaplar, testler, oturumlar, denemeler, planlar, notlar). `app_meta` girmez.
- **Fotoğraflar da iki yönlü gitsin.** Bilgisayarda eklenen fotoğraf telefona gider. Mevcut yol kuralları geçerli (`questions|solutions|notes/yyyy/mm/ad.uzantı`), boyut sınırı korunur. Telefon, bilgisayardan gelen fotoğrafı ML Kit okuma kuyruğuna alır; böylece metin okuma yine telefonda yapılır.
- **Başlangıç:** önce mevcut tam yedek ile birleştirme yapılır (bugünkü yol). Defter ondan sonra başlar.
- **Protokol:** mevcut eşleştirme, imza ve sıra numarası aynen kalır, telefon yine istemcidir. Telefon gönderimde kendi defter satırlarını yollar; cevapta bilgisayarın, telefonun henüz görmediği satırlarını alır (imleç: karşı tarafın son gördüğü sıra). Okuma ya da listeleme ucu eklenmez.
- **Çakışma:** aynı satır iki tarafta da değiştiyse HLC'si yeni olan kazanır. Kaybeden sürüm silinmez, `Cakismalar` listesine düşer ve iki uygulamada da görünür.
- **Geri alma:** bir değişikliği ya da bir Claude oturumunun tamamını geri al. Geri alma, `eski` değerleri yeni bir değişiklik olarak yazar (`kaynak: geri_al`), böylece geri alma da geri alınabilir. Satır o arada başkası tarafından değiştirildiyse üstüne yazmaz, çakışma olarak gösterir.
- **Ekranlar:** iki uygulamada **"Claude'un değişiklikleri"** listesi. Oturum oturum gruplanır, madde başına ve oturum başına "Geri al" düğmesi olur. Ayrıca **Çakışmalar** listesi.
- `docs/KABLOSUZ_AKTARIM.md` güncellensin.
- **Testler:** gerçek sunucu ve istemci 127.0.0.1'de. İki tarafta ayrı değişiklik, aynı satırda çakışma, saat farkı, bağlantının yarıda kopması (tekrar gönderimde çift kayıt olmasın), geri alma ve geri almayı geri alma.

Commit: `v8.8: değişiklik defteri, iki yönlü senkron, geri alma`

## Adım 3: `kocum` komut satırı aracı (Claude'un veriye eli)

Konum: `bin/kocum.dart`. Masaüstü veritabanını (`~/.local/share/com.kocum.kocum/kocum.sqlite`) açar ve her yazmada `_baglam`'a `kaynak: claude` ile oturum kimliğini yazar.

Komutlar:
- `kocum sorgu "<SELECT …>"`: salt okunur, JSON çıktı.
- `kocum not-ekle`, `kocum etiket-ekle <hedef> <etiket>`, `kocum etiket-kaldir`
- `kocum kisi-ekle <ad> [--takma …]`, `kocum kisi-bagla <not> <kişi>`
- `kocum bagla <not> <not|kart>`, `kocum duzelt <tablo> <id> <alan> <değer>`
- `kocum sil-oner <tablo> <id>`: silmez, sadece işaretler.
- `kocum oturumlar`, `kocum geri-al <değişiklik|--oturum X>`
- `kocum disa-aktar <klasör>`: notları ve günlük özetleri Markdown olarak yazar. Biçim: YAML başlık (id, zaman, tür, ders, konu, etiketler, kişiler, bağlar) + gövde. Dosya yolu `anlik/YYYY/MM/…md`, günlük özet `gunluk/YYYY-MM-DD.md`.

Ek kurallar:
- Masaüstü uygulaması açıkken de güvenli olsun: WAL ve `busy_timeout`. Masaüstü uygulaması `PRAGMA data_version` ile dış değişikliği fark edip ekranı yenilesin.
- Testler yazılsın, belgesi `docs/KOCUM_ARACI.md` olsun.

Commit: `v8.9: kocum aracı (Claude için düzenleme ve geri alma)`

## Adım 4: Bilgisayarda her türlü veri girişi (v8.10)

Telefonda girilebilen her şey bilgisayardan da girilebilsin ve Adım 2'deki senkronla telefona gitsin. Telefondaki giriş akışlarına dokunulmaz.

Mevcut `domain` kullanım durumları (use case) ve depolar aynen kullanılır, sadece masaüstü ekranları yazılır. İş kuralı kopyalanmaz.

Sıra (her biri ayrı commit, bir tanesi takılırsa sonrakine geç):
1. **Soru ekle / düzenle** (Defter'den): fotoğraf dosyadan seçilir ya da pencereye sürükle-bırak ile eklenir. Kırpma, mevcut kırpma ekranının masaüstüne uygun hâliyle yapılır. Ders, konu, neden, zorluk, şıklar ve çözüm girilir. Metin okuma bilgisayarda yapılmaz, telefona gidince yapılır; ekranda "okuma telefonda yapılacak" yazar.
2. **Kitaplar:** kitap ekleme (şablon JSON'u ve elle), test ve konu ağacını düzenleme.
3. **Optik:** kitap testinin cevaplarını klavyeyle hızlı girme (A–E tuşları, sonraki soruya otomatik geçiş).
4. **Denemeler:** elle deneme girme ve karne PDF'ini içe aktarma. `syncfusion_flutter_pdf` saf Dart, masaüstünde de çalışır.
5. **Çalışma oturumu:** bilgisayarda sayaçlı oturum. Bildirim kronometresi yerine pencere içi sayaç olur; telefonun bildirim servisine dokunulmaz.
6. **Planlar:** plan oluşturma, görev işaretleme, yapay zekâ programını içe aktarma.
7. Yer tutucu sayfalar (Kitaplar, Denemeler, Oturumlar, Analiz, Planlar) bu ekranlarla dolsun. Analiz sayfası mevcut dashboard analizlerini gösterir, sadece okumalıdır.

Adım 1b'deki arayüz kuralları burada da geçerli. Her ekran için widget testi yazılsın.

Commit'ler: `masaüstü 7…12: …`, sonunda `v8.10: bilgisayarda tüm veri girişi`

## Bitirirken

`docs/GECE_RAPORU.md` dosyasını yaz:
- ne yapıldı, ne yapılamadı ve neden;
- eklenen testler;
- sabah Ahmet'in elle yapması gerekenler (kurulum, telefonda deneme adımları).

`docs/SURUMLER.md` tablosunu güncelle ve raporu commit'le.
