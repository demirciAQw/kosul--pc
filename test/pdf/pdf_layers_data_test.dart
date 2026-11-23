import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/pdf/data/pdf_layers_repository.dart';
import 'package:kocum/features/pdf/domain/page_layer.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart' show PdfBox;
import 'package:kocum/features/pdf/domain/watermark.dart';

class _Ids implements IdGenerator {
  _Ids([this.p = 'k']);
  final String p;
  var _n = 0;
  @override
  String next() => '$p${(_n++).toString().padLeft(3, '0')}';
}

final _doc = 'a' * 64;

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

void main() {
  late AppDatabase db;
  late PdfLayersRepository repo;
  var tick = 0;

  setUp(() async {
    db = await _open();
    tick = 0;
    repo = PdfLayersRepository(db, ids: _Ids(), clock: () => DateTime(2026, 1, 1).add(Duration(minutes: tick++)));
  });

  const wm = WatermarkParams(tone: 200, strength: 0.8);

  test('ekle: z artar, kutu/parametre gidiş-dönüş, tüm sayfalar kapsamı', () async {
    final a = await repo.add(documentId: _doc, page: 2, kind: PdfLayerKind.watermark, params: wm.toJson());
    final b = await repo.add(
        documentId: _doc, page: 2, kind: PdfLayerKind.cover, box: const PdfBox(10, 20, 110, 70), params: const CoverParams(color: 0xFFFF0000, opacity: 0.5).toJson(), name: 'Kırmızı');
    final all = await repo.add(documentId: _doc, page: allPdfPages, kind: PdfLayerKind.watermark, params: wm.toJson());
    final l = await repo.forPage(_doc, 2);
    expect([for (final x in l) x.id], [a, b, all]);
    expect([for (final x in l) x.z], [0, 1, 2]);
    expect(l[0].box, isNull);
    expect(l[0].scope, PdfLayerScope.thisPage);
    expect(l[0].watermark, wm);
    expect(l[0].name, 'Filigran temizleme');
    expect((l[1].box, l[1].cover.color, l[1].cover.opacity, l[1].name), (const PdfBox(10, 20, 110, 70), 0xFFFF0000, 0.5, 'Kırmızı'));
    expect(l[1].scope, PdfLayerScope.region);
    expect(l[2].scope, PdfLayerScope.allPages);
    // Başka sayfada yalnız "tüm sayfalar" katmanı görünür; başka belgede hiçbiri.
    expect([for (final x in await repo.forPage(_doc, 5)) x.id], [all]);
    expect(await repo.forPage('b' * 64, 2), isEmpty);
    expect(() => repo.add(documentId: _doc, page: -2, kind: PdfLayerKind.cover, params: const {}), throwsArgumentError);
  });

  test('izleme: ekleme, gizleme, sıralama ve silme akışa yansır', () async {
    final seen = <List<String>>[];
    final sub = repo.watchForPage(_doc, 0).listen((l) => seen.add([for (final x in l) '${x.id}${x.visible ? '' : '-gizli'}']));
    addTearDown(sub.cancel);
    Future<void> pump() => Future.delayed(const Duration(milliseconds: 30));
    await pump();
    final a = await repo.add(documentId: _doc, page: 0, kind: PdfLayerKind.watermark, params: wm.toJson());
    final b = await repo.add(documentId: _doc, page: allPdfPages, kind: PdfLayerKind.cover, params: const {});
    await pump();
    expect(seen.last, [a, b]);
    await repo.setVisible(a, false);
    await pump();
    expect(seen.last, ['$a-gizli', b]);
    await repo.reorder([b, a]);
    await pump();
    expect(seen.last, [b, '$a-gizli']);
    await repo.softDelete(b);
    await pump();
    expect(seen.last, ['$a-gizli']);
    await repo.restore(b);
    await pump();
    expect(seen.last, [b, '$a-gizli']);
  });

  test('görünür katmanlar z sırasıyla; gizli ve silinen elenir; satır silinmez', () async {
    final a = await repo.add(documentId: _doc, page: 1, kind: PdfLayerKind.watermark, params: wm.toJson());
    final b = await repo.add(documentId: _doc, page: 1, kind: PdfLayerKind.cover, params: const {});
    final c = await repo.add(documentId: _doc, page: allPdfPages, kind: PdfLayerKind.watermark, params: wm.toJson());
    await repo.setVisible(b, false);
    var vis = visibleLayersFor(await repo.forPage(_doc, 1), 1);
    expect([for (final x in vis) x.id], [a, c]);
    await repo.reorder([c, a]);
    vis = visibleLayersFor(await repo.forPage(_doc, 1), 1);
    expect([for (final x in vis) x.id], [c, a]);
    expect(await repo.softDelete(a), isTrue);
    expect(await repo.forPage(_doc, 1), hasLength(2));
    expect(await db.select(db.pdfPageLayers).get(), hasLength(3)); // satır durur
    expect(await repo.all(_doc, deleted: true), hasLength(1));
    expect(await repo.softDelete('yok'), isFalse);
    expect(() => repo.reorder(['yok']), throwsArgumentError);
  });

  test('parametre ve kutu güncelle; boş ad reddedilir', () async {
    final a = await repo.add(documentId: _doc, page: 0, kind: PdfLayerKind.watermark, params: wm.toJson());
    await repo.updateParams(a, const WatermarkParams(tone: 180).toJson(), box: const PdfBox(1, 2, 30, 40), setBox: true);
    var l = (await repo.forPage(_doc, 0)).single;
    expect((l.watermark.tone, l.box), (180.0, const PdfBox(1, 2, 30, 40)));
    await repo.updateParams(a, wm.toJson());
    expect((await repo.forPage(_doc, 0)).single.box, const PdfBox(1, 2, 30, 40)); // kutu verilmezse durur
    await repo.updateParams(a, wm.toJson(), box: null, setBox: true);
    expect((await repo.forPage(_doc, 0)).single.box, isNull);
    expect(await repo.rename(a, '  '), isFalse);
    expect(await repo.rename(a, ' Logo '), isTrue);
    l = (await repo.forPage(_doc, 0)).single;
    expect(l.name, 'Logo');
  });

  test('clampLayerBox sayfaya kırpar', () {
    expect(clampLayerBox(const PdfBox(-5, -5, 700, 800), 612, 792), const PdfBox(0, 0, 612, 792));
    expect(clampLayerBox(const PdfBox(700, 10, 800, 90), 612, 792), isNull);
  });

  test('defter: katmanlar iki cihaza geçer; gizleme, silme ve geri alma', () async {
    final b = await _open('pc');
    final la = LedgerService(db), lb = LedgerService(b);
    final id = await repo.add(documentId: _doc, page: allPdfPages, kind: PdfLayerKind.watermark, box: const PdfBox(5, 5, 100, 100), params: wm.toJson());
    final res = await lb.applyRemote(await la.pendingFor(0));
    expect(res.applied, greaterThan(0));
    final r = await b.select(b.pdfPageLayers).getSingle();
    expect((r.id, r.page, r.kind, r.boxRight, r.visible), (id, -1, 'watermark', 100.0, true));
    await repo.setVisible(id, false);
    await repo.softDelete(id);
    await lb.applyRemote(await la.pendingFor(0));
    final r2 = await b.select(b.pdfPageLayers).getSingle();
    expect((r2.visible, r2.deleted), (false, true));
    // İkinci cihazdan yapılan değişiklik geri döner.
    await PdfLayersRepository(b, ids: _Ids('p')).restore(id);
    await la.applyRemote(await lb.pendingFor(0));
    expect((await db.select(db.pdfPageLayers).getSingle()).deleted, isFalse);
    // Değişiklik geri alınabilir.
    final change = (await la.history()).firstWhere((c) => c.table == 'pdf_page_layers' && c.op == 'degistir');
    await la.undoChange(change.id);
    expect(LedgerService(db).syncTables.any((t) => t.actualTableName == 'pdf_page_layers'), isTrue);
  });

  test('bilgisayar birleştirici katmanları satır satır alır, tekrar çalıştırınca değişmez', () async {
    final dir = await Directory.systemTemp.createTemp('katman_birles');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tel.db');
    final phone = AppDatabase(NativeDatabase(file));
    final prepo = PdfLayersRepository(phone, ids: _Ids('t'));
    await prepo.add(documentId: _doc, page: 3, kind: PdfLayerKind.watermark, params: wm.toJson());
    await prepo.add(documentId: _doc, page: 3, kind: PdfLayerKind.cover, box: const PdfBox(0, 0, 50, 50), params: const {});
    await phone.close();
    final pc = await _open('pc');
    final merges = await SnapshotMerger(pc).merge(file);
    expect(merges.firstWhere((m) => m.table == 'pdf_page_layers').added, 2);
    expect(await PdfLayersRepository(pc).forPage(_doc, 3), hasLength(2));
    final again = await SnapshotMerger(pc).merge(file);
    expect(again.where((m) => m.table == 'pdf_page_layers').fold<int>(0, (s, m) => s + m.added + m.updated), 0);
  });

  test('kocum aracı: duzelt katman satırında çalışır (otomatik kapsam)', () async {
    final pc = await _open('pc');
    final r = PdfLayersRepository(pc, ids: _Ids('c'));
    final id = await r.add(documentId: _doc, page: 0, kind: PdfLayerKind.cover, params: const {});
    final code = await runKocum(['duzelt', 'pdf_page_layers', id, 'name', 'Yeni ad'],
        db: pc, out: (_) {}, err: (_) {}, now: () => DateTime(2026, 10, 20), env: const {}, ids: _Ids('k'));
    expect(code, 0);
    expect((await r.forPage(_doc, 0)).single.name, 'Yeni ad');
  });

  // ───────────── Göç ─────────────

  Future<void> migrate(int from) async {
    final dir = await Directory.systemTemp.createTemp('katman_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var d = AppDatabase(NativeDatabase(file));
    await d.customSelect('SELECT 1').get();
    await d.into(d.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));
    final drop = [
      'pdf_page_layers',
      if (from < 19) ...['ink_notebooks', 'ink_note_pages', 'ink_notebook_tags', 'ink_notebook_people', 'ink_page_tags', 'ink_page_people'],
      if (from < 16) 'pdf_documents',
      if (from < 15) 'ink_strokes',
    ];
    for (final t in drop) {
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%$t%'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      await d.customStatement('DROP TABLE $t');
    }
    await d.customStatement('DROP INDEX IF EXISTS ix_pdf_layer_doc');
    await d.customStatement('DROP INDEX IF EXISTS ix_defter_sayfa');
    await d.customStatement('PRAGMA user_version = $from');
    await d.close();

    d = AppDatabase(NativeDatabase(file));
    addTearDown(d.close);
    final names = {for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get()) r.read<String>('name')};
    expect(names, contains('pdf_page_layers'));
    expect((await d.select(d.anlikNotes).getSingle()).body, 'eski not');
    expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 20);
    expect(await d.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_pdf_layer_doc'").get(), hasLength(1));
    final r2 = PdfLayersRepository(d);
    await r2.add(documentId: _doc, page: 0, kind: PdfLayerKind.watermark, params: wm.toJson());
    expect(await r2.forPage(_doc, 0), hasLength(1));
    expect((await LedgerService(d).history()).map((c) => c.table), contains('pdf_page_layers')); // tetikleyici kuruldu
  }

  test('v14 -> v20 göçü', () => migrate(14));
  test('v18 -> v20 göçü', () => migrate(18));
  test('v19 -> v20 göçü', () => migrate(19));

  test('sıfırdan kurulum: indeks ve tetikleyiciler tamam', () async {
    expect(await db.customSelect("SELECT name FROM sqlite_master WHERE name = 'ix_pdf_layer_doc'").get(), hasLength(1));
    expect(await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'pdf_page_layers'").get(), isNotEmpty);
  });
}
