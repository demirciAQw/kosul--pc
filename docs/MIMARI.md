# Mimari

## Katmanlar

Her özellik üç katmana ayrılır:

- `domain/`: saf Dart. Flutter, Drift, dart:io bilmez. Kurallar burada, testler burada.
- `data/`: Drift tabloları, JSON, dosya ve ağ erişimi.
- `presentation/`: ekranlar ve Riverpod denetleyicileri.

Bağımlılık yönü içe doğrudur (presentation → data → domain).

## Tek kod tabanı, iki uygulama

| Konu | Telefon | Masaüstü |
|---|---|---|
| Giriş | `lib/main.dart` | `lib/desktop/desktop_main.dart` |
| Ekranlar | `lib/features/*/presentation` | `lib/desktop/*` |
| Veritabanı | Drift (`lib/core/database`), ortak | aynı şema, ayrı dosya (`~/.local/share/...`) |
| Platform denetimi | `lib/app/platform.dart` (`platformName`, `canReceiveWirelessly`) | aynı dosya; başka yerde `Platform` kullanılmaz |
| Android izinleri | `tool/patch_android.dart` üzerinden | yok |

`pubspec.yaml` ortaktır. Yeni paket eklerken Android derlemesi de düşünülür.

Masaüstünde telefonun arka plan işleri (metin okuma, kamera, hatırlatıcı) başlamaz; masaüstü ekranları `sessionChronometerProvider` ve `reminderServiceProvider` okumaz.

## Veri akışı: telefon → bilgisayar

```
Telefon                                          Bilgisayar
collectFullBackup ──► (fotoğraf listesi + kocum.db kopyası)
SyncClient ── /kocum/v1/fotograflar ───────────► eksikleri söyler
           ── /kocum/v1/fotograf (PUT) ────────► media/ altına yazar
           ── /kocum/v1/yedek (PUT, ZIP) ──────► ImportService.prepare/run
                                                  (telefon kazanır, silme yok)
```

`collectFullBackup` (`lib/features/tools/full_backup.dart`) hem Araçlar'daki yedeğin hem kablosuz gönderimin ortak kaynağıdır.

## Birleştirme kuralları (masaüstü içe aktarma)

- Satır satır birleştirme: telefon kazanır.
- `app_meta` alınmaz; bilgisayarın kendi ayarları `masaustu.` önekiyle tutulur.
- Hiçbir kayıt sessizce silinmez.
- Anahtarlar (`esitleme.json`) veritabanında değil, ayrı dosyada durur; veritabanı kopyası yedeğe ve bilgisayara gittiği için anahtar sızmasın.

## Kitap şablonu

Şablon JSON sözleşmesi v1: [MOBIL_OZELLIKLER.md](MOBIL_OZELLIKLER.md). Örnekler: `assets/templates/`. 3. aşamada masaüstünde kitap ekleme/düzenleme bu sözleşmeyi kullanacak.

## Testler

- Domain testleri saf Dart (`test/*_domain_test.dart`).
- `test/sync_end_to_end_test.dart`: gerçek sunucu ve istemci 127.0.0.1'de (`allowLoopback: true` yalnızca testte).
- `test/network_patch_test.dart`: Android manifest yaması.

Geliştirme kuralları ve yaşanmış tuzaklar için `CLAUDE.md`.
