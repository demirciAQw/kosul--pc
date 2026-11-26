# Claude Code ile Koçum verisi (yerel MCP sunucusu)

Bilgisayardaki Claude Code, Koçum verisini **yerel bir MCP sunucusu** (`bin/kocum_mcp.dart`) üzerinden okur. Ağ yok, API anahtarı yok: Claude Code sunucuyu kendi süreci olarak başlatır, konuşma STDIO üzerindendir.

Kod: `lib/mcp/` (saf Dart), giriş `bin/kocum_mcp.dart`. Testler: `test/mcp/mcp_test.dart`.
(Uygulama içinden Claude API için bkz. CLAUDE.md "Claude entegrasyonu"; o ayrı bir yoldur.)

## Ekleme

Yer tutucuları kendi yollarınla değiştir.

```bash
claude mcp add kocum -- dart run /YOL/kocum/bin/kocum_mcp.dart --db /YOL/kocum.sqlite
# yazma araçları da istenirse (aşağıya bak):
claude mcp add kocum-yaz -- dart run /YOL/kocum/bin/kocum_mcp.dart --db /YOL/kocum.sqlite --yaz
```

ya da proje kökünde `.mcp.json`:

```json
{
  "mcpServers": {
    "kocum": {
      "command": "dart",
      "args": ["run", "/YOL/kocum/bin/kocum_mcp.dart", "--db", "/YOL/kocum.sqlite"]
    }
  }
}
```

- `--db` yoksa `KOCUM_DB`, o da yoksa bilgisayar uygulamasının veritabanı: `~/.local/share/com.kocum.kocum/kocum.sqlite`. Dosya yoksa sunucu çıkış kodu 2 ile kapanır (önce bilgisayardaki Koçum'u bir kez aç).
- Uygulama açıkken de çalışır (WAL, `busy_timeout`).
- Sunucu veritabanını uygulamadan YENİ bir şemada bulursa yükseltemez (salt okuma kilidi). Önce uygulamayı aç.

## Araçlar

Salt okuma (her zaman): `ozet`, `yanlis_sorular` (ders/konu/baslangic/bitis/durum, `en_cok` ≤ 100, `sayfa`), `konu_analizi`, `deneme_sonuclari`, `kitap_ilerlemesi`, `ara` (Türkçe duyarsız, `normalizeTr`). **Ham SQL aracı yoktur.**

Yazma (yalnız `--yaz` ile listelenir): `soru_konu_duzelt`, `soru_etiket_ekle` (var olan etiket; yenisini oluşturmaz), `not_ekle`.

## Güvenlik modeli

- **STDIO, ağ yok.** Sunucu soket açmaz; stdout yalnızca JSON-RPC, tanı iletileri stderr'e.
- **Varsayılan salt okuma.** `--yaz` yoksa yazma araçları listelenmez ve çağrılırsa JSON-RPC hatası döner; ayrıca veritabanı bağlantısı `PRAGMA query_only = ON` ile kilitlenir (açılıştan sonra), yani bir hata olsa bile yazılamaz.
- **Sağlık verisi yok.** `saglik_*` tabloları hiçbir araçta okunmaz; araçlar yalnızca sabit, parametreli sorgular çalıştırır (kullanıcı metni asla SQL'e eklenmez, `LIKE` joker karakterleri etkisizdir).
- **Yazmalar deftere girer.** Hepsi `kocum` aracının yolundan (`LedgerService.withSource('claude', session: …)`) geçer: uygulamadaki "Claude'un değişiklikleri" ekranında görünür, madde madde ya da oturum oturum geri alınır. Oturum adı `claude-mcp-<tarih>` (`--oturum X` ile değişir). Silme aracı yoktur.
- Yazma araçlarında değerler `--` ile başlayamaz (komut satırı bayrağı sızdırılamaz); bilinmeyen `((etiket))`/`@kişi` hata verir.
- Çıktı kişisel veri içerir (sorular, notlar): Claude Code'a erişim verdiğin şeyin bu olduğunu bil.

## Protokol

Sunucu `initialize` el sıkışmalı sürümleri konuşur: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05` (istemcinin istediği sürüm destekleniyorsa aynısı, değilse en yenisi döner). Bildirimler yanıtsızdır; `ping`, `tools/list`, `tools/call` desteklenir. Hata kodları: `-32700` geçersiz JSON, `-32600` geçersiz istek, `-32601` yöntem yok, `-32602` geçersiz parametre/bilinmeyen araç, `-32603` iç hata (ayrıntısız). Araç hataları `isError: true` ile döner.

modelcontextprotocol.io'da "güncel" sürüm `2026-07-28` olarak görünüyor ve el sıkışmasızdır (`server/discover`). Stdio geri uyumluluk kuralı gereği yeni istemci `server/discover` sorusuna "yöntem yok" hatası alınca `initialize`a döner; bu sunucu yeni sürümü ayrıca UYGULAMAZ. Gerçek Claude Code ile uçtan uca denenmedi (aşağıdaki not).
