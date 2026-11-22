import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/anlik/data/anlik_repository_impl.dart';
import 'package:kocum/features/anlik/domain/anlik.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/domain/notebook_filter.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/notebooks_screen.dart';

InkNotebookRecord _nb(String id) => InkNotebookRecord(
  id: id,
  title: id,
  coverColor: 0,
  defaultTemplate: PageTemplate.plain,
  sortOrder: 0,
  pageCount: 1,
  deleted: false,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Tag _tag(String id, String label, {String? parent}) =>
    Tag(id: id, name: label.toLowerCase(), label: label, parentId: parent, createdAt: DateTime(2026));

class _H {
  _H(this.db, this.repo, this.anlik);
  final AppDatabase db;
  final InkNotebookRepository repo;
  final DriftAnlikRepository anlik;
}

Future<_H> _db(WidgetTester t) async {
  late _H h;
  await t.runAsync(() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    h = _H(db, InkNotebookRepository(db), DriftAnlikRepository(db));
  });
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.runAsync(h.db.close);
  });
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  return h;
}

Future<void> _wait(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(_H h, Widget home) => ProviderScope(
  overrides: [appDatabaseProvider.overrideWithValue(h.db), clockProvider.overrideWithValue(() => DateTime(2026, 1, 1))],
  child: MaterialApp(home: home),
);

void main() {
  test('süzme: etiket ve altındaki etiketler; null hepsi', () {
    final tags = [_tag('his', 'his'), _tag('tik', 'tiksinti', parent: 'his'), _tag('x', 'başka')];
    final list = [_nb('a'), _nb('b'), _nb('c')];
    final map = {
      'a': {'tik'},
      'b': {'x'},
    };
    expect(filterNotebooksByTag(list, map, tags, null), list);
    expect(filterNotebooksByTag(list, map, tags, 'his').map((e) => e.id), ['a']); // alt etiket sayılır
    expect(filterNotebooksByTag(list, map, tags, 'tik').map((e) => e.id), ['a']);
    expect(filterNotebooksByTag(list, map, tags, 'x').map((e) => e.id), ['b']);
    expect(filterNotebooksByTag(list, map, tags, 'yok'), isEmpty);
  });

  testWidgets('etiket haritası: defter etiketi + sayfa etiketi; silinen sayfa sayılmaz', (t) async {
    final h = await _db(t);
    late String a, b, p;
    await t.runAsync(() async {
      await h.anlik.saveTag(_tag('t1', 'fizik'));
      await h.anlik.saveTag(_tag('t2', 'kimya'));
      a = await h.repo.createNotebook(title: 'A');
      b = await h.repo.createNotebook(title: 'B');
      await h.repo.addNotebookTag(a, 't1');
      p = await h.repo.addPage(b);
      await h.repo.addPageTag(p, 't2');
      expect(await h.repo.watchNotebookTagMap().first, {a: {'t1'}, b: {'t2'}});
      await h.repo.deletePage(p);
      expect(await h.repo.watchNotebookTagMap().first, {a: {'t1'}});
    });
  });

  testWidgets('defter listesi: etiket çipleri ve etikete göre süzme', (t) async {
    final h = await _db(t);
    late String a, b;
    await t.runAsync(() async {
      await h.anlik.saveTag(_tag('t1', 'fizik'));
      await h.anlik.saveTag(_tag('t2', 'kimya'));
      a = await h.repo.createNotebook(title: 'Fizik defteri');
      b = await h.repo.createNotebook(title: 'Kimya defteri');
      await h.repo.createNotebook(title: 'Etiketsiz');
      await h.repo.addNotebookTag(a, 't1');
      await h.repo.addPageTag((await h.repo.pages(b)).single.id, 't2'); // yalnız sayfa etiketi
    });
    await t.pumpWidget(_app(h, NotebooksScreen(onOpen: (_, _) {})));
    await _wait(t);
    expect(find.text('Fizik defteri'), findsOneWidget);
    expect(find.text('Kimya defteri'), findsOneWidget);
    expect(find.text('Etiketsiz'), findsOneWidget);
    expect(find.byKey(Key('notebook-chip-$a-t1')), findsOneWidget);
    expect(find.byKey(Key('notebook-chip-$b-t2')), findsOneWidget);

    await t.tap(find.byKey(const Key('notebook-filter-t1')));
    await _wait(t, 2);
    expect(find.text('Fizik defteri'), findsOneWidget);
    expect(find.text('Kimya defteri'), findsNothing);
    expect(find.text('Etiketsiz'), findsNothing);

    await t.tap(find.byKey(const Key('notebook-filter-t2')));
    await _wait(t, 2);
    expect(find.text('Kimya defteri'), findsOneWidget);
    expect(find.text('Fizik defteri'), findsNothing);

    await t.tap(find.byKey(const Key('notebook-filter-t2'))); // süzmeyi kaldır
    await _wait(t, 2);
    expect(find.text('Etiketsiz'), findsOneWidget);
  });

  testWidgets('panel: mevcut etiket/kişiyi deftere ve sayfaya bağla, kaldır', (t) async {
    final h = await _db(t);
    late String nb, page;
    await t.runAsync(() async {
      await h.anlik.saveTag(_tag('t1', 'fizik'));
      await h.anlik.saveTag(_tag('t2', 'kimya'));
      await h.anlik.savePerson(Person(id: 'k1', name: 'Ayşe', createdAt: DateTime(2026)));
      nb = await h.repo.createNotebook(title: 'D');
      page = (await h.repo.pages(nb)).single.id;
    });
    await t.pumpWidget(_app(h, InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)));
    await _wait(t);
    await t.tap(find.byKey(const Key('note-tags-btn')));
    await _wait(t, 4);
    expect(find.text('Etiketler ve kişiler'), findsOneWidget);

    Finder inNb(String key) => find.descendant(of: find.byKey(const Key('ink-tags-notebook')), matching: find.byKey(ValueKey(key)));
    Finder inPg(String key) => find.descendant(of: find.byKey(const Key('ink-tags-page')), matching: find.byKey(ValueKey(key)));

    // Deftere etiket.
    await t.tap(inNb('etiket-ekle'));
    await _wait(t, 3);
    await t.tap(find.text('fizik').last);
    await _wait(t, 4);
    expect(await t.runAsync(() => h.repo.notebookTagIds(nb)), {'t1'});

    // Sayfaya etiket.
    await t.tap(inPg('etiket-ekle'));
    await _wait(t, 3);
    await t.tap(find.text('kimya').last);
    await _wait(t, 4);
    expect(await t.runAsync(() => h.repo.pageTagIds(page)), {'t2'});
    expect(await t.runAsync(() => h.repo.notebookTagIds(nb)), {'t1'}); // karışmadı

    // Sayfaya kişi.
    await t.tap(find.descendant(of: find.byKey(const Key('ink-people-page')), matching: find.byKey(const ValueKey('kisi-ekle'))));
    await _wait(t, 3);
    await t.tap(find.text('Ayşe').last);
    await _wait(t, 4);
    expect(await t.runAsync(() => h.repo.pagePersonIds(page)), {'k1'});

    // Kaldır: çipin silme düğmesi.
    await t.tap(find.descendant(of: find.byKey(const ValueKey('etiket:t1')), matching: find.byIcon(Icons.clear)));
    await _wait(t, 4);
    expect(await t.runAsync(() => h.repo.notebookTagIds(nb)), isEmpty);
    expect(await t.runAsync(() => h.repo.pageTagIds(page)), {'t2'});
  });

  testWidgets('panel: ((etiket)) ve @kişi yazımı çözülür; yeni adlar onayla oluşur ve sayfaya bağlanır; yinelenme yok', (t) async {
    final h = await _db(t);
    late String nb, page;
    await t.runAsync(() async {
      await h.anlik.saveTag(_tag('t1', 'fizik'));
      nb = await h.repo.createNotebook(title: 'D');
      page = (await h.repo.pages(nb)).single.id;
    });
    await t.pumpWidget(_app(h, InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)));
    await _wait(t);
    await t.tap(find.byKey(const Key('note-tags-btn')));
    await _wait(t, 4);

    await t.enterText(find.byKey(const Key('ink-tags-quick')), '((fizik)) ((his > tiksinti)) @Ayşe');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _wait(t, 4);
    // Yeni ad var: onay diyaloğu.
    expect(find.text('Yeni ad var'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('yeni-onayla')));
    await _wait(t, 6);

    final tags = (await t.runAsync(() => h.anlik.allTags()))!;
    expect(tags.map((e) => e.name).toSet(), {'fizik', 'his', 'tiksinti'}); // fizik çiftlenmedi
    final tik = tags.firstWhere((e) => e.name == 'tiksinti');
    expect(tik.parentId, tags.firstWhere((e) => e.name == 'his').id);
    final people = (await t.runAsync(() => h.anlik.allPeople()))!;
    expect(people.map((e) => e.name), ['Ayşe']);
    expect(await t.runAsync(() => h.repo.pageTagIds(page)), {'t1', tik.id});
    expect(await t.runAsync(() => h.repo.pagePersonIds(page)), {people.single.id});
    expect(await t.runAsync(() => h.repo.notebookTagIds(nb)), isEmpty);

    // Aynı yazım yeniden: onay istemez (hepsi var), kopya oluşmaz.
    await t.enterText(find.byKey(const Key('ink-tags-quick')), '((FİZİK)) @ayşe');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await _wait(t, 4);
    expect(find.text('Yeni ad var'), findsNothing);
    expect((await t.runAsync(() => h.anlik.allTags()))!, hasLength(3));
    expect((await t.runAsync(() => h.anlik.allPeople()))!, hasLength(1));
  });
}
