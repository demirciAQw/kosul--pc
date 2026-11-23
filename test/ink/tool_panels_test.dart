import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_outline.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/domain/shape_recognizer.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_input.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';
import 'package:kocum/features/pdf/presentation/pdf_page_ink_layer.dart';

final _doc = 'c' * 64;

/// Sayfa katmanı 612x792 piksel (ölçek 1), sol-üst köşede.
Future<(PdfInkSession, InkStrokeRepository)> _host(WidgetTester t) async {
  late AppDatabase db;
  late InkStrokeRepository repo;
  await t.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = InkStrokeRepository(db);
  });
  addTearDown(() => t.runAsync(db.close));
  final s = PdfInkSession(documentId: _doc, repository: repo);
  addTearDown(s.dispose);
  t.view.physicalSize = const Size(800, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PdfInkInput(
          session: s,
          stylusOnlyOverride: true,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 612,
              height: 792,
              child: PdfPageInkLayer(
                session: s,
                page: 0,
                pageWidth: 612,
                pageHeight: 792,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return (s, repo);
}

Future<List<InkStroke>> _saved(
  WidgetTester t,
  PdfInkSession s,
  InkStrokeRepository repo,
) async {
  late List<InkStroke> rows;
  await t.runAsync(() async {
    await s.flush();
    rows = await repo.forPage(PdfPageOwner(_doc, 0), attemptNo: 1, layer: 0);
  });
  return rows;
}

void main() {
  group('buildShape (saf)', () {
    const a = InkPoint(x: 10, y: 20), b = InkPoint(x: 110, y: 80);
    test('çizgi ve ok', () {
      final l = buildShape(ShapeTool.line, a, b);
      expect(l.map((p) => (p.x, p.y)), [(10.0, 20.0), (110.0, 80.0)]);
      final ar = buildShape(ShapeTool.arrow, a, b);
      expect(ar, hasLength(5));
      expect((ar[1].x, ar[1].y), (110.0, 80.0));
      // Ok başı uçtan geriye doğru: kanatlar başlangıca daha yakın.
      expect(ar[2].x, lessThan(110));
      expect(ar[4].x, lessThan(110));
    });
    test('dikdörtgen kapalı, ters sürüklemede de aynı kutu', () {
      final r = buildShape(ShapeTool.rectangle, b, a);
      expect(r, hasLength(5));
      expect((r.first.x, r.first.y), (r.last.x, r.last.y));
      expect(r.map((p) => p.x).reduce((x, y) => x < y ? x : y), 10);
      expect(r.map((p) => p.y).reduce((x, y) => x > y ? x : y), 80);
    });
    test('daire kısa kenara sığar, elips kutuyu doldurur', () {
      final c = buildShape(ShapeTool.circle, a, b);
      final xs = c.map((p) => p.x), ys = c.map((p) => p.y);
      expect(
        xs.reduce((x, y) => x > y ? x : y) - xs.reduce((x, y) => x < y ? x : y),
        closeTo(60, 1e-6),
      );
      expect(
        ys.reduce((x, y) => x > y ? x : y) - ys.reduce((x, y) => x < y ? x : y),
        closeTo(60, 1e-6),
      );
      final e = buildShape(ShapeTool.ellipse, a, b);
      final ex = e.map((p) => p.x);
      expect(
        ex.reduce((x, y) => x > y ? x : y) - ex.reduce((x, y) => x < y ? x : y),
        closeTo(100, 1e-6),
      );
    });
    test('üçgen: tepe üst ortada, taban altta', () {
      final tr = buildShape(ShapeTool.triangle, a, b);
      expect(tr, hasLength(4));
      expect((tr[0].x, tr[0].y), (60.0, 20.0));
      expect(tr[1].y, 80);
      expect(tr[2].y, 80);
    });
    test('aynı nokta ve sonsuz değer boş döner', () {
      for (final tool in ShapeTool.values) {
        expect(buildShape(tool, a, a), isEmpty, reason: tool.name);
        expect(
          buildShape(tool, a, const InkPoint(x: double.infinity, y: 0)),
          isEmpty,
        );
      }
    });
  });

  group('fosforlu', () {
    test(
      'profil: saydam, multiply, geniş; palet 5 renk; varsayılan kalınlık 18',
      () {
        final h = penProfiles[PenKind.highlighter]!;
        expect(h.opacity, lessThan(0.5));
        expect(h.multiply, isTrue);
        expect(highlighterPalette, hasLength(5));
        expect(
          NoteToolSettings().setKindAndWidth(PenKind.highlighter),
          highlighterDefaultWidth,
        );
        expect(highlighterDefaultWidth, 18);
      },
    );

    test('boya: saydam ve multiply karışımı', () {
      final p = inkPaintFor(
        const InkBrush(
          tool: InkTool.highlighter,
          color: 0xFFFFEB3B,
          width: 18,
          kind: PenKind.highlighter,
        ),
      );
      expect(p.blendMode, BlendMode.multiply);
      expect(p.color.a, lessThan(0.5));
      expect(p.color.a, greaterThan(0));
    });

    test(
      'kesik uç: yatay çizgide bant yüksekliği kalınlık kadar, dikeyde dar',
      () {
        const br = InkBrush(
          tool: InkTool.highlighter,
          width: 18,
          kind: PenKind.highlighter,
        );
        final horiz = inkOutlinePath(
          [for (var i = 0; i <= 10; i++) InkPoint(x: 50.0 + i * 20, y: 100)],
          br,
          complete: true,
        );
        final hb = horiz.getBounds();
        expect(hb.height, closeTo(18, 0.01));
        expect(hb.width, closeTo(200 + 18 * highlighterTipRatio, 0.01));
        final vert = inkOutlinePath(
          [for (var i = 0; i <= 10; i++) InkPoint(x: 50, y: 50.0 + i * 20)],
          br,
          complete: true,
        );
        expect(vert.getBounds().width, closeTo(18 * highlighterTipRatio, 0.01));
        // Kesişen parçalar delik açmaz (aynı yönde sarılı): yolun ortası dolu.
        expect(horiz.contains(const Offset(150, 100)), isTrue);
        expect(horiz.contains(const Offset(150, 100 + 8)), isTrue);
        expect(horiz.contains(const Offset(150, 100 + 12)), isFalse);
      },
    );

    testWidgets('gerçek çizim: kayıt fosforlu türünde; kalınlık 18 saklanır', (
      t,
    ) async {
      final (s, repo) = await _host(t);
      final tools = NoteToolSettings()..setKind(PenKind.highlighter);
      tools.apply(s);
      expect(s.brush.width, 18);
      expect(s.brush.kind, PenKind.highlighter);
      final g = await t.startGesture(
        const Offset(100, 200),
        kind: PointerDeviceKind.stylus,
      );
      for (var i = 1; i <= 10; i++) {
        await g.moveTo(Offset(100.0 + i * 20, 200));
      }
      await g.up();
      await t.pump();
      final rows = await _saved(t, s, repo);
      expect(rows, hasLength(1));
      expect(rows.single.tool, contains('highlighter'));
      expect(rows.single.width, 18);
    });
  });

  group('doğrudan şekil aracı (kalemle)', () {
    testWidgets(
      'sürüklerken canlı önizleme, bırakınca mükemmel dikdörtgen kaydedilir',
      (t) async {
        final (s, repo) = await _host(t);
        s.setBrush(const InkBrush(kind: PenKind.ballpoint));
        s.setShapeTool(ShapeTool.rectangle);
        final g = await t.startGesture(
          const Offset(100, 100),
          kind: PointerDeviceKind.stylus,
        );
        await g.moveTo(const Offset(150, 130));
        await g.moveTo(const Offset(300, 220));
        await t.pump();
        expect(find.byKey(const Key('ink-shape-preview')), findsOneWidget);
        await g.up();
        await t.pump();
        expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
        final rows = await _saved(t, s, repo);
        expect(rows, hasLength(1));
        final p = rows.single.points;
        expect(p, hasLength(5));
        expect((p[0].x, p[0].y), (100.0, 100.0));
        expect((p[2].x, p[2].y), (300.0, 220.0));
      },
    );

    testWidgets(
      'dokunuş (sürükleme yok) şekil bırakmaz; araç kapalıyken serbest çizgi',
      (t) async {
        final (s, repo) = await _host(t);
        s.setBrush(const InkBrush(kind: PenKind.ballpoint));
        s.setShapeTool(ShapeTool.circle);
        final g = await t.startGesture(
          const Offset(100, 100),
          kind: PointerDeviceKind.stylus,
        );
        await g.up();
        await t.pump();
        expect(await _saved(t, s, repo), isEmpty);
        s.setShapeTool(null);
        final g2 = await t.startGesture(
          const Offset(100, 100),
          kind: PointerDeviceKind.stylus,
        );
        for (var i = 1; i <= 8; i++) {
          await g2.moveTo(Offset(100.0 + i * 10, 100.0 + i * 3));
        }
        await g2.up();
        await t.pump();
        expect((await _saved(t, s, repo)).single.points.length, greaterThan(5));
      },
    );

    testWidgets('ok ve üçgen kaydedilir', (t) async {
      final (s, repo) = await _host(t);
      s.setBrush(const InkBrush(kind: PenKind.ballpoint));
      for (final (tool, n) in [(ShapeTool.arrow, 5), (ShapeTool.triangle, 4)]) {
        s.setShapeTool(tool);
        final g = await t.startGesture(
          const Offset(100, 100),
          kind: PointerDeviceKind.stylus,
        );
        await g.moveTo(const Offset(250, 180));
        await g.up();
        await t.pump();
        final rows = await _saved(t, s, repo);
        expect(rows.last.points, hasLength(n), reason: tool.name);
      }
    });
  });

  group('basılı tut: gerçek kalem hızı ve titremesi', () {
    // Kalem 13 ms aralıkla olay yollar; hareketsizken ±3 px titrer.
    Future<TestGesture> drawLineThenHold(
      WidgetTester t, {
      int holdFrames = 55,
      double jitter = 3,
    }) async {
      final g = await t.startGesture(
        const Offset(100, 300),
        kind: PointerDeviceKind.stylus,
      );
      for (var i = 1; i <= 20; i++) {
        await g.moveTo(Offset(100.0 + i * 12, 300));
        await t.pump(const Duration(milliseconds: 13));
      }
      for (var i = 0; i < holdFrames; i++) {
        final j = (i.isEven ? jitter : -jitter);
        await g.moveTo(Offset(340 + j, 300 + (i % 3 - 1) * jitter));
        await t.pump(const Duration(milliseconds: 13));
      }
      return g;
    }

    testWidgets('gürültülü sabit kalem ~700 ms sonra şekle döner', (t) async {
      final (s, repo) = await _host(t);
      s.setBrush(const InkBrush(kind: PenKind.ballpoint));
      s.setShapeSnap(true);
      final g = await drawLineThenHold(t); // 55 x 13 ms = 715 ms
      expect(find.byKey(const Key('ink-shape-preview')), findsOneWidget);
      await g.up();
      await t.pump();
      final rows = await _saved(t, s, repo);
      expect(rows.single.points, hasLength(2)); // düz çizgi
    });

    testWidgets('daha kısa bekleme (400 ms) şekle çevirmez', (t) async {
      final (s, _) = await _host(t);
      s.setBrush(const InkBrush(kind: PenKind.ballpoint));
      s.setShapeSnap(true);
      final g = await drawLineThenHold(t, holdFrames: 30);
      expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
      await g.up();
      await t.pump();
    });

    testWidgets('ilk 150 ms içindeki atılım zamanlayıcıyı sıfırlamaz', (
      t,
    ) async {
      final (s, _) = await _host(t);
      s.setBrush(const InkBrush(kind: PenKind.ballpoint));
      s.setShapeSnap(true);
      final g = await t.startGesture(
        const Offset(100, 300),
        kind: PointerDeviceKind.stylus,
      );
      // 100 ms içinde 20 adım hızlı yürü, sonra dur.
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(Offset(100.0 + i * 30, 300));
        await t.pump(const Duration(milliseconds: 13));
      }
      for (var i = 0; i < 48; i++) {
        await g.moveTo(Offset(340 + (i.isEven ? 3 : -3), 300));
        await t.pump(const Duration(milliseconds: 13));
      }
      expect(find.byKey(const Key('ink-shape-preview')), findsOneWidget);
      await g.up();
      await t.pump();
    });
  });

  group('silgi boyutu ve imleci', () {
    testWidgets(
      'yarıçap silgiye gerçekten gider: küçükle değmez, büyükle siler',
      (t) async {
        final (s, repo) = await _host(t);
        s.setBrush(const InkBrush(kind: PenKind.ballpoint));
        final g = await t.startGesture(
          const Offset(100, 100),
          kind: PointerDeviceKind.stylus,
        );
        for (var i = 1; i <= 10; i++) {
          await g.moveTo(Offset(100.0 + i * 20, 100));
        }
        await g.up();
        await t.pump();
        expect(await _saved(t, s, repo), hasLength(1));

        final tools = NoteToolSettings()..setEraseMode(EraseMode.stroke);
        tools.setSize(10); // yarıçap 10 (en az 8)
        tools.apply(s);
        final g1 = await t.startGesture(
          const Offset(200, 130),
          kind: PointerDeviceKind.stylus,
        );
        await g1.moveBy(const Offset(2, 0));
        await g1.up();
        await t.pump();
        expect(await _saved(t, s, repo), hasLength(1)); // 30 px uzakta, değmedi

        tools.setSize(50);
        tools.apply(s);
        final g2 = await t.startGesture(
          const Offset(200, 130),
          kind: PointerDeviceKind.stylus,
        );
        await g2.moveBy(const Offset(2, 0));
        await g2.up();
        await t.pump();
        expect(await _saved(t, s, repo), isEmpty);
      },
    );

    testWidgets(
      'silgi aktifken kalem havada yarıçap dairesi çizilir; silgi değilse çizilmez',
      (t) async {
        final (s, _) = await _host(t);
        final tools = NoteToolSettings()..setEraser(true);
        tools.setSize(30);
        tools.apply(s);
        final hover = await t.createGesture(kind: PointerDeviceKind.stylus);
        await hover.addPointer(location: const Offset(200, 200));
        await hover.moveTo(const Offset(220, 210));
        await t.pump();
        final cursor = find.byKey(const Key('ink-eraser-cursor'));
        expect(t.renderObject(cursor), paints..circle(radius: 30.0));
        await t.pump(const Duration(seconds: 1)); // olay kesilince söner
        expect(t.renderObject(cursor), isNot(paints..circle()));

        tools.setEraser(false);
        tools.apply(s);
        await hover.moveTo(const Offset(230, 210));
        await t.pump();
        expect(t.renderObject(cursor), isNot(paints..circle()));
        await hover.removePointer();
      },
    );
  });

  group('NoteToolSettings boyutları', () {
    test('kalem, fosforlu ve silgi boyutları ayrı saklanır ve sınırlanır', () {
      final t = NoteToolSettings();
      t.setKind(PenKind.ballpoint);
      t.setSize(5);
      t.setKind(PenKind.highlighter);
      expect(t.size, highlighterDefaultWidth);
      t.setSize(30);
      t.setEraser(true);
      expect(t.size, eraserRadiusDefault);
      t.setSize(1000);
      expect(t.eraserRadius, eraserRadiusMax);
      t.setSize(double.nan);
      expect(t.eraserRadius, eraserRadiusMax);
      t.setKind(PenKind.ballpoint);
      expect(t.size, 5);
      t.setKind(PenKind.highlighter);
      expect(t.size, 30);
    });

    test('silgi fırçası yarıçapı taşır; kayıt/okuma gidiş-dönüş', () {
      final t = NoteToolSettings()..setEraser(true);
      t.setSize(40);
      expect(t.brush.tool, InkTool.eraser);
      expect(t.brush.width * 2, 40 < 8 ? 8 : 40 * 1.0);
      final u = NoteToolSettings()..restoreSizes(t.toSizes());
      expect(u.eraserRadius, 40);
      u.restoreSizes({'eraser': 'bozuk', 'width.ballpoint': double.nan});
      expect(u.eraserRadius, 40);
    });

    test(
      'şekil aracı kalem seçince kapanır, silgi/kement ile birlikte olmaz',
      () {
        final t = NoteToolSettings();
        t.setShapeTool(ShapeTool.arrow);
        expect(t.shapeTool, ShapeTool.arrow);
        t.setShapeTool(ShapeTool.arrow);
        expect(t.shapeTool, isNull); // aynı araca yeniden dokun: kapanır
        t.setShapeTool(ShapeTool.circle);
        t.setEraser(true);
        expect(t.shapeTool, isNull);
        t.setShapeTool(ShapeTool.circle);
        expect(t.eraser, isFalse);
        t.setKind(PenKind.pencil);
        expect(t.shapeTool, isNull);
      },
    );
  });
}

extension on NoteToolSettings {
  /// Testte: fosforluyu seçip kalınlığını döndürür.
  double setKindAndWidth(PenKind k) {
    setKind(k);
    return width;
  }
}
