import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/note_page_editor.dart';

class _H {
  _H(this.db, this.repo, this.strokes);
  final AppDatabase db;
  final InkNotebookRepository repo;
  final InkStrokeRepository strokes;
}

Future<_H> _db(WidgetTester t) async {
  late _H h;
  await t.runAsync(() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    h = _H(db, InkNotebookRepository(db), InkStrokeRepository(db));
  });
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.runAsync(h.db.close);
  });
  t.view.physicalSize = const Size(1200, 2000); // sayfa tam görünsün (alttaki yuva çizim noktalarını örtmesin)
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  return h;
}

Future<void> _wait(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mountScreen(WidgetTester t, _H h, String nb) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(h.db)],
      child: MaterialApp(home: InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)),
    ),
  );
  await _wait(t);
}

NotePageEditorState _editor(WidgetTester t) => t.state<NotePageEditorState>(find.byType(NotePageEditor));

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(_editor(t).flush);
  await t.pump();
}

Rect _paper(WidgetTester t) => t.getRect(find.byKey(const Key('note-page-ink')));

Future<void> _drag(WidgetTester t, Offset from, Offset to, {int steps = 12}) async {
  final g = await t.startGesture(from, kind: PointerDeviceKind.stylus);
  for (var i = 1; i <= steps; i++) {
    await g.moveTo(Offset.lerp(from, to, i / steps)!);
  }
  await g.up();
  await t.pump();
}

Future<void> _path(WidgetTester t, List<Offset> pts) async {
  final g = await t.startGesture(pts.first, kind: PointerDeviceKind.stylus);
  for (final p in pts.skip(1)) {
    await g.moveTo(p);
  }
  await g.up();
  await t.pump();
}

Future<List<InkStroke>> _rows(WidgetTester t, _H h, String pageId) async {
  late List<InkStroke> rows;
  await t.runAsync(() async {
    final p = (await h.repo.findPage(pageId))!;
    rows = await h.strokes.forPage(NotePageOwner(p.id, p.pageNo), attemptNo: 0, layer: 0, noQuestion: true);
  });
  return rows;
}

Future<(String, String)> _openPage(WidgetTester t, _H h) async {
  late String nb;
  await t.runAsync(() async => nb = await h.repo.createNotebook());
  await _mountScreen(t, h, nb);
  final pageId = (await t.runAsync(() => h.repo.pages(nb)))!.single.id;
  return (nb, pageId);
}

/// Sayfa koordinatını ekran noktasına çevirir (zum 1).
Offset _view(WidgetTester t, double x, double y) {
  final r = _paper(t);
  return Offset(r.left + x * r.width / 1404, r.top + y * r.height / 1984);
}

List<Offset> _loop(Rect r) => [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft, r.topLeft + const Offset(0, 4)];

