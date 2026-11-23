import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/pdf/data/layer_renderer.dart';
import 'package:kocum/features/pdf/domain/page_layer.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/watermark.dart';

/// Gerçek zamanlı gecikmeli sahte belge: aynı anda kaç render çalıştığını sayar.
class _Doc implements PdfEngineDocument {
  _Doc(this.delay);
  final Duration delay;
  int running = 0, maxRunning = 0;
  final rendered = <int>[];

  @override
  int get pageCount => 500; // kalın kitap
  @override
  Future<void> close() async {}
  @override
  Future<PdfPageSize> pageSize(int page) async => const PdfPageSize(612, 792);
  @override
  Future<PdfRenderedImage> renderPage(int page, {required int width, required int height}) async {
    running++;
    if (running > maxRunning) maxRunning = running;
    await Future<void>.delayed(delay);
    rendered.add(page);
    running--;
    final b = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
    return PdfRenderedImage(width: width, height: height, bytes: b, format: PdfPixelFormat.rgba);
  }

  @override
  Future<String> textInBox(int page, PdfBox box) async => '';
}

PdfPageLayer _wm(String id, {int page = allPdfPages, int z = 0}) => PdfPageLayer(
      id: id,
      documentId: 'd',
      page: page,
      kind: PdfLayerKind.watermark,
      z: z,
      params: const WatermarkParams().toJson(),
    );

void main() {
  testWidgets('eşzamanlı iş sayısı sınırlı (1): çok sayfa aynı anda istense de tek render', (t) async {
    final doc = _Doc(const Duration(milliseconds: 15));
    final r = PdfLayerRenderer(documentId: 'd', open: () async => doc);
    addTearDown(() => t.runAsync(r.dispose));
    final l = _wm('a');
    await t.runAsync(() async {
      final imgs = await Future.wait([
        for (var p = 0; p < 6; p++) r.imageFor(p, l, [l], 700, token: LayerJobToken()),
      ]);
      for (final i in imgs) {
        expect(i, isNotNull);
        i!.dispose();
      }
    });
    expect(doc.maxRunning, 1);
    expect(r.peakActive, 1);
    expect(doc.rendered, [0, 1, 2, 3, 4, 5]);
  });

  testWidgets('hızlı sayfa değişimi: bekleyen eski işler iptal edilir (yalnız çalışan ve son iş sürer)', (t) async {
    final doc = _Doc(const Duration(milliseconds: 40));
    final r = PdfLayerRenderer(documentId: 'd', open: () async => doc);
    addTearDown(() => t.runAsync(r.dispose));
    final l = _wm('a');
    await t.runAsync(() async {
      final tokens = [for (var p = 0; p < 10; p++) LayerJobToken()];
      final futures = [for (var p = 0; p < 10; p++) r.imageFor(p, l, [l], 700, token: tokens[p])];
      await Future<void>.delayed(const Duration(milliseconds: 5));
      for (var p = 1; p < 9; p++) {
        tokens[p].cancel(); // kullanıcı sayfaları hızla geçti
      }
      final res = await Future.wait(futures);
      for (var p = 1; p < 9; p++) {
        expect(res[p], isNull, reason: 'sayfa $p iptal');
      }
      expect(res[9], isNotNull);
      for (final i in res) {
        i?.dispose();
      }
    });
    expect(doc.rendered.toSet(), {0, 9}, reason: 'iptal edilenler hiç render edilmedi');
    expect(r.cancelledJobs, greaterThanOrEqualTo(8));
    expect(doc.maxRunning, 1);
  });

  testWidgets('aynı sayfadaki katmanlar TEK tam sayfa render paylaşır', (t) async {
    final doc = _Doc(const Duration(milliseconds: 5));
    final r = PdfLayerRenderer(documentId: 'd', open: () async => doc);
    addTearDown(() => t.runAsync(r.dispose));
    final a = _wm('a', z: 1), b = _wm('b', z: 2);
    await t.runAsync(() async {
      final res = await Future.wait([
        r.imageFor(3, a, [a], 700),
        r.imageFor(3, b, [a, b], 700),
      ]);
      for (final i in res) {
        expect(i, isNotNull);
        i!.dispose();
      }
    });
    expect(r.renders, 2); // iki katman görüntüsü
    expect(r.fullRenders, 1); // tek PDF render'ı
    expect(doc.rendered, [3]);
  });

  testWidgets('önbellek BAYT sınırlı: toplam sınırı aşınca en eski çıkar ve dispose edilir', (t) async {

    final cache = LayerImageCache(maxBytes: 100000); // 100x100x4 = 40000 -> en çok 2
    final imgs = <ui.Image>[];
    await t.runAsync(() async {
      for (var i = 0; i < 5; i++) {
        final c = Completer<ui.Image>();
        ui.decodeImageFromPixels(Uint8List(100 * 100 * 4), 100, 100, ui.PixelFormat.rgba8888, c.complete);
        imgs.add(await c.future);
      }
    });
    for (var i = 0; i < 5; i++) {
      cache.put('k$i', imgs[i]);
      expect(cache.bytes, lessThanOrEqualTo(100000));
    }
    expect(cache.length, 2);
    expect(cache.keys.toList(), ['k3', 'k4']);
    expect(cache.contains('k0'), isFalse);
    // Büyük tek görüntü: boyutuna göre (piksel) sayılır, yalnız en yenisi kalır.
    final big = (await t.runAsync(() async {
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(Uint8List(300 * 300 * 4), 300, 300, ui.PixelFormat.rgba8888, c.complete);
      return c.future;
    }))!;
    cache.put('big', big);
    expect(cache.keys.toList(), ['big']);
    expect(cache.bytes, 300 * 300 * 4);
    // Varsayılan sınır 96 MB.
    expect(LayerImageCache.defaultMaxBytes, 96 * 1024 * 1024);
    cache.clear();
    expect(cache.bytes, 0);
  });
}
