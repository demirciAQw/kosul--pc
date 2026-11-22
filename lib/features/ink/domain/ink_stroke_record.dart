/// Veritabanındaki bir çizginin saf Dart karşılığı (noktalar çözülmüş).
library;

import 'stroke_codec.dart';

/// Çizginin sahibi: PDF sayfası ya da not sayfası (ikisinden biri).
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
