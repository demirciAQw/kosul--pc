/// Veritabanındaki bir çizginin saf Dart karşılığı (noktalar çözülmüş).
library;

import 'stroke_codec.dart';

/// Çizginin sahibi: PDF sayfası, not sayfası ya da fotoğraflı soru kartı.
sealed class StrokeOwner {
  const StrokeOwner();
}

class PdfPageOwner extends StrokeOwner {
  const PdfPageOwner(this.documentId, this.page);
  final String documentId;
  final int page;
}

class NotePageOwner extends StrokeOwner {
  const NotePageOwner(this.noteId, this.page);
  final String noteId;
  final int page;
}

/// Fotoğraflı (PDF'siz) soru kartının çözüm çizgisi: `pdfDocumentId`, `pdfPage`,
/// `noteId` boş; sahibi yalnızca `questionId`. Koordinat: görüntü genişliği 1000
/// birim olacak biçimde normalleştirilmiş görüntü uzayı (bkz. `photoUnitWidth`).
class QuestionImageOwner extends StrokeOwner {
  const QuestionImageOwner(this.questionId);
  final String questionId;
}

class InkStroke {
  const InkStroke({
    required this.id,
    required this.owner,
    required this.points,
    required this.startedAtMs,
    this.layer = 0,
    this.attemptNo = 0,
    this.questionId,
    this.tool = 'pen',
    this.color = 0xFF000000,
    this.width = 1.0,
    this.durationMs = 0,
    this.deleted = false,
  });

  final String id;
  final StrokeOwner owner;
  final List<StrokePoint> points;
  final int startedAtMs;
  final int layer;
  final int attemptNo;

  /// Çözüm çizgisinin sorusu (soru kartı kimliği); yoksa null.
  final String? questionId;
  final String tool;
  final int color;
  final double width;
  final int durationMs;
  final bool deleted;
}

/// Bir çizginin yalnızca zamanları (noktalar çözülmeden): süre hesabı için.
class StrokeTime {
  const StrokeTime({required this.attemptNo, required this.startedAtMs, required this.durationMs});
  final int attemptNo;
  final int startedAtMs;
  final int durationMs;
}
