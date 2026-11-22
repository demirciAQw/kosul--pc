import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/domain/shape_recognizer.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/note_ink_toolbar.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';

Future<NoteToolSettings> _open(WidgetTester t, Size size) async {
  debugAndroidOverride = true;
  addTearDown(() => debugAndroidOverride = null);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final tools = NoteToolSettings();
  addTearDown(tools.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: NoteInkToolbar(
          tools: tools,
          session: null,
          template: PageTemplate.values.first,
          onTemplate: (_) {},
          onTemplateAll: (_) {},
        ),
      ),
    ),
  );
  await t.pump();
  return tools;
}

void main() {
  const narrow = Size(800, 1280);

  testWidgets('seçili aracın adı görünür; fosforlu paleti ve varsayılan kalınlık', (t) async {
    final tools = await _open(t, narrow);
    String name() => t.widget<Text>(find.byKey(const Key('note-tool-name'))).data!;
    expect(name(), 'Tükenmez');
    await t.tap(find.byKey(const Key('note-pen-highlighter')));
    await t.pump();
    expect(name(), 'Fosforlu');
    expect(tools.width, highlighterDefaultWidth);
    for (final c in highlighterPalette) {
      expect(find.byKey(Key('note-color-${c.toRadixString(16)}')), findsOneWidget);
    }
    expect(find.byKey(Key('note-color-${penPalette.first.toRadixString(16)}')), findsNothing);
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    expect(name(), 'Silgi');
    await t.tap(find.byKey(const Key('note-lasso')));
    await t.pump();
    expect(name(), 'Kement');
    for (final k in PenKind.values) {
      expect(find.byKey(Key('note-pen-${k.name}')), findsOneWidget);
    }
  });

  testWidgets('Boyut paneli: kalem kalınlığı sürgü ve çiple değişir, ön izleme var', (t) async {
    final tools = await _open(t, narrow);
    await t.tap(find.byKey(const Key('note-size')));
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

  testWidgets('Boyut paneli silgide yarıçapı ayarlar; kalem boyutuna dokunmaz', (t) async {
    final tools = await _open(t, narrow);
    final penWidth = tools.width;
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    await t.tap(find.byKey(const Key('note-size')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-size-chip-44')));
    await t.pumpAndSettle();
    expect(tools.eraserRadius, 44);
    expect(tools.brush.width * 2, 44);
    expect(tools.width, penWidth);
    await t.tapAt(const Offset(2, 2));
    await t.pumpAndSettle();
    expect(find.text('Boyut 44'), findsOneWidget);
  });

  testWidgets('Şekil penceresi: anahtar + şekil araçları; seçince ad görünür ve pencere kapanır', (t) async {
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
    expect(t.widget<Text>(find.byKey(const Key('note-tool-name'))).data, 'Üçgen');
    // Silgiye geçince şekil aracı kapanır.
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    expect(tools.shapeTool, isNull);
  });

  for (final size in const [Size(800, 1280), Size(600, 1024), Size(1280, 800), Size(412, 915)]) {
    testWidgets('taşma yok ve tek satır (${size.width.toInt()}), her araçta', (t) async {
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
        expect(t.getSize(find.byType(NoteInkToolbar)).height, lessThan(64));
        expect(find.byKey(const Key('note-shape')), findsOneWidget);
      }
    });
  }
}