void main() {
  testWidgets('kement: seç, taşı (tek kalıcı işlem), boyutlandır, geri al, sil; yeniden açınca kalıcı', (t) async {
    final h = await _db(t);
    final (nb, pageId) = await _openPage(t, h);
    final c = _paper(t).center;
    await _drag(t, c + const Offset(-80, 0), c + const Offset(80, 0), steps: 16);
    await _flush(t);
    final before = (await _rows(t, h, pageId)).single;

    // Kement aracı, çizginin çevresinde kapalı yol.
    await t.tap(find.byKey(const Key('note-lasso')));
    await t.pumpAndSettle();
    await _path(t, _loop(Rect.fromCenter(center: c, width: 260, height: 100)));
    final s = _editor(t).session;
    expect(s.hasSelection, isTrue);
    expect(find.byKey(const Key('note-sel-delete')), findsOneWidget);
    expect(await _rows(t, h, pageId), hasLength(1)); // çizim yok, yalnız seçim

    // Gövdeden sürükle: 100 px sağa.
    await _drag(t, c, c + const Offset(100, 0), steps: 10);
    await _flush(t);
    var rows = await _rows(t, h, pageId);
    expect(rows, hasLength(1)); // çizgi güncellendi, kopya yok
    expect(rows.single.id, before.id);
    final unit = 1404 / _paper(t).width;
    expect(rows.single.points.first.x - before.points.first.x, closeTo(100 * unit, 3));

    // Sağ-alt köşe tutamacından büyüt (orantılı).
    final b = s.selectionBoundsSaved!;
    final w0 = rows.single.points.last.x - rows.single.points.first.x;
    final corner = _view(t, b.right, b.bottom);
    await _drag(t, corner, corner + const Offset(60, 30), steps: 6);
    await _flush(t);
    rows = await _rows(t, h, pageId);
    expect(rows.single.points.last.x - rows.single.points.first.x, greaterThan(w0 * 1.2));

    // İki geri al: büyütme, taşıma.
    await t.tap(find.byKey(const Key('note-undo')));
    await _flush(t);
    await t.tap(find.byKey(const Key('note-undo')));
    await _flush(t);
    rows = await _rows(t, h, pageId);
    expect(rows.single.points.first.x, closeTo(before.points.first.x, 0.2));
    await t.tap(find.byKey(const Key('note-redo')));
    await _flush(t);
    await t.tap(find.byKey(const Key('note-redo')));
    await _flush(t);
    final moved = (await _rows(t, h, pageId)).single;

    // Yeniden aç: kalıcı.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await _mountScreen(t, h, nb);
    final again = (await _rows(t, h, pageId)).single;
    expect(again.points.first.x, closeTo(moved.points.first.x, 1e-6));
    expect(again.points.last.x, closeTo(moved.points.last.x, 1e-6));

    // Sil.
    await t.tap(find.byKey(const Key('note-lasso')));
    await t.pumpAndSettle();
    final c2 = _view(t, (moved.points.first.x + moved.points.last.x) / 2, moved.points.first.y);
    await _path(t, _loop(Rect.fromCenter(center: c2, width: 700, height: 160)));
    expect(_editor(t).session.hasSelection, isTrue);
    await t.tap(find.byKey(const Key('note-sel-delete')));
    await _flush(t);
    expect(await _rows(t, h, pageId), isEmpty);
    await t.tap(find.byKey(const Key('note-undo')));
    await _flush(t);
    expect(await _rows(t, h, pageId), hasLength(1));
  });

  testWidgets('kement: boş alan seçimi kaldırır; kopyala/yapıştır', (t) async {
    final h = await _db(t);
    final (_, pageId) = await _openPage(t, h);
    final c = _paper(t).center;
    await _drag(t, c + const Offset(-60, 0), c + const Offset(60, 0), steps: 12);
    await _flush(t);
    await t.tap(find.byKey(const Key('note-lasso')));
    await t.pumpAndSettle();
    await _path(t, _loop(Rect.fromCenter(center: c, width: 220, height: 90)));
    expect(_editor(t).session.hasSelection, isTrue);
    await t.tap(find.byKey(const Key('note-sel-copy')));
    await t.tap(find.byKey(const Key('note-sel-paste')));
    await _flush(t);
    expect(await _rows(t, h, pageId), hasLength(2));
    // Boşluğa çiz: seçim kalkar.
    await _path(t, _loop(Rect.fromLTWH(c.dx + 200, c.dy - 300, 60, 60)));
    expect(_editor(t).session.hasSelection, isFalse);
  });

  group('şekil düzeltme (basılı tutma)', () {
    Future<List<Offset>> wobblyLine(Offset a, Offset b) async => [
      for (var i = 0; i <= 14; i++)
        Offset.lerp(a, b, i / 14)! + Offset(0, i.isEven ? 1.2 : -1.2),
    ];

    testWidgets('düz çizgi: 0,6 sn hareketsiz → önizleme düz çizgi; kalkınca iki noktalı şekil kaydedilir', (t) async {
      final h = await _db(t);
      final (_, pageId) = await _openPage(t, h);
      final c = _paper(t).center;
      final pts = await wobblyLine(c + const Offset(-120, -20), c + const Offset(120, 30));
      final g = await t.startGesture(pts.first, kind: PointerDeviceKind.stylus);
      for (final p in pts.skip(1)) {
        await g.moveTo(p);
      }
      // Sahte zaman: 0,4 sn → henüz değil, 0,7 sn → şekil.
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('ink-shape-preview')), findsOneWidget);
      await g.up();
      await t.pump();
      await _flush(t);
      final rows = await _rows(t, h, pageId);
      expect(rows, hasLength(1));
      expect(rows.single.points, hasLength(2)); // düzeltilmiş: düz çizgi
      expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
      // Geri al: düzeltilmiş şekil kalkar (özgün serbest çizgi hiç kaydedilmedi).
      await t.tap(find.byKey(const Key('note-undo')));
      await _flush(t);
      expect(await _rows(t, h, pageId), isEmpty);
    });

    testWidgets('daire: kapalı yol tanınır, çok noktalı kapalı şekil kaydedilir', (t) async {
      final h = await _db(t);
      final (_, pageId) = await _openPage(t, h);
      final c = _paper(t).center;
      final pts = [
        for (var i = 0; i <= 40; i++)
          c + Offset(90 * math.cos(i / 40 * 2 * math.pi), 90 * math.sin(i / 40 * 2 * math.pi)) +
              Offset(i.isEven ? 1.5 : -1.5, 0),
      ];
      final g = await t.startGesture(pts.first, kind: PointerDeviceKind.stylus);
      for (final p in pts.skip(1)) {
        await g.moveTo(p);
      }
      await t.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const Key('ink-shape-preview')), findsOneWidget);
      await g.up();
      await t.pump();
      await _flush(t);
      final pts2 = (await _rows(t, h, pageId)).single.points;
      expect(pts2.length, greaterThan(10));
      expect((pts2.first.x - pts2.last.x).abs(), lessThan(3));
    });

    testWidgets('tanınmayan (zikzak) basılı tutulsa da serbest çizgi aynen kalır', (t) async {
      final h = await _db(t);
      final (_, pageId) = await _openPage(t, h);
      final c = _paper(t).center;
      final pts = [for (var i = 0; i <= 24; i++) c + Offset(-100.0 + i * 8, i.isEven ? -40 : 40)];
      final g = await t.startGesture(pts.first, kind: PointerDeviceKind.stylus);
      for (final p in pts.skip(1)) {
        await g.moveTo(p);
      }
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
      await g.up();
      await t.pump();
      await _flush(t);
      final rows = await _rows(t, h, pageId);
      expect(rows.single.points.length, greaterThan(20)); // serbest, noktalar korundu
    });

    testWidgets('hareket süreyi sıfırlar; ayar kapalıyken düzeltme olmaz', (t) async {
      final h = await _db(t);
      final (_, pageId) = await _openPage(t, h);
      final c = _paper(t).center;
      final pts = await wobblyLine(c + const Offset(-120, 0), c + const Offset(120, 0));
      var g = await t.startGesture(pts.first, kind: PointerDeviceKind.stylus);
      for (final p in pts.skip(1)) {
        await g.moveTo(p);
      }
      await t.pump(const Duration(milliseconds: 400));
      await g.moveTo(pts.last + const Offset(30, 0)); // hareket: süre yeniden başlar
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
      await g.up();
      await t.pump();
      await _flush(t);
      expect((await _rows(t, h, pageId)).single.points.length, greaterThan(5));

      // Ayarı kapat.
      await t.tap(find.byKey(const Key('note-shape')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-shape-snap')));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(2, 2)); // pencereyi kapat
      await t.pumpAndSettle();
      expect(_editor(t).session.shapeSnap, isFalse);
      final pts2 = await wobblyLine(c + const Offset(-120, 80), c + const Offset(120, 80));
      g = await t.startGesture(pts2.first, kind: PointerDeviceKind.stylus);
      for (final p in pts2.skip(1)) {
        await g.moveTo(p);
      }
      await t.pump(const Duration(milliseconds: 900));
      expect(find.byKey(const Key('ink-shape-preview')), findsNothing);
      await g.up();
      await t.pump();
    });
  });
}
