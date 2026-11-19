import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/entry/exams_page.dart';
import 'package:kocum/features/mock_exam/domain/karne_import.dart';
import 'package:kocum/features/mock_exam/domain/karne_parser.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'x${_n++}';
}

KarneImportPlan _plan() {
  final json = jsonDecode(File('test/fixtures/karne_vip_maarif.json').readAsStringSync()) as Map<String, dynamic>;
  final pages = [
    for (final page in json['pages'] as List)
      [for (final w in page as List) PdfWord(w[0] as String, (w[1] as num).toDouble(), (w[2] as num).toDouble())],
  ];
  return planKarneImport(parseKarne(pages));
}

void main() {
  late AppDatabase db;

  Future<ProviderContainer> pump(WidgetTester tester, {Widget page = const DesktopExamsPage()}) async {
    tester.view.physicalSize = const Size(1300, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      idGeneratorProvider.overrideWithValue(_Ids()),
      clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 10)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: Scaffold(body: page))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    return c;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('elle deneme: hazır TYT dersleri, net kendiliğinden, sayı hatası uyarı, kaydet, düzenle, sil', (tester) async {
    await pump(tester);
    expect(find.textContaining('Henüz deneme yok'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('deneme-ekle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('deneme-ad')), 'Eylül Denemesi');
    // Matematik: 40 soru; 45 işaret hatası.
    await tester.enterText(find.byKey(const ValueKey('dogru:TYT Matematik')), '38');
    await tester.enterText(find.byKey(const ValueKey('yanlis:TYT Matematik')), '7');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('deneme-kaydet')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('soruyu geçemez'), findsOneWidget);
    expect(await db.select(db.mockExams).get(), isEmpty);

    await tester.enterText(find.byKey(const ValueKey('dogru:TYT Matematik')), '35');
    await tester.enterText(find.byKey(const ValueKey('yanlis:TYT Matematik')), '4');
    await tester.enterText(find.byKey(const ValueKey('bos:TYT Matematik')), '1');
    await tester.enterText(find.byKey(const ValueKey('dogru:TYT Türkçe')), '30');
    await tester.pump();
    expect(find.text('Toplam net: 64'), findsOneWidget); // (35-1) + 30
    await tester.tap(find.byKey(const ValueKey('deneme-kaydet')));
    await settle(tester);
    await tester.pumpAndSettle();

    final exam = (await db.select(db.mockExams).get()).single;
    expect(exam.title, 'Eylül Denemesi');
    final sections = await db.select(db.mockExamSections).get();
    expect(sections.length, 9);
    final mat = sections.firstWhere((s) => s.subject == 'TYT Matematik');
    expect((mat.correct, mat.wrong, mat.blank, mat.questionCount), (35, 4, 1, 40));
    expect(find.text('Eylül Denemesi'), findsWidgets);

    // Düzenle: yanlışı 2 yap.
    await tester.tap(find.byKey(const ValueKey('deneme-duzenle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('yanlis:TYT Matematik')), '2');
    await tester.tap(find.byKey(const ValueKey('deneme-kaydet')));
    await settle(tester);
    await tester.pumpAndSettle();
    final again = (await db.select(db.mockExamSections).get()).firstWhere((s) => s.subject == 'TYT Matematik');
    expect(again.wrong, 2);
    expect((await db.select(db.mockExams).get()).length, 1);

    // Sil (onaylı).
    await tester.tap(find.byKey(const ValueKey('deneme-sil')));
    await tester.pumpAndSettle();
    expect(find.text('Deneme silinsin mi?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('deneme-sil-onay')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(await db.select(db.mockExams).get(), isEmpty);
  });

  testWidgets('karne önizleme: adı değiştirilir, deneme ve yanlış/boş kartlar eklenir; aynı karne ikinci kez uyarır', (tester) async {
    late BuildContext ctx;
    late WidgetRef wref;
    await pump(tester, page: Consumer(builder: (context, ref, _) {
      ctx = context;
      wref = ref;
      return const DesktopExamsPage();
    }));
    final plan = _plan();

    var done = false;
    unawaited_(showKarnePreview(ctx, wref, plan).then((_) => done = true));
    await tester.pumpAndSettle();
    expect(find.text('Karne önizleme'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('karne-ad')), 'VİP Deneme 1');
    await tester.tap(find.byKey(const ValueKey('karne-kaydet')));
    await settle(tester);
    await settle(tester);
    await tester.pumpAndSettle();
    expect(done, isTrue);

    final exam = (await db.select(db.mockExams).get()).single;
    expect(exam.title, 'VİP Deneme 1');
    final cards = await db.select(db.questionCards).get();
    expect(cards.length, plan.mistakes.length);
    expect(cards.every((k) => k.mockExamId == exam.id && k.origin == 'mockExam'), isTrue);

    // Aynı karne: zaten kayıtlı uyarısı; Atla ile hiçbir şey eklenmez.
    done = false;
    unawaited_(showKarnePreview(ctx, wref, plan).then((_) => done = true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('karne-ad')), 'VİP Deneme 1');
    await tester.tap(find.byKey(const ValueKey('karne-kaydet')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Bu deneme zaten kayıtlı'), findsOneWidget);
    await tester.tap(find.text('Atla'));
    await settle(tester);
    await tester.pumpAndSettle();
    expect((await db.select(db.mockExams).get()).length, 1);
    expect((await db.select(db.questionCards).get()).length, cards.length);
  });
}

void unawaited_(Future<void> f) {}
