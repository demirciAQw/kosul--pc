import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
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
  _repo = repo;
  session.readViewMatrix = () => tc.value.clone();
  session.writeViewMatrix = (m) => tc.value = (m as Matrix4).clone();
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
late InkStrokeRepository _repo;

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

  Future<TestGesture> _hoverAt(WidgetTester t, Offset p) async {
    final h = await t.createGesture(kind: PointerDeviceKind.stylus);
    await h.addPointer(location: p);
    await h.moveTo(p + const Offset(5, 0));
    await t.pump();
    return h;
  }

  testWidgets('kalem havada: görünüm kilitli değil, uzaktan tek parmak kaydırır', (t) async {
    final (s, tc) = await _host(t);
    final hover = await _hoverAt(t, const Offset(50, 50));
    expect(s.penNear, isTrue);
    expect(s.viewerLocked.value, isFalse);
    final before = tc.value.clone();
    await _pan(t, 7, 100); // (300,400): kaleme ~900 px uzak
    expect(tc.value, isNot(before));
    await hover.removePointer();
  });

  testWidgets('kalem havada: iki parmak zum çalışır', (t) async {
    final (_, tc) = await _host(t);
    final hover = await _hoverAt(t, const Offset(50, 50));
    await _pinch(t, 100);
    expect(tc.value.getMaxScaleOnAxis(), greaterThan(1.05));
    await hover.removePointer();
  });

  testWidgets('kalem havada: yakın temas (avuç) yutulur, hover bitince geçer', (t) async {
    final (s, tc) = await _host(t);
    final hover = await _hoverAt(t, const Offset(320, 420));
    final before = tc.value.clone();
    await _pan(t, 8, 100); // (300,400): kaleme ~30 px
    expect(tc.value, before);
    await hover.removePointer();
    await t.pump(const Duration(milliseconds: 600));
    expect(s.penNear, isFalse);
    await _pan(t, 9, 100);
    expect(tc.value, isNot(before));
  });

  testWidgets('kalem aşağıdayken tüm dokunmalar yutulur (uzak olsa da)', (t) async {
    final (s, tc) = await _host(t);
    final pen = await t.startGesture(const Offset(50, 50), kind: PointerDeviceKind.stylus);
    expect(s.viewerLocked.value, isTrue);
    final before = tc.value.clone();
    await _pan(t, 10, 100);
    expect(tc.value, before);
    await pen.up();
    await t.pumpAndSettle();
  });

  testWidgets('kalem kalktıktan 150 ms sonra parmak çalışır', (t) async {
    final (s, tc) = await _host(t);
    final pen = await t.startGesture(const Offset(300, 400), kind: PointerDeviceKind.stylus);
    await pen.up();
    await t.pump(const Duration(milliseconds: 150));
    expect(s.penActive, isFalse);
    final before = tc.value.clone();
    await _pan(t, 11, 100);
    expect(tc.value, isNot(before));
  });

  // --- geriye dönük avuç reddi ---
  Future<void> _palmDown(WidgetTester t, int id, Offset p, {double r = 100}) async {
    _down(id, p, r);
    for (var i = 0; i < 6; i++) {
      p += const Offset(0, -15);
      _move(id, p, const Offset(0, -15), r);
      await t.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('avuç önce: sayfa kayar, kalem hover olunca dönüşüm GERİ gelir, avuç sonra kaydıramaz', (t) async {
    final (s, tc) = await _host(t);
    final start = tc.value.clone();
    await _palmDown(t, 21, const Offset(300, 400));
    expect(tc.value, isNot(start)); // avuç sıradan parmak gibi sayfayı kaydırdı
    final hover = await _hoverAt(t, const Offset(340, 380));
    expect(tc.value, start); // anlık geri alındı
    expect(s.palm.isPalm(21), isTrue);
    expect(s.viewerLocked.value, isTrue);
    await t.pump();
    var p = const Offset(300, 310);
    for (var i = 0; i < 6; i++) {
      p += const Offset(0, -20);
      _move(21, p, const Offset(0, -20), 100);
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(tc.value, start); // avuç artık kaydıramaz
    _up(21, p);
    await t.pump();
    expect(s.viewerLocked.value, isFalse); // avuç kalkınca görünüm serbest
    await hover.removePointer();
    await t.pump(const Duration(milliseconds: 600));
    await _pan(t, 22, 100);
    expect(tc.value, isNot(start)); // sonraki parmak çalışır
  });

  testWidgets('avuç önce + kalem DOWN: dönüşüm geri, çizgi kaydedilir', (t) async {
    final (s, tc) = await _host(t);
    final start = tc.value.clone();
    await _palmDown(t, 23, const Offset(300, 400));
    expect(tc.value, isNot(start));
    final pen = await t.startGesture(const Offset(340, 380), kind: PointerDeviceKind.stylus);
    expect(tc.value, start);
    for (var i = 0; i < 6; i++) {
      await pen.moveBy(const Offset(10, 0));
    }
    await pen.up();
    _up(23, const Offset(300, 310));
    await t.pumpAndSettle();
    late int n;
    await t.runAsync(() async {
      await s.flush();
      n = (await _repo.forPage(PdfPageOwner('c' * 64, 0), attemptNo: 1, layer: 0)).length;
    });
    expect(n, 1);
  });

  testWidgets('üç temas aynı anda: kalemi beklemeden avuç, görünüm geri alınır', (t) async {
    final (s, tc) = await _host(t);
    final start = tc.value.clone();
    _down(31, const Offset(200, 300), 100);
    _down(32, const Offset(260, 300), 100);
    for (var i = 1; i <= 5; i++) {
      _move(31, Offset(200, 300 - i * 10.0), const Offset(0, -10), 100);
      _move(32, Offset(260, 300 - i * 10.0), const Offset(0, -10), 100);
      await t.pump(const Duration(milliseconds: 16));
    }
    _down(33, const Offset(320, 300), 100);
    await t.pump();
    expect(s.palm.isPalm(33), isTrue);
    expect(tc.value, start);
    _up(31, const Offset(200, 250));
    _up(32, const Offset(260, 250));
    _up(33, const Offset(320, 300));
    await t.pump();
    expect(s.viewerLocked.value, isFalse);
  });
}
