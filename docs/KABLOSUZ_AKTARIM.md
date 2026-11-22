# Kablosuz aktarım ve iki yönlü senkron (telefon ⇄ bilgisayar)

Protokol v1, düz HTTP (`dart:io`). Portlar: TCP **47321**, UDP **47322** (bulma). Kod: `lib/features/sync/` (ortak), `lib/desktop/sync/` (sunucu).

## Kurallar

| Kural | Nasıl sağlanır |
|---|---|
| Yalnızca uygulamanın alanı | Sunucuda okuma/listeleme yok. Yazma yalnızca `media/` altına, `^(questions\|solutions\|notes)/\d{4}/\d{2}/[A-Za-z0-9_-]{1,80}(\.[A-Za-z0-9]{1,8})?$` yollarıyla; ve (isteğe bağlı) `pdfs/` altına yalnızca `^[0-9a-f]{64}\.pdf$`. `../` ve symlink kaçışı reddedilir. Telefon yalnızca kendi listesindeki dosyaları gönderir. |
| Yalnızca eşleşmiş cihaz | Eşleşmemiş istek reddedilir. |
| En fazla iki cihaz | Bir bilgisayar, bir telefon **ya da** tablet (aynı anda biri). Yenisi için eskisi elle kaldırılır (veri silinmez); bkz. "Merkez mimarisi". |
| Windows reddi | Yalnızca `android` telefon eşleşir; alma yalnızca `linux` bilgisayarda açılır. |
| Atlatma yolları | Aşağıda. |

## Eşleşme

- Bilgisayar 6 haneli tek seferlik kod gösterir: 5 dakika, 5 deneme.
- İki taraf anahtarı ayrı hesaplar: Diffie-Hellman (RFC 7919 ffdhe2048) + kod + kimlikler + sınav + açık değerler (HMAC-SHA256). **Anahtar ağdan geçmez.**
- Karşılıklı kanıt (farklı etiketlerle) ile iki taraf da kodu bildiğini gösterir.

## Her istek

- HMAC-SHA256 imzası: `yöntem|yol|oturum|sıra|medyaYolu|gövdeÖzeti`.
- Sıra numarası kesin artan; yeniden gönderilen istek reddedilir, oturum kapanır.
- Tek kullanımlık sınavlar: 2 dk, en çok 32 açık.
- Sabit zamanlı karşılaştırma.

## Ağ

- Yalnızca özel adresler: 10/8, 172.16/12, 192.168/16, 169.254/16, IPv6 ULA ve link-local.
- 100.64/10 (VPN/CGNAT) ve loopback reddedilir.
- Tarayıcı başlıkları (`origin`, `sec-fetch-*`, `referer`) reddedilir.
- `Host` başlığı IP olmalı (DNS rebinding).
- Bir adres 10 dakikada 20 hata yaparsa 10 dakika engellenir.
- Bulma yanıtı sorgudan büyük olamaz (yansıtma saldırısı): sorgu 512 bayta doldurulur.

## Aktarım

1. Telefon fotoğraf listesini sunar; bilgisayar eksikleri döndürür (boyut farkı = eksik).
2. Telefon eksikleri PUT eder; dosya `.part` olarak yazılır, imza doğrulanınca yeniden adlandırılır.
3. Telefon fotoğrafsız yedek ZIP'ini (`kocum_yedek.json` + `kocum.db`) PUT eder; bilgisayar `ImportService` ile birleştirir.
4. Kopma olursa yeniden gönder: kaldığı yerden devam eder. 3 deneme; IP değiştiyse kimliğe göre yeniden bulunur.

## Bilinen sınırlar

- **İçerik şifrelenmez, yalnızca imzalanır.** Ağı dinleyen görebilir ama değiştiremez ve senin yerine gönderemez. Okul, kafe gibi ortak Wi-Fi'da kullanma.
- Platform bildirimi taklit edilebilir; asıl kilit koddan türeyen anahtardır.
- Android 17 hedefinde yerel ağ için çalışma zamanı izni (`ACCESS_LOCAL_NETWORK`) gerekecek; şimdilik INTERNET izni (`tool/network_patch.dart`) yeterli.
- Güvenlik duvarı: `sudo ufw allow from 192.168.0.0/16 to any port 47321 proto tcp` ve `... port 47322 proto udp`.

## İki yönlü senkron (v8.8)

