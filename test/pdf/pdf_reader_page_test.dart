import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/pdf_reader_page.dart';
import 'package:pdfrx/pdfrx.dart' show pdfrxInitialize;

import 'pdf_test_support.dart';

import 'package:kocum/features/pdf/presentation/pdf_page_ink_layer.dart';

final _id = 'c' * 64;

/// Gerçek PdfViewer + gerçek PDFium (Linux'ta çalışır). Çizim ve dosya
/// işleri gerçek zaman ister: `runAsync` + kısa beklemeler.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late String path;

  Future<void> settle(WidgetTester t, [int ms = 600]) async {
    await t.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
  }

  Future<void> open(WidgetTester t, {String? filePath}) async {
    tmp = await t.runAsync(
      () => Directory.systemTemp.createTemp('okuyucu'),
    ) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    path = '${tmp.path}/a.pdf';
    await t.runAsync(() async {
      await File(path).writeAsBytes(
        minimalPdf([
          [('Birinci', 72, 700)],
          [('Ikinci', 72, 700)],
          [('Ucuncu', 72, 700)],
        ]),
      );
      await pdfrxInitialize();
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
    });
    addTearDown(() => t.runAsync(db.close));
    t.view.physicalSize = const Size(900, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final info = PdfOpenInfo(
      PdfDocumentRecord(
        id: _id,
        sha256: _id,
        title: 'Deneme PDF',
        pageCount: 3,
        fileName: 'a.pdf',
      ),
      filePath ?? path,
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          pdfOpenInfoProvider(_id).overrideWith((ref) async => info),
        ],
        child: MaterialApp(home: PdfReaderPage(documentId: _id)),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await settle(t, 400);
    }
  }

  testWidgets(
    'açılır: başlık, sayfa göstergesi, araç çubuğu; küçük resim şeridi açılıp kapanır',
    (t) async {
      await open(t);
      expect(find.text('Deneme PDF'), findsOneWidget);
      expect(find.byKey(const Key('pdf-page-indicator')), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      for (final k in [
        'pdf-tool-pen',
        'pdf-tool-highlighter',
        'pdf-tool-eraser',
        'pdf-undo',
        'pdf-redo',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget);
      }
      expect(find.byKey(const Key('pdf-thumb-strip')), findsNothing);
      await t.tap(find.byKey(const Key('pdf-thumbs-toggle')));
      await settle(t, 300);
      expect(find.byKey(const Key('pdf-thumb-strip')), findsOneWidget);
      await t.tap(find.byKey(const Key('pdf-thumbs-toggle')));
      await t.pump();
      expect(find.byKey(const Key('pdf-thumb-strip')), findsNothing);
    },
  );

  testWidgets(
    'kalem sayfaya çizer ve kaydeder; parmak sayfayı kaydırır (göstergesi değişir)',
    (t) async {
      await open(t);
      // Kalem: ekranın ortasında çiz → sayfa 1'de kayıt, sayfa göstergesi aynı.
      final pen = await t.startGesture(
        const Offset(450, 500),
        kind: PointerDeviceKind.stylus,
      );
      for (var i = 0; i < 6; i++) {
        await pen.moveBy(const Offset(10, 0));
      }
      await pen.up();
      await settle(t, 200);
      late List<InkStroke> rows;
      await t.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 200));
        rows = await ref(t)
            .read(inkStrokeRepositoryProvider)
            .forPage(PdfPageOwner(_id, 0), attemptNo: 1, layer: 0);
      });
      expect(rows, hasLength(1));
      expect(find.text('1 / 3'), findsOneWidget);

      // Parmak: yukarı sürükle → görünüm kayar, çizgi eklenmez.
      for (var k = 0; k < 4; k++) {
        final f = await t.startGesture(
          const Offset(450, 900),
          kind: PointerDeviceKind.touch,
        );
        for (var i = 0; i < 8; i++) {
          await f.moveBy(const Offset(0, -100));
        }
        await f.up();
        await settle(t, 150);
      }
      expect(find.text('1 / 3'), findsNothing);
      late List<InkStroke> after;
      await t.runAsync(() async {
        after = await ref(t)
            .read(inkStrokeRepositoryProvider)
            .forPage(PdfPageOwner(_id, 0), attemptNo: 1, layer: 0);
      });
      expect(after, hasLength(1));
    },
  );

  testWidgets(
    'kalem çizerken parmak/avuç görünümü kaydırmaz; kalem kalkınca parmak yine kaydırır',
    (t) async {
      await open(t);
      final pen = await t.startGesture(
        const Offset(450, 500),
        kind: PointerDeviceKind.stylus,
      );
      final palm = await t.startGesture(
        const Offset(700, 1000),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 8; i++) {
        await palm.moveBy(const Offset(0, -100));
        await pen.moveBy(const Offset(6, 0));
      }
      await palm.up();
      await pen.up();
      await settle(t, 200);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(
        t.getRect(find.byType(PdfPageInkLayer).first).top,
        closeTo(116.5, 1),
      );

      final f = await t.startGesture(
        const Offset(450, 900),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 8; i++) {
        await f.moveBy(const Offset(0, -100));
      }
      await f.up();
      await settle(t, 200);
      expect(find.text('1 / 3'), findsNothing);
    },
  );

  testWidgets('kaydırdıktan sonra çizgi görünen (ikinci) sayfaya kaydedilir', (
    t,
  ) async {
    await open(t);
    final f = await t.startGesture(
      const Offset(450, 1000),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 0; i < 8; i++) {
      await f.moveBy(const Offset(0, -110));
    }
    await f.up();
    await settle(t, 800);
    // Ekranın (450, 600) noktasını kaplayan sayfa katmanı.
    const tapY = 600.0;
    final hit = [
      for (final e in find.byType(PdfPageInkLayer).evaluate())
        if (t
            .getRect(find.byWidget(e.widget))
            .contains(const Offset(450, tapY)))
          e.widget as PdfPageInkLayer,
    ].single;
    final rect = t.getRect(find.byWidget(hit));
    final pen = await t.startGesture(
      const Offset(450, tapY),
      kind: PointerDeviceKind.stylus,
    );
    for (var i = 0; i < 6; i++) {
      await pen.moveBy(const Offset(10, 0));
    }
    await pen.up();
    await settle(t, 200);
    late List<InkStroke> rows;
    await t.runAsync(() async {
      await Future.delayed(const Duration(milliseconds: 200));
      rows = await ref(t)
          .read(inkStrokeRepositoryProvider)
          .forPage(PdfPageOwner(_id, hit.page));
    });
    expect(hit.page, greaterThan(0)); // kaydırıldı: ilk sayfada değiliz
    expect(rows, hasLength(1));
    expect(
      rows.single.points.first.y,
      closeTo((tapY - rect.top) * 792 / rect.height, 0.2),
    );
    expect(
      rows.single.points.first.x,
      closeTo((450 - rect.left) * 612 / rect.width, 0.2),
    );
  });

  testWidgets('dosyası olmayan belge: açıklama gösterilir', (t) async {
    tmp = await t.runAsync(
      () => Directory.systemTemp.createTemp('okuyucu2'),
    ) as Directory;
    addTearDown(() => t.runAsync(() => tmp.delete(recursive: true)));
    final info = PdfOpenInfo(
      PdfDocumentRecord(
        id: _id,
        sha256: _id,
        title: 'Uzak PDF',
        pageCount: 3,
        fileName: 'a.pdf',
      ),
      null,
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [pdfOpenInfoProvider(_id).overrideWith((ref) async => info)],
        child: MaterialApp(home: PdfReaderPage(documentId: _id)),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.textContaining('dosyası bu cihazda yok'), findsOneWidget);
  });
}

ProviderContainer ref(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(PdfReaderView)));
