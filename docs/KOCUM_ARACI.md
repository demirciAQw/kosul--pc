# `kocum` komut satırı aracı (Claude'un veriye eli)

Claude'un bilgisayardaki Koçum verisini okuyup düzenlemesi içindir. Her yazma **`kaynak: claude`** ve bir **oturum kimliğiyle** değişiklik defterine geçer; yani "Claude'un değişiklikleri" ekranından madde madde ya da oturum oturum geri alınabilir.

Kod: `lib/cli/kocum_cli.dart` (testli, saf Dart), giriş: `bin/kocum.dart`. Testler: `test/kocum_cli_test.dart`, `test/external_change_test.dart`.

## Çalıştırma

```bash
dart run bin/kocum.dart <komut> …          # depodan
tool/kocum.sh <komut> …                    # aynısı, her klasörden
dart compile exe bin/kocum.dart -o ~/.local/bin/kocum   # tek dosya (libsqlite3 gerekir)
```

- Veritabanı: `~/.local/share/com.kocum.kocum/kocum.sqlite` (bilgisayar uygulaması). Başka dosya için `KOCUM_DB=/yol/kocum.sqlite`.
- Dosya yoksa araç hata verir: önce bilgisayardaki Koçum'u bir kez aç.
- **Uygulama açıkken de güvenli**: WAL ve `busy_timeout` (5 sn). Araç yazarken uygulama beklemez/bozulmaz. Bilgisayar uygulaması `PRAGMA data_version` ile dış değişikliği 2 sn içinde fark edip ekranları yeniler.
- Araç, uygulamadan **yeni sürümdeyse** veritabanını yükseltir; uygulamayı da güncelle (aynı depo).
- Çıktı JSON (stdout). Hata: stderr'e `{"hata": "…"}`. Dönüş kodu: 0 tamam, 1 işlem hatası, 2 kullanım hatası.

## Oturum

Claude'un bir çalışması tek oturumdur; geri alma oturum başınadır.

1. `--oturum X` bayrağı, yoksa
2. `KOCUM_OTURUM` ortam değişkeni, yoksa
3. `claude-<bugünün tarihi>`.

Her yazma çıktısı `oturum` ve `degisiklik` (deftere giren satır sayısı) alanlarını döner.

## Komutlar

### Okuma

| Komut | Ne yapar |
|---|---|
| `sorgu "<SELECT …>" [--limit N]` | **Salt okunur** sorgu (`SELECT` ya da `WITH`); tek ifade. Yazan, çoklu ya da PRAGMA içeren sorgu reddedilir. Varsayılan en çok 1000 satır. |
| `oturumlar` | Claude oturumları: değişiklik sayısı, geri alınan, ilk ve son zaman. |
| `disa-aktar <klasör>` | Notları ve günlük özetleri Markdown yazar (aşağıda). |

### Yazma

| Komut | Ne yapar |
|---|---|
| `not-ekle <metin> [--etiket a,b] [--kisi ad,ad] [--ders D] [--konu K] [--zaman 2026-10-20T08:30] [--ruh 1-5] [--olustur]` | Anlık not. Metindeki `((etiket))` ve `@kişi` çözülür. |
| `etiket-ekle <hedef> <etiket> [--olustur]` | Nota ya da soru kartına etiket. Hedef: `not:<id>`, `soru:<id>` ya da yalın kimlik. Etiket `üst > alt` yolu olabilir. |
| `etiket-kaldir <hedef> <etiket>` | Etiketi kaldırır (etiketin kendisi silinmez). |
| `kisi-ekle <ad> [--takma a,b] [--not "kim"]` | Kişi ekler (aynı ad ya da takma ad varsa hata). |
| `kisi-bagla <not> <kişi>` | Kişiyi nota bağlar (ad, takma ad ya da kimlik). |
| `bagla <not> <not:<id> \| soru:<id>>` | Notu başka nota ya da soru kartına bağlar. |
| `duzelt <tablo> <id> <alan> <değer>` | Bir alanı değiştirir. Değer alan türüne göre okunur (`null`, sayı, `true/false`, tarih → saniye). Kimlik, defter ve `app_meta` düzeltilemez. `anlik_notes.body` değişince arama metni ve güncelleme zamanı da güncellenir. |
| `sil-oner <tablo> <id> [--neden "…"]` | **Silmez**; yalnızca işaretler. Öneri iki uygulamada "Claude'un değişiklikleri" ekranının üstünde görünür; kullanıcı **Sil** ya da **Kalsın** der. |
| `geri-al <değişiklik-id>` / `geri-al --oturum X` | Geri alır: `eski` değer yeni bir değişiklik olarak yazılır (`kaynak: geri_al`), geri alma da geri alınabilir. Satır o arada değiştiyse üstüne yazılmaz, Çakışmalar'a düşer. |

