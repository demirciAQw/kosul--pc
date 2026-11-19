import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/hlc.dart';
import 'package:kocum/core/ledger/ledger_service.dart';

final _t = DateTime(2026, 10, 20, 9);

Future<(AppDatabase, LedgerService)> _open(String source) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  final ledger = LedgerService(db);
  await db.customSelect('SELECT 1').get(); // açılış: tetikleyiciler kurulur
  return (db, ledger);
}

Future<void> _note(AppDatabase db, String id, String body) => db.into(db.anlikNotes).insert(
    AnlikNotesCompanion.insert(id: id, createdAt: _t, updatedAt: _t, body: body, searchText: Value(body)));

Future<void> _edit(AppDatabase db, String id, String body) =>
    (db.update(db.anlikNotes)..where((n) => n.id.equals(id))).write(AnlikNotesCompanion(body: Value(body)));

Future<String?> _body(AppDatabase db, String id) async =>
    (await (db.select(db.anlikNotes)..where((n) => n.id.equals(id))).getSingleOrNull())?.body;

/// [from]'un karşıya gidecek değişiklikleri [to]'ya (tam liste: yeniden gönderim dedupe ile korunur).
Future<ApplyResult> _push(LedgerService from, LedgerService to, {int after = 0}) async =>
    to.applyRemote(await from.pendingFor(after));

