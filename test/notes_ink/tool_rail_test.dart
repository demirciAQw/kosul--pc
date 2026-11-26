import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/ink/presentation/ink_mask.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';
import 'package:kocum/features/notes/presentation/tool_rail.dart';

Future<NoteToolSettings> _open(WidgetTester t, {VoidCallback? onSelect}) async {
  t.view.physicalSize = const Size(1000, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final tools = NoteToolSettings();
  addTearDown(tools.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(children: [ToolRail(tools: tools, session: null, onSelect: onSelect)]),
      ),
    ),
  );
  await t.pump();
  return tools;
}

void main() {
  testWidgets('çubuk solda, dikeyde ortada; ana düğmeler var', (t) async {
    await _open(t);
    final rail = t.getRect(find.byKey(const Key('note-rail')));
    expect(rail.left, lessThan(20));
    expect(rail.center.dy, closeTo(700, 80));
    for (final k in ['note-pen', 'note-pen-highlighter', 'note-eraser', 'note-undo', 'note-redo', 'note-ink-hide', 'note-lasso', 'note-shape', 'note-rail-more']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
  });

  testWidgets('seçili araca yeniden dokununca boyut + renk penceresi açılır; "+" özel renk', (t) async {
    final tools = await _open(t);
    // Kalem varsayılan olarak seçili: dokununca pencere açılır.
    await t.tap(find.byKey(const Key('note-pen')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-size-slider')), findsOneWidget);
    expect(find.byKey(const Key('note-size-value')), findsOneWidget);
    expect(find.byKey(const Key('note-color-custom')), findsOneWidget);
    await t.tap(find.byKey(Key('note-color-${penPalette[2].toRadixString(16)}')));
    await t.pump();
    expect(tools.color, penPalette[2]);
    await t.tap(find.byKey(const Key('note-color-custom')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-color-dialog')), findsOneWidget);
    await t.tap(find.byKey(const Key('note-color-ok')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-color-dialog')), findsNothing);
  });

  testWidgets('silgi penceresi: yalnız boyut ve sürterek/seçerek sil', (t) async {
    final tools = await _open(t);
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pump();
    await t.tap(find.byKey(const Key('note-eraser')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('note-size-slider')), findsOneWidget);
    expect(find.byKey(const Key('note-color-custom')), findsNothing);
    await t.tap(find.text('Seçerek sil'));
    await t.pump();
    expect(tools.eraseMode.name, 'stroke');
  });

  testWidgets('"..." menüsü eski yuvaya geçirir', (t) async {
    final tools = await _open(t);
    await t.tap(find.byKey(const Key('note-rail-more')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('note-rail-old-dock')));
    await t.pumpAndSettle();
    expect(tools.rail, isFalse);
  });

  testWidgets('InkMask kayıt olur ve çıkınca silinir; dikdörtgeni piksele çevirir', (t) async {
    final before = InkMaskRegistry.count;
    await t.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(padding: EdgeInsets.all(10), child: InkMask(child: SizedBox(width: 50, height: 40))),
        ),
      ),
    );
    expect(InkMaskRegistry.count, before + 1);
    final r = InkMaskRegistry.rectsPx(2).single;
    expect(r, const Rect.fromLTWH(20, 20, 100, 80));
    await t.pumpWidget(const SizedBox());
    expect(InkMaskRegistry.count, before);
  });

  test('rail ayarı kalıcı haritada gidip gelir', () {
    final a = NoteToolSettings()..setRail(false);
    final b = NoteToolSettings()..restoreSizes(a.toPrefs());
    expect(b.rail, isFalse);
    a.dispose();
    b.dispose();
  });
}
