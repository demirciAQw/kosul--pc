# Kablosuz aktarım ve iki yönlü senkron (telefon ⇄ bilgisayar)

Protokol v1, düz HTTP (`dart:io`). Portlar: TCP **47321**, UDP **47322** (bulma). Kod: `lib/features/sync/` (ortak), `lib/desktop/sync/` (sunucu).

## Kurallar

| Kural | Nasıl sağlanır |
|---|---|
| Yalnızca uygulamanın alanı | Sunucuda genel okuma/listeleme yok; yalnızca **üç dar istisna**: `fotograf-al` (defterde ya da tam durum sayfalarında geçen tek fotoğraf), imzalı "bu özet var mı?" sorusu (tek PDF özeti) ve `pdf-al` (bilgisayarın `pdf_documents` satırında geçen tek PDF). Gerekçe: üçü de istemcinin zaten bildiği tek bir kimliği (yol ya da özet) sorar; liste dönmez; kimlik bilgisayarın kendi kaydında yoksa 404 (varlık sızmaz); hepsi imzalı ve sıra numaralıdır. Yazma yalnızca `media/` altına, `^(questions\|solutions\|notes)/\d{4}/\d{2}/[A-Za-z0-9_-]{1,80}(\.[A-Za-z0-9]{1,8})?$` yollarıyla; ve (isteğe bağlı) `pdfs/` altına yalnızca `^[0-9a-f]{64}\.pdf$`. `../` ve symlink kaçışı reddedilir. Telefon yalnızca kendi listesindeki dosyaları gönderir. |
| Yalnızca eşleşmiş cihaz | Eşleşmemiş istek reddedilir. |
| Cihaz sayısı | Bir alıcıya **en çok 4 cihaz** aynı anda eşleşik (`SyncLimits.maxDevices`); bir istemci en çok 4 eşe bağlanır (`SyncLimits.maxPeers`, v9.23). Telefon ↔ tablet de doğrudan eşleşebilir (v9.23). Cihaz kaldırmak öbürlerini etkilemez (veri silinmez); bkz. "Merkez mimarisi" ve "Her cihaz hem istemci hem alıcı". |
| Windows reddi | İSTEMCİ olarak yalnızca `android` eşleşir; ALICI `linux` bilgisayar ya da (v9.23) ekranı açıkken `android` olur. Windows ve diğerleri iki yönde de reddedilir. |
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
- Genel okuma ya da listeleme ucu eklenmedi; istisnalar `fotograf-al` ve imzalı gövdesiz "bu PDF özeti var mı?" sorusudur. `fotograf-al`, bilgisayarın kendi eklediği fotoğrafı telefona vermenin tek yoludur ve yalnızca defterde geçen yollarla çalışır.
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

