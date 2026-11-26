import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_overlay_codec.dart';
import 'package:kocum/features/ink/data/ink_overlay_controller.dart';
import 'package:kocum/features/ink/data/ink_overlay_host.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_overlay.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';
import 'package:kocum/features/pdf/presentation/pdf_page_ink_layer.dart';

const _ch = MethodChannel('kocum/ink_overlay/test_pdf');
final _doc = 'c' * 64;

class _Env {
  final calls = <MethodCall>[];

  /// releaseStrokes geldiği anda sayfada çizgi var mıydı (kayıttan SONRA gönderim kanıtı).
  final strokesAtRelease = <bool>[];
  late InkOverlayController ctl;
  late PdfInkSession session;
  Iterable<MethodCall> of(String m) => calls.where((c) => c.method == m);
  String? get lastMode => of(inkOverlaySetMode).isEmpty ? null : (of(inkOverlaySetMode).last.arguments as Map)['mode'] as String;
}

Future<_Env> _setup(WidgetTester t, {bool enabled = true, bool pumpLayer = true}) async {
  final env = _Env();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_ch, (call) async {
    env.calls.add(call);
    if (call.method == inkOverlayPing) return true;
    if (call.method == inkOverlayReleaseStrokes) env.strokesAtRelease.add(env.session.hasStrokes);
    return null;
  });
  env.ctl = InkOverlayController(_ch);
  final host = InkOverlayHost.instance..testController = env.ctl;
  InkOverlayHost.nativeEnabled.value = enabled;
  await t.runAsync(env.ctl.probe);
  addTearDown(() {
    host.resetForTest();
    PdfInkOverlay.afterDrawOverride = null;
    env.ctl.dispose();
    messenger.setMockMethodCallHandler(_ch, null);
  });
  late AppDatabase db;
  late InkStrokeRepository repo;
  await t.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = InkStrokeRepository(db);
  });
  addTearDown(() => t.runAsync(db.close));
  env.session = PdfInkSession(documentId: _doc, repository: repo);
  addTearDown(env.session.dispose);
  if (pumpLayer) {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 40, top: 30),
              child: SizedBox(
                width: 400,
                height: 600,
                child: PdfPageInkLayer(session: env.session, page: 0, pageWidth: 612, pageHeight: 792),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }
  return env;
}

Future<void> _deliver(WidgetTester t, String m, Object? args) => t.runAsync(
  () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    _ch.name,
    const StandardMethodCodec().encodeMethodCall(MethodCall(m, args)),
    (_) {},
  ),
);

