# Sürüm geçmişi

Sürüm numarası `pubspec.yaml` içindedir; her sürüm bir git etiketidir (`v8.6`, ...). Ayrıntı için ilgili commit mesajına bak.

| Etiket | Tarih | Not |
|---|---|---|
| v0.2 | 2026-10-12 | optik form, Eksikler, kitapsız oturum, iptal, uygulama içi kırpma, deneme analizi, örüntüler, sabit imza |
| v0.3 | 2026-10-12 | hazır kitaplar (Sıfır Risk Paragraf, Aydın 11 Kimya), test bazlı soru sayısı, plan bölümü |
| v0.4 | 2026-10-13 | Kitaplar sekmesi, test bazlı optik, kitaptan hızlı soru, düzenle/sil her yerde, logo |
| v0.5 | 2026-10-13 | okul karnesinden deneme içe aktarma |
| v0.5.1 | 2026-10-17 | soru silme gerçekten siler; tekrar ve eksik sayaçları düzelir |
| v0.5.2 | 2026-10-17 | MEB 11. sınıf kitap şablonları (Biyoloji, Fizik, Kimya, Matematik, Türk Dili ve Edebiyatı) |
| v0.5.3 | 2026-10-17 | beş soru bankası ve TYT / AYT / MEB rafları |
| v6.0 | 2026-10-18 | Google tarzı tasarım ve yeni logo |
| v6.1 | 2026-10-18 | Defter'e Notlar sekmesi, beyaz arka plan |
| v6.2 | 2026-10-18 | Google tarzı seçili seçenekler, açık gri zemin geri |
| v6.3 | 2026-10-18 | şıklar zorunlu, oturum testleri hemen işaretlenir, sorular kitaba bağlanır |
| v6.4 | 2026-10-19 | çözülen testler mavi, defter galerisi, fotoğraflı not defteri |
| v6.5 | 2026-10-21 | Ayarlar ve günlük hatırlatıcılar |
| v6.6 | 2026-10-21 | dışa aktarma, geri alınabilir tekrar notu, MEB düzeltmeleri |
| v6.6.1 | 2026-10-23 | derleme hatası düzeltmesi |
| v6.6.2 | 2026-10-23 | oturum ağacında 'results' derleme hatası |
| v6.7 | 2026-10-23 | yapay zekâ raporu, tekrarda benzer hatalar öne |
| v6.8 | 2026-10-24 | açık uçlu sorular için yazılı cevap |
| v6.9 | 2026-10-24 | derin analiz, sabit program, yapay zekâ programını içe aktarma |
| v7.0 | 2026-10-24 | Araçlar sekmesi, Claude paketleri, PDF yanlış defteri, yanlışlardan test |
| v7.1 | 2026-10-24 | LibreOffice Calc / Excel için tablo dışa aktarma |
| v7.2 | 2026-10-25 | kaybolan çip yazıları, deneme optiğinde görüntüleme modu, ortalama ve seçilebilir deneme |
| v7.3 | 2026-10-25 | hızlı fotoğraf: arka planda sıkıştırma, PNG'siz kırpma, hızlı mod |
| v7.4 | 2026-10-25 | Defter tek kaydırma alanında, grup hatası giderildi; kırpma önizlemeyle hızlı |
| v7.5 | 2026-10-25 | akıllı arama, arama geçmişi, arama veri seti |
| v7.6 | 2026-10-25 | fotoğraftaki metni okuma (ML Kit, telefonda) |
| v7.7 | 2026-10-26 | Koçum okuyucu 2: yeni nesil soruları yapısıyla okuma |
| v7.8 | 2026-10-26 | soru kökü analizi |
| v7.9 | 2026-10-26 | resim açıklaması (ML Kit GenAI, Gemini Nano) ile grafik ve şekil etiketleme |
| v8.0 | 2026-10-26 | otomatik konu ve soru türü etiketleri (modelsiz, telefonda) |
| v8.0.1 | 2026-10-26 | derleme hatası: math.max/min tür çıkarımı |
| v8.0.2 | 2026-10-26 | R8 eksik sınıf hatası (ML Kit dil okuyucuları) |
| v8.0.3 | 2026-10-27 | sürüm derlemesinde metin okuma hatası (R8) |
| v8.1 | 2026-10-27 | hızlı kamera (performans modu) ve optikte 'fotoğrafı yok' göstergesi |
| v8.1.1 | 2026-10-28 | Claude Code için proje notları ve tablet + PDF modu tarifi |
| v8.1.2 | 2026-10-29 | tarif: benzer sorularda gelişim ('bu hatayı öğrendim mi?') |
| v8.2 | 2026-10-29 | kurşun kalem ve renkli kalem izi altındaki yazıyı okuma |
| v8.3 | 2026-10-29 | benzer soruları yerelde arama (yanlışlar ve doğrular ayrı) |
| v8.4 | 2026-10-29 | parça parça, terim odaklı benzerlik ve soru eşleme |
| v8.5 | 2026-11-12 | yedeğe veritabanı kopyası (kocum.db) |
| v8.6 | 2026-11-12 | Bilgisayara gönder (telefon) ve Kablosuz alma (bilgisayar) |

## Masaüstü ve eşitleme (v8.6 öncesi ve sırası)

| Commit | Not |
|---|---|
| masaüstü 1 | bilgisayar uygulaması iskeleti |
| masaüstü 2 | bağımlılıksız ZIP okuyucu |
| masaüstü 3 | telefon yedeğini birleştirme motoru |
| masaüstü 4 | içe aktarma ekranı, izlenen klasör, koç klasörü |
| masaüstü 5 | Defter (tablo + ayrıntı) |
| belge | bilgisayar uygulaması notları (CLAUDE.md) |
| v8.6 hazırlık | tüm veri yedeğini toplayan ortak kod |
| eşitleme 1 | ortak kurallar, eşleştirme ve imza (domain) |
| eşitleme 2 | bilgisayarın yerel ağ sunucusu |
| eşitleme 3 | telefon istemcisi ve uçtan uca testler |
| eşitleme 4 | Android ağ izni ve belgeler |
