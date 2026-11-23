import 'dart:async';

import 'package:kocum/features/handwriting/domain/handwriting_recognizer.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';

/// Kutuyu dolduran (zikzak) sentetik çizgi.
InkStroke box(String id, double x, double y, double w, double h,
    {int at = 0, String tool = 'pen', bool deleted = false, bool closed = false}) {
  final pts = <StrokePoint>[
    StrokePoint(x, y, t: 0),
    StrokePoint(x + w, y + h * 0.3, t: 10),
    StrokePoint(x, y + h * 0.6, t: 20),
    StrokePoint(x + w, y + h, t: 30),
    if (closed) StrokePoint(x + 1, y + 1, t: 40),
  ];
  return InkStroke(
    id: id,
    owner: const NotePageOwner('p', 0),
    points: pts,
    startedAtMs: at,
    tool: tool,
    deleted: deleted,
  );
}

/// Düz çizgi (x1,y)->(x2,y).
InkStroke hline(String id, double x1, double x2, double y) => InkStroke(
      id: id,
      owner: const NotePageOwner('p', 0),
      points: [for (var i = 0; i <= 10; i++) StrokePoint(x1 + (x2 - x1) * i / 10, y, t: i * 5)],
      startedAtMs: 0,
    );

/// Bir satır: [n] harf kutusu (40 yüksek, 30 geniş), soldan sağa.
List<InkStroke> letters(String prefix, int n, double y, {double x0 = 100, int at = 0, double h = 40}) =>
    [for (var i = 0; i < n; i++) box('$prefix$i', x0 + i * 40.0, y, 30, h, at: at + i)];

/// Sahte tanıyıcı: satırları sırayla [answers] ile döner, çağrıları kaydeder.
class FakeRecognizer implements HandwritingRecognizer {
  FakeRecognizer(this.answers,
      {this.status = HandwritingModelStatus.downloaded, this.failAt = const {}, this.supported = true, this.downloadError, this.gate});
  final List<String?> answers;
  final bool supported;

  /// Doluysa indirme bu hatayla düşer.
  final HandwritingException? downloadError;

  /// Doluysa indirme bu tamamlanana kadar bekler.
  final Completer<void>? gate;
  HandwritingModelStatus status;
  final Set<int> failAt;
  final calls = <({List<List<InkSample>> strokes, String preContext, RecognizerArea? area})>[];
  var downloads = 0;
  var deletes = 0;

  @override
  String get languageCode => 'tr-TR';
  @override
  bool get isSupported => supported;
  @override
  Future<HandwritingModelStatus> modelStatus() async => status;
  @override
  Future<void> downloadModel({bool wifiOnly = false}) async {
    downloads++;
    await gate?.future;
    if (downloadError != null) throw downloadError!;
    status = HandwritingModelStatus.downloaded;
  }

  @override
  Future<void> deleteModel() async {
    deletes++;
    status = HandwritingModelStatus.notDownloaded;
  }

  @override
  Future<String?> recognizeLine(List<List<InkSample>> strokes, {String preContext = '', RecognizerArea? area}) async {
    final i = calls.length;
    calls.add((strokes: strokes, preContext: preContext, area: area));
    if (failAt.contains(i)) {
      throw const HandwritingException(HandwritingErrorKind.failed, 'tanıma hatası');
    }
    return i < answers.length ? answers[i] : null;
  }
}