- **Çok cihaz (v9.15):** bilgisayar en çok 4 cihazı aynı anda tutar. `esitleme.json`: `{id, acik, cihazlar: [{id, ad, platform, tur, anahtar, eslesme, sonEsitleme}]}`; her cihazın kendi DH anahtarı, kimliği ve oturumu vardır (`SyncServer._sessions`: oturum kimliği → oturum; cihaz başına tek oturum, her birinin kendi sıra sayacı). Eşleşme kodu akışı her yeni cihaz için tekrarlanır ("Yeni cihaz ekle"); mevcut cihazlar kopmaz. Eski tek cihaz biçimi (`telefon:`) okunurken `cihazlar` listesine taşınır (eşleşme bozulmaz). Cihazlar eşzamanlı istek yapabilir; yalnızca veritabanına yazan bölümler (defter alışverişi, yedek içe aktarma) sunucuda `_dbLock` ile sırayla çalışır, bekleyen istek hata almaz. Cihazların imleçleri (`gonderilen_sira`, `alinan_sira`) kendi veritabanlarındadır; bilgisayar cihaz başına imleç tutmaz (cihaz `received` gönderir) ve bilgisayar tarafında cihaz başına yalnızca `sonEsitleme` saklanır.
- Bilgisayar bir cihazdan aldığı satırları (`uzak = 1`, **özgün `cihazId` ve kimlikle**) öbür cihaza da verir: `LedgerService.pendingFor(…, relayExcept: karşıCihaz)`. Karşı cihazın kendi yazdıkları ona geri dönmez. Alan cihaz kimliğe bakıp çift kayıt yapmaz. İlk sürümde bu aktarım yoktu (bilgisayar yalnız kendi yazdıklarını veriyordu; tablet telefonun verisini göremezdi): `test/sync_hub_test.dart` bunu yakalar.
- Aynı satırı iki cihaz ayrı değiştirirse HLC'si yeni olan kazanır, kaybeden `cakismalar`'da kalır; üç cihaz da aynı sonuca yakınsar (test).
- Fotoğraflar da merkezden geçer: `fotograf-al`, bilgisayarın defterindeki herhangi bir satırda (öbür cihazdan gelen dahil) geçen kurala uyan yolu verir.
- Kapsam: `ink_strokes` (BLOB nokta verisi dahil), `pdf_documents`, PDF alanlı `question_cards`, `ink_notebooks`, `ink_note_pages`, `ink_notebook_tags|people`, `tags` hepsi senkron tablosudur ve iki yönde taşınır (testli).
- **Tam durum (v9.15):** İlk eşitlemede gelen **tam yedek** satır olarak deftere yazılmaz (tetikleyiciler susturulur), bu yüzden bu eski veri defter akışıyla öbür cihaza gitmezdi. Çözüm: yeni eşleşen (ya da "Bilgisayardaki her şeyi yeniden al" diyen) cihaz `degisiklikler` isteğine `anlik` imleci koyar; bilgisayar defter değişikliği yerine senkron tablolarının güncel satırlarını sayfa sayfa (en çok 400 satır / 1,5 MB) `ekle` kaydı biçiminde döner (`LedgerService.snapshotPage`; yeni okuma ucu yok). Bu sırada defter geçmişi yeniden oynatılmaz (sahte çakışma çıkmasın); ilk sayfadan önce alınan bilgisayar defter sırası saklanır, bitince YALNIZ boş cihazda (`alinan_sira = 0`) `alinan_sira` oraya çekilir; dolu cihazda imleç KORUNUR (tam durum var olan satıra dokunmaz ve silineni bilmez; N+1..M arası güncelleme/silmeler normal akışla gelir, yeniden oynatma "aynıysa atla" ile güvenlidir). Ardından bir tur normal alışveriş yapılır. Cihaz tarafı (`applySnapshot`) yalnızca EKSİK satır ekler: var olan satıra dokunulmaz, cihazın defterinde `sil` kaydı olan satır geri gelmez, satırlar deftere işlenmez (bilgisayara geri yankılanmaz), yabancı anahtar denetimi sayfa süresince kapalıdır (DİKKAT: `PRAGMA foreign_keys` bağlantı geneldir; bu kısa pencerede aynı bağlantıdan gelen arayüz yazımları da FK denetimsiz çalışır; pencere tek sayfalık işlem kadardır). Bayrak `tam_durum_gerek` (`esitleme_durum`); yeni eşleşmede kurulur, v9.14'ten kalan eşleşmeler kendiliğinden almaz (düğmeyle ister). Sınır: cihazda ÖNCEDEN (defter öncesi) silinmiş ama bilgisayarda hâlâ duran satır, yeniden eşleşmede geri gelebilir. Fotoğraflar: tam durum sayfalarında geçen yollar o sayfa için `fotograf-al` ile verilir. **Bilinen sınırlar:** (1) Tam durumda ana kayıt sonraki sayfada geliyorsa yabancı anahtar denetimi bu sayfalar boyunca kapalı olduğu için sorun çıkmaz; bütün sayfalar gelmeden kesilirse (tur sınırı) bayrak açık kalır ve bir sonraki eşitleme sürdürür. (2) Eşleşme yuvası sınırı: bkz. yukarı (4 cihaz). (3) **Eski imleç (v9.10):** v9.9'a kadar bilgisayar öbür cihazdan gelen satırları vermiyordu ama telefonun `alinan_sira` imleci yine de ilerliyordu; kaçan tablet satırları için ilk v9.10 eşitlemesinde imleç bir kez sıfırlanır (`aktarma_imleci_sifirlandi` işareti, `esitleme_durum`); tekrar gelenler kimlikten atlanır. (4) **Aktarılmayanlar:** bilgisayarda çakışmayı kaybeden ya da uygulanamayan satır deftere `kaynak='senkron'` ile işlenir ve öbür cihaza aktarılmaz (`uzak` sütununda `CHECK (uzak IN (0,1))` olduğundan üçüncü değer yazılamaz; şema değişmedi). v9.9'da bu yüzden kayıtlı eski satırlar `kaynak` değişmeden kalır ve aktarılabilir. (5) **Cihaz kimliği:** bilgisayar, istekteki beyana (`req.device`) göre "karşı cihazın kendi satırlarını" süzer. Veritabanı başka kuruluma kopyalanırsa (yedekten geri yükleme) aynı defter kimliği iki cihazda olurdu; gönderimden önce `LedgerService.bindToInstall` veritabanındaki kurulum kimliğini `esitleme.json` kimliğiyle karşılaştırır, farklıysa defter cihaz kimliğini yeniler. Aynı `esitleme.json` ile iki cihaz kurmak (aynı bulut yedeğini iki cihaza geri yüklemek) hâlâ çift kimlik verir; eşleşme zaten tek yuvalı ve kurulum kimliği ayrıdır. Bilgisayar tarafı bildirilen kimliği saklamıyor (protokol değişmedi).

