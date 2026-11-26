import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/data/ink_surface_a.dart';
import 'package:kocum/features/ink/domain/ink_channel_codec.dart';
import 'package:kocum/features/ink/presentation/ink_lab_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'A modunda parmak yakınlaştırır (yerele setTransform), kalem yakınlaştırmaz',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      final touches = <int>[]; // yerele giden dokunma olayları (pointer sayısı)
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        c,
      ) async {
        if (c.method == 'create') return 1; // doku kimliği
        if (c.method == 'touch') touches.add(1);
        return null;
      });
      final nativeCalls = <MethodCall>[];
      // Görünüm kimliği sayaçtan gelir: olası kimliklerin hepsini dinle.
      for (var id = 0; id < 64; id++) {
        messenger.setMockMethodCallHandler(MethodChannel(inkChannelName(id)), (
          c,
        ) async {
          nativeCalls.add(c);
          return null;
        });
      }
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
        for (var id = 0; id < 64; id++) {
          messenger.setMockMethodCallHandler(
            MethodChannel(inkChannelName(id)),
            null,
          );
        }
      });

      await t.binding.setSurfaceSize(const Size(1000, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        const MaterialApp(home: InkLabPage(androidAvailable: true)),
      );
      await t.tap(find.text('A (yerel)'));
      await t.pump();
      expect(find.byType(InkSurfaceAView), findsOneWidget);

      final c = t.getCenter(find.byType(InkSurfaceAView));
      final tf = nativeCalls.where((e) => e.method == 'setTransform').toList();
      expect(tf, isEmpty); // kimlik dönüşüm: gönderilmez

      // Kalemle çizim: dönüşüm değişmez.
      final pen = await t.startGesture(c, kind: PointerDeviceKind.stylus);
      await pen.moveBy(const Offset(40, 10));
      await pen.up();
      await t.pump();
      expect(nativeCalls.where((e) => e.method == 'setTransform'), isEmpty);

      final beforeFingers = touches.length;
      expect(beforeFingers, greaterThan(0)); // kalem yerele gitti
      // İki parmakla açma: dönüşüm yerele gider (ölçek > 1).
      final f1 = await t.startGesture(
        c - const Offset(20, 0),
        kind: PointerDeviceKind.touch,
        pointer: 21,
      );
      final f2 = await t.startGesture(
        c + const Offset(20, 0),
        kind: PointerDeviceKind.touch,
        pointer: 22,
      );
      await f1.moveBy(const Offset(-40, 0));
      await f2.moveBy(const Offset(40, 0));
      await t.pump();
      await f1.up();
      await f2.up();
      await t.pump();
      final sent = nativeCalls
          .where((e) => e.method == 'setTransform')
          .toList();
      expect(sent, isNotEmpty);
      final last = sent.last.arguments as Map;
      expect(last['scale'] as double, greaterThan(1.5));

      // Parmak dokunuşları yerel görünüme iletilmedi (yalnız kalem iletilir).
      expect(
        touches.length,
        beforeFingers,
        reason: 'parmak olayları yerele sızmamalı',
      );
    },
  );
}
