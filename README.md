# Koçum

YKS öğrencileri için **çevrimdışı** çalışma, süre ve hata analizi takipçisi. İki uygulama, tek kod tabanı:

| | Platform | Rol |
|---|---|---|
| **Koçum Mobil** | Android (telefon, tablet) | Çalışırken kullanılan uygulama: oturum sayacı, optik form, yanlış defteri, fotoğraftan okuma, tekrar, deneme, analiz |
| **Koçum Masaüstü** | Linux (Flutter Linux hedefi) | Telefondaki verinin büyük ekranda görüldüğü ve yönetildiği yer: yedek içe aktarma, Defter tablosu, kablosuz alma |

Flutter · Clean Architecture · SQLite (Drift) · Riverpod 3. Veriler cihazda kalır; bulut ve hesap yoktur.

> Bu depo, ana geliştirme deposu olan `demirciAQw/kosul`'un tam geçmişiyle birlikte telefon ve bilgisayar kodunu tek yerde toplar.

## Durum

Güncel sürüm: **8.6.0** (`pubspec.yaml`). Sürüm notları: [docs/SURUMLER.md](docs/SURUMLER.md).

| Parça | Durum |
|---|---|
| Mobil uygulama | Kararlı, v0.2'den v8.6'ya kadar geliştirildi |
| Masaüstü 1. aşama (yedek içe aktarma, Defter) | Yazıldı; **sandbox'ta derlenemedi**, ilk `flutter test`te doğrulanacak |
| Masaüstü 2. aşama (kablosuz aktarım) | Yazıldı, uçtan uca testleri var; **henüz derlenip çalıştırılmadı** |
| Masaüstü 3. aşama (kitap ekleme/düzenleme) | Planlandı, başlanmadı |

## Hızlı başlangıç

```bash
git clone https://github.com/demirciAQw/kosul--pc.git
cd kosul--pc
tool/setup.sh                                            # Android iskeleti + paketler + kod üretimi
dart run build_runner build --delete-conflicting-outputs
flutter test
```

**Telefon:** `flutter run --release` ya da GitHub Actions ile APK (`ci/build-apk.yml`, ayrıntı: [NASIL_DENENIR.md](NASIL_DENENIR.md)).

**Bilgisayar (Linux):**
```bash
tool/setup_linux.sh        # linux/ iskeleti + paketler + kod üretimi
flutter run -d linux
tool/install_linux.sh      # isteğe bağlı: uygulama menüsüne kur
```
Ya da GitHub Actions → **Linux derle** ile hazır paket (`kocum-linux-x64.tar.gz`). Masaüstü verisi `~/.local/share/com.kocum.kocum/` altında durur. Ayrıntı: [docs/MASAUSTU.md](docs/MASAUSTU.md).

## Telefon ile bilgisayar nasıl konuşur?

İki yol var; ikisi de **veriyi satır satır birleştirir, telefon kazanır, hiçbir şey sessizce silinmez**.

1. **Yedek ZIP'i:** Telefonda Araçlar → tüm veriyi dışa aktar. ZIP'in içindeki `kocum.db` kopyası masaüstünde içe aktarılır.
2. **Kablosuz (v8.6):** Aynı Wi-Fi'da, Araçlar → *Bilgisayara gönder*. Eşleşme tek seferlik 6 haneli kodla yapılır; yalnızca yeni fotoğraflar ve veritabanı kopyası gider. Güvenlik tasarımı: [docs/KABLOSUZ_AKTARIM.md](docs/KABLOSUZ_AKTARIM.md).

## Mimari özeti

```
lib/
├─ main.dart              telefon girişi
├─ app/                   kabuk, router, tema, platform denetimi (tek yerde)
├─ core/                  database, media, notifications, json, text, utils
├─ features/              telefon özellikleri (domain / data / presentation)
│  ├─ question_bank/ library/ study_session/ planning/ mock_exam/
│  ├─ dashboard/ curriculum/ notes/ ocr/ tools/ settings/ home/
│  └─ sync/               telefon istemcisi + ortak kablosuz kurallar (saf Dart)
└─ desktop/               yalnızca masaüstü: desktop_main.dart girişi
   ├─ import/ notebook/ settings/ shell/ widgets/
   └─ sync/               bilgisayar sunucusu ve ekranı
```

Kurallar: domain saf Dart; bağımlılık yönü içe doğrudur; masaüstüne özel kod yalnızca `lib/desktop/` altındadır ve platform denetimi tek dosyadadır (`lib/app/platform.dart`). Telefon akışı bozulmaz, Android derlemesi ve APK aynen çalışır. Ayrıntı: [docs/MIMARI.md](docs/MIMARI.md).

## Belgeler

| Belge | İçerik |
|---|---|
| [docs/MASAUSTU.md](docs/MASAUSTU.md) | Bilgisayar sürümü: ne yapar, birleştirme, dosya haritası, kurulum |
| [docs/MIMARI.md](docs/MIMARI.md) | Katmanlar, ortak ve masaüstüne özel kod, veri akışı, kararlar |
| [docs/KABLOSUZ_AKTARIM.md](docs/KABLOSUZ_AKTARIM.md) | Eşleşme, imza, ağ ve dosya kuralları, tehdit modeli, sınırlar |
| [docs/MOBIL_OZELLIKLER.md](docs/MOBIL_OZELLIKLER.md) | Telefon modülleri, önemli kararlar, kitap şablonu JSON sözleşmesi v1, bilinen sınırlar |
| [docs/SURUMLER.md](docs/SURUMLER.md) | v0.2'den v8.6'ya sürüm geçmişi |
| [docs/TABLET_PDF.md](docs/TABLET_PDF.md) | Tablet + PDF modu tarifi |
| [CLAUDE.md](CLAUDE.md) | Geliştirme kuralları, tuzaklar, masaüstü ve kablosuz notları |
| [NASIL_DENENIR.md](NASIL_DENENIR.md) | APK derleme ve sabit imza |

## Gizlilik ve güvenlik kuralları

- İmza dosyaları (`imza.env`, `kocum-release.jks`) **asla** depoya girmez.
- APK'ya API anahtarı gömülmez.
- Kullanıcı verisi sessizce silinmez; geçici dosyalar iş bitince silinir.
- Kablosuz aktarım yalnızca eşleşmiş tek Android telefon ve tek Linux bilgisayar arasındadır; yalnızca uygulamanın kendi medya alanına yazar.

## Sonra yapılabilir

İçerik şifreleme (yeni paket gerekir) · QR ile eşleşme · mDNS ile bulma · şarjdayken otomatik gönderim · bilgisayardan telefona yön · sürükle-bırak · masaüstünde Kitaplar, Denemeler, Oturumlar, Analiz, Planlar, Notlar sayfaları · masaüstünde kitap ekleme/düzenleme (3. aşama).

## Lisans

Bkz. [LICENSE](LICENSE).
