# Gece raporu (ilerleme günlüğü)

- 02:12 Adım 0 başladı
- 02:15 Adım 0 bitti: analiz temiz, 219 test geçti, Linux release derlendi ve açıldı. Android SDK yok (derlenmedi), telefon bağlı değil.
- 02:15 Adım 1 başladı
- 02:19 Adım 1: tablolar+göç (v12), domain, depo, 21 test hazır. NOT: bu Drift sürümü references() kuralını SQL'e yazmıyor (mevcut tablolarda da); yeni tablolarda customConstraint kullanıldı. Sıra: arayüz
- 02:24 Adım 1 bitti (v8.7): telefon arayüzü (Anlık sekmesi, editör, Kişiler, Etiketler, süzgeç, uyku kartı), 28 test (alan+widget). Sıra: 1b bilgisayar
- 02:28 Adım 1b bitti: bilgisayarda Notlar (Ctrl+N/S/F, Esc, dar pencere), Kişiler, Etiketler, Defter'de soru etiketi ve bağlı not; telefonda soru ayrıntısında etiket. 252 test geçiyor.
- 02:39 Adım 2 bitti (v8.8): defter+tetikleyiciler+HLC, iki yönlü senkron (imzalı yanıt, fotoğraf iki yön), çakışma, geri alma, ekranlar. 286 test. NOT: fotograf-al ucu 'okuma ucu yok' kuralına dar bir istisna (yalnızca bilgisayarın kendi değişikliğinde geçen yollar); ayrıntı KABLOSUZ_AKTARIM.md. Sıra: Adım 3 kocum aracı