## PDF dosyası aktarımı (T7 + v9.15, isteğe bağlı, iki yön)

Satırlar (belge, çizgi, kutu, soru) defterle her zaman gider; PDF **dosyası** ayrıdır, büyüktür ve yalnızca kullanıcı açarsa gider.

| Konu | Kural |
|---|---|
| Ayar | Tablet/telefon, Bilgisayarla eşitle ekranı → "PDF dosyalarını da gönder". Varsayılan **kapalı** (`esitleme.json` içinde `pdfGonder`); kapalıyken istemci hiç PDF isteği yapmaz. |
| Uç | `PUT /kocum/v1/pdf`, başlık `x-kocum-yol: <sha256>.pdf`. İmza (`yöntem|yol|oturum|sıra|yol|gövdeÖzeti`) ve sıra numarası her zamanki gibi. |
| Ad | `^[0-9a-f]{64}\.pdf$`; başka her şey (`..`, alt klasör, büyük harf, başka uzantı) 400. Hedef `<veri klasörü>/pdfs/<sha256>.pdf`: `PdfImportService.fileOf` ile aynı düzen, masaüstü okuyucu doğrudan bulur. Hedef ya da klasör symlink ise yazılmaz. |
| Var mı? | **Gövdesiz PUT** = "bu özet sende var mı?" (listeleme/okuma değil; gönderen yalnızca elindeki tek özeti sorar, imza şart, imzasız ya da yanlış imzalı soru 401 ve varlık bilgisi sızmaz). Varsa gövde hiç gitmez ve istemci dosyayı hiç özetlemez (ad = içe aktarmada hesaplanmış özet); yoksa dosya yüklemeden önce bir kez özetlenir ve ada uymuyorsa gönderilmez. Sunucu "zaten var" dalında gövdeyi okumaz, 200'ü gönderip bağlantıyı kapatır. (dart:io gövde okunmadan verilen yanıtı güvenle iletemediği için doğrudan PUT + kesme yerine bu seçildi.) |
| Doğrulama | İki uçta sha256: istemci göndermeden dosyanın özetini hesaplar (bozuksa yollamaz); sunucu imzayı gövde okunmadan ADIN özetiyle doğrular, gövdeyi `kablosuz/*.part`'a akıtırken özet hesaplar, adla uyuşmazsa 400 ile reddedip siler. |
| Boyut | En çok 300 MB (`SyncLimits.pdf`); fazlası Content-Length'ten 413 (gövde okunmaz, bağlantı kapanır), istemci de göndermez ve "sınırı aştı" yazar. |
| Yarım kalma | `.part` + atomik yeniden adlandırma (farklı disk bölümünde hedef klasörde ikinci `.part` ve yeniden adlandırma); hata, kopma, iptalde her `.part` silinir; sunucu açılışta `kablosuz/` klasörünü temizler. |
| İlerleme/iptal | Ekran "PDF i / n: x MB / y MB" ve "İptal et" gösterir; iptal isteği yarıda keser. Satırların eşitlenmesi PDF aşaması başarısız ya da iptal olsa da bozulmaz. |
| Ters yön (v9.15) | **`pdf-al`** (üçüncü dar istisna): `POST /kocum/v1/pdf-al`, gövde `{"yol": "<sha256>.pdf", "baslangic": n}` (imzalı JSON). Ayar: Bilgisayarla eşitle → "PDF'leri bilgisayardan al" (`pdfAl`, varsayılan **kapalı**; kapalıyken istemci hiç istek yapmaz). Sunucu kuralları: imza + sıra şart; ad `^[0-9a-f]{64}\.pdf$` (yoksa 400); özet bilgisayarın `pdf_documents` satırında geçmeli (yoksa 404, dosya diskte olsa da); `pdfs/` altında gerçek dosya (symlink ya da klasör kaçışı reddedilir); boyut ≤ 300 MB (413); `baslangic` 0..boyut. Gövde `baslangic` bayttan akıtılır (kopan indirme `.part` dosyasından sürer; kısmi dosya istemcide yeniden özetlenir). Yanıt imzası `ad\|başlangıç\|toplam` üzerindedir (300 MB'ı iki kez okumayız); baytların bütünlüğünü ADIN SHA-256'sı kanıtlar: istemci tutmazsa dosyayı atar, `.part` silinir. Hedef ya da klasör symlink ise yazılmaz; `.part`+atomik yeniden adlandırma; iptalde `.part` silinir. Ekranda "PDF i / n indiriliyor: x MB / y MB" ve "iptal". Böylece tabletten bilgisayara yüklenen PDF telefona da iner. |

Testler: `test/sync_pdf_test.dart` (başarı, yinelenen, özet uyuşmazlığı, aşırı boyut, yol enjeksiyonu, symlink, yarım kesilme, iptal, anahtarsız/imzasız/tekrar, ayar kapalı), `test/sync_hub_test.dart` (3 cihaz yakınsaması).

Çok cihaz, tam durum ve `pdf-al` testleri: `test/sync_multi_device_test.dart` (telefon + tablet eşzamanlı, ayrı anahtarlar, cihaz kaldırma, 4 cihaz sınırı, eski saklama biçimi göçü, eski deftersiz veri dahil tam durum, çok sayfalı imleç, `pdf-al`: yol enjeksiyonu, imzasız, bilinmeyen özet, symlink, özet uyuşmazlığı, 300 MB sınırı, ayar kapalı, kaldığı yerden devam, iptal).

**Kilit ve iptal (v9.15 inceleme):** Bilgisayarda defter alışverişi ve yedek içe aktarma tek kilitten (`_dbLock`) sırayla geçer. Kilit beklemesi `lockWait` (varsayılan 20 sn) ile sınırlıdır; aşılırsa 409 "meşgul" (iş hiç çalışmaz, istemci yeniden dener). Büyük yedek içe aktarılırken gelen defter isteği beklemez: hemen 409. Kilitten çıkınca bağlantı koptuysa, cihaz kaldırıldıysa ya da eşleşmesi gittiyse iş UYGULANMAZ. `forgetDevice` o cihazın süren isteklerini iptal eder (PDF akışı kesilir). `pdf-al` yumuşak silinmiş (`deleted`) belgenin PDF'ini vermez. Tam durum fotoğraf izni cihaza özgüdür (oturumdaki eşleşme kimliğine bağlı; A'nın tam durumu B'ye izin açmaz). Bilinen sınır: istekteki `device` (defter kimliği) beyandır, eşleşme kimliğine bağlı doğrulanmaz (ikisi farklı kimliktir); yetkili cihaz yalnızca kendi imzalı oturumuyla konuşabilir, kimlik taklidi (başka cihazın anahtarı/oturumu) 401'dir. Aynı cihaz kimliğiyle doğru kodlu yeniden eşleşme o cihazın anahtarını yeniler (kod = kullanıcı onayı); yanlış kodla mevcut cihaz ezilmez.

Gerçek Wi-Fi'da (farklı cihazlar, gerçek ağ gecikmesi, Android arka plan kısıtları) doğrulanmadı; testler 127.0.0.1'dedir.


## Her cihaz hem istemci hem alıcı (v9.23)

İstek: "tablet = telefon = bilgisayar arasında AYRI AYRI eşleştirme yapılabilsin". Bilgisayar tek merkez olmak zorunda değil; bilgisayar hâlâ aracı olabilir.

**Alıcı Android.** `SyncServer` masaüstüne özgü olmaktan çıktı: `lib/features/sync/data/sync_server.dart` (+ `server_sync_store.dart`, `ledger_exchange.dart`); yollar (`mediaRoot`, `pdfRoot`, `workDir`), kalıcı depo ve `kind` dışarıdan verilir, yalnızca `dart:io` kullanılır. `lib/desktop/sync/data/*` eski içe aktarmalar için `export` verir. Android'de `ReceiveController` (Ayarlar → Cihazlarla eşitle → "Bu cihazda kod göster"): 6 haneli kod, 5 dk, 5 hak, eşleşmiş cihaz listesi, kaldır; en çok 4 cihaz. **Arka plan servisi yok:** sunucu uygulama ön plandayken çalışır; `AppLifecycleState.paused/hidden`da durur, öne gelince (kullanıcı "Alıcı açık" bıraktıysa) yeniden başlar; eşleşmeler `alici.json`'da kalır. Ek izin gerekmedi (INTERNET zaten var; dinleme için ayrı manifest izni yok). Gerçek cihazda Android'in yerel ağ/güç kısıtları (ör. Android 17 `ACCESS_LOCAL_NETWORK`, ekran kapanınca soket) DOĞRULANMADI.

**Güvenlik kuralları değişmedi** (aynı sınıf, aynı denetimler): yalnızca yerel ağ adresleri (loopback yalnız testte), tarayıcı başlıkları ve alan adlı Host reddi, kod 5 dk / 5 hak, DH + HMAC + sıra numarası, imzalı yanıt, adres başına hata yasağı, "genel okuma yok" + üç dar istisna (`fotograf-al`, gövdesiz PDF var-mı, `pdf-al`), sağlık tabloları senkron dışı, anahtarlar veritabanı DIŞINDA ayrı dosyada (`alici.json` alıcı için, `esitleme.json` istemci için; ikisi yedeğe ve kablosuz eşitlemeye girmez). Değişenler: (1) `acceptedComputerPlatforms` = {linux, android}: istemci artık Android alıcıya da bağlanır; (2) Android alıcı tam yedek (ZIP) ucunu kapatır (`importBackup == null` → 404): yabancı bir veritabanını satır satır birleştiren yol yalnızca bilgisayarda; (3) hello'ya isteğe bağlı `tur` (bilgisayar/telefon/tablet) ve defter yanıtına isteğe bağlı `cihaz` (alıcının defter kimliği) eklendi (eski sürümle uyumlu: yoksa yok sayılır); (4) `LedgerRequest.anlikGonder`: yalnız eksik satır ekleyen tam durum itmesi (Android alıcıya; bilgisayar bunun yerine ilk eşitlemede yedek alır).

**Çok eş (istemci).** `PhoneSyncStore.computers()` en çok 4 eş tutar (`esler`: id, ad, adres, anahtar, platform, tür; eski tek `bilgisayar` kaydı okunurken göçer, `eskiImlec` bayrağıyla genel imleçler o eşe bir kez kopyalanır). Eşleşme kayıtları, anahtar, istemci kimliği ve ledger imleçleri eş başınadır: `gonderilen_sira:<eş>`, `alinan_sira:<eş>`, `tam_durum_*:<eş>`, `anlik_ver_*:<eş>`, `es_defter_kimligi:<eş>` (`esitleme_durum`). `LedgerSync(scope: eşKimliği)` eş başına çalışır; `scope == null` v9.22 davranışıdır (genel imleçler, yalnızca kendi satırları: eski testler). Bir eşi kaldırmak yalnızca onun imleçlerini siler (`LedgerSync.forgetPeer`), veri silinmez, öbür eşler etkilenmez.

**Aracılık, yankı ve döngü.** İstemci de aracıdır: eşten aldığı satırları, eşin KENDİ yazdıkları hariç (`pendingFor(relayExcept: eşin defter kimliği)`), öbür eşlere verir; ilk turda eşin defter kimliği bilinmediği için yalnız alır (yankı olmasın). Tekilleştirme: her değişiklik tek `id`'dir; `applyRemote` bilinen kimliği atlar, yani üçgenin iki yolundan gelen aynı değişiklik bir kez uygulanır. Yankı önleme: (a) satırın kaynağına geri gitmesi `cihaz_id` süzgeciyle; (b) bir turda eşten uygulanan satırlar deftere `(from, to]` aralığında yazılır (`LedgerService.applyRemoteRanged`, AYNI işlemde okunur: arayüz yazımı araya giremez); aralığa kadar verilecek başka satır kalmadıysa eşe geri verilmez ve imleç aralığın sonuna çekilir (hem alıcı yanıtında hem istemci gönderiminde). Kalan: aynı satır üçüncü bir yoldan geldiğinde BİR KEZ "zaten vardı" sayılır (ör. telefon↔tablet doğrudan eşleşmiş ve ikisi de bilgisayarla eşleşmişse); sonra imleç geçer ve hareket durur. Döngü yok: yeni kayıt yalnızca ilk uygulamada oluşur. Aynı satırı iki cihaz ayrı değiştirirse HLC'si yeni olan kazanır, kaybeden `cakismalar`'da kalır; üç cihaz aynı değere yakınsar (`test/sync_p2p_test.dart`).

**Tam durum, iki yön.** Yeni eş (`LedgerSync.markNewPeer`): karşıdaki güncel satırlar çekilir (`anlik`, eskisi gibi); Android alıcıya ayrıca kendi güncel satırlarım verilir (`anlikGonder` → alıcıda `applySnapshot`: yalnız eksik satır, var olana dokunulmaz, silineni geri getirmez, deftere işlenmez). Bu sırada defter geçmişi yeniden oynatılmaz; bitince YENİ eşte alınan/gönderilen sıra işarete çekilir (yeniden oynatma sahte çakışma çıkarırdı). Bilgisayara bunun yerine ilk eşitlemede tam yedek gider (yalnız Linux alıcıya; eş başına `defter_basladi:<eş>`).

**Bilinen sınırlar / doğrulanmayanlar.**
- Tam durumla (çekme ya da itme) gelen satırlar deftere girmediği için başka eşe aktarılmaz: tabletin telefondan tam durumla aldığı eski (deftersiz) satırlar, tablet bilgisayarla da eşleşmişse, bilgisayara tabletten gitmez (bilgisayara telefondan yedekle ya da kendi tam durumuyla gelir).
- Her iki cihazda da bulunan ama farklı içerikli eski satır, eşleşmede kendiliğinden eşitlenmez ("var olana dokunulmaz"); sonraki değişiklik normal çakışma kuralıyla çözülür.
- Bilgisayar İSTEMCİ olarak başka bir Android alıcıya bağlanamaz (yalnızca Android cihaz istemcidir). Bilgisayar ↔ Android veri akışı yine iki yönlüdür: Android bilgisayara bağlandığında hem gönderir hem alır; bilgisayarın Android kodunu girmesi eklenmedi (en küçük güvenli kapsam).
- Android alıcının ön plan açılışında kendiliğinden başlaması için `receiveControllerProvider`'ın uygulama kökünde izlenmesi gerekir (`lib/app/app.dart`; bu görev kapsamı dışında bırakıldı): şimdilik ekran/sağlayıcı ilk okunduğunda başlar.
- Gerçek Wi-Fi'da (iki cihaz, Android güç/ağ kısıtları, UDP yayın) doğrulanmadı; testler 127.0.0.1'dedir.