void main() {
  group('HLC', () {
    test('sıralama düz metinle aynı; yerel olayda sayaç artar', () {
      const a = Hlc(1000, 0, 'a');
      expect(a.tick(2000), const Hlc(2000, 0, 'a'));
      expect(a.tick(1000), const Hlc(1000, 1, 'a')); // saat ilerlemedi
      expect(a.tick(500), const Hlc(1000, 1, 'a')); // saat geri gitti
      expect(Hlc.tryParse(a.toString()), a);
      expect(Hlc.tryParse('bozuk'), isNull);
      expect(const Hlc(1000, 9, 'a') > const Hlc(999, 99, 'z'), isTrue);
    });

    test('karşıdan gelen saatin üstüne çıkar (cihaz saati geride olsa da)', () {
      const local = Hlc(1000, 0, 'a');
      const remote = Hlc(5000, 3, 'b');
      final next = local.receive(remote, 1200); // yerel duvar saati geride
      expect(next > remote, isTrue);
      expect(next, const Hlc(5000, 4, 'a'));
    });
  });

  group('tetikleyiciler', () {
    test('ekle / değiştir / sil deftere yazılır; değişmeyen güncelleme yazılmaz', () async {
      final (db, ledger) = await _open('telefon');
      await _note(db, 'n1', 'bir');
      await _edit(db, 'n1', 'iki');
      await _edit(db, 'n1', 'iki'); // aynı değer: kayıt yok
      await (db.delete(db.anlikNotes)..where((n) => n.id.equals('n1'))).go();
      final h = (await ledger.history()).reversed.toList();
      expect([for (final c in h) c.op], ['ekle', 'degistir', 'sil']);
      expect(h.first.old, isNull);
      expect(h.first.neu, contains('"body":"bir"'));
      expect(h[1].old, contains('"bir"'));
      expect(h[1].neu, contains('"iki"'));
      expect(h.last.neu, isNull);
      expect(h.every((c) => c.source == 'telefon' && c.table == 'anlik_notes' && c.rowId == 'n1'), isTrue);
      // saatler artar
      expect(h[0].clock.compareTo(h[1].clock) < 0 && h[1].clock.compareTo(h[2].clock) < 0, isTrue);
    });

    test('kaynak ve oturum bağlamdan gelir; bastir susturur; app_meta girmez', () async {
      final (db, ledger) = await _open('pc');
      await ledger.withSource('claude', session: 'oturum-1', body: () => _note(db, 'c1', 'claude yazdı'));
      await _note(db, 'k1', 'ben yazdım');
      await ledger.silently(() => _note(db, 's1', 'sessiz'));
      await db.into(db.appMeta).insert(AppMetaCompanion.insert(metaKey: 'x', metaValue: 'y'));
      final h = (await ledger.history()).reversed.toList();
      expect(h.length, 2);
      expect((h[0].source, h[0].session), ('claude', 'oturum-1'));
      expect((h[1].source, h[1].session), ('pc', null)); // bağlam varsayılana döndü
      expect(await ledger.deviceId(), isNotEmpty);
    });

    test('cascade ile silinen alt satırlar da deftere yazılır', () async {
      final (db, ledger) = await _open('telefon');
      await _note(db, 'n', 'x');
      await db.into(db.tags).insert(TagsCompanion.insert(id: 't', name: 't', label: 't', createdAt: _t));
      await db.into(db.anlikNoteTags).insert(AnlikNoteTagsCompanion.insert(id: 'n:t', noteId: 'n', tagId: 't'));
      await (db.delete(db.anlikNotes)..where((n) => n.id.equals('n'))).go();
      final h = await ledger.history();
      expect(h.any((c) => c.table == 'anlik_note_tags' && c.op == 'sil'), isTrue);
    });
  });

  group('iki cihaz', () {
    test('ayrı değişiklikler iki yöne gider', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await _note(a, 'ta', 'telefonda');
      await _note(b, 'pb', 'bilgisayarda');
      final r1 = await _push(la, lb);
      final r2 = await _push(lb, la);
      expect(r1.applied, 1);
      expect(r2.applied, 1);
      expect(await _body(b, 'ta'), 'telefonda');
      expect(await _body(a, 'pb'), 'bilgisayarda');
      // Alınanlar geri gönderilmez.
      expect(await la.pendingFor(1), isEmpty);
      expect((await lb.pendingFor(0)).map((c) => c.rowId), ['pb']);
    });

    test('değiştirme ve silme karşıya geçer', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await _note(a, 'n', 'bir');
      await _push(la, lb);
      await _edit(b, 'n', 'iki');
      await _push(lb, la);
      expect(await _body(a, 'n'), 'iki');
      await (a.delete(a.anlikNotes)..where((n) => n.id.equals('n'))).go();
      await _push(la, lb);
      expect(await _body(b, 'n'), isNull);
    });

    test('bağlantı yarıda kopup aynı toplu yeniden gelince çift kayıt olmaz', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await _note(a, 'n', 'bir');
      await _edit(a, 'n', 'iki');
      final batch = await la.pendingFor(0);
      final first = await lb.applyRemote(batch);
      final again = await lb.applyRemote(batch); // yanıt kaybolmuştu, telefon yeniden yolladı
      expect(first.applied, 2);
      expect(again.duplicates, 2);
      expect(again.applied, 0);
      expect(await _body(b, 'n'), 'iki');
      final c = await b.customSelect('SELECT COUNT(*) AS n FROM degisiklikler').getSingle();
      expect(c.read<int>('n'), 2); // her değişiklik defterde bir kez
    });

    test('aynı satır iki tarafta değişti: HLC yeni olan kazanır, kaybeden Çakışmalar\'a düşer', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await la.setTestClock(1_000_000);
      await lb.setTestClock(1_000_000);
      await _note(a, 'n', 'ilk');
      await _push(la, lb);
      // İki taraf eşzamanlı değiştirir; bilgisayar daha geç.
      await la.setTestClock(2_000_000);
      await _edit(a, 'n', 'telefon sürümü');
      await lb.setTestClock(3_000_000);
      await _edit(b, 'n', 'pc sürümü');
      await _push(la, lb); // bilgisayarda çakışma: yerel (pc) kazanır
      await _push(lb, la); // telefonda çakışma: uzak (pc) kazanır
      expect(await _body(a, 'n'), 'pc sürümü');
      expect(await _body(b, 'n'), 'pc sürümü');
      final ca = await la.watchConflicts().first;
      final cb = await lb.watchConflicts().first;
      expect(ca.length, 1);
      expect(cb.length, 1);
      expect(cb.single.kaybeden, contains('telefon sürümü')); // kaybeden silinmedi
      expect(ca.single.kaybeden, contains('telefon sürümü'));
      expect(ca.single.taraf, 'uzak');
      expect(cb.single.taraf, 'yerel');
      await la.resolveConflict(ca.single.id);
      expect(await la.watchConflicts().first, isEmpty);
    });

    test('cihaz saati geride olsa da gördüğü değişikliğin üstüne yazan kazanır', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await lb.setTestClock(10_000_000);
      await _note(b, 'n', 'pc ilk');
      await la.setTestClock(1_000_000); // telefonun saati bir gün geride
      await _push(lb, la);
      await _edit(a, 'n', 'telefon sonra'); // değişikliği gördükten sonra yazdı
      final back = await la.pendingFor(0);
      expect(Hlc.tryParse(back.last.clock)! > Hlc.tryParse((await lb.pendingFor(0)).last.clock)!, isTrue);
      final r = await lb.applyRemote(back);
      expect(r.applied, 1);
      expect(r.conflicts, 0);
      expect(await _body(b, 'n'), 'telefon sonra');
    });

    test('silme ile değiştirme çakışması: yeni olan kazanır', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await la.setTestClock(1_000_000);
      await lb.setTestClock(1_000_000);
      await _note(a, 'n', 'x');
      await _push(la, lb);
      await la.setTestClock(2_000_000);
      await (a.delete(a.anlikNotes)..where((n) => n.id.equals('n'))).go();
      await lb.setTestClock(3_000_000);
      await _edit(b, 'n', 'y');
      await _push(la, lb);
      await _push(lb, la);
      expect(await _body(b, 'n'), 'y'); // sonradan düzenlenen silmeyi yener
      expect(await _body(a, 'n'), 'y');
      expect((await la.watchConflicts().first).length, 1);
    });

    test('yedek birleştirme gibi susturulmuş yazmalar karşıya gitmez', () async {
      final (a, la) = await _open('telefon');
      await la.silently(() => _note(a, 'n', 'sessiz'));
      expect(await la.pendingFor(0), isEmpty);
    });
  });

  group('geri alma', () {
    test('Claude değişikliği geri alınır; geri alma kaydı kaynak geri_al ve geri alınabilir', () async {
      final (db, ledger) = await _open('pc');
      await _note(db, 'n', 'benim');
      await ledger.withSource('claude', session: 'o1', body: () => _edit(db, 'n', 'claude düzeltti'));
      final change = (await ledger.history()).first;
      expect(change.source, 'claude');

      expect(await ledger.undoChange(change.id), UndoResult.done);
      expect(await _body(db, 'n'), 'benim');
      final undo = (await ledger.history()).first;
      expect(undo.source, 'geri_al');
      expect(undo.undoes, change.id);
      expect(await ledger.undoChange(change.id), UndoResult.already);

      // Geri almayı geri al.
      expect(await ledger.undoChange(undo.id), UndoResult.done);
      expect(await _body(db, 'n'), 'claude düzeltti');
    });

    test('satır o arada değiştiyse üstüne yazmaz, çakışma gösterir', () async {
      final (db, ledger) = await _open('pc');
      await _note(db, 'n', 'a');
      await ledger.withSource('claude', session: 'o1', body: () => _edit(db, 'n', 'b'));
      final change = (await ledger.history()).first;
      await _edit(db, 'n', 'c'); // sonradan ben değiştirdim
      expect(await ledger.undoChange(change.id), UndoResult.conflict);
      expect(await _body(db, 'n'), 'c');
      final c = (await ledger.watchConflicts().first).single;
      expect((c.taraf, c.tablo), ('geri_al', 'anlik_notes'));
    });

    test('eklenen satır geri alınınca silinir, silinen satır geri gelir', () async {
      final (db, ledger) = await _open('pc');
      await ledger.withSource('claude', session: 'o1', body: () => _note(db, 'n', 'claude ekledi'));
      final add = (await ledger.history()).first;
      expect(await ledger.undoChange(add.id), UndoResult.done);
      expect(await _body(db, 'n'), isNull);

      await _note(db, 'm', 'önemli');
      await ledger.withSource('claude', session: 'o2', body: () => (db.delete(db.anlikNotes)..where((n) => n.id.equals('m'))).go());
      final del = (await ledger.history()).first;
      expect(del.op, 'sil');
      expect(await ledger.undoChange(del.id), UndoResult.done);
      expect(await _body(db, 'm'), 'önemli');
    });

    test('oturum geri alma: oturumdaki her şey sondan başa; başka oturum ve ben dokunulmaz', () async {
      final (db, ledger) = await _open('pc');
      await _note(db, 'k', 'benim notum');
      await ledger.withSource('claude', session: 'o1', body: () async {
        await _note(db, 'c1', 'bir');
        await _edit(db, 'c1', 'iki');
        await _edit(db, 'k', 'claude benim notumu değiştirdi');
      });
      await ledger.withSource('claude', session: 'o2', body: () => _note(db, 'c2', 'başka oturum'));
      final r = await ledger.undoSession('o1');
      expect(r[UndoResult.done], 3);
      expect(await _body(db, 'c1'), isNull);
      expect(await _body(db, 'k'), 'benim notum');
      expect(await _body(db, 'c2'), 'başka oturum');
    });

    test('geri alma karşıya da gider', () async {
      final (a, la) = await _open('telefon');
      final (b, lb) = await _open('pc');
      await lb.withSource('claude', session: 'o', body: () => _note(b, 'n', 'claude'));
      await _push(lb, la);
      expect(await _body(a, 'n'), 'claude');
      expect((await la.history(source: 'claude')).single.session, 'o'); // oturum bilgisi telefonda da var
      final change = (await lb.history()).first;
      await lb.undoChange(change.id);
      await _push(lb, la);
      expect(await _body(a, 'n'), isNull);
      expect(await la.undoneIds(), contains(change.id)); // telefonda da "geri alındı" görünür
    });
  });

  test('uygulanan ve geri alınan satırlar liste akışlarına haber verir', () async {
    final (a, la) = await _open('telefon');
    final (b, lb) = await _open('pc');
    final emitted = <int>[];
    final sub = a.select(a.anlikNotes).watch().listen((rows) => emitted.add(rows.length));
    addTearDown(sub.cancel);
    await pumpEventQueue();
    await _note(b, 'n', 'karşıdan');
    await _push(lb, la);
    await pumpEventQueue();
    expect(emitted.last, 1);
    await la.undoChange((await la.history()).first.id);
    await pumpEventQueue();
    expect(emitted.last, 0);
  });

  test('v12 veritabanı v13\'e yükselir: defter tabloları ve tetikleyiciler kurulur, eski veri durur', () async {
    final dir = await Directory.systemTemp.createTemp('defter_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    await _note(db, 'eski', 'v12 notu');
    // v12'yi taklit et: defter yok, tetikleyici yok.
    for (final r in await db.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'").get()) {
      await db.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
    }
    for (final t in ['degisiklikler', '_baglam', 'cakismalar', 'esitleme_durum']) {
      await db.customStatement('DROP TABLE "$t"');
    }
    await db.customStatement('PRAGMA user_version = 12');
    await db.close();

    db = AppDatabase(NativeDatabase(file), 'telefon');
    addTearDown(db.close);
    final ledger = LedgerService(db);
    expect(await ledger.deviceId(), isNotEmpty);
    expect(await _body(db, 'eski'), 'v12 notu');
    await _note(db, 'yeni', 'v13 notu');
    final h = await ledger.history();
    expect(h.single.rowId, 'yeni'); // geçmiş yazılmaz, yeni değişiklik izlenir
    final trig = await db.customSelect("SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'trigger'").getSingle();
    expect(trig.read<int>('n'), greaterThan(60));
  });

  test('imleç durumu saklanır', () async {
    final (_, ledger) = await _open('telefon');
    expect(await ledger.intState(LedgerService.keySentSeq), 0);
    await ledger.setIntState(LedgerService.keySentSeq, 42);
    await ledger.setIntState(LedgerService.keySentSeq, 43);
    expect(await ledger.intState(LedgerService.keySentSeq), 43);
  });

  test('bozuk gelen değişiklik ayrıştırılmaz', () {
    expect(LedgerChange.tryParse({'id': 'x'}), isNull);
    expect(
      LedgerChange.tryParse({'id': 'a', 'cihaz': 'd', 'kaynak': 'pc', 'tablo': 't', 'satir': 'r', 'islem': 'yık', 'saat': '0000000000001-0000-d'}),
      isNull,
    );
    expect(LedgerChange.tryParse('metin'), isNull);
  });
}
