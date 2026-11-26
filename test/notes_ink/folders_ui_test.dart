import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/notes/data/ink_board_repository.dart';
import 'package:kocum/features/notes/data/ink_folder_repository.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/ink_folder.dart';
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/presentation/folder_nav.dart';
import 'package:kocum/features/notes/presentation/notebooks_screen.dart';
import 'package:kocum/features/notes/presentation/page_info_sheet.dart';

class _H {
  _H(this.db)
    : nbs = InkNotebookRepository(db),
      folders = InkFolderRepository(db) {
    board = InkBoardRepository(db, notebooks: nbs);
  }
  final AppDatabase db;
  final InkNotebookRepository nbs;
  final InkFolderRepository folders;
  late final InkBoardRepository board;
  final opened = <String>[];
}

Future<_H> _setup(WidgetTester t, {Size size = const Size(1200, 900)}) async {
  late _H h;
  await t.runAsync(() async {
    final db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    h = _H(db);
  });
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.runAsync(h.db.close);
  });
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  return h;
}

Future<void> _wait(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpScreen(WidgetTester t, _H h, [Widget? home]) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(h.db),
        clockProvider.overrideWithValue(() => DateTime(2026, 1, 1)),
      ],
      child: MaterialApp(
        home: home ?? NotebooksScreen(onOpen: (c, n) => h.opened.add(n.id)),
      ),
    ),
  );
  await _wait(t);
}

Future<void> _seedTree(AppDatabase db) async {
  Future<void> node(
    String id,
    String? parent,
    String subject,
    String title,
    int depth,
    int order, [
    String exam = 'TYT',
  ]) => db
      .into(db.curriculumNodes)
      .insert(
        CurriculumNodesCompanion.insert(
          id: id,
          parentId: Value(parent),
          examType: exam,
          subject: subject,
          title: title,
          aliases: const [],
          depth: depth,
          sortOrder: order,
        ),
      );
  await node('f.u1', null, 'Fizik', 'Hareket', 0, 0);
  await node('f.u1.k1', 'f.u1', 'Fizik', 'Hız', 1, 0);
  await node('f.u1.k2', 'f.u1', 'Fizik', 'İvme', 1, 1);
  await node('f.u2', null, 'Fizik', 'Kuvvet', 0, 1);
  await node('m.u1', null, 'Matematik', 'Sayılar', 0, 0);
}

