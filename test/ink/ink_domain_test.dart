import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/ink_channel_codec.dart';
import 'package:kocum/features/ink/domain/ink_geometry.dart';
import 'package:kocum/features/ink/domain/ink_latency.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';

void main() {
  group('model', () {
    test('InkBrush eşitlik ve copyWith', () {
      const b = InkBrush();
      expect(b.copyWith(width: 5), const InkBrush(width: 5));
      expect(b.copyWith(tool: InkTool.eraser).tool, InkTool.eraser);
      expect(b == const InkBrush(), isTrue);
    });
    test('InkPoint eşitlik', () {
      expect(const InkPoint(x: 1, y: 2), const InkPoint(x: 1, y: 2));
      expect(const InkPoint(x: 1, y: 2) == const InkPoint(x: 1, y: 3), isFalse);
    });
  });

  group('sözleşme', () {
    test('setBrush kodlama', () {
      final m = encodeBrush(
        const InkBrush(tool: InkTool.highlighter, color: 0x80FFEB3B, width: 12),
      );
      expect(m, {'tool': 'highlighter', 'color': 0x80FFEB3B, 'width': 12.0});
      expect(encodeInputMode(stylusOnly: true), {'stylusOnly': true});
      expect(inkChannelName(7), 'kocum/ink/7');
    });

    test('strokeStart/Point/End ayrıştırma', () {
      final args = {
        'id': 3,
        'x': 10,
        'y': 20.5,
        'pressure': 0.7,
        'tilt': 0.2,
        't': 1234,
      };
      final s = decodeInkCall('strokeStart', args);
      expect(s, isA<InkStrokeStart>());
      expect(s!.strokeId, 3);
      expect(
        s.point,
        const InkPoint(x: 10, y: 20.5, pressure: 0.7, tilt: 0.2, tMs: 1234),
      );
      expect(decodeInkCall('strokePoint', args), isA<InkStrokePoint>());
      expect(decodeInkCall('strokeEnd', args), isA<InkStrokeEnd>());
    });

    test('eksik baskı varsayılan, aralık dışı kırpılır', () {
      final e = decodeInkCall('strokePoint', {
        'id': 1,
        'x': 0,
        'y': 0,
        'pressure': 4,
      });
      expect(e!.point!.pressure, 1.0);
      final f = decodeInkCall('strokePoint', {'id': 1, 'x': 0, 'y': 0});
      expect(f!.point!.pressure, 0.5);
    });

    test('strokeCancel yalnız id ister, nokta yok', () {
      final e = decodeInkCall('strokeCancel', {'id': 4});
      expect(e, isA<InkStrokeCancel>());
      expect(e!.strokeId, 4);
      expect(e.point, isNull);
      expect(() => decodeInkCall('strokeCancel', {}), throwsFormatException);
    });

    test('bilinmeyen yöntem null, bozuk bağımsız değişken hata', () {
      expect(decodeInkCall('baskaBir', {}), isNull);
      expect(() => decodeInkCall('strokeStart', 'x'), throwsFormatException);
      expect(
        () => decodeInkCall('strokeStart', {'x': 1, 'y': 2}),
        throwsFormatException,
      );
      expect(
        () => decodeInkCall('strokeStart', {'id': 1, 'x': double.nan, 'y': 2}),
        throwsFormatException,
      );
      expect(
        () => decodeInkCall('strokeStart', {'id': 1, 'x': 1}),
        throwsFormatException,
      );
    });
  });

  group('gecikme', () {
    test('kareye girmiş girişler eşleşir, sonrakiler bekler', () {
      final t = InkLatencyTracker();
      t.onInput(1000);
      t.onInput(5000);
      t.onInput(20000); // kare başladıktan sonra geldi
      final ms = t.onFrame(buildStartUs: 10000, rasterFinishUs: 18000);
      expect(ms, [17.0, 13.0]);
      expect(t.pendingCount, 1);
      expect(t.onFrame(buildStartUs: 30000, rasterFinishUs: 40000), [20.0]);
      expect(t.pendingCount, 0);
    });
    test('vsync gecikmesi raster gecikmesinden ayrı hesaplanır', () {
      final t = InkLatencyTracker();
      t.onInput(5000);
      final r = t.onFrameDetailed(
        buildStartUs: 10000,
        rasterFinishUs: 25000,
        vsyncUs: 9000,
      );
      expect(r.raster, [20.0]);
      expect(r.vsync, [4.0]);
      t.onInput(9500);
      final r2 = t.onFrameDetailed(
        buildStartUs: 10000,
        rasterFinishUs: 25000,
        vsyncUs: 9000,
      );
      expect(r2.vsync, [0.0]); // vsync'ten sonra gelen giriş: 0
    });

    test('bekleyen sayısı sınırlı', () {
      final t = InkLatencyTracker(maxPending: 3);
      for (var i = 0; i < 10; i++) {
        t.onInput(i);
      }
      expect(t.pendingCount, 3);
    });
  });

  group('silgi geometrisi', () {
    final line = [const InkPoint(x: 0, y: 0), const InkPoint(x: 100, y: 0)];
    test('çizgiye yakın değer', () {
      expect(strokeHitsPoint(line, 50, 4, 5), isTrue);
      expect(strokeHitsPoint(line, 50, 10, 5), isFalse);
      expect(strokeHitsPoint(line, 50, 10, 5, halfWidth: 6), isTrue);
    });
    test('uç noktaları ve tek nokta', () {
      expect(strokeHitsPoint(line, 104, 0, 5), isTrue);
      expect(strokeHitsPoint(line, 110, 0, 5), isFalse);
      expect(strokeHitsPoint([const InkPoint(x: 5, y: 5)], 6, 6, 2), isTrue);
      expect(strokeHitsPoint(const [], 0, 0, 100), isFalse);
    });
  });
}
