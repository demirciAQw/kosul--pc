import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/data/ink_b_controller.dart';
import 'package:kocum/features/ink/data/ink_surface_b.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/presentation/ink_viewport.dart';

Widget _host(
  InkBController c, {
  GlobalKey<InkViewportState>? vk,
  List<double>? lat,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 400,
        child: InkViewport(
          key: vk,
          child: InkSurfaceBView(
            controller: c,
            onLatency: (ms, n) => lat?.add(ms),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _stroke(
  WidgetTester t,
  Offset from,
  PointerDeviceKind kind, {
  int steps = 5,
}) async {
  final g = await t.startGesture(from, kind: kind);
  for (var i = 1; i <= steps; i++) {
    await g.moveBy(const Offset(10, 4));
  }
  await g.up();
}

void main() {
  testWidgets('kalem çizer, biten çizgi önbelleğe alınır', (t) async {
    final c = InkBController();
    addTearDown(c.dispose);
    final events = <InkEvent>[];
    c.events.listen(events.add);
    await t.pumpWidget(_host(c));
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));

    await _stroke(t, origin + const Offset(50, 50), PointerDeviceKind.stylus);
    expect(c.finished, hasLength(1));
    expect(c.finished.first.points.length, greaterThanOrEqualTo(6));
    expect(events.first, isA<InkStrokeStart>());
    expect(events.last, isA<InkStrokeEnd>());
    expect(events.map((e) => e.strokeId).toSet(), hasLength(1));

    await _stroke(t, origin + const Offset(50, 150), PointerDeviceKind.stylus);
    await _stroke(t, origin + const Offset(50, 250), PointerDeviceKind.stylus);
    expect(c.finished, hasLength(3));
    // Her biten çizgi için yol bir kez; ek karelerde yeniden hesaplanmaz.
    final before = c.outlineComputeCount;
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    c.notifyListeners();
    await t.pump();
    expect(c.outlineComputeCount, before);
    expect(c.hasLive, isFalse);
  });

  testWidgets('süren çizgi yalnız yeni nokta gelince yeniden hesaplanır', (
    t,
  ) async {
    final c = InkBController();
    addTearDown(c.dispose);
    await t.pumpWidget(_host(c));
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));
    final g = await t.startGesture(
      origin + const Offset(20, 20),
      kind: PointerDeviceKind.stylus,
    );
    await g.moveBy(const Offset(10, 10));
    await t.pump();
    final n = c.outlineComputeCount;
    expect(c.hasLive, isTrue);
    await t.pump();
    await t.pump();
    expect(c.outlineComputeCount, n);
    await g.moveBy(const Offset(10, 10));
    await t.pump();
    expect(c.outlineComputeCount, n + 1);
    await g.up();
    expect(c.finished, hasLength(1));
  });

  testWidgets(
    'parmak çizmez (avuç yok sayılır), fare yalnız kapalıyken çizer',
    (t) async {
      final c = InkBController();
      addTearDown(c.dispose);
      await t.pumpWidget(_host(c));
      final origin = t.getTopLeft(find.byType(InkSurfaceBView));

      await _stroke(t, origin + const Offset(50, 50), PointerDeviceKind.touch);
      expect(c.finished, isEmpty);
      await _stroke(t, origin + const Offset(50, 50), PointerDeviceKind.mouse);
      expect(c.finished, isEmpty);

      c.setInputMode(stylusOnly: false);
      await _stroke(t, origin + const Offset(50, 50), PointerDeviceKind.mouse);
      expect(c.finished, hasLength(1));
      // Parmak yine çizmez.
      await _stroke(t, origin + const Offset(50, 150), PointerDeviceKind.touch);
      expect(c.finished, hasLength(1));
    },
  );

  test('inkPointerDraws kuralı', () {
    expect(inkPointerDraws(PointerDeviceKind.stylus, stylusOnly: true), isTrue);
    expect(
      inkPointerDraws(PointerDeviceKind.touch, stylusOnly: false),
      isFalse,
    );
    expect(inkPointerDraws(PointerDeviceKind.mouse, stylusOnly: true), isFalse);
    expect(inkPointerDraws(PointerDeviceKind.mouse, stylusOnly: false), isTrue);
  });

  testWidgets(
    'kalem görünümü oynatmaz; parmak kaydırır ve koordinat dönüşümden bağımsız kalır',
    (t) async {
      final c = InkBController();
      addTearDown(c.dispose);
      final vk = GlobalKey<InkViewportState>();
      await t.pumpWidget(_host(c, vk: vk));
      final origin = t.getTopLeft(find.byType(InkSurfaceBView));

      await _stroke(
        t,
        origin + const Offset(100, 100),
        PointerDeviceKind.stylus,
        steps: 10,
      );
      expect(vk.currentState!.matrix.storage[12], 0); // kalem kaydırmadı

      final g = await t.startGesture(
        origin + const Offset(200, 200),
        kind: PointerDeviceKind.touch,
      );
      await g.moveBy(const Offset(60, 0));
      await g.moveBy(const Offset(60, 0));
      await g.up();
      await t.pump();
      final dx = vk.currentState!.matrix.storage[12];
      expect(dx, greaterThan(40));
      expect(c.finished, hasLength(1)); // parmak çizmedi

      // Kalem ekranda (150,100)'a basar; çizim koordinatı dönüşüm kadar kaymış olmalı.
      final g2 = await t.startGesture(
        origin + const Offset(150, 100),
        kind: PointerDeviceKind.stylus,
      );
      await g2.up();
      final p = c.finished.last.points.first;
      expect(p.x, closeTo(150 - dx, 0.01));
      expect(p.y, closeTo(100, 0.01));
    },
  );

  for (final pen in [true]) {
    testWidgets(
      pen
          ? 'kalem iptali (avuç) çizgiyi bitirir ve kaydeder'
          : 'fare iptali yarım çizgiyi atar ve strokeCancel yollar',
      (t) async {
        final c = InkBController();
        addTearDown(c.dispose);
        final events = <InkEvent>[];
        c.events.listen(events.add);
        await t.pumpWidget(_host(c));
        final origin = t.getTopLeft(find.byType(InkSurfaceBView));
        final g = await t.startGesture(
          origin + const Offset(30, 30),
          kind: pen ? PointerDeviceKind.stylus : PointerDeviceKind.mouse,
        );
        await g.moveBy(const Offset(20, 5));
        await g.cancel();
        await t.pump();
        expect(c.hasLive, isFalse);
        if (pen) {
          expect(c.finished, hasLength(1));
          expect(events.last, isA<InkStrokeEnd>());
        } else {
          expect(c.finished, isEmpty);
          expect(events.last, isA<InkStrokeCancel>());
        }
      },
    );
  }

  testWidgets('silgi çizgiyi kaldırır, clear hepsini siler', (t) async {
    final c = InkBController();
    addTearDown(c.dispose);
    await t.pumpWidget(_host(c));
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));
    await _stroke(t, origin + const Offset(50, 50), PointerDeviceKind.stylus);
    await _stroke(t, origin + const Offset(50, 300), PointerDeviceKind.stylus);
    expect(c.finished, hasLength(2));

    c.setBrush(const InkBrush(tool: InkTool.eraser, width: 12));
    final g = await t.startGesture(
      origin + const Offset(60, 52),
      kind: PointerDeviceKind.stylus,
    );
    await g.up();
    expect(c.finished, hasLength(1));
    expect(c.hasLive, isFalse);

    c.clear();
    expect(c.finished, isEmpty);
  });

  testWidgets('FrameTiming gecikme geri çağrılarını besler (raster ve vsync)', (
    t,
  ) async {
    final c = InkBController();
    addTearDown(c.dispose);
    final raster = <double>[];
    final vsync = <double>[];
    final key = GlobalKey<InkSurfaceBViewState>();
    await t.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 400,
          child: InkSurfaceBView(
            key: key,
            controller: c,
            onLatency: (ms, n) => raster.add(ms),
            onVsyncLatency: (ms, n) => vsync.add(ms),
          ),
        ),
      ),
    );
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));
    final g = await t.startGesture(
      origin + const Offset(50, 50),
      kind: PointerDeviceKind.stylus,
    );
    await g.up();
    const base = 1000000000; // giriş zamanından çok sonra (us)
    key.currentState!.handleTimings([
      ui.FrameTiming(
        vsyncStart: base,
        buildStart: base,
        buildFinish: base + 2000,
        rasterStart: base + 3000,
        rasterFinish: base + 30000,
        rasterFinishWallTime: base + 30000,
      ),
    ]);
    expect(raster, hasLength(1));
    expect(vsync, hasLength(1));
    expect(raster.single - vsync.single, closeTo(30.0, 0.001));
    expect(vsync.single, greaterThan(0));
    // Giriş tüketildi: ikinci kare ölçüm üretmez.
    key.currentState!.handleTimings([
      ui.FrameTiming(
        vsyncStart: base + 16000,
        buildStart: base + 16000,
        buildFinish: base + 17000,
        rasterStart: base + 18000,
        rasterFinish: base + 40000,
        rasterFinishWallTime: base + 40000,
      ),
    ]);
    expect(raster, hasLength(1));
  });

  testWidgets(
    'uzun süren çizgi parçalanır: getStroke her seferinde sınırlı nokta alır',
    (t) async {
      final c = InkBController();
      addTearDown(c.dispose);
      await t.pumpWidget(_host(c));
      final origin = t.getTopLeft(find.byType(InkSurfaceBView));
      final g = await t.startGesture(
        origin + const Offset(5, 5),
        kind: PointerDeviceKind.stylus,
      );
      for (var i = 0; i < 600; i++) {
        await g.moveBy(Offset(0.5, (i.isEven ? 0.3 : -0.3)));
        if (i % 7 == 0) await t.pump();
      }
      await t.pump();
      expect(c.liveChunks.length, greaterThan(3));
      expect(c.maxLiveOutlinePoints, lessThanOrEqualTo(110));
      await g.up();
      expect(c.finished, hasLength(1));
      expect(
        c.finished.single.points.length,
        greaterThan(590),
      ); // tamamı saklanır
      expect(c.liveChunks, isEmpty);
    },
  );

  testWidgets('biten çizgi bildirimcisi yalnız liste değişince tetiklenir', (
    t,
  ) async {
    final c = InkBController();
    addTearDown(c.dispose);
    var n = 0;
    c.finishedChanges.addListener(() => n++);
    await t.pumpWidget(_host(c));
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));
    final g = await t.startGesture(
      origin + const Offset(20, 20),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(5, 5));
    }
    expect(n, 0);
    await g.up();
    expect(n, 1);
    c.clear();
    expect(n, 2);
  });

  testWidgets('ters kalem ucu silgi gibi siler', (t) async {
    final c = InkBController();
    addTearDown(c.dispose);
    await t.pumpWidget(_host(c));
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));
    await _stroke(t, origin + const Offset(50, 50), PointerDeviceKind.stylus);
    expect(c.finished, hasLength(1));
    final g = await t.startGesture(
      origin + const Offset(60, 54),
      kind: PointerDeviceKind.invertedStylus,
    );
    await g.moveBy(const Offset(5, 2));
    await g.up();
    await t.pump();
    expect(c.finished, isEmpty);
  });

  test('dispose sonrası çizim çağrıları kapalı akışa yazmaz', () {
    final c = InkBController();
    c.beginStroke(const InkPoint(x: 1, y: 1, pressure: 0.5, tilt: 0, tMs: 0));
    c.dispose();
    const p = InkPoint(x: 2, y: 2, pressure: 0.5, tilt: 0, tMs: 1);
    expect(() {
      c.addPoint(p);
      c.cancelStroke();
      c.beginStroke(p);
      c.endStroke(p);
      c.clear();
    }, returnsNormally);
  });

  testWidgets('kalem çizerken ikinci parmak görünümü oynatmaz', (t) async {
    final c = InkBController();
    addTearDown(c.dispose);
    final vk = GlobalKey<InkViewportState>();
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: InkViewport(
              key: vk,
              drawingActive: () => c.liveStrokeId != null,
              child: InkSurfaceBView(controller: c),
            ),
          ),
        ),
      ),
    );
    final origin = t.getTopLeft(find.byType(InkSurfaceBView));
    final pen = await t.startGesture(
      origin + const Offset(50, 50),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(5, 5));
    final palm = await t.startGesture(
      origin + const Offset(200, 200),
      kind: PointerDeviceKind.touch,
    );
    await palm.moveBy(const Offset(80, 60));
    await palm.moveBy(const Offset(40, 40));
    await t.pump();
    expect(vk.currentState!.matrix.storage[12], 0);
    expect(vk.currentState!.matrix.storage[13], 0);
    await palm.up();
    await pen.up();
  });
}
