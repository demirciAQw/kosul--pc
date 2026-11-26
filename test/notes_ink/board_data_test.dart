import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/database/health_tables.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/notes/data/curriculum_notebook_service.dart';
import 'package:kocum/features/notes/data/ink_board_repository.dart';
import 'package:kocum/features/notes/data/ink_folder_repository.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/data/ink_page_item_repository.dart';
import 'package:kocum/features/notes/data/page_image_store.dart';
import 'package:kocum/features/notes/domain/page_board.dart';
import 'package:kocum/features/sync/domain/ledger_protocol.dart' show mediaPathsIn;
import 'package:kocum/features/notes/domain/page_item_geometry.dart';

class _Ids implements IdGenerator {
  _Ids([this.p = 'i']);
  final String p;
  var n = 0;

  /// Bu sıradaki (0'dan) çağrıda hata fırlatır; null = hiç.
  int? failAt;
  @override
  String next() {
    if (failAt != null && n == failAt) throw StateError('kimlik üretilemedi');
    return '$p${(n++).toString().padLeft(3, '0')}';
  }
}

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

class _FakeStorage implements MediaStorage {
  _FakeStorage(this.root);
  final Directory root;
  var n = 0;
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async {
    final rel = '$bucket/2026/11/dosya-${n++}${sourcePath.substring(sourcePath.lastIndexOf('.'))}';
    final f = resolve(rel)..parent.createSync(recursive: true);
    await File(sourcePath).copy(f.path);
    return rel;
  }

  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');
  @override
  Future<void> delete(String relativePath) async => throw StateError('görsel dosyası silinmemeli');
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

class _FakeEncoder implements PageImageEncoder {
  int? seenMax;
  @override
  Future<EncodedPageImage> encode(Uint8List source, {int maxSide = 2048}) async {
    seenMax = maxSide;
    return EncodedPageImage(Uint8List.fromList([...source, 1]), 4000, 3000);
  }
}

void main() {
  late AppDatabase db;
  late _Ids ids;
  late InkNotebookRepository nbs;
  late InkBoardRepository board;
  late InkFolderRepository folders;
  late InkPageItemRepository items;
  var tick = 0;
  DateTime clock() => DateTime(2026, 1, 1).add(Duration(minutes: tick++));

  setUp(() async {
    db = await _open();
    tick = 0;
    ids = _Ids();
    nbs = InkNotebookRepository(db, ids: ids, clock: clock);
    board = InkBoardRepository(db, ids: ids, clock: clock, notebooks: nbs);
    folders = InkFolderRepository(db, ids: ids, clock: clock);
    items = InkPageItemRepository(db, ids: ids, clock: clock);
  });

  Future<String> firstPage(String nb) async => (await nbs.pages(nb)).first.id;

  group('klasörler', () {
    test('ağaç, yeniden adlandırma, renk, sıra ve defter sayısı', () async {
      final a = await folders.createFolder('  Fizik ');
      final b = await folders.createFolder('Kimya');
      final a1 = await folders.createFolder('Optik', parentId: a);
      expect((await folders.folders(parentId: null, onlyChildrenOf: true)).map((f) => f.name), ['Fizik', 'Kimya']);
      expect((await folders.folders(parentId: a, onlyChildrenOf: true)).single.id, a1);
      await folders.renameFolder(b, 'Kimya 2');
      await folders.setFolderColor(b, 0xFF00FF00);
      expect((await folders.findFolder(b))!.name, 'Kimya 2');
      expect((await folders.findFolder(b))!.color, 0xFF00FF00);
      await folders.reorderFolders(null, [b, a]);
      expect((await folders.folders(parentId: null, onlyChildrenOf: true)).map((f) => f.id), [b, a]);
      expect(() => folders.reorderFolders(null, [a]), throwsArgumentError);
      final nb = await nbs.createNotebook(title: 'Elektrik');
      await nbs.moveNotebookToFolder(nb, a1);
      expect((await nbs.findNotebook(nb))!.folderId, a1);
      expect((await folders.findFolder(a1))!.notebookCount, 1);
      expect((await folders.pathOf(a1)).map((f) => f.id), [a, a1]);
      await nbs.moveNotebookToFolder(nb, null);
      expect((await folders.findFolder(a1))!.notebookCount, 0);
      expect(() => nbs.moveNotebookToFolder(nb, 'yok'), throwsStateError);
      expect(() => folders.createFolder('x', parentId: 'yok'), throwsStateError);
    });

    test('taşıma: kendi altına ve torununun altına reddedilir; geçerli taşıma sona ekler', () async {
      final a = await folders.createFolder('A');
      final b = await folders.createFolder('B', parentId: a);
      final c = await folders.createFolder('C', parentId: b);
      final d = await folders.createFolder('D');
      expect(() => folders.moveFolder(a, a), throwsArgumentError);
      expect(() => folders.moveFolder(a, c), throwsArgumentError);
      await folders.moveFolder(c, d);
      expect((await folders.findFolder(c))!.parentId, d);
      await folders.moveFolder(c, null);
      expect((await folders.findFolder(c))!.parentId, isNull);
      expect((await folders.folders(parentId: null, onlyChildrenOf: true)).last.id, c);
      // Taşıma reddedilince hiçbir şey değişmedi.
      expect((await folders.findFolder(a))!.parentId, isNull);
    });

    test('yumuşak sil: defterler ve alt klasörler ebeveyne çıkar, kaybolmaz; geri al', () async {
      final a = await folders.createFolder('A');
      final b = await folders.createFolder('B', parentId: a);
      final sub = await folders.createFolder('B-alt', parentId: b);
      final nb = await nbs.createNotebook(title: 'Not');
      await nbs.moveNotebookToFolder(nb, b);
      await folders.deleteFolder(b);
      expect((await folders.findFolder(b))!.deleted, isTrue);
      expect((await nbs.findNotebook(nb))!.folderId, a);
      expect((await folders.findFolder(sub))!.parentId, a);
      expect((await folders.folders()).map((f) => f.id), isNot(contains(b)));
      await folders.restoreFolder(b);
      expect((await folders.findFolder(b))!.deleted, isFalse);
      expect((await folders.findFolder(b))!.parentId, a);
      // Ebeveyni de silinmişse köke gelir.
      await folders.deleteFolder(b);
      await folders.deleteFolder(a);
      await folders.restoreFolder(b);
      expect((await folders.findFolder(b))!.parentId, isNull);
      expect(() => folders.createFolder('x', parentId: a), throwsStateError);
    });

    test('akış: klasör ve defter sayısı değişince yeni liste gelir', () async {
      final a = await folders.createFolder('A');
      final seen = <int>[];
      final sub = folders.watchFolders().listen((l) => seen.add(l.single.notebookCount));
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final nb = await nbs.createNotebook();
      await nbs.moveNotebookToFolder(nb, a);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last, 1);
    });
  });

