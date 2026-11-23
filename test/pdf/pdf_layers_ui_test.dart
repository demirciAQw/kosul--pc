import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ocr/data/ocr_repository_impl.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';
import 'package:kocum/features/pdf/data/layer_renderer.dart';
import 'package:kocum/features/pdf/data/pdf_layers_repository.dart';
import 'package:kocum/features/pdf/data/pdf_question_service.dart';
import 'package:kocum/features/pdf/data/pdfrx_engine.dart';
import 'package:kocum/features/pdf/domain/page_layer.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/watermark.dart';
import 'package:kocum/features/pdf/pdf_layers_providers.dart';
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/layer_overlay.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';
import 'package:kocum/features/pdf/presentation/pdf_layers_controller.dart';
import 'package:kocum/features/pdf/presentation/pdf_layers_panel.dart';
import 'package:kocum/features/pdf/presentation/pdf_reader_page.dart';
import 'package:kocum/features/pdf/presentation/pdf_solve_page.dart';
import 'package:kocum/features/pdf/presentation/solve_background.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:kocum/features/pdf/domain/solve.dart' show solveRegion;
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;
import 'package:path/path.dart' as p;

import 'pdf_test_support.dart';

final _id = 'e' * 64;

/// Sayfada (100..400 x, 292..492 y; sol-üst) açık gri (0.85 = 217) dikdörtgen: "filigran".
/// Ayrıca (500..560, 100..160) 0.75 (191) ikinci bir leke.
const _content = '0.85 g 100 300 300 200 re f\n0.75 g 500 632 60 60 re f\n0 g';
const _wm = WatermarkParams(tone: 217, toneRange: 8);
const _wm2 = WatermarkParams(tone: 191, toneRange: 8);

class _Ids implements IdGenerator {
  var n = 0;
  @override
  String next() => 'L${(n++).toString().padLeft(3, '0')}';
}

