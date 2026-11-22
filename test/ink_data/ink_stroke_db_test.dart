import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';

final _pts = [
  const StrokePoint(10, 20, pressure: 0.5, tilt: 0.4, t: 0),
  const StrokePoint(11.5, 21, pressure: 0.6, tilt: 0.41, t: 8),
  const StrokePoint(13, 22.5, pressure: 0.7, tilt: 0.42, t: 17),
];

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

Future<Set<String>> _tables(AppDatabase db) async => {
      for (final r in await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'table'").get())
        r.read<String>('name'),
    };

void main() {
  test('depo: ekle, sayfaya göre oku, ayır, yumuşak sil, geri getir', () async {
    final db = await _open();
    final repo = InkStrokeRepository(db);
    const doc = PdfPageOwner('belge1', 3);
    final a = await repo.add(owner: doc, points: _pts, startedAtMs: 2000, attemptNo: 1, color: 0xFFFF0000, width: 2.5, tool: 'pen');
    final b = await repo.add(owner: doc, points: _pts, startedAtMs: 1000, attemptNo: 2);
    await repo.add(owner: const PdfPageOwner('belge1', 4), points: _pts, startedAtMs: 1);
    await repo.add(owner: const NotePageOwner('not1', 0), points: _pts, startedAtMs: 1, layer: 1);

    final page = await repo.forPage(doc);
    expect(page.map((s) => s.id), [b, a]); // çizim sırası
    final s = page.last;
    expect(s.points.length, 3);
    expect(s.durationMs, 17);
    expect((s.points[1].x - 11.5).abs(), lessThan(StrokeCodec.positionError(20) + 1e-9));
    expect((s.color, s.width, s.attemptNo), (0xFFFF0000, 2.5, 1));
    expect((await repo.forPage(doc, attemptNo: 1)).single.id, a);
    expect((await repo.forPage(const NotePageOwner('not1', 0), layer: 1)), hasLength(1));
    expect(await repo.forPage(const NotePageOwner('not1', 1)), isEmpty);

    expect(await repo.softDelete(a), isTrue);
    expect(await repo.softDelete(a), isFalse); // zaten silinmiş
    expect(await repo.softDelete('yok'), isFalse);
    expect((await repo.forPage(doc)).map((s) => s.id), [b]);
    final raw = await db.select(db.inkStrokes).get();
    expect(raw, hasLength(4)); // satır durur
    expect(await repo.restore(a), isTrue);
    expect(await repo.forPage(doc), hasLength(2));
  });

  test('depo: bozuk tek blob sayfayı düşürmez, atlanır ve işaretlenir; veri durur', () async {
    final db = await _open();
    final repo = InkStrokeRepository(db);
    const owner = NotePageOwner('n', 7);
    final good = await repo.add(owner: owner, points: _pts, startedAtMs: 1);
    final bad = await repo.add(owner: owner, points: _pts, startedAtMs: 2);
    await db.customStatement("UPDATE ink_strokes SET points = x'0102' WHERE id = ?", [bad]);
    expect((await repo.forPage(owner)).map((s) => s.id), [good]);
    expect(repo.corruptIds, {bad});
    final emitted = await repo.watchPage(owner).first;
    expect(emitted.map((s) => s.id), [good]);
    expect(await db.select(db.inkStrokes).get(), hasLength(2)); // silinmedi
  });

  test('depo: akış değişince yenilenir', () async {
    final db = await _open();
    final repo = InkStrokeRepository(db);
    const owner = NotePageOwner('n', 2);
    final emitted = <int>[];
    final sub = repo.watchPage(owner).listen((l) => emitted.add(l.length));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    final id = await repo.add(owner: owner, points: _pts, startedAtMs: 1);
    await pumpEventQueue();
    await repo.softDelete(id);
    await pumpEventQueue();
    expect(emitted, [0, 1, 0]);
  });

  test('defter: BLOB dahil satır karşıya geçer, silme ve geri alma çalışır', () async {
    final a = await _open('telefon');
    final b = await _open('pc');
    final la = LedgerService(a), lb = LedgerService(b);
    final repo = InkStrokeRepository(a);
    final id = await repo.add(owner: const PdfPageOwner('d', 1), points: _pts, startedAtMs: 5);
    final bytes = (await a.select(a.inkStrokes).getSingle()).points;

    var res = await lb.applyRemote(await la.pendingFor(0));
    expect(res.applied, greaterThan(0));
    final got = await b.select(b.inkStrokes).getSingle();
    expect(got.points, bytes); // bayt bayta aynı
    expect(got.id, id);
    expect(StrokeCodec.decode(got.points), hasLength(3));

    await repo.softDelete(id);
    await lb.applyRemote(await la.pendingFor(0));
    expect((await b.select(b.inkStrokes).getSingle()).deleted, isTrue);
    expect((await b.select(b.inkStrokes).getSingle()).points, bytes);

    // Geri al: BLOB hex'ten yeniden yazılır.
    final change = (await la.history()).firstWhere((c) => c.table == 'ink_strokes' && c.op == 'degistir');
    await la.undoChange(change.id);
    expect((await a.select(a.inkStrokes).getSingle()).deleted, isFalse);
    expect((await a.select(a.inkStrokes).getSingle()).points, bytes);
  });

  test('boş BLOB da defterden geçer', () async {
    final a = await _open('telefon');
    final b = await _open('pc');
    await InkStrokeRepository(a).add(owner: const NotePageOwner('n', 0), points: const [], startedAtMs: 1);
    await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
    expect(StrokeCodec.decode((await b.select(b.inkStrokes).getSingle()).points), isEmpty);
  });

  Future<void> migrate(int from) async {
    final dir = await Directory.systemTemp.createTemp('ink_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await db.into(db.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'eski', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'eski not', searchText: const Value('eski not')));
    // Eski sürümü taklit et: yeni tablo ve tetikleyicileri yok.
    for (final r in await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%ink_strokes%'").get()) {
      await db.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
    }
    await db.customStatement('DROP TABLE ink_strokes');
    if (from < 14) await db.customStatement('DROP TABLE silme_onerileri');
    await db.customStatement('PRAGMA user_version = $from');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    expect(await _tables(db), contains('ink_strokes'));
    expect((await db.select(db.anlikNotes).getSingle()).body, 'eski not');
    expect((await db.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), db.schemaVersion);
    final idx = await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'ix_ink_%'").get();
    expect(idx, hasLength(3));
    // Tetikleyici kurulu: yeni çizgi deftere yazılır.
    await InkStrokeRepository(db).add(owner: const PdfPageOwner('d', 0), points: _pts, startedAtMs: 1);
    expect((await LedgerService(db).history()).any((c) => c.table == 'ink_strokes'), isTrue);
  }

  test('v14 -> v15 göçü', () => migrate(14));
  test('v13 -> v15 göçü', () => migrate(13));

  test('bilgisayar birleştirici çizgileri satır satır alır (BLOB dahil)', () async {
    final dir = await Directory.systemTemp.createTemp('ink_birles');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/tel.db');
    final phone = AppDatabase(NativeDatabase(file));
    final id = await InkStrokeRepository(phone).add(owner: const PdfPageOwner('d', 7), points: _pts, startedAtMs: 9);
    final bytes = (await phone.select(phone.inkStrokes).getSingle()).points;
    await phone.close();

    final pc = await _open('pc');
    final merges = await SnapshotMerger(pc).merge(file);
    expect(merges.firstWhere((m) => m.table == 'ink_strokes').added, 1);
    final row = await pc.select(pc.inkStrokes).getSingle();
    expect(row.id, id);
    expect(row.points, bytes);
    // İkinci birleştirme değişiklik bulmaz.
    final again = await SnapshotMerger(pc).merge(file);
    expect(again.firstWhere((m) => m.table == 'ink_strokes').added + again.firstWhere((m) => m.table == 'ink_strokes').updated, 0);
  });
}