  group('sayfa başlığı ve konu', () {
    test('başlık: kırpılır, boş null olur; konu eşle/kaldır; pagesForKonu silinmişleri saymaz', () async {
      final nb = await nbs.createNotebook();
      final p1 = await firstPage(nb);
      final p2 = await nbs.addPage(nb);
      await nbs.setPageTitle(p1, '  Vektörler ');
      expect((await nbs.findPage(p1))!.title, 'Vektörler');
      await nbs.setPageTitle(p1, '   ');
      expect((await nbs.findPage(p1))!.title, isNull);

      await board.setPageKonu(p1, 'tyt.fiz.vektor');
      await board.setPageKonu(p2, 'tyt.fiz.vektor');
      expect(await board.konuOfPage(p1), 'tyt.fiz.vektor');
      expect((await board.pagesForKonu('tyt.fiz.vektor')).map((p) => p.id), [p1, p2]);
      await nbs.deletePage(p2);
      expect((await board.pagesForKonu('tyt.fiz.vektor')).map((p) => p.id), [p1]);
      await board.clearPageKonu(p1);
      expect(await board.konuOfPage(p1), isNull);
      expect(await board.pagesForKonu('tyt.fiz.vektor'), isEmpty);
      expect(() => board.setPageKonu('yok', 'x'), throwsStateError);
      expect(() => board.konuOfPage('yok'), throwsStateError);
      // Silinmiş defterdeki sayfa konu listesinde görünmez.
      await board.setPageKonu(p1, 'k2');
      await nbs.deleteNotebook(nb);
      expect(await board.pagesForKonu('k2'), isEmpty);
    });
  });

