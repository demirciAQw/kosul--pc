import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/domain/shape_recognizer.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/note_tool_dock.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';
import 'package:kocum/features/pdf/domain/page_coords.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';

PageStyleControl _page() => PageStyleControl(
  template: PageTemplate.plain,
  background: 0xFFFFFFFF,
  spacing: 1,
  onTemplate: (_) {},
  onTemplateAll: (_) {},
  onBackground: (_) {},
  onSpacing: (_) {},
);

Future<NoteToolSettings> _open(
  WidgetTester t,
  Size size,
  DockPosition pos, {
  PdfInkSession? session,
  PageStyleControl? page,
  VoidCallback? onSelect,
}) async {
  debugAndroidOverride = true;
  addTearDown(() => debugAndroidOverride = null);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final tools = NoteToolSettings()..setDockPosition(pos);
  addTearDown(tools.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            FloatingToolDock(
              tools: tools,
              session: session,
              page: page ?? _page(),
              onSelect: onSelect,
            ),
          ],
        ),
      ),
    ),
  );
  await t.pump();
  return tools;
}

void main() {
  for (final size in const [
    Size(1250, 2000),
    Size(2000, 1250),
    Size(1250, 800),
    Size(800, 1280),
    Size(412, 915),
    Size(360, 740),
  ]) {
    for (final pos in const [DockPosition.left, DockPosition.right]) {
      testWidgets(
        'dikey yuva ${pos.name} ${size.width.toInt()}x${size.height.toInt()}: taşma yok, her araç ve pencere',
        (t) async {
          final tools = await _open(t, size, pos, onSelect: () {});
          expect(t.takeException(), isNull);
          for (final act in <void Function()>[
            () => tools.setKind(PenKind.highlighter),
            () => tools.setEraser(true),
            () => tools.setLasso(true),
            () => tools.setShapeTool(ShapeTool.rectangle),
          ]) {
            act();
            await t.pump();
            expect(t.takeException(), isNull);
            final dock = t.getRect(find.byKey(const Key('note-dock')));
            expect(dock.width, lessThan(90)); // dar sütun
            expect(dock.height, lessThanOrEqualTo(size.height));
            expect(dock.left, greaterThanOrEqualTo(0));
            expect(dock.right, lessThanOrEqualTo(size.width));
            // Sütun: düğmeler alt alta, aynı x.
            final a = t.getCenter(find.byKey(const Key('note-pen'))).dx;
            expect(
              (t.getCenter(find.byKey(const Key('note-shape'))).dx - a).abs(),
              lessThan(1),
            );
            expect(
              t.getCenter(find.byKey(const Key('note-shape'))).dy,
              greaterThan(t.getCenter(find.byKey(const Key('note-pen'))).dy),
            );
          }
          // Geri al/yinele her zaman görünür (ekran yüksekliği yetmese de kaydırmayla ulaşılır).
          expect(find.byKey(const Key('note-undo')), findsOneWidget);
          expect(find.byKey(const Key('note-redo')), findsOneWidget);
          // Pencereler yana açılır ve ekran içinde kalır.
          for (final k in const [
            'note-pen',
            'note-pen-highlighter',
            'note-eraser',
            'note-shape',
            'note-template',
            'note-dock-move',
          ]) {
            await t.ensureVisible(find.byKey(Key(k)));
            await t.pump();
            final btn = t.getRect(find.byKey(Key(k)));
            await t.tap(find.byKey(Key(k)));
            await t.pumpAndSettle();
            if (find.byKey(const Key('note-popover')).evaluate().isEmpty) {
              await t.tap(find.byKey(Key(k)));
              await t.pumpAndSettle();
            }
            expect(t.takeException(), isNull, reason: k);
            final pop = t.getRect(find.byKey(const Key('note-popover')));
            expect(pop.left, greaterThanOrEqualTo(0), reason: k);
            expect(pop.top, greaterThanOrEqualTo(0), reason: k);
            expect(pop.right, lessThanOrEqualTo(size.width), reason: k);
            expect(pop.bottom, lessThanOrEqualTo(size.height), reason: k);
            // Yuvanın yanında: düğmeyle yatayda örtüşmez.
            expect(
              pop.left >= btn.right - 1 || pop.right <= btn.left + 1,
              isTrue,
              reason: k,
            );
            await t.tapAt(Offset(size.width > 800 ? 700 : 1, 1));
            await t.pumpAndSettle();
            if (find.byKey(const Key('note-popover')).evaluate().isNotEmpty) {
              await t.tapAt(Offset(size.width / 2, 2));
              await t.pumpAndSettle();
            }
          }
        },
      );
    }
  }

  testWidgets(
    'dikey yuva: Konum menüsünden yatay düzene dönülür, sütun yatay satır olur',
    (t) async {
      final tools = await _open(t, const Size(1250, 2000), DockPosition.left);
      await t.tap(find.byKey(const Key('note-dock-move')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-dock-pos-bottom')));
      await t.pumpAndSettle();
      expect(tools.dockPosition, DockPosition.bottom);
      final dock = t.getRect(find.byKey(const Key('note-dock')));
      expect(dock.height, lessThan(80));
      expect(dock.width, greaterThan(300));
      expect(dock.bottom, greaterThan(1900)); // altta
    },
  );

  testWidgets('kenar yerleşimi: üst, alt, sol, sağ', (t) async {
    for (final (pos, check) in <(DockPosition, bool Function(Rect, Size))>[
      (DockPosition.top, (r, s) => r.top < 20),
      (DockPosition.bottom, (r, s) => r.bottom > s.height - 20),
      (DockPosition.left, (r, s) => r.left < 20),
      (DockPosition.right, (r, s) => r.right > s.width - 20),
    ]) {
      const size = Size(1250, 800);
      await _open(t, size, pos);
      expect(
        check(t.getRect(find.byKey(const Key('note-dock'))), size),
        isTrue,
        reason: pos.name,
      );
    }
  });

  group('geri al / yinele', () {
    testWidgets(
      'oturum yokken de görünür (soluk), oturumla etkinleşir ve çalışır',
      (t) async {
        late AppDatabase db;
        late PdfInkSession s;
        await t.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
          await db.customSelect('SELECT 1').get();
          s = PdfInkSession(
            documentId: 'p1',
            repository: InkStrokeRepository(db),
            attemptNo: 0,
            retryDelays: const [Duration.zero],
            ownerOf: (_) => const NotePageOwner('p1', 1),
            penKinds: true,
          );
        });
        addTearDown(() => t.runAsync(db.close));
        addTearDown(s.dispose);

        // Oturumsuz: görünür.
        await _open(t, const Size(1250, 800), DockPosition.bottom);
        expect(find.byKey(const Key('note-undo')), findsOneWidget);
        expect(find.byKey(const Key('note-redo')), findsOneWidget);

        await _open(t, const Size(1250, 800), DockPosition.left, session: s);
        expect(s.canUndo, isFalse);
        expect(
          t.getSize(find.byKey(const Key('note-undo'))).shortestSide,
          greaterThanOrEqualTo(48),
        );
        final coords = PageCoords.tryCreate(
          pageWidth: 600,
          pageHeight: 800,
          viewWidth: 600,
          viewHeight: 800,
        )!;
        await t.runAsync(() async {
          s.addStroke(0, const InkBrush(), [
            for (var i = 0; i < 5; i++)
              InkPoint(x: 10.0 + i * 5, y: 20, pressure: 0.5, tMs: i * 8.0),
          ], coords);
          await s.flush();
        });

        await t.pump();
        expect(s.canUndo, isTrue);
        await t.tap(find.byKey(const Key('note-undo')));
        await t.runAsync(
          () => Future.delayed(const Duration(milliseconds: 300)),
        );
        await t.pump();
        expect(s.canUndo, isFalse);
        expect(s.canRedo, isTrue);
        await t.tap(find.byKey(const Key('note-redo')));
        await t.runAsync(
          () => Future.delayed(const Duration(milliseconds: 300)),
        );
        await t.pump();
        expect(s.canUndo, isTrue);
        expect(s.canRedo, isFalse);
      },
    );
  });

  testWidgets(
    'PDF yuvası: sayfa düğmesi yok, soru seç var ve seçiliyken araçlar seçili görünmez',
    (t) async {
      var toggles = 0;
      late NoteToolSettings tools;
      tools = await _open(
        t,
        const Size(1250, 800),
        DockPosition.bottom,
        page: null,
        onSelect: () => toggles++,
      );
      // `page: null` varsayılana düşer: doğrudan NoteToolDock ile dene.
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NoteToolDock(
              tools: tools,
              session: null,
              onSelect: () => toggles++,
              selecting: true,
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('note-template')), findsNothing);
      expect(find.byKey(const Key('pdf-tool-select')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pump();
      expect(toggles, 1); // önce seçim kapanır
      expect(tools.eraser, isTrue);
    },
  );
}
