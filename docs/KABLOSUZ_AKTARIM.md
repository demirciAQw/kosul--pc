# Kablosuz aktarım ve iki yönlü senkron (telefon ⇄ bilgisayar)

Protokol v1, düz HTTP (`dart:io`). Portlar: TCP **47321**, UDP **47322** (bulma). Kod: `lib/features/sync/` (ortak), `lib/desktop/sync/` (sunucu).

## Kurallar

| Kural | Nasıl sağlanır |
|---|---|
| Yalnızca uygulamanın alanı | Sunucuda okuma/listeleme yok. Yazma yalnızca `media/` altına, `^(questions\|solutions\|notes)/\d{4}/\d{2}/[A-Za-z0-9_-]{1,80}(\.[A-Za-z0-9]{1,8})?$` yollarıyla. `../` ve symlink kaçışı reddedilir. Telefon yalnızca kendi listesindeki dosyaları gönderir. |
| Yalnızca eşleşmiş cihaz | Eşleşmemiş istek reddedilir. |
| En fazla iki cihaz | Bir bilgisayar, bir telefon. Yenisi için eskisi elle kaldırılır (veri silinmez). |
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
- Senkron dışı tablolar: `app_meta`, `degisiklikler`, `_baglam`, `cakismalar`, `esitleme_durum`. Bunlar bilgisayara ve yedek birleştirmeye girmez.
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