İlk eşitlemede bugünkü yol çalışır (fotoğraflar + tam yedek, telefon kazanır). Ondan sonra **yedek gitmez**; yalnızca **değişiklik defteri** taşınır.

### Değişiklik defteri

- `degisiklikler` tablosu: `id` (iki cihazda aynı), `yerelSira`, `cihazId`, `kaynak` (`telefon | pc | claude | senkron | geri_al`), `oturumId`, `tablo`, `satirId`, `islem` (`ekle | degistir | sil`), `eski`, `yeni` (satırın tamamı, JSON), `saat` (HLC), `uzak`, `geriAlinan`.
- **SQLite tetikleyicileri** (`lib/core/ledger/ledger_triggers.dart`) her senkron tablosunda ekleme, güncelleme (yalnızca satır gerçekten değişince) ve silmeyi yazar. Böylece uygulamanın her yeri ve dışarıdan yazan araçlar (`kocum`) kendiliğinden kaydolur.
- Yazanın kim olduğu işlemden önce tek satırlık `_baglam` tablosuna yazılır (`LedgerService.withSource`). `bastir = 1` tetikleyicileri susturur (yedek birleştirme, karşıdan gelen satırların uygulanması).
- BLOB sütunları (`ink_strokes.points`): `json_object` BLOB taşıyamadığı için `hex()` ile onaltılık metin olarak yazılır (NULL BLOB NULL kalır), uygulanırken (`_writeRow`) bayta çevrilir. Dikkat: hex satır boyutunu ~2 katına çıkarır ve `eski` + `yeni` iki kez yazıldığı için silinen/değişen BLOB'lu bir çizgi satırı defterde nokta verisinin ~4 katı yer tutar; defter budaması yok. Yeni BLOB'lu senkron tablosu kendiliğinden bu yoldan geçer.
- Senkron dışı tablolar: `app_meta`, `degisiklikler`, `_baglam`, `cakismalar`, `esitleme_durum` ve `curriculum_nodes` (MEB ağacını her cihaz aynı varlıktan kendisi tohumlar). Bunlar bilgisayara ve yedek birleştirmeye girmez.
- Şema 19 (kalemli defter): `ink_notebooks`, `ink_note_pages` ve Anlık etiket/kişi bağları `ink_notebook_tags|people`, `ink_page_tags|people` senkron tablosudur; hepsi tek sütunlu `id` ve tetikleyiciyle deftere girer, ek kod gerekmedi. Sayfa çizgileri `ink_strokes` satırıdır: `noteId` = sayfa kimliği, `notePage` = sayfanın değişmeyen `pageNo`'su (sıra `sortOrder`'dadır; sayfa taşınınca BLOB'lu çizgiler yeniden yazılıp defteri şişirmez). Sayfa/bağ tablolarında defter/sayfa için yabancı anahtar yok (sıra bozuk gelse de takılmasın); etiket/kişiye var.
- **HLC** (`lib/core/ledger/hlc.dart`): `<ms>-<sayaç>-<cihaz>`. Karşıdan gelen saati gören cihaz kendi saatini onun üstüne taşır; saati geride olsa da gördüğü değişikliğin üstüne yazan kazanır.
- Defter sonsuz büyümesin diye budama henüz yok (satır başına birkaç yüz bayt).

### Protokol

Mevcut eşleştirme, imza ve sıra numarası aynen kalır; telefon yine istemcidir. İki yeni uç:

| İstek | Ne yapar |
|---|---|
| `POST /kocum/v1/degisiklikler` | Telefon kendi satırlarını (`sira > gonderilen`) ve "bilgisayardan şu sıraya kadar aldım" imlecini yollar. Bilgisayar uygular, `onay` döner; cevapta telefonun görmediği kendi satırlarını, başvurdukları fotoğrafların listesini ve `daha` bayrağını verir. En çok 300 satır ve 5 MB; fazlası birkaç turda gider. |
| `POST /kocum/v1/fotograf-al` | Telefon, bilgisayarın **kendi değişikliklerinde geçen** bir fotoğrafı ister. Başka yol verilmez (genel dosya okuma yoktur). |

