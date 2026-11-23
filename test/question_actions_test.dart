import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/tablet.dart' show debugAndroidOverride;
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:kocum/features/question_bank/presentation/screens/question_detail_screen.dart';
import 'package:kocum/features/question_bank/presentation/screens/question_viewer_screen.dart';
import 'package:kocum/features/question_bank/presentation/widgets/question_actions.dart';
import 'package:kocum/features/question_bank/presentation/widgets/question_tile.dart';
import 'package:kocum/features/question_bank/question_bank_providers.dart';

final _docId = 'e' * 64;

class _Media implements MediaStorage {
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async => throw UnimplementedError();
  @override
  File resolve(String relativePath) => File('/nonexistent/$relativePath');
  @override
  Future<void> delete(String relativePath) async {}
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

QuestionCard _card(String id, {bool pdf = false, String? image}) => QuestionCard(
  id: id,
  status: QuestionStatus.wrong,
  origin: QuestionOrigin.independent,
  sourceName: 'kaynak',
  subject: 'TYT Matematik',
  difficulty: 5,
  createdAt: DateTime(2026),
  questionImage: image,
  pdfDocumentId: pdf ? _docId : null,
  pdfPage: pdf ? 2 : null,
  pdfBox: pdf ? const PdfBox(10, 20, 300, 400) : null,
);

void main() {
  group('saf eylem listesi', () {
    test('PDF yok/var/PDF bağsız', () {
      List<String> labels(List<QuestionActionEntry> l) => [for (final e in l) e.label];
      final noPdf = questionActionEntries(_card('a', image: 'x.png'), pdfAvailable: null, selected: false);
      expect(labels(noPdf), ['Düzenle', 'Çiz / Çöz', 'Seç', 'Sil']);
      final missing = questionActionEntries(_card('a', pdf: true), pdfAvailable: false, selected: false);
      final pdf = missing.firstWhere((e) => e.action == QuestionAction.openPdf);
      expect(pdf.enabled, isFalse);
      expect(pdf.hint, 'PDF bu cihazda yok');
      final ok = questionActionEntries(_card('a', pdf: true), pdfAvailable: true, selected: true);
      expect(ok.firstWhere((e) => e.action == QuestionAction.openPdf).enabled, isTrue);
      expect(labels(ok), contains('Seçimden çıkar'));
    });
  });

  group('ekranlar', () {
    late AppDatabase db;

    Future<void> settle(WidgetTester t) async {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
    }

    Future<void> pump(WidgetTester t, Widget Function(List<QuestionCard>) home, List<QuestionCard> cards,
        {required Size size, bool pdfHere = true}) async {
      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
        for (final c in cards) {
          await DriftQuestionCardRepository(db).insert(c);
        }
      });
      addTearDown(() => t.runAsync(db.close));
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => home(cards)),
        GoRoute(path: '/questions/:id/edit', builder: (_, s) => Scaffold(body: Text('EDIT ${s.uri}'))),
        GoRoute(path: '/soru/:id/coz', builder: (_, s) => Scaffold(body: Text('COZ ${s.uri}'))),
        GoRoute(path: '/pdf/:id', builder: (_, s) => Scaffold(body: Text('PDF ${s.uri}'))),
      ]);
      addTearDown(router.dispose);
      await t.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          mediaStorageProvider.overrideWithValue(_Media()),
          pdfAvailableProvider(_docId).overrideWith((ref) async => pdfHere),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await settle(t);
    }

    Future<void> close(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    }

    for (final size in [const Size(1250, 800), const Size(412, 900)]) {
      testWidgets('görüntüleyici: yazılı çubuk, taşma yok (${size.width.toInt()} dp)', (t) async {
        await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('p1', pdf: true)], size: size);
        for (final label in ['Düzenle', 'PDF\'te aç', 'Çiz / Çöz', 'Seç', 'Sil']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(t.takeException(), isNull);
        await close(t);
      });
    }

    testWidgets('görüntüleyici: Düzenle, PDF\'te aç, Çiz/Çöz yönlendirir; Seç seçer', (t) async {
      await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('p1', pdf: true)],
          size: const Size(1250, 800));
      await t.tap(find.byKey(const Key('viewer-select')));
      await settle(t);
      final container = ProviderScope.containerOf(t.element(find.byType(QuestionViewerScreen)));
      expect(container.read(questionSelectionProvider), {'p1'});
      expect(find.text('Seçimden çıkar'), findsOneWidget);
      await t.tap(find.byKey(const Key('viewer-open-pdf')));
      await settle(t);
      expect(find.textContaining('PDF /pdf/$_docId?page=2&box=10.0,20.0,300.0,400.0'), findsOneWidget);
      await close(t);
    });

    testWidgets('görüntüleyici: Düzenle rotası', (t) async {
      await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('p1', pdf: true)],
          size: const Size(412, 900));
      await t.tap(find.byKey(const Key('viewer-edit')));
      await settle(t);
      expect(find.text('EDIT /questions/p1/edit'), findsOneWidget);
      await close(t);
    });

    testWidgets('PDF cihazda yoksa düğme devre dışı; PDF bağsız kartta yok', (t) async {
      await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('p1', pdf: true)],
          size: const Size(1250, 800), pdfHere: false);
      final btn = t.widget<ButtonStyleButton>(find.byKey(const Key('viewer-open-pdf')));
      expect(btn.onPressed, isNull);
      expect(find.byTooltip('PDF bu cihazda yok'), findsOneWidget);
      await close(t);
      await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('f1', image: 'x.png')],
          size: const Size(1250, 800));
      expect(find.byKey(const Key('viewer-open-pdf')), findsNothing);
      await close(t);
    });

    testWidgets('ayrıntı: aynı çubuk (Düzenle yazılı)', (t) async {
      await pump(t, (c) => QuestionDetailScreen(cardId: 'p1'), [_card('p1', pdf: true)],
          size: const Size(412, 900));
      expect(find.text('Düzenle'), findsOneWidget);
      expect(find.text('PDF\'te aç'), findsOneWidget);
      await t.tap(find.byKey(const Key('detail-edit')));
      await settle(t);
      expect(find.text('EDIT /questions/p1/edit'), findsOneWidget);
      await close(t);
    });

    testWidgets('kart: ⋮ menüsü eylemleri sunar', (t) async {
      await pump(
        t,
        (c) => Scaffold(body: SizedBox(width: 200, height: 260, child: QuestionTile(card: c.first))),
        [_card('p1', pdf: true)],
        size: const Size(1250, 800),
      );
      await t.tap(find.byTooltip('Soru işlemleri'));
      await settle(t);
      for (final label in ['Düzenle', 'PDF\'te aç', 'Çiz / Çöz', 'Seç', 'Sil']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await t.tap(find.byKey(const Key('menu-edit')));
      await settle(t);
      expect(find.text('EDIT /questions/p1/edit'), findsOneWidget);
      await close(t);
    });

    for (final size in [const Size(1250, 800), const Size(412, 900)]) {
      testWidgets('kart: uzun basış SEÇİM başlatır (menü açmaz), ⋮ ile Seç de seçer (${size.width.toInt()} dp)', (t) async {
        await pump(
          t,
          (c) => Scaffold(body: SizedBox(width: 200, height: 260, child: QuestionTile(card: c.first))),
          [_card('p1', pdf: true)],
          size: size,
        );
        final container = ProviderScope.containerOf(t.element(find.byType(QuestionTile)));
        await t.longPress(find.byType(QuestionTile));
        await settle(t);
        expect(container.read(questionSelectionProvider), {'p1'});
        expect(find.text('Sil'), findsNothing, reason: 'menü açılmamalı');
        container.read(questionSelectionProvider.notifier).clear();
        await settle(t);
        expect(find.byTooltip('Soru işlemleri'), findsOneWidget);
        await t.tap(find.byTooltip('Soru işlemleri'));
        await settle(t);
        await t.pump(const Duration(milliseconds: 500));
        await t.tap(find.byKey(const Key('menu-select')));
        await settle(t);
        expect(container.read(questionSelectionProvider), {'p1'});
        await close(t);
      });
    }

    testWidgets('görüntüleyici: kart başka yerde silinince eski kopya gösterilmez', (t) async {
      await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('p1', image: 'x.png'), _card('p2', image: 'y.png')],
          size: const Size(412, 900));
      expect(find.text('1 / 2'), findsOneWidget);
      final container = ProviderScope.containerOf(t.element(find.byType(QuestionViewerScreen)));
      await t.runAsync(() => container.read(deleteQuestionCardProvider).call('p1'));
      await settle(t);
      await settle(t);
      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.text('2 / 2'), findsNothing);
      await close(t);
    });

    testWidgets('görüntüleyici: silinen kart seçimden çıkar', (t) async {
      await pump(t, (c) => QuestionViewerScreen(cards: c, initialIndex: 0), [_card('p1', image: 'x.png'), _card('p2', image: 'y.png')],
          size: const Size(1250, 800));
      final container = ProviderScope.containerOf(t.element(find.byType(QuestionViewerScreen)));
      container.read(questionSelectionProvider.notifier).selectAll(['p1', 'p2']);
      await settle(t);
      await t.tap(find.byKey(const Key('viewer-delete')));
      await settle(t);
      await t.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Sil')));
      await settle(t);
      await settle(t);
      expect(container.read(questionSelectionProvider), {'p2'});
      await close(t);
    });
  });
}
