import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/data/ink_overlay_codec.dart';
import 'package:kocum/features/ink/data/ink_overlay_controller.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_overlay_geometry.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('kodek', () {
    test('Dart -> yerel iletiler', () {
      expect(encodeSetMode(InkOverlayMode.highlighter), {'mode': 'highlighter'});
      expect(
        encodeSetBrush(family: InkOverlayFamily.pressurePen, argb: 0xFF112233, sizePx: 6),
        {'family': 'pressurePen', 'argb': 0xFF112233, 'sizePx': 6.0, 'epsilon': 0.1},
      );
      // Geçersiz boyut/epsilon güvenli değere iner.
      final bad = encodeSetBrush(family: InkOverlayFamily.marker, argb: 1, sizePx: double.nan, epsilon: 0);
      expect(bad['sizePx'], 1.0);
      expect(bad['epsilon'], 0.1);
      expect(
        encodeRects([const Rect.fromLTRB(1, 2, 30, 40), const Rect.fromLTRB(5, 5, 5, 9), Rect.fromLTRB(0, 0, double.infinity, 1)]),
        {
          'rects': [
            [1.0, 2.0, 30.0, 40.0],
          ],
        },
      );
      expect(encodeRelease([3, 4]), {'ids': [3, 4]});
    });

    test('yerel -> Dart: başla, bitir, iptal', () {
      final s = decodeOverlayCall(inkOverlayStrokeStart, {'id': 7});
      expect(s, isA<OverlayStrokeStart>().having((e) => e.id, 'id', 7));
      final c = decodeOverlayCall(inkOverlayStrokeCanceled, {'id': 8});
      expect(c, isA<OverlayStrokeCanceled>().having((e) => e.id, 'id', 8));
      final f = decodeOverlayCall(inkOverlayStrokeFinished, {
        'id': 9,
        'family': 'highlighter',
        'argb': 0x80FF0000,
        'sizePx': 14.5,
        'points': Float32List.fromList([10, 20, 0, 0.5, 0.25, 1, 11, 21, 8, 0.75, 0.25, 1]),
      });
      expect(f, isA<OverlayStrokeFinished>());
      final e = f! as OverlayStrokeFinished;
      expect(e.family, InkOverlayFamily.highlighter);
      expect(e.argb, 0x80FF0000);
      expect(e.sizePx, 14.5);
      expect(e.points.length, 2);
      expect(e.points[1], const OverlayPoint(x: 11, y: 21, tMs: 8, pressure: 0.75, tilt: 0.25, orientation: 1));
    });

    test('bilinmeyen yöntem null, bozuk ileti FormatException', () {
      expect(decodeOverlayCall('nope', const {}), isNull);
      expect(() => decodeOverlayCall(inkOverlayStrokeStart, 5), throwsFormatException);
      expect(() => decodeOverlayCall(inkOverlayStrokeStart, {'x': 1}), throwsFormatException);
      expect(
        () => decodeOverlayCall(inkOverlayStrokeFinished, {
          'id': 1,
          'family': 'pressurePen',
          'argb': 1,
          'sizePx': 2,
          'points': Float32List.fromList([1, 2, 3]),
        }),
        throwsFormatException,
      );
      expect(
        () => decodeOverlayCall(inkOverlayStrokeFinished, {
          'id': 1,
          'family': 'bilinmez',
          'argb': 1,
          'sizePx': 2,
          'points': Float32List(0),
        }),
        throwsFormatException,
      );
    });
  });

  group('denetleyici (sahte kanal)', () {
    const ch = MethodChannel('kocum/ink_overlay/test_ctrl');
    final calls = <MethodCall>[];
    late InkOverlayController ctl;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        return call.method == inkOverlayPing ? true : null;
      });
      ctl = InkOverlayController(ch);
    });
    tearDown(() {
      ctl.dispose();
      messenger.setMockMethodCallHandler(ch, null);
    });

    test('probe: katman var -> available', () async {
      expect(ctl.available, isFalse);
      expect(await ctl.probe(), isTrue);
      expect(ctl.available, isTrue);
    });

    test('probe: kanal yoksa (eski Android, hata) available false', () async {
      messenger.setMockMethodCallHandler(ch, null);
      expect(await ctl.probe(), isFalse);
      expect(ctl.available, isFalse);
    });

    test('aynı değer tekrar gönderilmez; invalidate sonrası gider', () async {
      ctl.setMode(InkOverlayMode.pen);
      ctl.setMode(InkOverlayMode.pen);
      ctl.setBrush(family: InkOverlayFamily.pressurePen, argb: 1, sizePx: 5);
      ctl.setBrush(family: InkOverlayFamily.pressurePen, argb: 1, sizePx: 5);
      ctl.setRegions([const Rect.fromLTRB(0, 0, 10, 10)]);
      ctl.setRegions([const Rect.fromLTRB(0, 0, 10, 10)]);
      ctl.setMask([const Rect.fromLTRB(0, 0, 1, 1)]);
      ctl.setMask([const Rect.fromLTRB(0, 0, 1, 1)]);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), [inkOverlaySetMode, inkOverlaySetBrush, inkOverlaySetRegions, inkOverlaySetMask]);
      ctl.setRegions([const Rect.fromLTRB(0, 0, 11, 10)]);
      ctl.invalidate();
      ctl.setMode(InkOverlayMode.pen);
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method).skip(4), [inkOverlaySetRegions, inkOverlaySetMode]);
    });

    test('releaseStrokes ve cancelCurrent', () async {
      ctl.releaseStrokes(const []); // boşsa gitmez
      ctl.releaseStrokes([2, 3]);
      ctl.cancelCurrent();
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), [inkOverlayReleaseStrokes, inkOverlayCancelCurrent]);
      expect(calls.first.arguments, {'ids': [2, 3]});
    });

    test('yerelden gelen olaylar akışa düşer, bozuk ileti yutulur', () async {
      final got = <InkOverlayEvent>[];
      final sub = ctl.events.listen(got.add);
      Future<void> deliver(String m, Object? args) => messenger.handlePlatformMessage(
        ch.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(m, args)),
        (_) {},
      );
      await deliver(inkOverlayStrokeStart, {'id': 1});
      await deliver(inkOverlayStrokeStart, 'bozuk');
      await deliver(inkOverlayStrokeFinished, {
        'id': 1,
        'family': 'marker',
        'argb': 5,
        'sizePx': 3,
        'points': Float32List.fromList([1, 2, 0, 1, 0, 0]),
      });
      await deliver(inkOverlayStrokeCanceled, {'id': 2});
      await Future<void>.delayed(Duration.zero);
      expect(got.map((e) => e.runtimeType), [OverlayStrokeStart, OverlayStrokeFinished, OverlayStrokeCanceled]);
      await sub.cancel();
    });
  });

  group('koordinat dönüşümü', () {
    test('pencere px -> görünüm: dpr ve kaydırma', () {
      // dpr 2: 400 px = 200 mantıksal; katman (50, 30) mantıksal konumunda -> (150, ...)
      expect(
        overlayPxToView(const Offset(400, 260), dpr: 2, layerOriginLogical: const Offset(50, 30)),
        const Offset(150, 100),
      );
      // Kaydırma: katman yukarı kaydı (negatif başlangıç), nokta aşağı düşer.
      expect(
        overlayPxToView(const Offset(100, 100), dpr: 1, layerOriginLogical: const Offset(0, -300)),
        const Offset(100, 400),
      );
    });

    test('noktalar görünüme: baskı süzgeci, zaman ve eğim korunur', () {
      final pts = overlayPointsToView(
        const [
          OverlayPoint(x: 300, y: 150, tMs: 0, pressure: 0.5, tilt: 0.2, orientation: 0),
          OverlayPoint(x: 330, y: 180, tMs: 12, pressure: 1, tilt: 0.3, orientation: 0),
        ],
        dpr: 3,
        layerOriginLogical: const Offset(20, 10),
        shapePressure: (p) => p * 0.5,
      );
      expect(pts[0], const InkPoint(x: 80, y: 40, pressure: 0.25, tilt: 0.2, tMs: 0));
      expect(pts[1], const InkPoint(x: 90, y: 50, pressure: 0.5, tilt: 0.3, tMs: 12));
    });

    test('sayfa birimine tam yol: zum sonrası aynı sayfa noktası', () {
      // Sayfa 600 birim, görünümde 300 mantıksal px (zum 0,5): 1 mantıksal px = 2 birim.
      // Zum 2 katı: 600 px; aynı fiziksel nokta (sayfanın ortası) aynı sayfa noktasına düşer.
      double pageX(double px, double viewW, double originLogical) =>
          overlayPxToView(Offset(px, 0), dpr: 2, layerOriginLogical: Offset(originLogical, 0)).dx * 600 / viewW;
      expect(pageX(2 * (100 + 150), 300, 100), closeTo(300, 1e-9));
      expect(pageX(2 * (100 + 300), 600, 100), closeTo(300, 1e-9));
    });
  });

  group('bölge seçimi', () {
    const rects = [Rect.fromLTRB(0, 0, 100, 100), Rect.fromLTRB(0, 120, 100, 220), Rect.fromLTRB(50, 50, 150, 150)];
    test('içerdeki dikdörtgen; üst üste binince sonuncusu; dışında null', () {
      expect(pickRegionIndex(rects, const Offset(10, 10)), 0);
      expect(pickRegionIndex(rects, const Offset(10, 130)), 1);
      expect(pickRegionIndex(rects, const Offset(75, 75)), 2); // 0 ile 2 örtüşür -> sonuncu
      expect(pickRegionIndex(rects, const Offset(300, 300)), isNull);
      expect(pickRegionIndex(const [], const Offset(1, 1)), isNull);
    });
  });

  group('fırça eşleme', () {
    test('kalem türleri: aile, ortalama çarpan, renk saydamlığı', () {
      final ballpoint = overlayBrushFor(const InkBrush(width: 4, color: 0xFF102030, kind: PenKind.ballpoint), 2)!;
      expect(ballpoint.mode, InkOverlayMode.pen);
      expect(ballpoint.family, InkOverlayFamily.pressurePen);
      expect(ballpoint.sizePx, closeTo(4 * 2 * 1.0 * kInkOverlayPenSizeScale, 1e-9)); // (0,85+1,15)/2 = 1
      expect(ballpoint.argb, 0xFF102030);
      final pencil = overlayBrushFor(const InkBrush(width: 4, color: 0xFF000000, kind: PenKind.pencil), 1)!;
      expect(pencil.argb >> 24, (255 * 0.8).round());
      final plain = overlayBrushFor(const InkBrush(width: 3, color: 0xFF000000), 3)!;
      expect(plain.family, InkOverlayFamily.pressurePen);
      expect(plain.sizePx, 9 * kInkOverlayPenSizeScale);
    });

    test('fosforlu: highlighter ailesi, Flutter saydamlığı; silgi null', () {
      final h = overlayBrushFor(const InkBrush(tool: InkTool.highlighter, width: 14, color: 0xFFFFEB3B), 1)!;
      expect(h.mode, InkOverlayMode.highlighter);
      expect(h.family, InkOverlayFamily.highlighter);
      expect(h.argb >> 24, (255 * 0.35).round());
      final k = overlayBrushFor(const InkBrush(width: 14, color: 0xFFFFEB3B, kind: PenKind.highlighter), 1)!;
      expect(k.family, InkOverlayFamily.highlighter);
      expect(overlayBrushFor(const InkBrush(tool: InkTool.eraser), 1), isNull);
    });
  });
}