void main() {
  testWidgets('araç değişince mod ve fırça yerele gider; silgi/kement/seç/şekil ise kapanır', (t) async {
    final env = await _setup(t);
    final s = env.session;
    await t.pump();
    expect(env.lastMode, 'pen');
    expect(env.of(inkOverlaySetBrush), isNotEmpty);

    s.setBrush(const InkBrush(tool: InkTool.highlighter, width: 14, color: 0xFFFFEB3B));
    await t.pump();
    expect(env.lastMode, 'highlighter');
    expect((env.of(inkOverlaySetBrush).last.arguments as Map)['family'], 'highlighter');

    s.setBrush(const InkBrush(width: 4, color: 0xFF1565C0, kind: PenKind.fountain));
    await t.pump();
    expect(env.lastMode, 'pen');
    expect((env.of(inkOverlaySetBrush).last.arguments as Map)['argb'], 0xFF1565C0);

    s.setBrush(const InkBrush(tool: InkTool.eraser, width: 8));
    await t.pump();
    expect(env.lastMode, 'off');

    s.setBrush(const InkBrush());
    await t.pump();
    expect(env.lastMode, 'pen');
    s.setLassoMode(true);
    await t.pump();
    expect(env.lastMode, 'off');
    s.setLassoMode(false);
    s.setSelecting(true);
    await t.pump();
    expect(env.lastMode, 'off');
    s.setSelecting(false);
    s.setShapeSnap(true);
    await t.pump();
    expect(env.lastMode, 'off');
    s.setShapeSnap(false);
    s.setInkInputOff(true);
    await t.pump();
    expect(env.lastMode, 'off');
    s.setInkInputOff(false);
    await t.pump();
    expect(env.lastMode, 'pen');
  });

  testWidgets('sayfa dikdörtgeni fiziksel pikselle bildirilir, değişmeyince tekrar gitmez', (t) async {
    final env = await _setup(t);
    await t.pump();
    await t.pump();
    final dpr = t.view.devicePixelRatio;
    final regions = env.of(inkOverlaySetRegions).where((c) => ((c.arguments as Map)['rects'] as List).isNotEmpty).toList();
    expect(regions, hasLength(1));
    final r = (regions.single.arguments as Map)['rects'] as List;
    expect(r, hasLength(1));
    expect(r.single, [40 * dpr, 30 * dpr, 440 * dpr, 600 * dpr]);
    await t.pump();
    await t.pump();
    expect(
      env.of(inkOverlaySetRegions).where((c) => ((c.arguments as Map)['rects'] as List).isNotEmpty),
      hasLength(1),
    );
  });

  testWidgets('strokeFinished: çizgi sayfaya kaydedilir, releaseStrokes ondan SONRA gider', (t) async {
    final env = await _setup(t, pumpLayer: false);
    final gate = Completer<void>();
    PdfInkOverlay.afterDrawOverride = () => gate.future; // köprü kurulmadan ÖNCE
    await t.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 40, top: 30),
            child: SizedBox(
              width: 400,
              height: 500,
              child: PdfPageInkLayer(session: env.session, page: 0, pageWidth: 612, pageHeight: 792),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    final dpr = t.view.devicePixelRatio;
    final pts = Float32List.fromList([
      for (var i = 0; i < 5; i++) ...[(100 + i * 10) * dpr, (100 + i * 4) * dpr, i * 8.0, 0.6, 0.3, 0],
    ]);
    await _deliver(t, inkOverlayStrokeFinished, {'id': 41, 'family': 'pressurePen', 'argb': 0xFF000000, 'sizePx': 6.0, 'points': pts});
    await t.pump();
    expect(env.session.hasStrokes, isTrue, reason: 'çizgi hemen sayfaya eklenir');
    expect(env.of(inkOverlayReleaseStrokes), isEmpty, reason: 'çizim karesi bitmeden bırakılmaz');
    gate.complete();
    await t.pump();
    await t.pump();
    expect(env.of(inkOverlayReleaseStrokes), hasLength(1));
    expect((env.of(inkOverlayReleaseStrokes).single.arguments as Map)['ids'], [41]);
    expect(env.strokesAtRelease, [true]);
    await t.runAsync(env.session.flush);
  });

  testWidgets('sayfa dışına düşen çizgi kaydedilmez ama ıslak çizgi yine bırakılır', (t) async {
    final env = await _setup(t);
    await t.pump();
    await t.pump();
    await _deliver(t, inkOverlayStrokeFinished, {
      'id': 5,
      'family': 'pressurePen',
      'argb': 0xFF000000,
      'sizePx': 6.0,
      'points': Float32List.fromList([5, 5, 0, 0.5, 0, 0, 9, 9, 8, 0.5, 0, 0]),
    });
    await t.pump();
    await t.pump();
    await t.pump();
    expect(env.session.hasStrokes, isFalse);
    expect(env.of(inkOverlayReleaseStrokes), hasLength(1));
  });

  testWidgets('strokeCanceled hiçbir şey kaydetmez', (t) async {
    final env = await _setup(t);
    await t.pump();
    await _deliver(t, inkOverlayStrokeCanceled, {'id': 3});
    await t.pump();
    expect(env.session.hasStrokes, isFalse);
    expect(env.of(inkOverlayReleaseStrokes), isEmpty);
  });

  testWidgets('anahtar kapalıyken yerel katmana hiçbir şey gitmez (Flutter yolu)', (t) async {
    final env = await _setup(t, enabled: false);
    await t.pump();
    await t.pump();
    expect(env.calls.where((c) => c.method != inkOverlayPing), isEmpty);
  });

  testWidgets('anahtar çalışırken kapanınca mod off olur, açılınca geri döner', (t) async {
    final env = await _setup(t);
    await t.pump();
    expect(env.lastMode, 'pen');
    InkOverlayHost.nativeEnabled.value = false;
    await t.pump();
    expect(env.lastMode, 'off');
    InkOverlayHost.nativeEnabled.value = true;
    await t.pump();
    expect(env.lastMode, 'pen');
  });

  testWidgets('katman yoksa (kanal yok) hiçbir şey gitmez', (t) async {
    final env = _Env();
    env.ctl = InkOverlayController(_ch); // probe edilmedi: available false
    InkOverlayHost.instance.testController = env.ctl;
    addTearDown(() {
      InkOverlayHost.instance.resetForTest();
      env.ctl.dispose();
    });
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_ch, (c) async {
      env.calls.add(c);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_ch, null));
    late AppDatabase db;
    late InkStrokeRepository repo;
    await t.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
      repo = InkStrokeRepository(db);
    });
    addTearDown(() => t.runAsync(db.close));
    final s = PdfInkSession(documentId: _doc, repository: repo);
    addTearDown(s.dispose);
    await t.pumpWidget(
      MaterialApp(home: SizedBox(width: 300, height: 400, child: PdfPageInkLayer(session: s, page: 0, pageWidth: 612, pageHeight: 792))),
    );
    await t.pump();
    s.setLassoMode(true);
    await t.pump();
    expect(env.calls, isEmpty);
  });

  testWidgets('üstte başka rota (diyalog) varken bölge bildirilmez', (t) async {
    final env = await _setup(t);
    await t.pump();
    await t.pump();
    expect(((env.of(inkOverlaySetRegions).last.arguments as Map)['rects'] as List), hasLength(1));
    final ctx = t.element(find.byType(PdfPageInkLayer));
    unawaited(showDialog<void>(context: ctx, builder: (_) => const AlertDialog(title: Text('x'))));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(((env.of(inkOverlaySetRegions).last.arguments as Map)['rects'] as List), isEmpty);
  });
}
