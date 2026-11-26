import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/features/anlik/domain/anlik.dart';
import 'package:kocum/features/anlik/presentation/anlik_screens.dart';
import 'package:kocum/features/anlik/presentation/sleep_card.dart';
import 'package:kocum/features/anlik/presentation/widgets/anlik_editor.dart';
import 'package:kocum/features/anlik/presentation/widgets/people_tags_manage.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'w${_n++}';
}

Future<(AppDatabase, ProviderContainer)> _setup(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    idGeneratorProvider.overrideWithValue(_Ids()),
    clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 8, 30)),
  ]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
  return (db, container);
}

Widget _app(ProviderContainer c, Widget home) =>
    UncontrolledProviderScope(container: c, child: MaterialApp(home: Scaffold(body: home)));

void main() {
  testWidgets('editör açılınca yazma alanı odaklı; tek dokunuşla kaydolur ve geri alınır', (tester) async {
    final (db, c) = await _setup(tester);
    AnlikNote? saved;
    Future<void> Function()? undo;
    await tester.pumpWidget(_app(c, AnlikEditor(onSaved: (n, u) {
      saved = n;
      undo = u;
    })));
    await tester.pump();

    final field = tester.widget<TextField>(find.byKey(const ValueKey('anlik-yazi')));
    expect(field.autofocus, isTrue);

    await tester.enterText(find.byKey(const ValueKey('anlik-yazi')), 'Bugün iyi geçti');
    await tester.tap(find.byKey(const ValueKey('anlik-kaydet')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(saved?.body, 'Bugün iyi geçti');
    expect(await db.select(db.anlikNotes).get(), hasLength(1));

    await tester.runAsync(() => undo!());
    expect(await db.select(db.anlikNotes).get(), isEmpty); // geri alındı
  });

  testWidgets('boş not kaydedilmez; hata görünür', (tester) async {
    final (db, c) = await _setup(tester);
    var calls = 0;
    await tester.pumpWidget(_app(c, AnlikEditor(onSaved: (n, u) => calls++)));
    await tester.tap(find.byKey(const ValueKey('anlik-kaydet')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('Bir şeyler yaz.'), findsOneWidget);
    expect(await db.select(db.anlikNotes).get(), isEmpty);
  });

  testWidgets('olmayan etiket: onay penceresi çıkar, Vazgeç yazmaz, Oluştur yazar', (tester) async {
    final (db, c) = await _setup(tester);
    var calls = 0;
    await tester.pumpWidget(_app(c, AnlikEditor(onSaved: (n, u) => calls++)));
    await tester.enterText(find.byKey(const ValueKey('anlik-yazi')), 'Kantinde ((his > tiksinti)) hissettim');

    await tester.tap(find.byKey(const ValueKey('anlik-kaydet')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('Yeni ad var'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(await db.select(db.tags).get(), isEmpty); // sessizce oluşmadı

    await tester.tap(find.byKey(const ValueKey('anlik-kaydet')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('yeni-onayla')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect((await db.select(db.tags).get()).map((t) => t.label).toSet(), {'his', 'tiksinti'});
  });

  testWidgets('yazarken ((tik öneri çipi çıkar ve dokununca yerine yazılır', (tester) async {
    final (db, c) = await _setup(tester);
    await db.into(db.tags).insert(TagsCompanion.insert(
        id: 't', name: 'tiksinti', label: 'Tiksinti', createdAt: DateTime(2026)));
    await tester.pumpWidget(_app(c, AnlikEditor(onSaved: (n, u) {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    await tester.enterText(find.byKey(const ValueKey('anlik-yazi')), 'Bugün ((tik');
    await tester.pump();
    expect(find.byKey(const ValueKey('oneri:Tiksinti')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('oneri:Tiksinti')));
    await tester.pump();
    final text = tester.widget<TextField>(find.byKey(const ValueKey('anlik-yazi'))).controller!.text;
    expect(text, 'Bugün ((Tiksinti))');
  });

  testWidgets('ana ekran uyku kartı: Yattım → Kalktım, tek dokunuş', (tester) async {
    final (db, c) = await _setup(tester);
    await tester.pumpWidget(_app(c, const SleepCard()));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Yattım'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('uyku-karti')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump();
    expect((await db.select(db.anlikNotes).get()).single.kind, 'uyku_yattim');
    expect(find.text('Kalktım'), findsOneWidget);
  });

  testWidgets('kişi ekleme penceresi: ad zorunlu, takma adlar kaydolur; liste ve boş durum', (tester) async {
    final (db, c) = await _setup(tester);
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: PeopleScreen())));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.textContaining('Henüz kişi yok'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('kisi-yeni')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kisi-kaydet')));
    await tester.pump();
    expect(find.text('Bir ad yaz'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('kisi-ad')), 'Şule');
    await tester.enterText(find.byKey(const ValueKey('kisi-takma')), 'Şulo, Şuşu');
    await tester.tap(find.byKey(const ValueKey('kisi-kaydet')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    final row = (await db.select(db.people).get()).single;
    expect(row.aliases, ['Şulo', 'Şuşu']);
    expect(find.text('Şule'), findsWidgets);
  });

  testWidgets('etiketler sayfası: yeniden adlandırma ad çakışmasında uyarır', (tester) async {
    final (db, c) = await _setup(tester);
    for (final (id, label) in [('a', 'Bir'), ('b', 'İki')]) {
      await db.into(db.tags).insert(TagsCompanion.insert(
          id: id, name: label.toLowerCase().replaceAll('İ', 'i'), label: label, createdAt: DateTime(2026)));
    }
    await tester.pumpWidget(UncontrolledProviderScope(
        container: c, child: const MaterialApp(home: Scaffold(body: TagsManager()))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Bir'), findsOneWidget);
  });
}
