# Koçum Masaüstü (Linux)

Telefondaki Koçum verisinin büyük ekranda görüldüğü ve yönetildiği uygulama. Telefonla **aynı depo, aynı veritabanı şeması, aynı analiz kodu**; yalnızca ekranlar ve giriş noktası ayrı.

> **Durum:** Derlenir ve açılır (`flutter build linux --release`, v8.7'de ilk kez derlendi); testler `flutter test` içindedir. Telefondaki veri girişinin tamamı bilgisayardan da yapılabilir (v8.10) ve iki yönlü senkronla telefona gider ([KABLOSUZ_AKTARIM.md](KABLOSUZ_AKTARIM.md)).

## Ne yapar?

| Bölüm | Durum | Ne yapar |
|---|---|---|
| **Defter** | hazır | Soldaki tabloda tüm sorular, sağda seçili sorunun ayrıntısı (fotoğraf, çözüm, etiketler, benzer sorular). Sütunlar: Tarih, Ders, Konu, Kitap / kaynak, Durum, Neden. Sütun başlığına basınca sıralar, yeniden basınca yön değişir. Filtreler: ders, durum (Yanlış/Boş/Doğru), kaynak, neden; Türkçe harf duyarsız arama. Klavyeyle ↑ ↓ Page Up / Page Down. |
| **Ayarlar → Telefondan veri al** | hazır | Telefonun yedek ZIP'ini ya da açılmış klasörünü seç; özet gösterilir, onaylayınca birleştirilir. |
| **Ayarlar → İzlenen klasör** | hazır | Syncthing, KDE Connect ya da USB ile bir klasöre düşen yeni yedek, yazılması bitince (3 sn sessizlik) kendiliğinden içe aktarılır. |
| **Ayarlar → Koç klasörü** | hazır | Her içe aktarmadan sonra fotoğrafsız `Koçum/kocum_yedek.json` bu klasöre (ör. Obsidian kasası) yazılır; yapay zekâ koçu buradan okuyabilir. |
| **Ayarlar → Telefonda silinenler** | hazır | Telefonda silinip bilgisayarda duran kayıtlar burada listelenir; yalnızca sen silersen silinir. |
| **Ayarlar → Telefon eşleştirme** | hazır | Aynı Wi-Fi'daki eşleşmiş telefondan gönderim alır ([KABLOSUZ_AKTARIM.md](KABLOSUZ_AKTARIM.md)). |
| **Ayarlar → Görünüm, İçe aktarma geçmişi** | hazır | Sistem/açık/koyu tema; geçmiş içe aktarmalar. |
| **Defter → Soru ekle / Düzenle** | hazır | Soru ve çözüm fotoğrafı: dosya seç ya da pencereye sürükle-bırak; mevcut kırpma ekranıyla kırp (PNG). Ders, MEB konusu, neden, zorluk, şık ya da yazılı cevap, çözüm metni. Ctrl+S kaydeder. Fotoğraftaki yazı telefonda okunur. Seçili soruya etiket ve not bağlanır. |
| **Kitaplar** | hazır | Elle kitap, şablon dosyası (JSON) ya da hazır şablonlardan ekle; bölüm ve test ağacını düzenle (ekle, yeniden adlandır, sırala, onaylı sil); test sonucu işaretle. |
| **Optik** | hazır | Kitap testinin cevaplarını klavyeyle gir: A–E (cevap anahtarıyla) ya da D / Y / B; her tuşta sonraki soru. Ok tuşları gezer, Boşluk boş, Geri siler, Tab kip değiştirir, Ctrl+S kaydeder. |
| **Denemeler** | hazır | Elle deneme (TYT, AYT, YDT, branş), düzenle, onaylı sil; karne PDF'i içe aktar (önizleme, yanlış ve boşları deftere ekle). |
| **Oturumlar** | hazır | Pencere içi sayaçla çalışma oturumu (kitaptan ya da kitapsız); bitir, sonuç gir, süreyi düzelt, onaylı sil. Telefonun bildirim kronometresine dokunulmaz. |
| **Planlar** | hazır | Plan oluştur, görev ekle ve işaretle, yapay zekâ programını içe aktar. |
| **Analiz** | hazır, salt okunur | Telefondaki derin analiz, soru kökü analizi, örüntüler, en çok yanlış ve çalışma süresi. |
| **Notlar, Kişiler, Etiketler** | hazır | Anlık notlar (Ctrl+N, Ctrl+S, Ctrl+F), kişiler, etiket ağacı (yeniden adlandır, üst etiket, birleştir). |
| **Claude'un değişiklikleri, Çakışmalar** | hazır | `kocum` aracının yaptığı değişiklikler oturum oturum geri alınır; iki cihazda da değişen satırların kaybeden sürümü ([KOCUM_ARACI.md](KOCUM_ARACI.md)). |

Masaüstünde **olmayanlar**: kamera, fotoğraftan metin okuma (ML Kit), oturum sayacı bildirimi, hatırlatıcılar. Bunlar telefonun işi ve bilgisayarda hiç başlatılmaz.

## Birleştirme: "telefon kazanır"

`lib/desktop/import/data/snapshot_merger.dart`

1. Yedekteki `kocum.db` kopyası geçici bir yere yazılır ve SQLite `ATTACH` ile açılır.
2. Tablo ve sütun listesi **şemadan okunur**: şema değişince birleştirme kodu değişmez.
3. Aynı kimlikli satır telefondakiyle değişir, yeni satır eklenir.
4. Bilgisayarda olup kopyada olmayan satır **silinmez**; "telefonda silindi" listesine düşer, ilk görüldüğü tarih saklanır.
5. `app_meta` (uygulama ayarları) alınmaz. Bilgisayarın kendi ayarları `app_meta`'da `masaustu.` önekiyle durur.
6. Fotoğraflar `media/` altına kopyalanır; aynı boyuttaki dosya yeniden yazılmaz.
7. Yedek, son içe aktarılandan **eskiyse** önce sorulur: eski yedek yeni kayıtları "silindi" gösterir.

## Dosya haritası (`lib/desktop/`)

| Dosya | Görev |
|---|---|
| `desktop_main.dart` | Kompozisyon kökü: veri klasörü, veritabanı, medya, MEB tohumlama. Telefonun arka plan işleri başlamaz. |
| `desktop_app.dart` | `MaterialApp` ve tema |
| `desktop_providers.dart` | Veri klasörü, bölümler (`DesktopSection`), uygulama geneli bildirim |
| `shell/desktop_shell.dart` | Soldaki kalıcı gezinme (`NavigationRail`) ve sayfalar |
| `widgets/` | `DesktopPage` iskeleti, `SettingsCard`, `FileDropZone` (sürükle-bırak; `desktop_drop`) |
| `entry/` | Veri girişi sayfaları: soru düzenleyici, kitaplar, optik, denemeler, oturumlar, planlar |
| `anlik/` | Notlar, Kişiler, Etiketler sayfaları |
| `analysis/` | Salt okunur Analiz |
| `data/external_change_watcher.dart` | `PRAGMA data_version` ile dış değişikliği fark edip ekranları yeniler |
| `import/domain/` | Saf Dart: içe aktarma modelleri, hangi tabloların alınacağı, "eski yedek mi", silinenler listesi |
| `import/data/backup_source.dart` | ZIP ya da klasörden yedek okuma (bağımlılıksız ZIP okuyucu) |
| `import/data/snapshot_merger.dart` | Satır satır birleştirme |
| `import/data/import_service.dart` | `prepare` (özet) → `run` (birleştir), koç klasörüne yazma |
| `import/data/desktop_state_store.dart` | İçe aktarma geçmişi, izlenen ve koç klasörü ayarları |
| `import/presentation/` | İçe aktarma akışı, özet penceresi, izlenen klasör izleyicisi |
| `notebook/domain/notebook_table.dart` | Saf Dart: sütunlar, filtre, sıralama, arama |
| `notebook/notebook_page.dart` | Tablo + ayrıntı ekranı |
| `settings/desktop_settings_page.dart` | Ayarlar sayfası |
| `sync/` | Kablosuz alma: sunucu, eşleşme kaydı, denetleyici, ekran |

Ortak kod: `lib/core/` (veritabanı, medya, metin), `lib/features/*/domain` ve `data` (depolar, analizler), `lib/features/sync/domain` (kablosuz kurallar). Platform denetimi yalnızca `lib/app/platform.dart`; `lib/main.dart` tek satırla `runDesktop()`'a geçer.

## Veriler nerede?

| Ne | Yer |
|---|---|
| Veritabanı | `~/.local/share/com.kocum.kocum/kocum.sqlite` |
| Fotoğraflar | aynı klasörde `media/` |
| Kablosuz eşleşme anahtarı | aynı klasörde `esitleme.json` (izin 600, veritabanında değil) |

Klasör adı uygulama kimliğinden gelir; `flutter create --org com.kocum` ile `com.kocum.kocum` olur.

## Kurulum

### 1. Gerekenler

```bash
# Arch / CachyOS
sudo pacman -S --needed clang cmake ninja pkgconf gtk3
# Ubuntu / Debian
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
```

Flutter (stable) kurulu olmalı. Dosya seçme penceresi için KDE'de `kdialog`, GNOME'da `zenity` gerekir (çoğunda zaten vardır).

### 2. Derle ve çalıştır

```bash
tool/setup_linux.sh          # linux/ iskeleti + paketler + Drift kodu
flutter test
flutter run -d linux
```

### 3. Uygulama menüsüne kur (isteğe bağlı)

```bash
tool/install_linux.sh
```

Program `~/.local/opt/kocum/` altına kurulur ve menüde "Koçum" olarak görünür. Verilere dokunulmaz. Kaldırmak için `~/.local/opt/kocum/`, `~/.local/share/applications/com.kocum.kocum.desktop` ve simgeyi silmek yeter.

### Derlemeden indirmek

GitHub Actions → **Linux derle** → Run workflow. Bittiğinde **kocum-linux** dosyasını indir:

```bash
tar -xzf kocum-linux-x64.tar.gz
./kocum/kocum
```

## Güvenlik duvarı (kablosuz alma için)

```bash
sudo ufw allow from 192.168.0.0/16 to any port 47321 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 47322 proto udp
```

## Sıradaki işler

- Soru fotoğrafı için bilgisayarda kırpma ekranı fare ve klavyeyle çalışır ama dokunmatik ekran için ayrı ayarı yoktur.
- Tablet + PDF modu: [TABLET_PDF.md](TABLET_PDF.md).
