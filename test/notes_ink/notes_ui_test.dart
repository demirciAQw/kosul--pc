import 'dart:async';

import 'package:drift/drift.dart' show TableUpdate, UpdateKind;
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
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/notes_providers.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/note_page_editor.dart';
import 'package:kocum/features/notes/presentation/notebooks_screen.dart';
import 'package:kocum/features/notes/presentation/page_template_painter.dart';

/// Silme yazımı geciken depo: akış güncellenmeden liste yine de hemen kalkmalı.
class _SlowDeleteRepo extends InkNotebookRepository {
  _SlowDeleteRepo(super.db);
  final gate = Completer<void>();
  @override
  Future<void> deleteNotebook(String id) async {
    await gate.future;
    return super.deleteNotebook(id);
  }
}

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

Future<void> _drag(WidgetTester t, Offset from, Offset to, PointerDeviceKind kind, {int steps = 12}) async {
  final g = await t.startGesture(from, kind: kind);
  for (var i = 1; i <= steps; i++) {
    await g.moveTo(Offset.lerp(from, to, i / steps)!);
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

Future<void> _tapMenu(WidgetTester t, String itemKey) async {
  await t.tap(find.byKey(const Key('note-page-menu')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(itemKey)));
  await _wait(t);
}

double _scale(WidgetTester t) =>
    t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.getMaxScaleOnAxis();

void main() {
  testWidgets('defter oluştur, sayfa ekle, şablon değiştir, kalemle çiz; yeniden açılınca görünür', (t) async {
    final h = await _db(t);
    late String nb;
    await t.runAsync(() async => nb = await h.repo.createNotebook(title: 'Fizik'));
    await _mountScreen(t, h, nb);
    expect(find.text('Fizik'), findsOneWidget);
    expect(find.byKey(const Key('note-page-indicator')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '1 / 1');

    await _tapMenu(t, 'note-page-add');
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '2 / 2');

    // Şablon: varsayılan çizgili; kareli yap.
    PageTemplatePainter paper() =>
        t.widget<CustomPaint>(find.byKey(const Key('note-page-paper'))).painter! as PageTemplatePainter;
    expect(paper().template, PageTemplate.ruled);
    await t.tap(find.byKey(const Key('note-template')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-template-grid')));
    await _wait(t);
    expect(paper().template, PageTemplate.grid);
    await t.tapAt(const Offset(2, 2)); // Sayfa penceresini kapat (açıkken sayfaya dokunuş geçmez)
    await t.pumpAndSettle();
    late List<InkNotePageRecord> pages;
    await t.runAsync(() async => pages = await h.repo.pages(nb));
    expect([for (final p in pages) p.template], [PageTemplate.ruled, PageTemplate.grid]);

    // Kalemle çiz (tükenmez, varsayılan renk).
    final r = _paper(t);
    await _drag(t, r.center + const Offset(-80, 0), r.center + const Offset(80, 20), PointerDeviceKind.stylus);
    await _flush(t);
    final rows = await _rows(t, h, pages[1].id);
    expect(rows, hasLength(1));
    expect(rows.single.tool, 'ballpoint');
    expect(rows.single.points.length, greaterThan(5));
    expect(await _rows(t, h, pages[0].id), isEmpty);

    // Kapat, yeniden aç: 1. sayfa açılır; 2. sayfa küçük resminden seçilince çizgi yüklenir.
    await t.pumpWidget(const SizedBox());
    await _wait(t, 3);
    await _mountScreen(t, h, nb);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '1 / 2');
    await t.tap(find.byKey(const Key('note-strip-toggle'))); // şerit varsayılan kapalı
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('note-thumb-${pages[1].id}')));
    await _wait(t);
    expect(_editor(t).session.penFor(0).strokes, hasLength(1));
    expect(_editor(t).session.penFor(0).strokes.single.brush.kind?.name, 'ballpoint');
  });

  testWidgets('açılışta ensureVisiblePage: sayfasız defter ve tüm sayfaları silinmiş defter', (t) async {
    final h = await _db(t);
    late String empty, gone, gonePage;
    await t.runAsync(() async {
      empty = await h.repo.createNotebook(title: 'Boş', withFirstPage: false);
      gone = await h.repo.createNotebook(title: 'Silinmiş');
      gonePage = (await h.repo.pages(gone)).single.id;
      // İki cihaz son sayfaları ayrı sildi: görünür sayfa kalmadı.
      await h.db.customStatement('UPDATE ink_note_pages SET deleted = 1 WHERE id = ?', [gonePage]);
    });
    await _mountScreen(t, h, empty);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '1 / 1');
    late List<InkNotePageRecord> p;
    await t.runAsync(() async => p = await h.repo.pages(empty));
    expect(p, hasLength(1));

    await t.pumpWidget(const SizedBox());
    await _wait(t, 3);
    await _mountScreen(t, h, gone);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '1 / 1');
    await t.runAsync(() async => p = await h.repo.pages(gone));
    expect(p.single.id, gonePage); // yeni sayfa açılmadı, silinen geri geldi
  });

  testWidgets('kalem çizer; parmak çizmez, yalnız yakınlaştırır; avuç ve kalem sırasındaki ikinci temas yutulur', (t) async {
    final h = await _db(t);
    late String nb;
    await t.runAsync(() async => nb = await h.repo.createNotebook());
    await _mountScreen(t, h, nb);
    final pageId = (await t.runAsync(() => h.repo.pages(nb)))!.single.id;
    final r = _paper(t);

    // Parmak çizmez.
    await _drag(t, r.center + const Offset(-60, 0), r.center + const Offset(60, 0), PointerDeviceKind.touch);
    await _flush(t);
    expect(await _rows(t, h, pageId), isEmpty);

    // İki parmakla yakınlaştır.
    expect(_scale(t), 1);
    final c = r.center;
    final g1 = await t.startGesture(c + const Offset(-20, 0));
    final g2 = await t.startGesture(c + const Offset(20, 0));
    for (var i = 1; i <= 8; i++) {
      await g1.moveTo(c + Offset(-20 - i * 8.0, 0));
      await g2.moveTo(c + Offset(20 + i * 8.0, 0));
    }
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    expect(_scale(t), greaterThan(1.3));
    expect(await _rows(t, h, pageId), isEmpty);
    final before = t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.clone();

    // Avuç (büyük temas): ne çizer ne kaydırır.
    final b = GestureBinding.instance;
    b.handlePointerEvent(PointerDownEvent(pointer: 90, position: c, radiusMajor: 400));
    for (var i = 1; i <= 6; i++) {
      b.handlePointerEvent(PointerMoveEvent(
        pointer: 90,
        position: c + Offset(0, -i * 15.0),
        delta: const Offset(0, -15),
        radiusMajor: 400,
      ));
    }
    b.handlePointerEvent(PointerUpEvent(pointer: 90, position: c + const Offset(0, -90)));
    await t.pumpAndSettle();
    expect(t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value, before);
    await _flush(t);
    expect(await _rows(t, h, pageId), isEmpty);

    // Kalem çizerken ikinci temas (avuç gibi) kaydırmaz, çizgiyi bozmaz; kalem yakınlaşmış sayfada çizer.
    final pen = await t.startGesture(c + const Offset(-40, 0), kind: PointerDeviceKind.stylus);
    expect(_editor(t).session.viewerLocked.value, isTrue);
    final palm = await t.startGesture(c + const Offset(60, 40));
    for (var i = 1; i <= 8; i++) {
      await palm.moveBy(const Offset(0, -20));
      await pen.moveBy(const Offset(10, 0));
    }
    await palm.up();
    await pen.up();
    await t.pumpAndSettle();
    expect(t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value, before);
    await _flush(t);
    final rows = await _rows(t, h, pageId);
    expect(rows, hasLength(1));
    // Çizgi sayfa koordinatında yatay ve (zum 1,3+ olduğundan) sayfa genişliğinin küçük bir kısmı.
    final xs = rows.single.points.map((p) => p.x);
    expect(xs.reduce((a, b) => a > b ? a : b) - xs.reduce((a, b) => a < b ? a : b), greaterThan(30));
    expect(rows.single.points.map((p) => p.y).toSet().length, lessThan(rows.single.points.length));
  });

  testWidgets('silgi iki mod: çizgi silgisi bütün siler, alan silgisi keser; geri al/yinele', (t) async {
    final h = await _db(t);
    late String nb;
    await t.runAsync(() async => nb = await h.repo.createNotebook());
    await _mountScreen(t, h, nb);
    final pageId = (await t.runAsync(() => h.repo.pages(nb)))!.single.id;
    final r = _paper(t);
    final c = r.center;
    await _drag(t, c + const Offset(-100, 0), c + const Offset(100, 0), PointerDeviceKind.stylus, steps: 20);
    await _flush(t);
    final original = (await _rows(t, h, pageId)).single.id;

    Future<void> undo() async {
      await t.tap(find.byKey(const Key('note-undo')));
      await t.runAsync(_editor(t).flush);
      await _wait(t, 2);
    }

    Future<void> redo() async {
      await t.tap(find.byKey(const Key('note-redo')));
      await t.runAsync(_editor(t).flush);
      await _wait(t, 2);
    }

    // Çizgi modu.
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pumpAndSettle();
    await _drag(t, c + const Offset(0, -30), c + const Offset(0, 30), PointerDeviceKind.stylus);
    await _flush(t);
    expect(await _rows(t, h, pageId), isEmpty);
    await undo();
    expect((await _rows(t, h, pageId)).map((e) => e.id), [original]);
    await redo();
    expect(await _rows(t, h, pageId), isEmpty);
    await undo();

    // Alan modu.
    await t.tap(find.byKey(const Key('note-eraser'))); // seçili silgiye yeniden dokun: ayar penceresi
    await t.pumpAndSettle();
    await t.tap(find.text('Alan'));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();
    await _drag(t, c + const Offset(0, -30), c + const Offset(0, 30), PointerDeviceKind.stylus);
    await _flush(t);
    var rows = await _rows(t, h, pageId);
    expect(rows, hasLength(2));
    expect(rows.map((e) => e.id), isNot(contains(original)));
    // Silinen aralıkta nokta kalmadı.
    final cx = c.dx;
    final pageUnitsPerPx = 1404 / r.width;
    final cutX = (cx - r.left) * pageUnitsPerPx;
    for (final row in rows) {
      expect(row.points.every((p) => (p.x - cutX).abs() > 5), isTrue);
    }
    // Hareket başına TEK kayıt: bir geri al özgün çizgiyi getirir.
    await undo();
    expect((await _rows(t, h, pageId)).map((e) => e.id), [original]);
    await redo();
    expect(await _rows(t, h, pageId), hasLength(2));
    await undo();
    expect((await _rows(t, h, pageId)).map((e) => e.id), [original]);
  });

  testWidgets('sayfa işlemleri: araya ekle, çoğalt (çizgilerle), sırala, son sayfa silinemez, sil ve geri al', (t) async {
    final h = await _db(t);
    late String nb;
    await t.runAsync(() async => nb = await h.repo.createNotebook());
    await _mountScreen(t, h, nb);
    final first = (await t.runAsync(() => h.repo.pages(nb)))!.single.id;
    final r = _paper(t);
    await _drag(t, r.center + const Offset(-50, 0), r.center + const Offset(50, 0), PointerDeviceKind.stylus);
    await _flush(t);

    // Son sayfa silinemez.
    await _tapMenu(t, 'note-page-del');
    expect(find.text('Defterin son sayfası silinemez.'), findsOneWidget);

    // Çoğalt: bekleyen kayıt bitirilir, yeni sayfa çizgiyi taşır.
    await _tapMenu(t, 'note-page-dup');
    late List<InkNotePageRecord> pages;
    await t.runAsync(() async => pages = await h.repo.pages(nb));
    expect(pages, hasLength(2));
    expect(pages[0].id, first);
    expect(await _rows(t, h, pages[1].id), hasLength(1));
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '2 / 2');

    // Bundan sonra ekle: 2. sayfanın arkasına.
    await _tapMenu(t, 'note-page-insert');
    await t.runAsync(() async => pages = await h.repo.pages(nb));
    expect(pages, hasLength(3));
    final inserted = pages[2].id;

    // Öne al: eklenen 2. sıraya gelir.
    await _tapMenu(t, 'note-page-up');
    await t.runAsync(() async => pages = await h.repo.pages(nb));
    expect(pages[1].id, inserted);

    // Sil (onaylı) + geri al.
    await _tapMenu(t, 'note-page-del');
    await t.tap(find.byKey(const Key('note-page-delete-confirm')));
    await _wait(t);
    await t.runAsync(() async => pages = await h.repo.pages(nb));
    expect(pages, hasLength(2));
    await t.tap(find.text('Geri al'));
    await _wait(t);
    await t.runAsync(() async => pages = await h.repo.pages(nb));
    expect(pages, hasLength(3));
  });

  testWidgets('açıkken tüm sayfalar senkronla silinirse: sonsuz gösterge yok, görünür sayfa sağlanır', (t) async {
    final h = await _db(t);
    late String nb, only;
    await t.runAsync(() async {
      nb = await h.repo.createNotebook(title: 'Senkron');
      only = (await h.repo.pages(nb)).single.id;
    });
    await _mountScreen(t, h, nb);
    expect(find.byType(NotePageEditor), findsOneWidget);
    await t.runAsync(() async {
      await h.db.customStatement('UPDATE ink_note_pages SET deleted = 1 WHERE id = ?', [only]);
      h.db.notifyUpdates({TableUpdate.onTable(h.db.inkNotePages, kind: UpdateKind.update)});
    });
    await _wait(t);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(NotePageEditor), findsOneWidget);
    late List<InkNotePageRecord> p;
    await t.runAsync(() async => p = await h.repo.pages(nb));
    expect(p.single.id, only); // silinen geri geldi
  });

  testWidgets('açık sayfa başka cihazda silinirse: işlemler gösterilen (ilk) sayfaya uygulanır', (t) async {
    final h = await _db(t);
    late String nb;
    late List<InkNotePageRecord> pages;
    await t.runAsync(() async {
      nb = await h.repo.createNotebook(title: 'Üç');
      await h.repo.addPage(nb);
      await h.repo.addPage(nb);
      pages = await h.repo.pages(nb);
    });
    await _mountScreen(t, h, nb);
    await t.tap(find.byKey(const Key('note-strip-toggle')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('note-thumb-${pages[2].id}')));
    await _wait(t);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '3 / 3');
    await t.runAsync(() async {
      await h.db.customStatement('UPDATE ink_note_pages SET deleted = 1 WHERE id = ?', [pages[2].id]);
      h.db.notifyUpdates({TableUpdate.onTable(h.db.inkNotePages, kind: UpdateKind.update)});
    });
    await _wait(t);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '1 / 2');
    await _tapMenu(t, 'note-page-del');
    await t.tap(find.byKey(const Key('note-page-delete-confirm')));
    await _wait(t);
    late List<InkNotePageRecord> left;
    await t.runAsync(() async => left = await h.repo.pages(nb));
    expect(left.map((p) => p.id), [pages[1].id]); // gösterilen 1. sayfa silindi, eski id (3.) değil
  });

  testWidgets('sayfa ekleyince yeni sayfa kendi oturumuyla açılır, eskisi kapanır', (t) async {
    final h = await _db(t);
    late String nb;
    await t.runAsync(() async => nb = await h.repo.createNotebook(title: 'Bir'));
    await _mountScreen(t, h, nb);
    final first = _editor(t);
    await _tapMenu(t, 'note-page-add');
    final second = _editor(t);
    expect(identical(first, second), isFalse);
    expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '2 / 2');
    expect(first.mounted, isFalse);
  });

  group('defter listesi', () {
    Future<List<InkNotebookRecord>> opened(WidgetTester t, _H h, List<InkNotebookRecord> out) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(h.db), clockProvider.overrideWithValue(() => DateTime(2026, 1, 1))],
          child: MaterialApp(home: NotebooksScreen(onOpen: (_, n) => out.add(n))),
        ),
      );
      await _wait(t);
      return out;
    }

    testWidgets('yeni defter, yeniden adlandır, sil (onaylı) ve geri al, silinenlerden geri getir', (t) async {
      final h = await _db(t);
      final opens = <InkNotebookRecord>[];
      await opened(t, h, opens);
      expect(find.textContaining('Henüz defter yok'), findsOneWidget);

      await t.tap(find.byKey(const Key('notebook-new')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('notebook-title-field')), 'Kimya');
      await t.tap(find.byKey(const Key('notebook-dialog-ok')));
      await _wait(t);
      expect(opens.single.title, 'Kimya'); // oluşturulunca açılır
      expect(find.text('Kimya'), findsOneWidget);
      expect(find.text('1 sayfa'), findsOneWidget);
      final id = opens.single.id;

      await t.tap(find.byKey(Key('notebook-rename-$id')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('notebook-title-field')), 'Organik Kimya');
      await t.tap(find.byKey(const Key('notebook-dialog-ok')));
      await _wait(t);
      expect(find.text('Organik Kimya'), findsOneWidget);

      // Vazgeçilen silme bir şey yapmaz.
      await t.tap(find.byKey(Key('notebook-del-$id')));
      await t.pumpAndSettle();
      await t.tap(find.text('Vazgeç'));
      await t.pumpAndSettle();
      expect(find.text('Organik Kimya'), findsOneWidget);

      await t.tap(find.byKey(Key('notebook-del-$id')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('notebook-delete-confirm')));
      await _wait(t);
      expect(find.text('Organik Kimya'), findsNothing);
      // Kayıt silinmedi, yumuşak silindi.
      late InkNotebookRecord? rec;
      await t.runAsync(() async => rec = await h.repo.findNotebook(id));
      expect(rec!.deleted, isTrue);

      // SnackBar "Geri al".
      await t.tap(find.text('Geri al'));
      await _wait(t);
      expect(find.text('Organik Kimya'), findsOneWidget);

      // Yine sil; Silinenler'den geri getir.
      await t.tap(find.byKey(Key('notebook-del-$id')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('notebook-delete-confirm')));
      await _wait(t);
      await t.tap(find.byKey(const Key('notebook-show-deleted')));
      await _wait(t);
      await t.tap(find.byKey(Key('notebook-restore-$id')));
      await _wait(t);
      expect(find.byKey(Key('notebook-$id')), findsOneWidget);
    });

    testWidgets('silinen defter yazım bitmeden listeden kalkar; Geri al ile döner', (t) async {
      final h = await _db(t);
      late String id;
      await t.runAsync(() async => id = await h.repo.createNotebook(title: 'Fizik'));
      final slow = _SlowDeleteRepo(h.db);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(h.db),
            inkNotebookRepositoryProvider.overrideWithValue(slow),
          ],
          child: const MaterialApp(home: NotebooksScreen()),
        ),
      );
      await _wait(t);
      expect(find.text('Fizik'), findsOneWidget);
      await t.tap(find.byKey(Key('notebook-del-$id')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('notebook-delete-confirm')));
      await t.pumpAndSettle();
      expect(find.text('Fizik'), findsNothing); // veritabanı yazımı henüz bitmedi
      slow.gate.complete();
      await _wait(t);
      expect(find.text('Fizik'), findsNothing);
      await t.tap(find.text('Geri al'));
      await _wait(t);
      expect(find.text('Fizik'), findsOneWidget);
    });

    testWidgets('sıra: depodaki sıraya göre listelenir; sürükleyerek yeniden sıralanır', (t) async {
      final h = await _db(t);
      late List<String> ids;
      await t.runAsync(() async {
        ids = [
          await h.repo.createNotebook(title: 'A'),
          await h.repo.createNotebook(title: 'B'),
          await h.repo.createNotebook(title: 'C'),
        ];
      });
      await opened(t, h, []);
      double y(String t0) => t.getTopLeft(find.text(t0)).dy;
      expect(y('A'), lessThan(y('B')));
      expect(y('B'), lessThan(y('C')));
      // C'yi tutamaçtan en üste sürükle.
      final handle = find.descendant(of: find.byKey(Key('notebook-${ids[2]}')), matching: find.byIcon(Icons.drag_handle));
      final g = await t.startGesture(t.getCenter(handle));
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -25));
        await t.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await _wait(t);
      late List<InkNotebookRecord> list;
      await t.runAsync(() async => list = await h.repo.notebooks());
      expect(list.first.title, 'C');
      expect(y('C'), lessThan(y('A')));
    });


    testWidgets('sıralama hatası: ArgumentError yakalanır, ileti çıkar, liste eski sıraya döner', (t) async {
      final h = await _db(t);
      late List<String> ids;
      await t.runAsync(() async {
        ids = [await h.repo.createNotebook(title: 'A'), await h.repo.createNotebook(title: 'B')];
      });
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(h.db),
            inkNotebookRepositoryProvider.overrideWithValue(_FailingReorderRepo(h.db)),
          ],
          child: MaterialApp(home: NotebooksScreen(onOpen: (_, n) {})),
        ),
      );
      await _wait(t);
      double y(String t0) => t.getTopLeft(find.text(t0)).dy;
      final handle = find.descendant(of: find.byKey(Key('notebook-${ids[1]}')), matching: find.byIcon(Icons.drag_handle));
      final g = await t.startGesture(t.getCenter(handle));
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -25));
        await t.pump(const Duration(milliseconds: 50));
      }
      await g.up();
      await _wait(t);
      expect(find.textContaining('Sıralama kaydedilemedi'), findsOneWidget);
      expect(y('A'), lessThan(y('B')));
      expect(t.takeException(), isNull);
    });
  });
}

class _FailingReorderRepo extends InkNotebookRepository {
  _FailingReorderRepo(super.db);

  @override
  Future<void> reorderNotebooks(List<String> ids) async => throw ArgumentError('Sıralama tüm defterleri içermeli');
}
