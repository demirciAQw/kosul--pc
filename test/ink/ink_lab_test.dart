import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/data/ink_surface_b.dart';
import 'package:kocum/features/ink/presentation/ink_lab_page.dart';

void main() {
  testWidgets('Android dışında A/B geçişi görünmez, B çalışır', (t) async {
    await t.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(const MaterialApp(home: InkLabPage(androidAvailable: false)));
    expect(find.byKey(const Key('ink-impl')), findsNothing);
    expect(find.byType(InkSurfaceBView), findsOneWidget);
    expect(find.text('Kalem denemesi'), findsOneWidget);

    // Kalemle çiz, renk ve silgi seç, temizle.
    await t.tap(find.byKey(const Key('ink-color-ffc62828')));
    await t.pump();
    final c = t.getCenter(find.byType(InkSurfaceBView));
    final g = await t.startGesture(c, kind: PointerDeviceKind.stylus);
    await g.moveBy(const Offset(30, 10));
    await g.up();
    await t.tap(find.byKey(const Key('ink-clear')));
    await t.pump();
    await t.tap(find.text('Silgi'));
    await t.pump();
    expect(find.byType(InkSurfaceBView), findsOneWidget);
  });
}
