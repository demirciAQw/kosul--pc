/// El yazısı tanıyıcı sözleşmesi (saf Dart). Gerçek uygulama (ML Kit) `data/` içindedir;
/// testler sahte tanıyıcı verir.
library;

/// Bir nokta: satır içinde, sıralı ve artan zamanlı (ms).
class InkSample {
  const InkSample(this.x, this.y, this.t);
  final double x;
  final double y;
  final int t;
}

/// Tanıyıcıya bildirilen yazı alanı (satır kadar yüksek; tek satır varsayımı).
class RecognizerArea {
  const RecognizerArea(this.width, this.height);
  final double width;
  final double height;
}

enum HandwritingModelStatus {
  /// Bu cihazda tanıma yok (masaüstü ya da eklenti yok).
  unsupported,
  notDownloaded,
  downloaded,
}

enum HandwritingErrorKind { modelMissing, network, unsupported, failed }

/// Anlaşılır Türkçe iletiyle hata ([message] kullanıcıya gösterilir).
class HandwritingException implements Exception {
  const HandwritingException(this.kind, this.message);
  final HandwritingErrorKind kind;
  final String message;

  @override
  String toString() => message;
}

abstract class HandwritingRecognizer {
  /// Türkçe model kodu (ML Kit: `tr-TR`).
  String get languageCode;

  /// Bu cihazda tanıma kullanılabilir mi (yalnız Android).
  bool get isSupported;

  Future<HandwritingModelStatus> modelStatus();

  /// Modeli indirir (~20 MB). Ağ yoksa [HandwritingException] (network).
  Future<void> downloadModel({bool wifiOnly = false});

  Future<void> deleteModel();

  /// TEK satırı tanır; aday yoksa null. [preContext] en çok 20 karakter.
  Future<String?> recognizeLine(
    List<List<InkSample>> strokes, {
    String preContext = '',
    RecognizerArea? area,
  });
}