- **Yanıtlar imzalıdır** (`x-kocum-yanit-imza`: oturum, sıra, gövde özeti). Telefon imzayı doğrulamadan hiçbir satırı ya da fotoğrafı uygulamaz; ağdaki biri yanıtı değiştirip veri sokamaz.
- Okuma ya da listeleme ucu eklenmedi. `fotograf-al`, bilgisayarın kendi eklediği fotoğrafı telefona vermenin tek yoludur ve yalnızca defterde geçen yollarla çalışır.
- Şema sürümü iki tarafta aynı olmalı; değilse açık hata verilir ve hiçbir şey uygulanmaz.
- **Sıra**: fotoğraflar satırlardan önce taşınır (giden fotoğraf önce yüklenir, gelen önce indirilir). Telefon, gelen kartın fotoğrafını önce aldığı için metin okuma kuyruğu eksik dosyayı "okunamadı" yazmaz; okuma yine telefonda yapılır.
- **İmleçler** yalnızca uygulama bitince ilerler. Bağlantı yarıda koparsa aynı satırlar yeniden gider; bilgisayar kimliğe bakıp çift kayıt yapmaz.

### Çakışma

Karşıdan gelen değişikliğin `eski` değeri, yereldeki satırla aynıysa doğrudan uygulanır. Değilse (iki taraf da değiştirdi) HLC'si yeni olan kazanır; **kaybeden sürüm `cakismalar` tablosuna düşer**, silinmez, iki uygulamada da görünür ("Kaybedeni geri getir" ya da "Kazanan kalsın"). Silme ile değiştirme çakışması da böyle çözülür.

### Geri alma

`LedgerService.undoChange(id)`: değişikliğin `eski` değerini **yeni bir değişiklik olarak** yazar (`kaynak: geri_al`, `geriAlinan: id`), yani geri alma da geri alınabilir. Satır o arada başkası tarafından değiştiyse üstüne yazılmaz, çakışma olarak gösterilir. `undoSession(oturum)`: oturumun Claude değişikliklerini sondan başa geri alır. Ekran: Araçlar → Claude'un değişiklikleri (telefon), "Claude'un değişiklikleri" bölümü (bilgisayar).

### Testler

