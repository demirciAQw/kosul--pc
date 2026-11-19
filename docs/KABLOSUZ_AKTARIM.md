# Kablosuz aktarım (telefon → bilgisayar)

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
