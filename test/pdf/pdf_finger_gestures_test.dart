import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_input.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';
import 'package:kocum/features/pdf/presentation/pdf_page_ink_layer.dart';

/// Gerçek InteractiveViewer + PdfInkInput. Gerçek tablet verisi: parmak
/// radiusMajor ~75-143 (Casper PAD H10); avuç çok daha büyük sayılır.
Future<(PdfInkSession, TransformationController)> _host(WidgetTester t) async {
  late AppDatabase db;
  late InkStrokeRepository repo;
  await t.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = InkStrokeRepository(db);
  });
  addTearDown(() => t.runAsync(db.close));
  final session = PdfInkSession(documentId: 'c' * 64, repository: repo);
  addTearDown(session.dispose);
  final tc = TransformationController();
  addTearDown(tc.dispose);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PdfInkInput(
        session: session,
        stylusOnlyOverride: true,
        child: ValueListenableBuilder<bool>(
          valueListenable: session.viewerLocked,
          builder: (_, locked, _) => InteractiveViewer(
            transformationController: tc,
            panEnabled: !locked,
            scaleEnabled: !locked,
            constrained: false,
            boundaryMargin: const EdgeInsets.all(double.infinity),
            child: SizedBox(
              width: 800,
              height: 1200,
              child: PdfPageInkLayer(session: session, page: 0, pageWidth: 612, pageHeight: 792),
            ),
          ),
        ),
      ),
    ),
  ));
  return (session, tc);
}

final _b = GestureBinding.instance;

void _down(int id, Offset p, double r) =>
    _b.handlePointerEvent(PointerDownEvent(pointer: id, position: p, radiusMajor: r));
void _move(int id, Offset p, Offset d, double r) =>
    _b.handlePointerEvent(PointerMoveEvent(pointer: id, position: p, delta: d, radiusMajor: r));
void _up(int id, Offset p) => _b.handlePointerEvent(PointerUpEvent(pointer: id, position: p));

Future<void> _pan(WidgetTester t, int id, double r) async {
  var p = const Offset(300, 400);
  _down(id, p, r);
  for (var i = 0; i < 8; i++) {
    final n = p + const Offset(0, -15);
    _move(id, n, const Offset(0, -15), r);
    p = n;
    await t.pump(const Duration(milliseconds: 16));
  }
  _up(id, p);
  await t.pumpAndSettle();
}

Future<void> _pinch(WidgetTester t, double r) async {
  _down(1, const Offset(300, 400), r);
  _down(2, const Offset(400, 400), r);
  for (var i = 1; i <= 8; i++) {
    final d = i * 12.0;
    _move(1, Offset(300 - d, 400), const Offset(-12, 0), r);
    _move(2, Offset(400 + d, 400), const Offset(12, 0), r);
    await t.pump(const Duration(milliseconds: 16));
  }
  _up(1, const Offset(200, 400));
  _up(2, const Offset(500, 400));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('parmak (radiusMajor 100) tek parmakla kaydırır', (t) async {
    final (_, tc) = await _host(t);
    final before = tc.value.clone();
    await _pan(t, 5, 100);
    expect(tc.value, isNot(before));
  });

  testWidgets('parmak (radiusMajor 100) iki parmakla yakınlaştırır', (t) async {
    final (_, tc) = await _host(t);
    await _pinch(t, 100);
    expect(tc.value.getMaxScaleOnAxis(), greaterThan(1.05));
  });

  testWidgets('radiusMajor 400 (avuç) yutulur: görünüm değişmez', (t) async {
    final (_, tc) = await _host(t);
    final before = tc.value.clone();
    await _pan(t, 6, 400);
    expect(tc.value, before);
  });

  testWidgets('kalem havadayken parmak yutulur, hover bitince tekrar geçer', (t) async {
    final (s, tc) = await _host(t);
    final hover = await t.createGesture(kind: PointerDeviceKind.stylus);
    await hover.addPointer(location: const Offset(100, 100));
    await hover.moveTo(const Offset(110, 100));
    expect(s.penNear, isTrue);
    await t.pump();
    final before = tc.value.clone();
    await _pan(t, 7, 100);
    expect(tc.value, before);
    // Kalem aniden ekran dışına çıktı: olay gelmez, zaman aşımı kilidi açar.
    await hover.removePointer();
    await t.pump(const Duration(milliseconds: 600));
    expect(s.penNear, isFalse);
    expect(s.viewerLocked.value, isFalse);
    await _pan(t, 8, 100);
    expect(tc.value, isNot(before));
  });
}