`test/ledger_test.dart` (tetikleyiciler, iki cihaz, çakışma, saat farkı, geri alma), `test/sync_ledger_e2e_test.dart` (gerçek sunucu ve istemci 127.0.0.1'de: iki yön, fotoğraf, çift gönderim, çok tur, sürüm farkı), `test/ledger_views_test.dart`.


## Merkez mimarisi: telefon, tablet, bilgisayar (T7)

Tablet de bir Android cihazdır (`platform = android`); bilgisayarla telefonla aynı yoldan eşleşir ve eşitlenir. **Telefon ↔ tablet doğrudan eşleşme yoktur** (güvenlik modeli: bir cihaz yalnızca eşleştiği bilgisayarla konuşur). Bilgisayar MERKEZDİR:

- Bilgisayarın yalnızca **bir** eşleşme yuvası vardır. Telefon ve tablet **sırayla** gezer: biri eşleşir, eşitler; eşleşme bilgisayarda kaldırılır; öbürü eşleşir, eşitler. Cihazların imleçleri (`gonderilen_sira`, `alinan_sira`) kendi veritabanlarındadır ve eşleşme kalkınca silinmez; bu yüzden her ziyaret kaldığı yerden devam eder.
- Bilgisayar bir cihazdan aldığı satırları (`uzak = 1`, **özgün `cihazId` ve kimlikle**) öbür cihaza da verir: `LedgerService.pendingFor(…, relayExcept: karşıCihaz)`. Karşı cihazın kendi yazdıkları ona geri dönmez. Alan cihaz kimliğe bakıp çift kayıt yapmaz. İlk sürümde bu aktarım yoktu (bilgisayar yalnız kendi yazdıklarını veriyordu; tablet telefonun verisini göremezdi): `test/sync_hub_test.dart` bunu yakalar.
- Aynı satırı iki cihaz ayrı değiştirirse HLC'si yeni olan kazanır, kaybeden `cakismalar`'da kalır; üç cihaz da aynı sonuca yakınsar (test).
- Fotoğraflar da merkezden geçer: `fotograf-al`, bilgisayarın defterindeki herhangi bir satırda (öbür cihazdan gelen dahil) geçen kurala uyan yolu verir.
- Kapsam: `ink_strokes` (BLOB nokta verisi dahil), `pdf_documents`, PDF alanlı `question_cards`, `ink_notebooks`, `ink_note_pages`, `ink_notebook_tags|people`, `tags` hepsi senkron tablosudur ve iki yönde taşınır (testli).
- **Bilinen sınırlar:** (1) İlk eşitlemede gelen **tam yedek** satır olarak deftere yazılmaz (tetikleyiciler susturulur); bu yüzden bir cihazın ilk yedeğiyle bilgisayara geçen eski veri, sonradan eşleşen öbür cihaza **gitmez** (yalnızca defter satırları gider). Yeni kurulmuş tablette sorun yok; tablete telefondaki eski veriyi taşımak ayrı bir iş. (2) Cihaz başına eşleşme yuvası tek olduğu için her geçişte eşleşmeyi kaldırıp yeniden kod girmek gerekir; iki yuva (telefon + tablet birden) istenirse `DesktopSyncStore` ve tek `_session` değişmeli.

## PDF dosyası aktarımı (T7, isteğe bağlı, yalnızca telefon/tablet → bilgisayar)

Satırlar (belge, çizgi, kutu, soru) defterle her zaman gider; PDF **dosyası** ayrıdır, büyüktür ve yalnızca kullanıcı açarsa gider.

| Konu | Kural |
|---|---|
| Ayar | Tablet/telefon, Bilgisayarla eşitle ekranı → "PDF dosyalarını da gönder". Varsayılan **kapalı** (`esitleme.json` içinde `pdfGonder`); kapalıyken istemci hiç PDF isteği yapmaz. |
| Uç | `PUT /kocum/v1/pdf`, başlık `x-kocum-yol: <sha256>.pdf`. İmza (`yöntem|yol|oturum|sıra|yol|gövdeÖzeti`) ve sıra numarası her zamanki gibi. |
| Ad | `^[0-9a-f]{64}\.pdf$`; başka her şey (`..`, alt klasör, büyük harf, başka uzantı) 400. Hedef `<veri klasörü>/pdfs/<sha256>.pdf`: `PdfImportService.fileOf` ile aynı düzen, masaüstü okuyucu doğrudan bulur. Hedef ya da klasör symlink ise yazılmaz. |
| Var mı? | **Gövdesiz PUT** = "bu özet sende var mı?" (listeleme/okuma değil; gönderen yalnızca elindeki tek özeti sorar, imza şart, imzasız ya da yanlış imzalı soru 401 ve varlık bilgisi sızmaz). Varsa gövde hiç gitmez. (dart:io gövde okunmadan verilen yanıtı güvenle iletemediği için doğrudan PUT + kesme yerine bu seçildi.) |
| Doğrulama | İki uçta sha256: istemci göndermeden dosyanın özetini hesaplar (bozuksa yollamaz); sunucu imzayı gövde okunmadan ADIN özetiyle doğrular, gövdeyi `kablosuz/*.part`'a akıtırken özet hesaplar, adla uyuşmazsa 400 ile reddedip siler. |
| Boyut | En çok 300 MB (`SyncLimits.pdf`); fazlası Content-Length'ten 413 (gövde okunmaz, bağlantı kapanır), istemci de göndermez ve "sınırı aştı" yazar. |
| Yarım kalma | `.part` + atomik yeniden adlandırma (farklı disk bölümünde hedef klasörde ikinci `.part` ve yeniden adlandırma); hata, kopma, iptalde her `.part` silinir; sunucu açılışta `kablosuz/` klasörünü temizler. |
| İlerleme/iptal | Ekran "PDF i / n: x MB / y MB" ve "İptal et" gösterir; iptal isteği yarıda keser. Satırların eşitlenmesi PDF aşaması başarısız ya da iptal olsa da bozulmaz. |
| Ters yön | **Yapılmadı:** bilgisayar → telefon/tablet PDF yok. "Sunucuda okuma/listeleme yok" kuralını bozmazdı ama gerek de yok: PDF'i kullanıcı cihazda kendisi içe aktarır; ters yön yeni bir okuma ucu ve hangi dosyaların verileceği kararı demektir. İstenirse `fotograf-al` gibi "defterde geçen belge" kuralıyla ayrıca tasarlanır. |

Testler: `test/sync_pdf_test.dart` (başarı, yinelenen, özet uyuşmazlığı, aşırı boyut, yol enjeksiyonu, symlink, yarım kesilme, iptal, anahtarsız/imzasız/tekrar, ayar kapalı), `test/sync_hub_test.dart` (3 cihaz yakınsaması).