**Yeni etiket ve kişi kendiliğinden oluşmaz**: Claude `--olustur` demeden, olmayan bir etiket ya da kişi kullanılırsa komut hata verir ve adları söyler (uygulamadaki "adı onayla" kuralının karşılığı).

Not: araçta otomatik konu etiketi yoktur (konu sözlüğü uygulamanın varlıklarından yüklenir); gerekirse Claude `--etiket` verir.

## Markdown dışa aktarma

`kocum disa-aktar <klasör>`:

- `anlik/YYYY/MM/YYYY-MM-DD_HHmm_<kimlik>.md`: her not bir dosya.
- `gunluk/YYYY-MM-DD.md`: günlük özet (not sayısı, ruh hâli ortalaması, uyku, etiketler, kişiler, notların ilk satırları).

Not dosyasının biçimi:

```markdown
---
id: 01a1f631-eceb-7af7-82d5-42b886d54239
zaman: 2026-10-20T08:30:00
tur: anlik            # anlik | uyku_yattim | uyku_kalktim
ruh: 2               # varsa
ders: TYT Matematik   # varsa
konu: Türev           # varsa (serbest konu ya da MEB kimliği)
etiketler: ["his > tiksinti", ders]
kisiler: [Şule]
baglar: [not:<id>, soru:<id>]
---

Notun gövdesi.
```

Aynı dosya yeniden yazılır (üzerine yazar); araç hiçbir dosyayı silmez.

## Soru kartında PDF koordinatı (şema 17)

Tabletten PDF'te seçilen sorular `question_cards` satırıdır; `sorgu` ve `duzelt` bu sütunları okur/yazar:

| Sütun | Anlam |
|---|---|
| `pdf_document_id` | `pdf_documents.id` (= PDF'in sha256'sı); PDF'siz kartta NULL |
| `pdf_page` | PDF sayfası, 0'dan |
| `pdf_box_left`, `pdf_box_top`, `pdf_box_right`, `pdf_box_bottom` | Kutu, sayfa birimi (1/72 inç), döndürülmüş sayfa, sol-üst başlangıç, y aşağı (`real`) |

`question_image` bu durumda kutunun küçük önizlemesidir (WebP; Android dışında PNG): PDF'i olmayan cihazlarda soru görüntüsü olarak görünür. Beşi birden dolu olmalıdır (`duzelt` tek tek yazar: kutuyu değiştirirken `pdf_box_*` dördünü de düzelt, `sag > sol` ve `alt > ust` kalsın; yoksa uygulama kutuyu yok sayar ve kart PDF'siz görünür).

```bash
dart run bin/kocum.dart sorgu "SELECT id, pdf_page, pdf_box_left, pdf_box_top, pdf_box_right, pdf_box_bottom FROM question_cards WHERE pdf_document_id IS NOT NULL"
```

## Güvenlik özeti

- `sorgu` salt okunurdur (`PRAGMA query_only`, ifade denetimi).
- Yazmalar yalnızca bilinen kullanıcı tablolarına; defter, çakışmalar, imleçler ve ayarlar düzeltilemez.
- Silme yok: `sil-oner` yalnızca işaretler; geri alma yeni bir değişiklik olarak yazılır.
- Her şey deftere geçer; bilgisayardaki değişiklikler eşitlemeyle telefona da gider ve oradan da geri alınabilir.
