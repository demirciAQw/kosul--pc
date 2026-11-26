import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
// `Ink` adı Material `Ink` widget'ıyla çakışır: önekle alınır.
import 'package:google_mlkit_digital_ink_recognition/google_mlkit_digital_ink_recognition.dart' as mlk;

import '../domain/handwriting_recognizer.dart';

/// Türkçe model kodu (yalın `tr` YOKTUR).
const handwritingLanguageCode = 'tr-TR';

/// Google ML Kit Digital Ink Recognition. Model (~20 MB) APK'ya gömülmez; ilk kullanımda
/// indirilir. YALNIZ Android'de oluşturulur (bkz. `handwriting_providers.dart`).
/// Gerçek tanıma doğruluğu ve modelin çevrimdışı çalışması cihazda doğrulanmadı.
class MlKitHandwritingRecognizer implements HandwritingRecognizer {
  MlKitHandwritingRecognizer({mlk.DigitalInkRecognizerModelManager? manager})
      : _manager = manager ?? mlk.DigitalInkRecognizerModelManager();

  final mlk.DigitalInkRecognizerModelManager _manager;
  mlk.DigitalInkRecognizer? _recognizer;

  @override
  String get languageCode => handwritingLanguageCode;

  @override
  bool get isSupported => true;

  @override
  Future<HandwritingModelStatus> modelStatus() async {
    try {
      final ok = await _manager.isModelDownloaded(languageCode);
      return ok ? HandwritingModelStatus.downloaded : HandwritingModelStatus.notDownloaded;
    } on MissingPluginException {
      return HandwritingModelStatus.unsupported;
    } on PlatformException {
      return HandwritingModelStatus.notDownloaded;
    }
  }

  @override
  Future<void> downloadModel({bool wifiOnly = false}) async {
    try {
      final ok = await _manager.downloadModel(languageCode, isWifiRequired: wifiOnly);
      if (!ok) throw _networkError(wifiOnly);
    } on HandwritingException {
      rethrow;
    } on MissingPluginException {
      throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
    } on PlatformException {
      throw _networkError(wifiOnly);
    }
  }

  static HandwritingException _networkError(bool wifiOnly) => HandwritingException(
        HandwritingErrorKind.network,
        wifiOnly
            ? 'Model indirilemedi. Wi-Fi\'ye bağlı olduğundan ve internetin çalıştığından emin ol, sonra yeniden dene.'
            : 'Model indirilemedi. İnternet bağlantını kontrol edip yeniden dene.',
      );

  @override
  Future<void> deleteModel() async {
    try {
      await _manager.deleteModel(languageCode);
    } on MissingPluginException {
      throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
    } on PlatformException {
      throw const HandwritingException(HandwritingErrorKind.failed, 'Model silinemedi. Yeniden dene.');
    }
  }

  @override
  Future<String?> recognizeLine(
    List<List<InkSample>> strokes, {
    String preContext = '',
    RecognizerArea? area,
  }) async {
    final ink = mlk.Ink();
    ink.strokes = [
      for (final s in strokes)
        mlk.Stroke()..points = [for (final p in s) mlk.StrokePoint(x: p.x, y: p.y, t: p.t)],
    ];
    final ctx = mlk.DigitalInkRecognitionContext(
      preContext: preContext.isEmpty ? null : (preContext.length > 20 ? preContext.substring(preContext.length - 20) : preContext),
      writingArea: area == null ? null : mlk.WritingArea(width: area.width, height: area.height),
    );
    try {
      final r = _recognizer ??= mlk.DigitalInkRecognizer(languageCode: languageCode);
      final candidates = await r.recognize(ink, context: ctx);
      return candidates.isEmpty ? null : candidates.first.text;
    } on MissingPluginException {
      throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
    } on PlatformException catch (e) {
      final m = '${e.message} ${e.details}'.toLowerCase();
      if (m.contains('model') && (m.contains('download') || m.contains('not'))) {
        throw const HandwritingException(
            HandwritingErrorKind.modelMissing, 'Türkçe el yazısı modeli indirilmemiş. Ayarlar > El yazısı tanıma.');
      }
      throw const HandwritingException(HandwritingErrorKind.failed, 'Bu satır okunamadı.');
    }
  }

  /// Tanıyıcıyı kapatır (kaynakları bırakır); sonraki çağrıda yeniden açılır.
  Future<void> close() async {
    final r = _recognizer;
    _recognizer = null;
    if (r != null) {
      try {
        await r.close();
      } on Object {
        // Kapatma hatası önemsiz.
      }
    }
  }
}

/// Android dışı (masaüstü): hiçbir şeye dokunmaz.
class UnsupportedHandwritingRecognizer implements HandwritingRecognizer {
  const UnsupportedHandwritingRecognizer();

  @override
  String get languageCode => handwritingLanguageCode;
  @override
  bool get isSupported => false;
  @override
  Future<HandwritingModelStatus> modelStatus() async => HandwritingModelStatus.unsupported;
  @override
  Future<void> downloadModel({bool wifiOnly = false}) =>
      throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
  @override
  Future<void> deleteModel() =>
      throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
  @override
  Future<String?> recognizeLine(List<List<InkSample>> strokes, {String preContext = '', RecognizerArea? area}) =>
      throw const HandwritingException(HandwritingErrorKind.unsupported, 'Bu cihazda el yazısı tanıma yok.');
}
