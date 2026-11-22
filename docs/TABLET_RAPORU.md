# Tablet + PDF raporu

Dal: `tablet-1`. Her adım: saat, sonuç, ölçüm, "Ahmet elle denesin".

## T0: Ortam (22.11.2026)
- Android SDK zaten kurulu (`~/Android/Sdk`, platform 36, build-tools 36.0.0); `flutter doctor` Android için temiz.
- `tool/gece_patch.dart`: debug derleme `.gece` son ekiyle ve "Koçum (deneme)" adıyla çıkar; release `com.kocum.kocum` / "Koçum" kalır. Testli (4 test). `flutter build apk --debug` gerçekten derlendi; `aapt2` ile doğrulandı: `com.kocum.kocum.gece`, "Koçum (deneme)".
- 340 test geçti. `flutter analyze` hata vermiyor (eski bilgi/uyarılar duruyor).
- Not: `flutter build --profile` son ek almaz (Flutter profile'ı kendi kopyalar); kullanılmıyor, derlenmedi.
- **Tablet `unauthorized`:** `adb devices` PADH10005831 için yetki istiyor. Tablete ölçüm yapılamadı.

### Ahmet elle denesin
- Tablette USB hata ayıklama iznini onayla (açılan "bu bilgisayara izin ver" penceresi), sonra `adb devices` "device" göstermeli.
- Sonra `flutter build apk --debug` ve `adb install -r build/app/outputs/flutter-apk/app-debug.apk`; "Koçum (deneme)" gerçek Koçum'un yanında ayrı simge olarak açılmalı.

## Araştırma notları (T1, T3)
- `androidx.ink` 1.0.0 (Apache-2.0, minSdk 24, Kotlin 2.2.20 ister, JNI → R8 kuralı gerekebilir). Hareket tahmini ve ön tampon çizimi içinde.
- Hybrid composition'da dokunuşlar Flutter'a yönlenir; kalem verisi (tarihsel noktalar, eğim) yerel view'e kayıpsız geçmeyebilir → InkSurface yerel view'e dokunuşu kendisi aldıracak şekilde denenecek.
- `perfect_freehand` 2.5.2+1 (MIT) B uygulaması için.
- `pdfrx` 3.1.0 (MIT; PDFium ikilisi derlemede indirilir, SHA-256 doğrulamalı; APK'ya ~+3-6 MB tahmini). Çakışmasız çözülüyor, `sdk ^3.14.0` ister. Uygulamaya PDFium lisans notu eklenecek.