Future<List<int>> _px(ui.Image img, double fx, double fy) async {
  final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final x = (img.width * fx).round().clamp(0, img.width - 1), y = (img.height * fy).round().clamp(0, img.height - 1);
  final i = (y * img.width + x) * 4;
  return [d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2)];
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late String path;
  late PdfLayersRepository repo;
  late PdfLayerRenderer renderer;
  late PdfLayersHub hub;

  Future<void> settle(WidgetTester t, [int ms = 500]) async {
    await t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  Future<void> setup(WidgetTester t) async {
    tmp = await t.runAsync(() => Directory.systemTemp.createTemp('katman_ui')) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    path = '${tmp.path}/a.pdf';
    await t.runAsync(() async {
      await File(path).writeAsBytes(minimalPdf([
        [('Birinci', 72, 700)],
        [('Ikinci', 72, 700)],
      ], rawContent: _content));
      await pdfrxInitialize();
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
    });
    addTearDown(() => t.runAsync(db.close));
    t.view.physicalSize = const Size(900, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    repo = PdfLayersRepository(db, ids: _Ids());
    final engine = PdfrxEngine(initialize: pdfrxInitialize);
    renderer = PdfLayerRenderer(documentId: _id, open: () => engine.openFile(path));
    hub = PdfLayersHub(documentId: _id, repository: repo, renderer: renderer);
    await t.runAsync(() async => hub.start()); // Drift akışı gerçek zamanda dinlenir
    addTearDown(() => t.runAsync(() => hub.dispose().timeout(const Duration(seconds: 3), onTimeout: () {})));
  }

  Future<ui.Image> imageOf(WidgetTester t, int page, PdfPageLayer target, List<PdfPageLayer> chain, [int bucket = 700]) async {
    final img = await t.runAsync(() => renderer.imageFor(page, target, chain, bucket));
    expect(img, isNotNull);
    addTearDown(img!.dispose);
    return img;
  }

  // ───────────── Üretici ve önbellek ─────────────

  testWidgets('filigran katmanı sayfayı temizler; metin ve filigransız yerler değişmez; PDF dosyası değişmez', (t) async {
    await setup(t);
    final bytesBefore = await t.runAsync(() => File(path).readAsBytes());
    final raw = (await t.runAsync(() => renderer.renderRaw(0, widthPx: 700)))!;
    // Ham görüntüde (250, 392) gri.
    final ix = (250 * raw.pxPerUnit).round(), iy = (392 * raw.pxPerUnit).round();
    final k = (iy * raw.width + ix) * 4;
    expect(raw.bytes[k + 1], inInclusiveRange(205, 230));

    await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson()));
    final l = (await t.runAsync(() => repo.forPage(_id, 0)))!.single;
    final img = await imageOf(t, 0, l, [l]);
    final c = (await t.runAsync(() => _px(img, 250 / 612, 392 / 792)))!;
    expect(c, [255, 255, 255]);
    // İkinci leke (191) bu katmanın tonunda değil: kalır.
    final s = (await t.runAsync(() => _px(img, 530 / 612, 130 / 792)))!;
    expect(s[0], lessThan(215));
    expect(await t.runAsync(() => File(path).readAsBytes()), bytesBefore);
  });

  testWidgets('bölge katmanı: yalnız kutu çizilir, kutu içi temizlenir', (t) async {
    await setup(t);
    await t.runAsync(() => repo.add(
        documentId: _id, page: 0, kind: PdfLayerKind.watermark, box: const PdfBox(90, 280, 420, 510), params: _wm.toJson()));
    final l = (await t.runAsync(() => repo.forPage(_id, 0)))!.single;
    final img = await imageOf(t, 0, l, [l]);
    // Görüntü yalnız kutu kadar (330x230 birim ≈ 1.14 px/birim).
    expect(img.width, inInclusiveRange(370, 385));
    expect(img.height, inInclusiveRange(255, 270));
    final c = (await t.runAsync(() => _px(img, 0.5, 0.5)))!;
    expect(c, [255, 255, 255]);
  });

  testWidgets('2. katman: iki filigran zincirde birlikte uygulanır; zincir farklıysa farklı anahtar', (t) async {
    await setup(t);
    await t.runAsync(() async {
      await repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson());
      await repo.add(documentId: _id, page: allPdfPages, kind: PdfLayerKind.watermark, params: _wm2.toJson());
    });
    final ls = (await t.runAsync(() => repo.forPage(_id, 0)))!;
    expect(ls, hasLength(2));
    final img2 = await imageOf(t, 0, ls[1], ls);
    expect((await t.runAsync(() => _px(img2, 250 / 612, 392 / 792)))!, [255, 255, 255]); // 1. katmanın işi
    expect((await t.runAsync(() => _px(img2, 530 / 612, 130 / 792)))!, [255, 255, 255]); // 2. katmanın işi
    // Birinci katman tek başına ikinci lekeyi temizlemez (zincir farkı anahtara girer).
    final first = await imageOf(t, 0, ls[0], [ls[0]]);
    expect((await t.runAsync(() => _px(first, 530 / 612, 130 / 792)))![0], lessThan(215));
    expect(renderer.cacheKey(0, ls[1], ls, 700), isNot(renderer.cacheKey(0, ls[1], [ls[0]], 700)));
    // "Tüm sayfalar" katmanı 2. sayfada da çalışır.
    final p2 = (await t.runAsync(() => repo.forPage(_id, 1)))!;
    expect(p2.single.id, ls[1].id);
    final img = await imageOf(t, 1, p2.single, p2);
    expect((await t.runAsync(() => _px(img, 530 / 612, 130 / 792)))!, [255, 255, 255]);
  });

  testWidgets('önbellek: isabet yeniden çizmez; sınır aşılınca en eski dispose edilir; dispose boşaltır', (t) async {
    await setup(t);
    await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson()));
    final l = (await t.runAsync(() => repo.forPage(_id, 0)))!.single;
    final a = await imageOf(t, 0, l, [l]);
    expect(renderer.renders, 1);
    final b = await imageOf(t, 0, l, [l]);
    expect(renderer.renders, 1);
    expect(identical(a, b), isFalse); // her çağırana kendi kopyası
    expect(renderer.cache.length, 1);

    final cache = LayerImageCache(capacity: 2);
    Future<ui.Image> mk() async {
      final rec = ui.PictureRecorder();
      Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint());
      return rec.endRecording().toImage(2, 2);
    }
    final i1 = (await t.runAsync(mk))!, i2 = (await t.runAsync(mk))!, i3 = (await t.runAsync(mk))!;
    cache.put('1', i1);
    cache.put('2', i2);
    final clone1 = cache.take('1')!; // 1 en yeni olur
    cache.put('3', i3); // 2 çıkar
    expect(i2.debugDisposed, isTrue);
    expect(i1.debugDisposed, isFalse);
    expect(cache.contains('2'), isFalse);
    expect(clone1.debugDisposed, isFalse); // kopya sağ
    clone1.dispose();
    cache.clear();
    expect([i1.debugDisposed, i3.debugDisposed], [true, true]);

    await t.runAsync(renderer.dispose);
    expect(renderer.cache.length, 0);
  });

  // ───────────── Panel ─────────────

  Future<void> pumpPanel(WidgetTester t, int page) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showPdfLayersPanel(context, hub: hub, page: page), child: const Text('aç')))),
    ));
    await t.tap(find.text('aç'));
    await settle(t, 300);
    await t.pumpAndSettle();
  }

  testWidgets('panel: boş sayfa, gizle/göster, sırala, onaylı silme ve geri alma; orijinali göster anahtarı', (t) async {
    await setup(t);
    late String a, b;
    await t.runAsync(() async {
      a = await repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson(), name: 'Logo');
      b = await repo.add(documentId: _id, page: 0, kind: PdfLayerKind.cover, box: const PdfBox(0, 0, 80, 80), params: const {}, name: 'Örtü');
    });
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await pumpPanel(t, 0);
    expect(find.text('Logo'), findsOneWidget);
    expect(find.text('Filigran temizleme · Bu sayfa'), findsOneWidget);
    expect(find.text('Örtü · Seçili bölge'), findsOneWidget);

    // Göz: gizle -> veritabanı, simge değişir.
    await t.tap(find.byKey(Key('layer-eye-$a')));
    await settle(t, 200);
    expect((await t.runAsync(() => repo.forPage(_id, 0)))!.first.visible, isFalse);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    await t.tap(find.byKey(Key('layer-eye-$a')));
    await settle(t, 200);
    expect((await t.runAsync(() => repo.forPage(_id, 0)))!.first.visible, isTrue);

    // Sırala: a'yı üste al -> [b, a].
    await t.tap(find.byKey(Key('layer-up-$a')));
    await settle(t, 200);
    expect([for (final x in (await t.runAsync(() => repo.forPage(_id, 0)))!) x.id], [b, a]);

    // Orijinali göster anahtarı hub'a bağlı.
    expect(hub.showOriginal.value, isFalse);
    await t.tap(find.byKey(const Key('layers-show-original')));
    await t.pump();
    expect(hub.showOriginal.value, isTrue);

    // Onaylı silme: vazgeç silmez, onay yumuşak siler, geri al döndürür.
    await t.tap(find.byKey(Key('layer-del-$b')));
    await t.pumpAndSettle();
    await t.tap(find.text('Vazgeç'));
    await t.pumpAndSettle();
    expect(await t.runAsync(() => repo.forPage(_id, 0)), hasLength(2));
    await t.tap(find.byKey(Key('layer-del-$b')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('layer-del-confirm')));
    await settle(t, 300);
    expect(await t.runAsync(() => repo.forPage(_id, 0)), hasLength(1));
    expect(await t.runAsync(() => db.select(db.pdfPageLayers).get()), hasLength(2)); // satır durur
    await t.tap(find.byKey(const Key('layer-undo')));
    await settle(t, 300);
    expect(await t.runAsync(() => repo.forPage(_id, 0)), hasLength(2));
  });

  testWidgets('panel: sayfa değişince doğru katmanlar; tüm sayfalar katmanı her sayfada', (t) async {
    await setup(t);
    await t.runAsync(() async {
      await repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: const {}, name: 'Yalnız-1');
      await repo.add(documentId: _id, page: 1, kind: PdfLayerKind.cover, params: const {}, name: 'Yalnız-2');
      await repo.add(documentId: _id, page: allPdfPages, kind: PdfLayerKind.watermark, params: const {}, name: 'Hepsi');
    });
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await pumpPanel(t, 0);
    expect([find.text('Yalnız-1').evaluate().length, find.text('Yalnız-2').evaluate().length, find.text('Hepsi').evaluate().length], [1, 0, 1]);
    expect(find.text('Filigran temizleme · Tüm sayfalar'), findsOneWidget);
    Navigator.of(t.element(find.byType(PdfLayersPanel))).pop();
    await t.pumpAndSettle();
    await t.tap(find.text('aç')); // sayfa 0 yine
    await t.pumpAndSettle();
    Navigator.of(t.element(find.byType(PdfLayersPanel))).pop();
    await t.pumpAndSettle();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: PdfLayersPanel(hub: hub, page: 1))));
    await settle(t, 200);
    expect([find.text('Yalnız-1').evaluate().length, find.text('Yalnız-2').evaluate().length, find.text('Hepsi').evaluate().length], [0, 1, 1]);
  });

  // ───────────── Akış: kapsam seç, önizle, kaydet; 2. katman ─────────────

  Future<PdfLayersController> pumpFlow(WidgetTester t) async {
    final session = PdfInkSession(documentId: _id, repository: InkStrokeRepository(db), clock: DateTime.now, penKinds: true);
    addTearDown(session.dispose);
    late PdfLayersController ctl;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctl = PdfLayersController(hub: hub, session: session, contextOf: () => context, currentPage: () => 0);
        return Scaffold(appBar: AppBar(actions: ctl.actions()), body: const SizedBox());
      }),
    ));
    return ctl;
  }

  /// Kaydet'e basıldıktan sonra: yazma sahte zamanda başlar; birkaç gerçek+sahte zaman turu bekle.
  Future<void> tapSave(WidgetTester t) async {
    await t.tap(find.byKey(const Key('layer-save')));
    for (var i = 0; i < 6; i++) {
      await settle(t, 150);
      await t.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> waitPreview(WidgetTester t) async {
    for (var i = 0; i < 40 && find.byKey(const Key('layer-preview-after')).evaluate().isEmpty; i++) {
      await settle(t, 200);
    }
    await settle(t, 300);
    expect(find.byKey(const Key('layer-preview-after')), findsOneWidget);
  }

  testWidgets('Filigranı temizle (tüm sayfa): önizleme, otomatik tespit, Önce/Sonra, Kaydet -> katman eklenir', (t) async {
    await setup(t);
    final ctl = await pumpFlow(t);
    expect(find.byKey(const Key('pdf-layers-original')), findsNothing); // katman yokken hızlı anahtar yok
    await t.tap(find.byKey(const Key('pdf-layers-button')));
    await settle(t, 300);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('layers-empty')), findsOneWidget);
    await t.tap(find.byKey(const Key('layers-add-page')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    await waitPreview(t);
    expect(find.text('Sonra'), findsWidgets);
    // Önce/Sonra: anahtar ham görüntüyü gösterir.
    await t.tap(find.byKey(const Key('layer-compare-switch')));
    await t.pump();
    expect(find.byKey(const Key('layer-preview-before')), findsOneWidget);
    await t.tap(find.byKey(const Key('layer-compare-switch')));
    await t.pump();
    // Otomatik tespit: 217 tonunu bulur (sürgü değişir).
    await t.tap(find.byKey(const Key('layer-auto')));
    await settle(t, 400);
    final tone = t.widget<Slider>(find.byKey(const Key('wm-tone'))).value;
    expect(tone, inInclusiveRange(185, 230));
    await tapSave(t);
    final l = (await t.runAsync(() => repo.forPage(_id, 0)))!;
    expect(l, hasLength(1));
    expect((l.single.kind, l.single.page, l.single.box, l.single.visible), (PdfLayerKind.watermark, 0, null, true));
    expect(l.single.watermark.strength, 1);
    expect(find.byKey(const Key('pdf-layers-original')), findsOneWidget);
    expect(ctl.picking, isFalse);
  });

  testWidgets('Tüm sayfalarda: page = -1 kaydedilir', (t) async {
    await setup(t);
    await pumpFlow(t);
    await t.tap(find.byKey(const Key('pdf-layers-button')));
    await settle(t, 300);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('layers-add-all')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    await waitPreview(t);
    await tapSave(t);
    final l = (await t.runAsync(() => repo.all(_id).timeout(const Duration(seconds: 5))))!;
    expect((l.single.page, l.single.scope), (allPdfPages, PdfLayerScope.allPages));
  });

  testWidgets('Seçili bölge: bölge çizilince düzenleyici açılır; kutu kaydedilir; vazgeç temizler', (t) async {
    await setup(t);
    final ctl = await pumpFlow(t);
    await t.tap(find.byKey(const Key('pdf-layers-button')));
    await settle(t, 300);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('layers-add-region')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(ctl.picking, isTrue);
    expect(find.byKey(const Key('layers-pick-banner')), findsOneWidget);
    // Çok küçük kutu reddedilir, seçim sürer.
    expect(ctl.consumeBox(0, 10, 10, 20, 20, 612, 792), isTrue);
    await t.pump();
    expect(ctl.picking, isTrue);
    // Vazgeç.
    await t.tap(find.byKey(const Key('layers-pick-cancel')));
    await t.pumpAndSettle();
    expect(ctl.picking, isFalse);
    expect(find.byKey(const Key('layers-pick-banner')), findsNothing);
    expect(ctl.consumeBox(0, 10, 10, 200, 200, 612, 792), isFalse); // seçim yokken tüketmez

    await t.tap(find.byKey(const Key('pdf-layers-button')));
    await settle(t, 300);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('layers-add-region')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    expect(ctl.consumeBox(0, 420, 510, 90, 280, 612, 792), isTrue); // ters sürükleme düzelir
    await t.pump(const Duration(milliseconds: 500));
    await waitPreview(t);
    await tapSave(t);
    final l = (await t.runAsync(() => repo.forPage(_id, 0)))!.single;
    expect(l.box, const PdfBox(90, 280, 420, 510));
    expect(l.scope, PdfLayerScope.region);
  });

  testWidgets('2. katman: filigranın üstüne örtü eklenir; ikisi de listede, kapatılabilir', (t) async {
    await setup(t);
    final ctl = await pumpFlow(t);
    await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson(), name: 'Birinci'));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await t.tap(find.byKey(const Key('pdf-layers-button')));
    await settle(t, 300);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('layers-add-second')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('second-cover')));
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
    // Bölge seçimi başladı: kutuyu ver.
    expect(ctl.consumeBox(0, 100, 100, 300, 300, 612, 792), isTrue);
    await t.pump(const Duration(milliseconds: 500));
    await waitPreview(t);
    // Önizleme zemini: Birinci katmanın üstüne örtü; renk ve opaklık seçilir.
    await t.tap(find.byKey(const Key('cover-color-fff44336')));
    await t.pump();
    t.widget<Slider>(find.byKey(const Key('cover-opacity'))).onChanged!(0.5);
    await t.pump();
    await tapSave(t);
    final l = (await t.runAsync(() => repo.forPage(_id, 0)))!;
    expect([for (final x in l) x.kind], [PdfLayerKind.watermark, PdfLayerKind.cover]);
    expect(l[1].cover.color, 0xFFF44336);
    expect(l[1].cover.opacity, 0.5);
    expect(l[0].z, lessThan(l[1].z));
    // Rozet 2, hızlı anahtar çalışır; ikisi de paneli listeler, biri kapatılınca öbürü durur.
    expect(find.byKey(const Key('pdf-layers-original')), findsOneWidget);
    await t.tap(find.byKey(const Key('pdf-layers-original')));
    await t.pump();
    expect(hub.showOriginal.value, isTrue);
    await t.tap(find.byKey(const Key('pdf-layers-original')));
    await t.pump();
    expect(hub.showOriginal.value, isFalse);
    await t.runAsync(() => repo.setVisible(l[1].id, false));
    expect([for (final x in visibleLayersFor((await t.runAsync(() => repo.forPage(_id, 0)))!, 0)) x.id], [l[0].id]);
  });

  // ───────────── Kaplama (okuyucuda görünüm) ─────────────

  testWidgets('kaplama: orijinali göster açıkken çizim istenmez; kapanınca filigran görüntüsü üretilir; dispose temizler', (t) async {
    await setup(t);
    await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson()));
    await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.cover, box: const PdfBox(0, 0, 50, 50), params: const CoverParams(color: 0xFFFF0000).toJson()));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    hub.showOriginal.value = true;
    await t.pumpWidget(MaterialApp(
      home: SizedBox(width: 306, height: 396, child: PdfPageLayerOverlay(hub: hub, page: 0, pageWidth: 612, pageHeight: 792)),
    ));
    await settle(t, 600);
    expect(renderer.renders, 0);
    expect(find.byType(CustomPaint), findsWidgets);
    hub.showOriginal.value = false;
    await t.pump();
    for (var i = 0; i < 40 && renderer.cache.length == 0; i++) {
      await settle(t, 200);
    }
    expect(renderer.renders, greaterThan(0));
    expect(renderer.cache.length, greaterThan(0));
    // Kaplama kapanınca (sayfa gider) kendi görüntülerini bırakır; önbellek hâlâ renderer'ındır.
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });

  // ───────────── Gerçek okuyucu ─────────────

  testWidgets('okuyucu: katman düğmesi var; katman gelince rozet ve hızlı anahtar; panel açılır; kalem/telefon akışı bozulmaz', (t) async {
    await setup(t);
    final info = PdfOpenInfo(PdfDocumentRecord(id: _id, sha256: _id, title: 'Deneme PDF', pageCount: 2, fileName: 'a.pdf'), path);
    await t.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        pdfOpenInfoProvider(_id).overrideWith((ref) async => info),
        pdfEngineProvider.overrideWithValue(PdfrxEngine(initialize: pdfrxInitialize)),
        pdfLayersRepositoryProvider.overrideWithValue(repo), // aynı depo: yazma okuyucuyu uyandırır
      ],
      child: MaterialApp(home: PdfReaderPage(documentId: _id)),
    ));
    for (var i = 0; i < 6; i++) {
      await settle(t, 400);
    }
    expect(find.byKey(const Key('pdf-layers-button')), findsOneWidget);
    expect(find.byKey(const Key('pdf-layers-original')), findsNothing);
    expect(find.byKey(const Key('note-pen')), findsOneWidget); // araç yuvası yerinde
    await t.runAsync(() => repo.add(documentId: _id, page: allPdfPages, kind: PdfLayerKind.watermark, params: _wm.toJson()));
    for (var i = 0; i < 4; i++) {
      await settle(t, 300);
    }
    expect(find.byKey(const Key('pdf-layers-original')), findsOneWidget);
    await t.tap(find.byKey(const Key('pdf-layers-button')));
    await settle(t, 300);
    await t.pumpAndSettle();
    expect(find.text('Filigran / Katmanlar'), findsOneWidget);
    expect(find.text('Filigran temizleme · Tüm sayfalar'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
  });

  // ───────────── Çözüm ekranı ve soru önizleme kırpması ─────────────

  testWidgets('çözüm ekranı arka planı görünür katmanı uygular, gizli katmanı uygulamaz', (t) async {
    await setup(t);
    final info = PdfOpenInfo(PdfDocumentRecord(id: _id, sha256: _id, title: 'X', pageCount: 2, fileName: 'a.pdf'), path);
    SolveBackground? bg;
    late WidgetRef cref;
    await t.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        pdfEngineProvider.overrideWithValue(PdfrxEngine(initialize: pdfrxInitialize)),
      ],
      child: MaterialApp(home: Consumer(builder: (context, ref, _) {
        cref = ref;
        return const SizedBox();
      })),
    ));
    const box = PdfBox(90, 280, 420, 510);
    Future<List<int>> center() async {
      final b = (await t.runAsync(() => loadPdfBackground(cref, info, 0, box)))! as PdfPageBackground;
      bg = b;
      return (await t.runAsync(() => _px(b.image, 250 / b.pageSize.width, 392 / b.pageSize.height)))!;
    }
    expect((await center())[1], lessThan(235)); // katman yok: gri
    bg!.dispose();
    final id = (await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson())))!;
    expect(await center(), [255, 255, 255]);
    bg!.dispose();
    await t.runAsync(() => repo.setVisible(id, false));
    expect((await center())[1], lessThan(235));
    bg!.dispose();
    // Başka sayfanın katmanı uygulanmaz.
    await t.runAsync(() => repo.setVisible(id, true));
    await t.runAsync(() => repo.softDelete(id));
    await t.runAsync(() => repo.add(documentId: _id, page: 1, kind: PdfLayerKind.watermark, params: _wm.toJson()));
    expect((await center())[1], lessThan(235));
    bg!.dispose();
    expect(solveRegion(box, const PdfPageSize(612, 792)), isNotNull);
  });

  testWidgets('soru önizleme kırpması görünür katmanı uygular', (t) async {
    await setup(t);
    final dir = Directory('${tmp.path}/m');
    final svc = PdfQuestionService(
      engine: _GrayEngine(),
      cards: DriftQuestionCardRepository(db),
      media: _DirMedia(dir),
      ids: _Ids(),
      clock: () => DateTime(2026, 11, 1),
      tempDir: Directory(tmp.path),
      lexicon: () async => TopicLexicon.fromJson(jsonDecode(File('assets/meb/konu_sozlugu.json').readAsStringSync()) as Map<String, dynamic>),
      ocrRepository: DriftOcrRepository(db),
      layers: repo,
    );
    final doc = PdfDocumentRecord(id: _id, sha256: _id, title: 'X', pageCount: 2, fileName: 'a.pdf');
    Future<List<int>> previewPixel(int page) async {
      final card = await svc.save(
          document: doc, pdfPath: 'x.pdf', page: page, box: const PdfBox(72, 100, 372, 400), status: QuestionStatus.wrong, subject: 'TYT Matematik');
      final bytes = File('${dir.path}/${card.questionImage}').readAsBytesSync();
      final codec = await ui.instantiateImageCodec(bytes);
      final img = (await codec.getNextFrame()).image;
      final px = await _px(img, 0.5, 0.5);
      img.dispose();
      return px;
    }
    expect((await t.runAsync(() => previewPixel(0)))![0], 217); // katman yok
    await t.runAsync(() => repo.add(documentId: _id, page: 0, kind: PdfLayerKind.watermark, params: _wm.toJson()));
    expect(await t.runAsync(() => previewPixel(0)), [255, 255, 255]); // temizlendi
    expect((await t.runAsync(() => previewPixel(1)))![0], 217); // başka sayfa: katman yok
    await t.runAsync(() => repo.add(documentId: _id, page: 1, kind: PdfLayerKind.cover, params: const CoverParams(color: 0xFF0000FF).toJson()));
    expect(await t.runAsync(() => previewPixel(1)), [0, 0, 255]); // örtü
  });
}