void main() {
  InkFolderRecord fr(String id, String? parent, [String? name]) =>
      InkFolderRecord(
        id: id,
        parentId: parent,
        name: name ?? id,
        color: 0,
        sortOrder: 0,
        deleted: false,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  test(
    'klasör yardımcıları: çocuklar, seçici sırası, yol, döngü/yetim güvenli',
    () {
      final all = [
        fr('a', null, 'Fizik'),
        fr('b', 'a', 'Mekanik'),
        fr('c', null),
        fr('o', 'yok', 'Yetim'),
      ];
      expect(childFolders(all, null).map((f) => f.id), [
        'a',
        'c',
        'o',
      ]); // yetim kökte
      expect(childFolders(all, 'a').map((f) => f.id), ['b']);
      expect(
        [for (final c in folderChoices(all)) '${c.depth}${c.folder.id}'],
        ['0a', '1b', '0c', '0o'],
      );
      expect(folderCrumbs('b', all).map((f) => f.id), ['a', 'b']);
      expect(folderCrumbs(null, all), isEmpty);
      expect(folderPathLabel('b', all), 'Fizik / Mekanik');
      final loop = [fr('x', 'y'), fr('y', 'x')];
      expect(folderChoices(loop), isEmpty);
      expect(folderCrumbs('x', loop), hasLength(2)); // sonsuz döngüye girmez
    },
  );

  testWidgets('klasör ağacında gezinme, yol çubuğu ve geri tuşu', (t) async {
    final h = await _setup(t);
    late String fizik, mekanik, kok, ic;
    await t.runAsync(() async {
      fizik = await h.folders.createFolder('Fizik');
      mekanik = await h.folders.createFolder('Mekanik', parentId: fizik);
      kok = await h.nbs.createNotebook(title: 'Kökte');
      ic = await h.nbs.createNotebook(title: 'Mekanik defteri');
      await h.nbs.moveNotebookToFolder(ic, mekanik);
    });
    await _pumpScreen(t, h);
    expect(find.byKey(Key('folder-$fizik')), findsOneWidget);
    expect(find.byKey(Key('folder-$mekanik')), findsNothing);
    expect(find.byKey(Key('notebook-$kok')), findsOneWidget);
    expect(find.byKey(Key('notebook-$ic')), findsNothing);
    expect(find.text('0 defter · 1 klasör'), findsOneWidget);

    await t.tap(find.byKey(Key('folder-$fizik')));
    await _wait(t, 2);
    expect(find.byKey(Key('crumb-$fizik')), findsOneWidget);
    expect(find.byKey(Key('folder-$mekanik')), findsOneWidget);
    expect(find.byKey(Key('notebook-$kok')), findsNothing);
    expect(find.text('1 defter'), findsOneWidget);

    await t.tap(find.byKey(Key('folder-$mekanik')));
    await _wait(t, 2);
    expect(find.byKey(Key('notebook-$ic')), findsOneWidget);

    // Geri tuşu bir üst klasöre döner.
    await t.binding.handlePopRoute();
    await _wait(t, 2);
    expect(find.byKey(Key('folder-$mekanik')), findsOneWidget);
    expect(find.byKey(Key('notebook-$ic')), findsNothing);
    // Yoldaki kök bağı ana düzeye döner.
    await t.tap(find.byKey(const Key('crumb-root')));
    await _wait(t, 2);
    expect(find.byKey(Key('folder-$fizik')), findsOneWidget);
  });

  testWidgets(
    'yeni klasör, defteri klasöre taşıma ve arama klasörler boyunca',
    (t) async {
      final h = await _setup(t);
      late String nb;
      await t.runAsync(
        () async => nb = await h.nbs.createNotebook(title: 'Türev notları'),
      );
      await _pumpScreen(t, h);

      await t.tap(find.byKey(const Key('folder-new')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const Key('folder-name-field')),
        'Matematik',
      );
      await t.tap(find.byKey(const Key('folder-dialog-ok')));
      await _wait(t);
      final f = (await t.runAsync(() => h.folders.folders()))!.single;
      expect(f.name, 'Matematik');

      await t.tap(find.byKey(Key('notebook-move-$nb')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('folder-pick-${f.id}')));
      await _wait(t);
      expect((await t.runAsync(() => h.nbs.findNotebook(nb)))!.folderId, f.id);
      expect(find.byKey(Key('notebook-$nb')), findsNothing); // kökten kalktı
      expect(find.text('1 defter'), findsOneWidget);

      // Arama klasör içindeki defteri de bulur ve yolunu gösterir.
      await t.enterText(find.byKey(const Key('notebook-search')), 'türev');
      await _wait(t);
      expect(find.byKey(Key('notebook-$nb')), findsOneWidget);
      expect(find.byKey(Key('notebook-loc-$nb')), findsOneWidget);
      expect(find.text('Matematik'), findsWidgets);
    },
  );

  testWidgets('klasörü kendi altına taşıma reddedilir ve mesaj gösterilir', (
    t,
  ) async {
    final h = await _setup(t);
    late String a, b;
    await t.runAsync(() async {
      a = await h.folders.createFolder('Ust');
      b = await h.folders.createFolder('Alt', parentId: a);
    });
    await _pumpScreen(t, h);
    await t.tap(find.byKey(Key('folder-more-$a')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('folder-act-move')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('folder-pick-$b')));
    await _wait(t);
    expect(find.text('Klasör kendi altına taşınamaz.'), findsOneWidget);
    expect((await t.runAsync(() => h.folders.findFolder(a)))!.parentId, isNull);
  });

  testWidgets(
    'klasör silme: onay uyarısı, içindekiler üst düzeye çıkar, Silinenler\'den geri gelir',
    (t) async {
      final h = await _setup(t);
      late String f, nb;
      await t.runAsync(() async {
        f = await h.folders.createFolder('Kimya');
        nb = await h.nbs.createNotebook(title: 'Organik');
        await h.nbs.moveNotebookToFolder(nb, f);
      });
      await _pumpScreen(t, h);
      await t.tap(find.byKey(Key('folder-more-$f')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('folder-act-delete')));
      await t.pumpAndSettle();
      expect(
        find.textContaining('1 defter SİLİNMEZ; bir üst düzeye çıkar'),
        findsOneWidget,
      );
      await t.tap(find.byKey(const Key('folder-delete-confirm')));
      await _wait(t);
      expect(find.byKey(Key('folder-$f')), findsNothing);
      expect(find.byKey(Key('notebook-$nb')), findsOneWidget); // kökte
      expect(
        (await t.runAsync(() => h.nbs.findNotebook(nb)))!.folderId,
        isNull,
      );

      await t.tap(find.byKey(const Key('notebook-show-deleted')));
      await _wait(t);
      expect(find.byKey(Key('folder-restore-$f')), findsOneWidget);
      await t.tap(find.byKey(Key('folder-restore-$f')));
      await _wait(t);
      expect(find.byKey(Key('folder-$f')), findsOneWidget);
    },
  );

  testWidgets(
    'konu ağacından defter: onay özeti, klasör, ikinci çağrıda çiftleme yok',
    (t) async {
      final h = await _setup(t);
      await t.runAsync(() => _seedTree(h.db));
      await _pumpScreen(t, h);

      await t.tap(find.byKey(const Key('curriculum-notebook-new')));
      await _wait(t, 4);
      await t.tap(find.byKey(const Key('curr-subject-Fizik')));
      await t.pumpAndSettle();
      // kapak + 2 ünite + 2 konu = 5
      expect(
        find.textContaining(
          '5 sayfa oluşturulacak: ders kapağı, 2 ünite, 2 konu',
        ),
        findsOneWidget,
      );
      expect(find.text('Konu: Hız'), findsOneWidget);
      await t.tap(find.byKey(const Key('curr-ok')));
      await _wait(t, 12);

      expect(h.opened, hasLength(1));
      final nb = (await t.runAsync(() => h.nbs.findNotebook(h.opened.single)))!;
      expect(nb.title, 'TYT Fizik');
      final folder = (await t.runAsync(
        () => h.folders.findFolder(nb.folderId!),
      ))!;
      expect(folder.name, 'Fizik');
      expect(
        await t.runAsync(() => h.board.pagesForKonu('f.u1.k1')),
        hasLength(1),
      );

      // İkinci kez: yeni defter açılmaz, "Zaten var: aç" önerilir.
      await t.tap(find.byKey(const Key('curriculum-notebook-new')));
      await _wait(t, 4);
      await t.tap(find.byKey(const Key('curr-subject-Fizik')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('curr-ok')));
      await _wait(t, 8);
      expect(find.text('Zaten var: aç'), findsOneWidget);
      await t.tap(find.byKey(const Key('curr-open-existing')));
      await _wait(t, 4);
      expect(h.opened, [nb.id, nb.id]);
      expect((await t.runAsync(() => h.nbs.notebooks()))!, hasLength(1));
      expect(
        (await t.runAsync(() => h.folders.folders()))!,
        hasLength(1),
      ); // ikinci klasör de açılmadı
    },
  );

  testWidgets(
    'sayfa bilgisi: başlık ve konu kaydedilir, yol ve sayı görünür, kaldırılır',
    (t) async {
      final h = await _setup(t);
      late String nbId, pid;
      await t.runAsync(() async {
        await _seedTree(h.db);
        nbId = await h.nbs.createNotebook(title: 'D');
        pid = (await h.nbs.pages(nbId)).first.id;
      });
      final page = (await t.runAsync(() => h.nbs.findPage(pid)))!;
      await _pumpScreen(
        t,
        h,
        Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () async =>
                  showPageInfoSheet(c, (await h.nbs.findPage(page.id))!),
              child: const Text('aç'),
            ),
          ),
        ),
      );
      await t.tap(find.text('aç'));
      await t.pumpAndSettle();
      expect(find.text('Bu sayfa bir konuya bağlı değil.'), findsOneWidget);
      await t.enterText(find.byKey(const Key('pageinfo-title')), 'Hız notları');
      await t.tap(find.byKey(const Key('pageinfo-konu-pick')));
      await _wait(t, 4);
      await t.enterText(find.byKey(const Key('konu-search')), 'hız');
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('konu-f.u1.k1')));
      await _wait(t, 4);
      expect(find.text('TYT Fizik › Hareket › Hız'), findsOneWidget);
      expect((await t.runAsync(() => h.board.konuOfPage(pid))), 'f.u1.k1');
      await t.tap(find.byKey(const Key('pageinfo-save')));
      await _wait(t, 4);
      final saved = (await t.runAsync(() => h.nbs.findPage(pid)))!;
      expect((saved.title, saved.konuId), ('Hız notları', 'f.u1.k1'));

      // Konu seçicide sayfa sayısı ve bağı kaldırma.
      await t.tap(find.text('aç'));
      await _wait(t, 3);
      expect(find.text('TYT Fizik › Hareket › Hız'), findsOneWidget);
      await t.tap(find.byKey(const Key('pageinfo-konu-clear')));
      await _wait(t, 3);
      expect((await t.runAsync(() => h.board.konuOfPage(pid))), isNull);
    },
  );

  testWidgets(
    'konuya göre görünüm: konu seç, eşli sayfalar listelenir, dokununca açılır',
    (t) async {
      final h = await _setup(t);
      late String nb;
      await t.runAsync(() async {
        await _seedTree(h.db);
        nb = await h.nbs.createNotebook(title: 'Fizik defterim');
        final p = (await h.nbs.pages(nb)).first.id;
        await h.board.setPageKonu(p, 'f.u1.k1');
        await h.nbs.setPageTitle(p, 'Hız özeti');
      });
      await _pumpScreen(t, h);
      await t.tap(find.text('Konuya göre'));
      await _wait(t, 2);
      await t.tap(find.byKey(const Key('bykonu-pick')));
      await _wait(t, 4);
      expect(find.byKey(const Key('konu-count-f.u1.k1')), findsOneWidget);
      expect(find.text('1 sayfa'), findsOneWidget);
      await t.tap(find.byKey(const Key('konu-f.u1.k1')));
      await _wait(t, 4);
      expect(find.text('Fizik defterim'), findsOneWidget);
      expect(find.text('Sayfa 1 · Hız özeti'), findsOneWidget);
      await t.tap(find.text('Fizik defterim'));
      expect(h.opened, [nb]);
    },
  );

  testWidgets('sayfa şeridi etiketi: başlık ve konu rozeti', (t) async {
    final h = await _setup(t);
    late InkNotePageRecord p;
    await t.runAsync(() async {
      final nb = await h.nbs.createNotebook(title: 'D');
      final id = (await h.nbs.pages(nb)).first.id;
      await h.nbs.setPageTitle(id, 'Başlık');
      await h.board.setPageKonu(id, 'f.u1');
      p = (await h.nbs.findPage(id))!;
    });
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageStripLabel(page: p, number: 3)),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    expect(find.byKey(Key('note-thumb-title-${p.id}')), findsOneWidget);
    expect(find.byKey(Key('note-thumb-konu-${p.id}')), findsOneWidget);
  });

  testWidgets(
    'telefon düzeni (360 dp): taşma yok, defter menüsü ve klasör kartı çalışır',
    (t) async {
      final h = await _setup(t, size: const Size(360, 740));
      late String f, nb;
      await t.runAsync(() async {
        f = await h.folders.createFolder(
          'Çok uzun bir klasör adı burada duruyor',
        );
        nb = await h.nbs.createNotebook(
          title: 'Çok uzun bir defter adı burada duruyor ve taşmamalı',
        );
      });
      await _pumpScreen(t, h);
      expect(find.byKey(Key('notebook-more-$nb')), findsOneWidget);
      expect(find.byKey(Key('notebook-rename-$nb')), findsNothing);
      await t.tap(find.byKey(Key('notebook-more-$nb')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('nb-act-move')), findsOneWidget);
      await t.tap(find.byKey(const Key('nb-act-move')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(Key('folder-pick-$f')));
      await _wait(t);
      expect((await t.runAsync(() => h.nbs.findNotebook(nb)))!.folderId, f);
      await t.tap(find.byKey(Key('folder-$f')));
      await _wait(t, 2);
      expect(find.byKey(Key('notebook-$nb')), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
