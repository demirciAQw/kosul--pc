import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/domain/shape_recognizer.dart';
import 'package:kocum/features/notes/data/note_tool_prefs_store.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/note_tool_dock.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart' show EraseMode;

class _Style {
  PageTemplate? template;
  PageTemplate? all;
  int? background;
  double? spacing;
}

Future<NoteToolSettings> _open(WidgetTester t, Size size, {_Style? style, bool small = false}) async {
  debugAndroidOverride = true;
  addTearDown(() => debugAndroidOverride = null);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final tools = NoteToolSettings();
  addTearDown(tools.dispose);
  final st = style ?? _Style();
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: NoteToolDock(
            tools: tools,
            session: null,
            small: small,
            page: PageStyleControl(
              template: PageTemplate.plain,
              background: 0xFFFFFFFF,
              spacing: 1,
              onTemplate: (v) => st.template = v,
              onTemplateAll: (v) => st.all = v,
              onBackground: (v) => st.background = v,
              onSpacing: (v) => st.spacing = v,
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return tools;
}

String _name(WidgetTester t) => t.widget<Text>(find.byKey(const Key('note-tool-name'))).data!;

void main() {
  setUpAll(() => NoteToolSettings.defaultRail = false); // eski yuva davranışı
  const narrow = Size(800, 1280);

  testWidgets('dokunuş aracı seçer; seçili araca ikinci dokunuş ayar penceresi açar', (t) async {
    final tools = await _open(t, narrow);
    expect(find.byKey(const Key('note-popover')), findsNothing);
    // Kalem zaten seçili: ilk dokunuş pencere açar.
    await t.tap(find.byKey(const Key('note-pen')));
    await t.pumpAndSettle();
    expect(_name(t), 'Tükenmez');
    expect(find.byKey(const Key('note-pen-kind-fountain')), findsOneWidget);
    await t.tapAt(const Offset(2, 2)); // dışına dokun: kapanır
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-popover')), findsNothing);

    // Fosforlu: ilk dokunuş seçer (pencere yok), ikincisi açar.
    await t.tap(find.byKey(const Key('note-pen-highlighter')));
    await t.pumpAndSettle();
    expect(tools.kind, PenKind.highlighter);
    expect(tools.width, highlighterDefaultWidth);
    expect(find.byKey(const Key('note-popover')), findsNothing);
    await t.tap(find.byKey(const Key('note-pen-highlighter')));
    await t.pumpAndSettle();
    expect(_name(t), 'Fosforlu');
    for (final c in highlighterPalette) {
      expect(find.byKey(Key('note-color-${c.toRadixString(16)}')), findsOneWidget);
    }
    expect(find.byKey(Key('note-color-${penPalette.first.toRadixString(16)}')), findsNothing);
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pumpAndSettle();
    expect(tools.eraser, isTrue);
    expect(find.byKey(const Key('note-popover')), findsNothing);
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pumpAndSettle();
    expect(_name(t), 'Silgi');
    expect(find.byKey(const Key('note-erase-mode-area')), findsOneWidget);
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();

    // Kement: seçer; ikinci dokunuş kaleme döner.
    await t.tap(find.byKey(const Key('note-lasso')));
    await t.pump();
    expect(tools.lasso, isTrue);
    await t.tap(find.byKey(const Key('note-lasso')));
    await t.pump();
    expect(tools.lasso, isFalse);
    expect(tools.kind, PenKind.ballpoint);
  });

  testWidgets('kalem penceresi: tür seçimi, renk, sertlik; kalem düğmesi son kalemi hatırlar', (t) async {
    final tools = await _open(t, narrow);
    await t.tap(find.byKey(const Key('note-pen')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-pen-kind-pencil')));
    await t.pumpAndSettle();
    expect(tools.kind, PenKind.pencil);
    final c = penPalette[3];
    await t.tap(find.byKey(Key('note-color-${c.toRadixString(16)}')));
    await t.pumpAndSettle();
    expect(tools.color, c);
    expect(find.byKey(const Key('note-hardness')), findsOneWidget);
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();
    // Fosforluya geç, kaleme dön: kurşun kalem geri gelir.
    await t.tap(find.byKey(const Key('note-pen-highlighter')));
    await t.pump();
    await t.tap(find.byKey(const Key('note-pen')));
    await t.pump();
    expect(tools.kind, PenKind.pencil);
  });

  testWidgets('Boyut: kalem kalınlığı sürgü ve çiple değişir, ön izleme var', (t) async {
    final tools = await _open(t, narrow);
    await t.tap(find.byKey(const Key('note-pen')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-size-preview')), findsOneWidget);
    final before = tools.width;
    await t.drag(find.byKey(const Key('note-size-slider')), const Offset(60, 0));
    await t.pumpAndSettle();
    expect(tools.width, greaterThan(before));
    await t.tap(find.byKey(const Key('note-size-chip-8')));
    await t.pumpAndSettle();
    expect(tools.width, 8);
    expect(tools.brush.width, 8);
  });

  testWidgets('Silgi penceresi yarıçapı ve modu ayarlar; kalem boyutuna dokunmaz', (t) async {
    final tools = await _open(t, narrow);
    final penWidth = tools.width;
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-size-chip-44')));
    await t.pumpAndSettle();
    expect(tools.eraserRadius, 44);
    expect(tools.brush.width * 2, 44);
    expect(tools.width, penWidth);
    expect(tools.eraseMode, EraseMode.area); // varsayılan: kısmi silgi
    await t.tap(find.byKey(const Key('note-erase-mode-stroke')));
    await t.pumpAndSettle();
    expect(tools.eraseMode, EraseMode.stroke);
    await t.tap(find.byKey(const Key('note-erase-mode-area')));
    await t.pumpAndSettle();
    expect(tools.eraseMode, EraseMode.area);
  });

  testWidgets('Şekil penceresi: anahtar + şekil araçları; seçince yuvada simge değişir ve pencere kapanır', (t) async {
    final tools = await _open(t, narrow);
    await t.tap(find.byKey(const Key('note-shape')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-shape-snap')), findsOneWidget);
    for (final s in ShapeTool.values) {
      expect(find.byKey(Key('note-shape-${s.name}')), findsOneWidget);
    }
    await t.tap(find.byKey(const Key('note-shape-triangle')));
    await t.pumpAndSettle();
    expect(tools.shapeTool, ShapeTool.triangle);
    expect(find.byKey(const Key('note-shape-snap')), findsNothing);
    // Silgiye geçince şekil aracı kapanır.
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    expect(tools.shapeTool, isNull);
  });

  testWidgets('Sayfa penceresi: hızlı şablon, tüm sayfalar, arka plan, çizgi aralığı', (t) async {
    final st = _Style();
    await _open(t, narrow, style: st);
    await t.tap(find.byKey(const Key('note-template')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-template-grid')));
    await t.pumpAndSettle();
    expect(st.template, PageTemplate.grid);
    await t.tap(find.byKey(const Key('note-template-all-dots')));
    await t.pumpAndSettle();
    expect(st.all, PageTemplate.dots);
    await t.tap(find.byKey(const Key('note-bg-cream')));
    await t.pumpAndSettle();
    expect(st.background, 0xFFFFF8E1);
    await t.tap(find.byKey(const Key('note-bg-dark')));
    await t.pumpAndSettle();
    expect(st.background, 0xFF263238);
    await t.tap(find.byKey(const Key('note-spacing-wide')));
    await t.pumpAndSettle();
    expect(st.spacing, 1.5);
    expect(t.takeException(), isNull);
  });

  testWidgets('Konum menüsü: dört yön seçilir ve araç ayarında tutulur', (t) async {
    final tools = await _open(t, narrow);
    expect(tools.dockPosition, DockPosition.bottom);
    await t.tap(find.byKey(const Key('note-dock-move')));
    await t.pumpAndSettle();
    for (final k in const ['top', 'bottom', 'left', 'right']) {
      expect(find.byKey(Key('note-dock-pos-$k')), findsOneWidget);
    }
    await t.tap(find.byKey(const Key('note-dock-pos-top')));
    await t.pumpAndSettle();
    expect(tools.dockAtTop, isTrue);
    expect(tools.toPrefs()['dock.top'], true);
    await t.tap(find.byKey(const Key('note-dock-move')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-dock-pos-right')));
    await t.pumpAndSettle();
    expect(tools.dockPosition, DockPosition.right);
    expect(tools.toPrefs()['dock.pos'], 'right');
    final back = NoteToolSettings()..restoreSizes(tools.toPrefs());
    addTearDown(back.dispose);
    expect(back.dockPosition, DockPosition.right);
  });

  testWidgets('Konum düğmesini basılı tutup sürükleyince en yakın kenara taşınır', (t) async {
    final tools = await _open(t, narrow);
    for (final (to, pos) in [
      (const Offset(4, 600), DockPosition.left),
      (const Offset(796, 600), DockPosition.right),
      (const Offset(400, 3), DockPosition.top),
      (const Offset(400, 1277), DockPosition.bottom),
    ]) {
      final g = await t.startGesture(t.getCenter(find.byKey(const Key('note-dock-move'))));
      await t.pump(const Duration(milliseconds: 700)); // basılı tut
      await g.moveTo(to);
      await t.pump();
      await g.up();
      await t.pumpAndSettle();
      expect(tools.dockPosition, pos);
      // Yön değişti: düğme yerinde değil, sonraki turda yeniden bulunur.
      await t.tap(find.byKey(const Key('note-dock-move')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('note-dock-pos-${pos.name}')));
      await t.pumpAndSettle();
    }
  });

  test('nearestDockPosition: boyuta oranlı en yakın kenar', () {
    const s = Size(1250, 2000);
    expect(nearestDockPosition(const Offset(600, 10), s), DockPosition.top);
    expect(nearestDockPosition(const Offset(600, 1990), s), DockPosition.bottom);
    expect(nearestDockPosition(const Offset(10, 1000), s), DockPosition.left);
    expect(nearestDockPosition(const Offset(1240, 1000), s), DockPosition.right);
    expect(nearestDockPosition(Offset.zero, Size.zero), DockPosition.bottom);
  });

  test('silgi varsayılanı kısmi (alan); mod kalıcı, bozuk değer yok sayılır', () {
    final a = NoteToolSettings();
    addTearDown(a.dispose);
    expect(a.eraseMode, EraseMode.area);
    a.setEraseMode(EraseMode.stroke);
    final b = NoteToolSettings()..restoreSizes(a.toPrefs());
    addTearDown(b.dispose);
    expect(b.eraseMode, EraseMode.stroke);
    final c = NoteToolSettings()..restoreSizes({'erase.mode': 'bozuk'});
    addTearDown(c.dispose);
    expect(c.eraseMode, EraseMode.area);
    final d = NoteToolSettings()..restoreSizes(const {}); // eski kayıt: mod yok -> alan
    addTearDown(d.dispose);
    expect(d.eraseMode, EraseMode.area);
  });

  testWidgets('silgi penceresi: iki mod kartı, kalınlık sürgüsü ve önizleme hep görünür', (t) async {
    final tools = await _open(t, narrow);
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pumpAndSettle();
    expect(find.text('Kısmi silgi (kalınlık)'), findsOneWidget);
    expect(find.text('Çizgi silgisi (tamamını sil)'), findsOneWidget);
    for (final m in [EraseMode.stroke, EraseMode.area]) {
      await t.tap(find.byKey(Key('note-erase-mode-${m.name}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-size-slider')), findsOneWidget);
      expect(find.byKey(const Key('note-size-preview')), findsOneWidget);
      expect(tools.eraseMode, m);
    }
    await t.drag(find.byKey(const Key('note-size-slider')), const Offset(200, 0));
    await t.pump();
    expect(tools.eraserRadius, greaterThan(eraserRadiusDefault));
  });

  testWidgets('odak modunda yuva küçülür: Sayfa ve Konum (⇅) açık kalır, araçlar durur', (t) async {
    await _open(t, narrow, small: true);
    expect(find.byKey(const Key('note-template')), findsOneWidget);
    expect(find.byKey(const Key('note-dock-move')), findsOneWidget);
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('note-undo')), findsOneWidget);
    expect(find.byKey(const Key('note-redo')), findsOneWidget);
    expect(find.byKey(const Key('note-pen')), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('note-eraser'))).shortestSide, 44);
  });

  testWidgets('kement seçiliyken seçim eylemleri yoktur oturum yoksa; kalemde yoktur', (t) async {
    final tools = await _open(t, narrow);
    expect(find.byKey(const Key('note-sel-delete')), findsNothing);
    tools.setLasso(true); // session null: eylem çubuğu gelmez, taşma da olmaz
    await t.pump();
    expect(t.takeException(), isNull);
  });

  for (final size in const [Size(1250, 2000), Size(2000, 1250), Size(800, 1280), Size(600, 1024), Size(412, 915), Size(360, 740)]) {
    testWidgets('taşma yok, tek satır (${size.width.toInt()}x${size.height.toInt()}), her araçta ve her pencerede', (t) async {
      final tools = await _open(t, size);
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
        final dock = t.getSize(find.byKey(const Key('note-dock')));
        expect(dock.height, lessThan(72));
        expect(dock.width, lessThanOrEqualTo(size.width));
        expect(find.byKey(const Key('note-shape')), findsOneWidget);
      }
      // Pencereler dar ekranda da taşmaz.
      for (final k in const ['note-pen', 'note-pen-highlighter', 'note-eraser', 'note-shape', 'note-template']) {
        await t.ensureVisible(find.byKey(Key(k)));
        await t.tap(find.byKey(Key(k)));
        await t.pumpAndSettle();
        if (find.byKey(const Key('note-popover')).evaluate().isEmpty) {
          // İlk dokunuş yalnız seçti; ikincisi pencere açar.
          await t.tap(find.byKey(Key(k)));
          await t.pumpAndSettle();
        }
        expect(t.takeException(), isNull, reason: k);
        await t.tapAt(const Offset(1, 1));
        await t.pumpAndSettle();
      }
    });
  }

  group('boyut kalıcılığı', () {
    testWidgets('kaydet -> yeni oturumda geri gelir; bozuk kayıt yok sayılır', (t) async {
      late AppDatabase db;
      late NoteToolPrefsStore store;
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
        store = NoteToolPrefsStore(db);
      });
      addTearDown(() => t.runAsync(db.close));

      final a = NoteToolSettings()
        ..setKind(PenKind.fountain)
        ..setSize(9)
        ..setKind(PenKind.highlighter)
        ..setSize(30)
        ..setEraser(true)
        ..setSize(44)
        ..setDockAtTop(true);
      addTearDown(a.dispose);
      await t.runAsync(() => store.save(a.toPrefs()));

      final b = NoteToolSettings();
      addTearDown(b.dispose);
      await t.runAsync(() async => b.restoreSizes(await store.load()));
      b.setKind(PenKind.fountain);
      expect(b.width, 9);
      b.setKind(PenKind.highlighter);
      expect(b.width, 30);
      expect(b.eraserRadius, 44);
      expect(b.dockAtTop, isTrue);

      // Boş/bozuk değerler varsayılanı bozmaz.
      final c = NoteToolSettings();
      addTearDown(c.dispose);
      c.restoreSizes({'width.ballpoint': 'x', 'eraser': null, 'dock.top': 5});
      expect(c.width, 3);
      expect(c.dockAtTop, isFalse);
    });
  });
}