/// Tüm sayfası 217 gri (BGRA) veren sahte motor.
class _GrayEngine implements PdfEngine {
  @override
  Future<PdfEngineDocument> openBytes(Uint8List b) => throw UnimplementedError();
  @override
  Future<PdfEngineDocument> openFile(String path) async => _GrayDoc();
}

class _GrayDoc implements PdfEngineDocument {
  @override
  int get pageCount => 2;
  @override
  Future<void> close() async {}
  @override
  Future<PdfPageSize> pageSize(int page) async => const PdfPageSize(612, 792);
  @override
  Future<PdfRenderedImage> renderPage(int page, {required int width, required int height}) async {
    final b = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 217);
    for (var i = 3; i < b.length; i += 4) {
      b[i] = 255;
    }
    return PdfRenderedImage(width: width, height: height, bytes: b, format: PdfPixelFormat.bgra);
  }

  @override
  Future<String> textInBox(int page, PdfBox box) async => '';
}

class _DirMedia implements MediaStorage {
  _DirMedia(this.root);
  final Directory root;
  var n = 0;
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async {
    final rel = '$bucket/${n++}${p.extension(sourcePath)}';
    final t = resolve(rel);
    await t.parent.create(recursive: true);
    await File(sourcePath).copy(t.path);
    return rel;
  }

  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');
  @override
  Future<void> delete(String relativePath) async {}
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}