  group('Pano', () {
    test('toplu konum tek işlem; yok olan sayfada hiçbiri yazılmaz; akış', () async {
      final nb = await nbs.createNotebook();
      final a = await firstPage(nb);
      final b = await nbs.addPage(nb);
      final seen = <List<BoardCard>>[];
      final sub = board.watchBoardCards(nb).listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await board.boardCards(nb)).every((c) => !c.placed), isTrue);

      await board.setBoardPositions({a: const BoardRect(10, 20, 320, 420), b: const BoardRect(500, 20, 300, 400)});
      final cards = {for (final c in await board.boardCards(nb)) c.pageId: c};
      expect((cards[a]!.x, cards[a]!.y, cards[a]!.w, cards[a]!.h), (10.0, 20.0, 320.0, 420.0));
      expect(cards[b]!.rect(), const BoardRect(500, 20, 300, 400));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last.first.placed, isTrue);

      final before = (await db.select(db.degisiklikler).get()).length;
      await board.setBoardPositions({a: const BoardRect(10, 20, 320, 420)}); // aynı: yazılmaz
      expect((await db.select(db.degisiklikler).get()).length, before);

      await expectLater(
        board.setBoardPositions({a: const BoardRect(99, 99, 320, 420), 'yok': const BoardRect(0, 0, 1, 1)}),
        throwsStateError,
      );
      expect((await board.boardCards(nb)).firstWhere((c) => c.pageId == a).x, 10.0); // geri alındı
      expect(() => board.setBoardPositions({a: const BoardRect(0, 0, 0, 5)}), throwsArgumentError);
    });

    test('arrangeNotebook: bağlantılı ağaç + bağsız ızgara, çakışma yok', () async {
      final nb = await nbs.createNotebook();
      final a = await firstPage(nb);
      final b = await nbs.addPage(nb);
      final c = await nbs.addPage(nb);
      await nbs.addPage(nb);
      await board.addLink(a, b);
      await board.addLink(a, c);
      await board.arrangeNotebook(nb);
      final rects = [for (final k in await board.boardCards(nb)) k.rect()!];
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse);
        }
      }
    });
  });

  group('bağlantılar', () {
    test('ekle, aynı yönü tekrar ekleme, etiket/renk, yumuşak sil/geri al, sayfa silinince gizlenir', () async {
      final nb = await nbs.createNotebook();
      final a = await firstPage(nb);
      final b = await nbs.addPage(nb);
      final c = await nbs.addPage(nb);
      final l1 = await board.addLink(a, b, label: ' neden ');
      expect(await board.addLink(a, b), l1); // çapasız tekrar eklenmez
      final l2 = await board.addLink(b, a); // ters yön ayrı
      final l3 = await board.addLink(a, c, kind: PageLinkKind.konu);
      expect((await board.links(nb)).map((l) => l.id), [l1, l2, l3]);
      expect((await board.findLink(l1))!.label, 'neden');
      await board.setLinkLabel(l1, 'sonuç');
      await board.setLinkColor(l1, 0xFFFF0000);
      await board.setLinkAnchor(l1, 10, 20);
      final l = (await board.findLink(l1))!;
      expect((l.label, l.color, l.fromX, l.fromY, l.kind), ('sonuç', 0xFFFF0000, 10.0, 20.0, PageLinkKind.link));
      await board.deleteLink(l2);
      expect((await board.links(nb)).map((x) => x.id), [l1, l3]);
      expect((await board.findLink(l2))!.deleted, isTrue); // veri duruyor
      await board.restoreLink(l2);
      expect(await board.links(nb), hasLength(3));
      await nbs.deletePage(c);
      expect((await board.links(nb)).map((x) => x.id), isNot(contains(l3)));
      await nbs.restorePage(c);
      expect(await board.links(nb), hasLength(3));
      expect((await board.linksFrom(a)).map((x) => x.id), [l1, l3]);
      expect(() => board.deleteLink('yok'), throwsStateError);
    });

    test('kendine, başka defterin sayfasına ve yok sayfaya bağlantı reddedilir', () async {
      final n1 = await nbs.createNotebook();
      final n2 = await nbs.createNotebook();
      final a = await firstPage(n1), x = await firstPage(n2);
      expect(() => board.addLink(a, a), throwsArgumentError);
      expect(() => board.addLink(a, x), throwsArgumentError);
      expect(() => board.addLink(a, 'yok'), throwsStateError);
      expect(await db.select(db.inkPageLinks).get(), isEmpty);
    });

    test('akış: bağlantı eklenince gelir', () async {
      final nb = await nbs.createNotebook();
      final a = await firstPage(nb);
      final b = await nbs.addPage(nb);
      final seen = <int>[];
      final sub = board.watchLinks(nb).listen((l) => seen.add(l.length));
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await board.addLink(a, b);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last, 1);
    });
  });

  group('alt sayfa', () {
    test('tek işlemde sayfa + parentPageId + çapalı child bağlantısı; ebeveynin yanına yerleşir', () async {
      final nb = await nbs.createNotebook();
      final p = await firstPage(nb);
      await nbs.setPageSize(p, 1000, 1500);
      await board.setBoardPositions({p: const BoardRect(0, 0, 320, 420)});
      final child = await board.createChildPage(p, 120, 340);
      final pg = (await nbs.findPage(child))!;
      expect((pg.notebookId, pg.parentPageId, pg.width, pg.height), (nb, p, 1000.0, 1500.0));
      expect(pg.boardX, greaterThan(320));
      final l = (await board.links(nb)).single;
      expect((l.kind, l.fromPageId, l.toPageId, l.fromX, l.fromY), (PageLinkKind.child, p, child, 120.0, 340.0));
      expect((await board.childPages(p)).single.id, child);
      // İkinci alt sayfa birincinin üstüne binmez.
      final second = await board.createChildPage(p, 1, 2);
      final r1 = (await board.boardCards(nb)).firstWhere((c) => c.pageId == child).rect()!;
      final r2 = (await board.boardCards(nb)).firstWhere((c) => c.pageId == second).rect()!;
      expect(r1.overlaps(r2), isFalse);
    });

    test('ebeveyn panoda yerleşmemişse alt sayfa da yerleşmemiş kalır', () async {
      final nb = await nbs.createNotebook();
      final child = await board.createChildPage(await firstPage(nb), 5, 6);
      expect((await nbs.findPage(child))!.boardX, isNull);
    });

    test('yarım kalırsa yetim sayfa YOK (bağlantı adımı hata verir -> hepsi geri alınır)', () async {
      final nb = await nbs.createNotebook();
      final p = await firstPage(nb);
      final pagesBefore = (await nbs.pages(nb, includeDeleted: true)).length;
      final changesBefore = (await db.select(db.degisiklikler).get()).length;
      ids.failAt = ids.n + 1; // 1. kimlik sayfa, 2. kimlik bağlantı
      await expectLater(board.createChildPage(p, 1, 2), throwsStateError);
      ids.failAt = null;
      expect((await nbs.pages(nb, includeDeleted: true)).length, pagesBefore);
      expect(await db.select(db.inkPageLinks).get(), isEmpty);
      expect((await db.select(db.degisiklikler).get()).length, changesBefore);
      expect((await nbs.findNotebook(nb))!.pageCount, 1);
    });

    test('silinmiş ya da yok sayfanın alt sayfası olmaz', () async {
      final nb = await nbs.createNotebook();
      final a = await firstPage(nb);
      await nbs.addPage(nb);
      await nbs.deletePage(a);
      expect(() => board.createChildPage(a, 0, 0), throwsStateError);
      expect(() => board.createChildPage('yok', 0, 0), throwsStateError);
    });
  });

  group('sayfa öğeleri', () {
    test('metin ve görsel ekle, güncelle, z sırası, yumuşak sil/geri al', () async {
      final nb = await nbs.createNotebook();
      final p = await firstPage(nb);
      final t = await items.addText(p, const BoardRect(10, 10, 300, 100), payload: const TextItemPayload(text: 'merhaba', bold: true));
      final img = await items.addImage(p, const BoardRect(50, 200, 400, 300), 'notes/2026/11/foto-1.webp', payload: const ImageItemPayload(pxW: 800, pxH: 600));
      var list = await items.items(p);
      expect(list.map((i) => i.id), [t, img]);
      expect((list[0].kind, list[0].text.text, list[0].text.bold, list[0].z), (PageItemKind.text, 'merhaba', true, 0));
      expect((list[1].kind, list[1].mediaPath, list[1].image.pxW, list[1].z), (PageItemKind.image, 'notes/2026/11/foto-1.webp', 800, 1));

      await items.updateText(t, const TextItemPayload(text: 'değişti', fontSize: 50));
      await items.updateGeometry(t, rect: const BoardRect(20, 30, 310, 110), rotation: 0.5);
      await items.updateImage(img, const ImageItemPayload(pxW: 800, pxH: 600, alpha: 0.4));
      await items.bringToFront(t);
      list = await items.items(p);
      expect(list.map((i) => i.id), [img, t]);
      final tt = (await items.findItem(t))!;
      expect((tt.text.text, tt.text.fontSize, tt.x, tt.y, tt.w, tt.h, tt.rotation), ('değişti', 50.0, 20.0, 30.0, 310.0, 110.0, 0.5));
      expect((await items.findItem(img))!.image.alpha, 0.4);
      final z = tt.z;
      await items.bringToFront(t); // zaten üstte: dokunmaz
      expect((await items.findItem(t))!.z, z);

      await items.deleteItem(img);
      expect((await items.items(p)).map((i) => i.id), [t]);
      expect(await items.items(p, includeDeleted: true), hasLength(2));
      await items.restoreItem(img);
      expect(await items.items(p), hasLength(2));
      expect(await items.mediaReferenceCount('notes/2026/11/foto-1.webp'), 1);
      await items.deleteItem(img);
      expect(await items.isMediaReferenced('notes/2026/11/foto-1.webp'), isTrue); // silinmiş öğe de sayılır
    });

    test('doğrulama: kötü yol, geçersiz kutu, tür uyuşmazlığı, yok sayfa/öğe', () async {
      final nb = await nbs.createNotebook();
      final p = await firstPage(nb);
      for (final bad in ['../x.png', 'questions/2026/11/a.webp', '/notes/2026/11/a.webp', 'notes/2026/11/a/b.webp']) {
        expect(() => items.addImage(p, const BoardRect(0, 0, 10, 10), bad), throwsArgumentError, reason: bad);
      }
      expect(() => items.addText(p, const BoardRect(0, 0, 0, 10)), throwsArgumentError);
      expect(() => items.addText('yok', const BoardRect(0, 0, 10, 10)), throwsStateError);
      final t = await items.addText(p, const BoardRect(0, 0, 10, 10));
      final i = await items.addImage(p, const BoardRect(0, 0, 10, 10), 'notes/2026/11/a.webp');
      expect(() => items.updateText(i, const TextItemPayload()), throwsStateError);
      expect(() => items.updateImage(t, const ImageItemPayload()), throwsStateError);
      expect(() => items.deleteItem('yok'), throwsStateError);
      expect(await db.select(db.inkPageItems).get(), hasLength(2)); // hatalılar yazılmadı
    });

    test('toplu geometri tek işlem; akış', () async {
      final nb = await nbs.createNotebook();
      final p = await firstPage(nb);
      final a = await items.addText(p, const BoardRect(0, 0, 10, 10));
      final b = await items.addText(p, const BoardRect(0, 0, 10, 10));
      final seen = <int>[];
      final sub = items.watchItems(p).listen((l) => seen.add(l.length));
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await items.updateGeometries({a: const BoardRect(5, 5, 20, 20), b: const BoardRect(7, 7, 30, 30)});
      await expectLater(items.updateGeometries({a: const BoardRect(100, 100, 20, 20), 'yok': const BoardRect(1, 1, 1, 1)}), throwsStateError);
      expect((await items.findItem(a))!.x, 5.0); // ikincisi hata verdi: birincisi geri alındı
      expect((await items.findItem(b))!.w, 30.0);
      await items.addText(p, const BoardRect(0, 0, 10, 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen.last, 3);
    });

    test('sayfa çoğaltma: öğeler (silinmişler hariç) ve başlık kopyalanır, görsel dosyası paylaşılır, konu/Pano kopyalanmaz', () async {
      final nb = await nbs.createNotebook();
      final p = await firstPage(nb);
      await nbs.setPageTitle(p, 'Kuvvet');
      await board.setPageKonu(p, 'k1');
      await board.setBoardPositions({p: const BoardRect(1, 2, 320, 420)});
      await items.addText(p, const BoardRect(1, 1, 50, 50), payload: const TextItemPayload(text: 'bir'));
      final gone = await items.addText(p, const BoardRect(1, 1, 50, 50), payload: const TextItemPayload(text: 'silinen'));
      await items.addImage(p, const BoardRect(9, 9, 50, 50), 'notes/2026/11/ortak.webp');
      await items.deleteItem(gone);

      final copy = await nbs.duplicatePage(p);
      final its = await items.items(copy);
      expect(its.map((i) => i.kind), [PageItemKind.text, PageItemKind.image]);
      expect(its.first.text.text, 'bir');
      expect(its.last.mediaPath, 'notes/2026/11/ortak.webp');
      expect(await items.mediaReferenceCount('notes/2026/11/ortak.webp'), 2);
      expect(its.map((i) => i.id).toSet().intersection((await items.items(p)).map((i) => i.id).toSet()), isEmpty);
      final cp = (await nbs.findPage(copy))!;
      expect((cp.title, cp.konuId, cp.boardX, cp.parentPageId), ('Kuvvet', null, null, null));
      expect(await items.items(p), hasLength(2)); // özgün bozulmadı
    });
  });

  group('konu ağacından defter', () {
    Future<void> seed() async {
      Future<void> node(String id, String? parent, String subject, String title, int depth, int order, [String exam = 'TYT']) =>
          db.into(db.curriculumNodes).insert(CurriculumNodesCompanion.insert(
                id: id, parentId: Value(parent), examType: exam, subject: subject, title: title, aliases: const [], depth: depth, sortOrder: order));
      await node('f.u1', null, 'Fizik', 'Hareket', 0, 0);
      await node('f.u1.k1', 'f.u1', 'Fizik', 'Hız', 1, 0);
      await node('f.u1.k2', 'f.u1', 'Fizik', 'İvme', 1, 1);
      await node('f.u1.k1.kz', 'f.u1.k1', 'Fizik', 'Kazanım', 2, 0);
      await node('f.u2', null, 'Fizik', 'Kuvvet', 0, 1);
      await node('m.u1', null, 'Matematik', 'Sayılar', 0, 0);
      await node('ayt.f.u1', null, 'Fizik', 'AYT Elektrik', 0, 0, 'AYT');
    }

    late CurriculumNotebookService svc;
    setUp(() => svc = CurriculumNotebookService(db, nbs, board));

    test('ders için kapak + ünite + konu sayfaları, başlık/konuId, bağlantılar, çakışmasız Pano', () async {
      await seed();
      final r = await svc.createNotebookFromCurriculum(examType: 'TYT', subject: 'Fizik');
      expect(r.created, isTrue);
      final nb = (await nbs.findNotebook(r.notebookId))!;
      expect(nb.title, 'TYT Fizik');
      final pages = await nbs.pages(r.notebookId);
      expect(pages, hasLength(5)); // kapak + 2 ünite + 2 konu; kazanım (derinlik 2) sayfa değil
      expect(pages.first.title, 'TYT Fizik');
      expect(pages.first.konuId, isNull);
      final byKonu = {for (final p in pages) if (p.konuId != null) p.konuId!: p};
      expect(byKonu.keys.toSet(), {'f.u1', 'f.u1.k1', 'f.u1.k2', 'f.u2'});
      expect(byKonu['f.u1.k1']!.title, 'Hız');
      expect((await board.pagesForKonu('f.u1.k2')).single.id, byKonu['f.u1.k2']!.id);
      // bağlantılar: kapak->2 ünite, ünite->2 konu
      final links = await board.links(r.notebookId);
      expect(links, hasLength(4));
      expect(links.every((l) => l.kind == PageLinkKind.konu), isTrue);
      expect(links.where((l) => l.fromPageId == pages.first.id), hasLength(2));
      expect(links.where((l) => l.fromPageId == byKonu['f.u1']!.id).map((l) => l.toPageId).toSet(), {byKonu['f.u1.k1']!.id, byKonu['f.u1.k2']!.id});
      // Pano: hepsi yerleşmiş, çakışma yok, kapak en üstte
      final cards = await board.boardCards(r.notebookId);
      expect(cards.every((c) => c.placed), isTrue);
      final rects = [for (final c in cards) c.rect()!];
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          expect(rects[i].overlaps(rects[j]), isFalse);
        }
      }
      expect(cards.first.y, 0);
      expect(byKonu['f.u1.k1']!.boardY, greaterThan(byKonu['f.u1']!.boardY!));
      // Sınav ayrı: AYT Fizik başka ders sayılır (TYT defteri onu kapsamaz).
      expect(byKonu.containsKey('ayt.f.u1'), isFalse);
    });

    test('aynı ders tekrar çağrılınca mevcut defter döner, çiftleme yok; silinince yenisi kurulur', () async {
      await seed();
      final a = await svc.createNotebookFromCurriculum(nodeId: 'f.u1.k1');
      final b = await svc.createNotebookFromCurriculum(examType: 'TYT', subject: 'Fizik');
      expect((b.created, b.notebookId), (false, a.notebookId));
      expect(await nbs.notebooks(), hasLength(1));
      await nbs.deleteNotebook(a.notebookId);
      final c = await svc.createNotebookFromCurriculum(nodeId: 'f.u2');
      expect((c.created, c.notebookId == a.notebookId), (true, false));
      // Başka ders etkilenmez.
      final m = await svc.createNotebookFromCurriculum(subject: 'Matematik');
      expect(m.created, isTrue);
      expect(await nbs.pages(m.notebookId), hasLength(2));
    });

    test('klasörle, belirsiz ders, bilinmeyen ders; derinlik sınırı; hata olursa defter kalmaz', () async {
      await seed();
      final f = await folders.createFolder('Fizik');
      final r = await svc.createNotebookFromCurriculum(nodeId: 'f.u1', folderId: f, maxDepth: 0);
      expect((await nbs.findNotebook(r.notebookId))!.folderId, f);
      expect(await nbs.pages(r.notebookId), hasLength(3)); // kapak + 2 ünite
      await expectLater(svc.createNotebookFromCurriculum(subject: 'Fizik'), throwsArgumentError); // TYT ve AYT var
      await expectLater(svc.createNotebookFromCurriculum(subject: 'Yok'), throwsStateError);
      await expectLater(svc.createNotebookFromCurriculum(nodeId: 'yok'), throwsStateError);
      await expectLater(svc.createNotebookFromCurriculum(subject: 'Matematik', folderId: 'yok-klasör'), throwsStateError);
      expect((await nbs.notebooks()).map((n) => n.title), ['TYT Fizik']); // Matematik defteri yarım kalmadı
      expect(await db.select(db.inkNotePages).get(), hasLength(3));
    });
  });

  group('görsel deposu', () {
    test('küçültür, notes/yyyy/mm/ad.uzantı yoluna yazar, geçici dosyayı siler, dosyayı SİLMEZ', () async {
      final root = await Directory.systemTemp.createTemp('gorsel_depo');
      final tmp = await Directory.systemTemp.createTemp('gorsel_tmp');
      addTearDown(() async {
        await root.delete(recursive: true);
        await tmp.delete(recursive: true);
      });
      final enc = _FakeEncoder();
      final store = PageImageStore(_FakeStorage(root), encoder: enc, tempDir: tmp);
      final r = await store.saveBytes(Uint8List.fromList([7, 8, 9]));
      expect(enc.seenMax, 2048);
      expect(isPageImagePath(r.path), isTrue);
      expect(r.path, startsWith('notes/2026/11/'));
      expect((r.pxW, r.pxH), (2048, 1536)); // 4000x3000 -> en uzun kenar 2048
      expect(await store.resolve(r.path).readAsBytes(), [7, 8, 9, 1]);
      expect(tmp.listSync(), isEmpty);
      // Depo hiçbir dosyayı silmez; öğe silinince de dosya yerinde kalır.
      final nb = await nbs.createNotebook();
      final id = await items.addImage(await firstPage(nb), const BoardRect(0, 0, 100, 100), r.path);
      await items.deleteItem(id);
      expect(store.resolve(r.path).existsSync(), isTrue);
      // Dosyadan kaydetme.
      final src = File('${tmp.path}/kaynak.png')..writeAsBytesSync([1, 2]);
      final r2 = await store.saveFile(src.path);
      expect(r2.path, isNot(r.path));
      expect(src.existsSync(), isTrue); // kaynağa dokunulmaz
    });

    test('ortak medya kuralına uymayan yolu üreten depo reddedilir', () async {
      final root = await Directory.systemTemp.createTemp('gorsel_depo2');
      final tmp = await Directory.systemTemp.createTemp('gorsel_tmp2');
      addTearDown(() async {
        await root.delete(recursive: true);
        await tmp.delete(recursive: true);
      });
      final store = PageImageStore(_BadStorage(root), encoder: _FakeEncoder(), tempDir: tmp);
      await expectLater(store.saveBytes(Uint8List.fromList([1])), throwsStateError);
      expect(tmp.listSync(), isEmpty);
    });
  });

  group('ledger, birleştirici, CLI', () {
    test('klasör + bağlantı + öğe iki cihaza geçer; yumuşak silme de; geri alma çalışır', () async {
      final b = await _open('pc');
      final la = LedgerService(db), lb = LedgerService(b);
      final f = await folders.createFolder('Fizik');
      final nb = await nbs.createNotebook(title: 'Optik');
      await nbs.moveNotebookToFolder(nb, f);
      final p1 = await firstPage(nb);
      final p2 = await nbs.addPage(nb);
      await nbs.setPageTitle(p1, 'Giriş');
      await board.setBoardPositions({p1: const BoardRect(0, 0, 320, 420)});
      final link = await board.addLink(p1, p2, label: 'devam');
      final item = await items.addImage(p1, const BoardRect(5, 5, 60, 40), 'notes/2026/11/sync-1.webp', payload: const ImageItemPayload(pxW: 9, pxH: 6));

      final res = await lb.applyRemote(await la.pendingFor(0));
      expect(res.applied, greaterThan(0));
      expect((await b.select(b.inkFolders).getSingle()).name, 'Fizik');
      expect((await b.select(b.inkNotebooks).getSingle()).folderId, f);
      expect((await b.select(b.inkNotePages).get()).firstWhere((p) => p.id == p1).title, 'Giriş');
      expect((await b.select(b.inkPageLinks).getSingle()).label, 'devam');
      final it = await b.select(b.inkPageItems).getSingle();
      expect((it.mediaPath, it.kind), ('notes/2026/11/sync-1.webp', 'image'));

      await board.deleteLink(link);
      await items.deleteItem(item);
      await folders.deleteFolder(f);
      await lb.applyRemote(await la.pendingFor(0));
      expect((await b.select(b.inkPageLinks).getSingle()).deleted, isTrue);
      expect((await b.select(b.inkPageItems).getSingle()).deleted, isTrue);
      expect((await b.select(b.inkFolders).getSingle()).deleted, isTrue);

      final change = (await la.history()).firstWhere((c) => c.table == 'ink_page_links' && c.op == 'degistir');
      await la.undoChange(change.id);
      expect((await db.select(db.inkPageLinks).getSingle()).deleted, isFalse);
    });

    test('görsel yolu kablosuz aktarımda fark edilir (ayrı sütun; JSON kaçışına gömülmez)', () async {
      final nb = await nbs.createNotebook();
      await items.addImage(await firstPage(nb), const BoardRect(0, 0, 10, 10), 'notes/2026/11/yol-1.webp');
      final ch = (await LedgerService(db).history()).firstWhere((c) => c.table == 'ink_page_items');
      expect(mediaPathsIn(ch.neu), ['notes/2026/11/yol-1.webp']);
    });

    test('bilgisayar birleştirici yeni tabloları satır satır alır, tekrarda değişmez', () async {
      final dir = await Directory.systemTemp.createTemp('pano_birles');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/tel.db');
      final phone = AppDatabase(NativeDatabase(file));
      final pi = _Ids('t');
      final pn = InkNotebookRepository(phone, ids: pi);
      final pb = InkBoardRepository(phone, ids: pi, notebooks: pn);
      final nb = await pn.createNotebook(title: 'Tel');
      final a = (await pn.pages(nb)).single.id;
      final b = await pn.addPage(nb);
      await pb.addLink(a, b);
      await InkPageItemRepository(phone, ids: pi).addText(a, const BoardRect(0, 0, 10, 10));
      await InkFolderRepository(phone, ids: pi).createFolder('K');
      await phone.close();

      final pc = await _open('pc');
      final merges = await SnapshotMerger(pc).merge(file);
      int added(String t) => merges.firstWhere((m) => m.table == t).added;
      expect([added('ink_folders'), added('ink_page_links'), added('ink_page_items')], [1, 1, 1]);
      final again = await SnapshotMerger(pc).merge(file);
      expect(again.where((m) => const {'ink_folders', 'ink_page_links', 'ink_page_items'}.contains(m.table)).fold<int>(0, (s, m) => s + m.added + m.updated), 0);
    });

    test('kocum aracı: duzelt ve sil-oner yeni tablolarda çalışır', () async {
      final pc = await _open('pc');
      final r = InkFolderRepository(pc, ids: _Ids('c'));
      final f = await r.createFolder('Eski');
      Future<int> run(List<String> args) =>
          runKocum(args, db: pc, out: (_) {}, err: (_) {}, now: () => DateTime(2026, 10, 20), env: const {}, ids: _Ids('k'));
      expect(await run(['duzelt', 'ink_folders', f, 'name', 'Yeni']), 0);
      expect((await r.findFolder(f))!.name, 'Yeni');
      final it = await InkPageItemRepository(pc, ids: _Ids('x')).addText(
          await InkNotebookRepository(pc, ids: _Ids('y')).createNotebook().then((n) => InkNotebookRepository(pc).pages(n).then((p) => p.single.id)),
          const BoardRect(0, 0, 10, 10));
      expect(await run(['duzelt', 'ink_page_items', it, 'z', '5']), 0);
      expect((await InkPageItemRepository(pc).findItem(it))!.z, 5);
      expect(await run(['sil-oner', 'ink_folders', f, '--neden', 'boş']), 0);
      expect(await pc.select(pc.silmeOnerileri).get(), hasLength(1));
      expect(await r.folders(), hasLength(1)); // silinmedi
    });
  });

  group('göç', () {
    Future<void> migrate(int from) async {
      final dir = await Directory.systemTemp.createTemp('pano_goc');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/k.sqlite');
      var d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      await d.into(d.anlikNotes).insert(AnlikNotesCompanion.insert(
          id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));

      Future<void> dropTable(String t) async {
        for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = '$t'").get()) {
          await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
        }
        await d.customStatement('DROP TABLE $t');
      }

      for (final t in ['ink_folders', 'ink_page_links', 'ink_page_items']) {
        await dropTable(t);
      }
      for (final i in ['ix_klasor_ust', 'ix_defter_klasor', 'ix_sayfa_konu', 'ix_sayfa_baglanti', 'ix_sayfa_ogeleri']) {
        await d.customStatement('DROP INDEX IF EXISTS $i');
      }
      if (from < 19) {
        for (final t in ['ink_notebooks', 'ink_note_pages', 'ink_notebook_tags', 'ink_notebook_people', 'ink_page_tags', 'ink_page_people']) {
          await dropTable(t);
        }
      } else {
        // Gerçek v19-22 şeması: yeni sütunlar olmadan (+ tetikleyiciler sütunlara bağlı: önce kaldırılır).
        for (final t in ['ink_notebooks', 'ink_note_pages']) {
          for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = '$t'").get()) {
            await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
          }
        }
        await d.customStatement('ALTER TABLE ink_notebooks DROP COLUMN folder_id');
        for (final c in ['title', 'konu_id', 'parent_page_id', 'board_x', 'board_y', 'board_w', 'board_h']) {
          await d.customStatement('ALTER TABLE ink_note_pages DROP COLUMN $c');
        }
        await d.customStatement(
            "INSERT INTO ink_notebooks (id, title, cover_color, default_template, sort_order, deleted, created_at, updated_at) VALUES ('eski-nb', 'Eski defter', 1, 'ruled', 0, 0, 1, 1)");
        await d.customStatement(
            "INSERT INTO ink_note_pages (id, notebook_id, page_no, sort_order, template, width, height, background, deleted, created_at, updated_at) VALUES ('eski-pg', 'eski-nb', 0, 0, 'ruled', 1404.0, 1984.0, 4294967295, 0, 1, 1)");
      }
      if (from < 20) await dropTable('pdf_page_layers');
      if (from < 21) await dropTable('ink_page_text');
      if (from < 22) {
        for (final t in healthTables) {
          await d.customStatement('DROP TABLE $t');
        }
      }
      await d.customStatement('PRAGMA user_version = $from');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      addTearDown(d.close);
      final names = {for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
      expect(names, containsAll(['ink_folders', 'ink_page_links', 'ink_page_items', 'ink_notebooks', 'ink_note_pages', 'anlik_notes']));
      expect((await d.select(d.anlikNotes).getSingle()).body, 'eski not');
      expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 23);
      final nbCols = {for (final c in await d.customSelect('PRAGMA table_info(ink_notebooks)').get()) c.read<String>('name')};
      final pgCols = {for (final c in await d.customSelect('PRAGMA table_info(ink_note_pages)').get()) c.read<String>('name')};
      expect(nbCols, contains('folder_id'));
      expect(pgCols, containsAll(['title', 'konu_id', 'parent_page_id', 'board_x', 'board_y', 'board_w', 'board_h']));
      for (final i in ['ix_klasor_ust', 'ix_defter_klasor', 'ix_sayfa_konu', 'ix_sayfa_baglanti', 'ix_sayfa_ogeleri']) {
        expect(await d.customSelect("SELECT name FROM sqlite_master WHERE name = '$i'").get(), hasLength(1), reason: i);
      }
      final r2 = InkNotebookRepository(d, ids: _Ids('n'));
      if (from >= 19) {
        // Eski satırlar bozulmadı; yeni alanlar boş.
        final nb = (await r2.findNotebook('eski-nb'))!;
        expect((nb.title, nb.folderId, nb.pageCount), ('Eski defter', null, 1));
        final pg = (await r2.findPage('eski-pg'))!;
        expect((pg.title, pg.konuId, pg.parentPageId, pg.boardX, pg.width), (null, null, null, null, 1404.0));
      }
      // Yeni özellikler çalışır ve deftere yazılır (tetikleyiciler kuruldu).
      final nb = await r2.createNotebook(title: 'Yeni');
      final pg = (await r2.pages(nb)).single.id;
      await InkBoardRepository(d, ids: _Ids('b'), notebooks: r2).createChildPage(pg, 1, 2);
      await InkFolderRepository(d, ids: _Ids('f')).createFolder('K');
      await InkPageItemRepository(d, ids: _Ids('i')).addText(pg, const BoardRect(0, 0, 10, 10));
      final tables = (await LedgerService(d).history()).map((c) => c.table).toSet();
      expect(tables, containsAll(['ink_folders', 'ink_page_links', 'ink_page_items', 'ink_note_pages']));
    }

    for (final v in [14, 17, 19, 20, 22]) {
      test('v$v -> v23 göçü', () => migrate(v));
    }

    test('sıfırdan kurulum: tablolar, sütunlar, indeksler ve tetikleyiciler tamam', () async {
      for (final t in ['ink_folders', 'ink_page_links', 'ink_page_items']) {
        expect(LedgerService(db).syncTables.any((x) => x.actualTableName == t), isTrue, reason: t);
        expect(await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = '$t'").get(), hasLength(3), reason: t);
      }
      for (final i in ['ix_klasor_ust', 'ix_defter_klasor', 'ix_sayfa_konu', 'ix_sayfa_baglanti', 'ix_sayfa_ogeleri']) {
        expect(await db.customSelect("SELECT name FROM sqlite_master WHERE name = '$i'").get(), hasLength(1), reason: i);
      }
      expect(db.schemaVersion, 23);
    });
  });
}

class _BadStorage extends _FakeStorage {
  _BadStorage(super.root);
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async => 'questions/2026/11/yanlis.webp';
}
