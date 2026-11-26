import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/features/anlik/data/anlik_repository_impl.dart';
import 'package:kocum/features/anlik/domain/anlik.dart';
import 'package:kocum/features/anlik/domain/markdown_export.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'c${_n++}';
}

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
  Map<String, dynamic> get json => jsonDecode(out) as Map<String, dynamic>;
  String get error => (jsonDecode(err) as Map)['hata'] as String;
}

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late DriftAnlikRepository repo;
  final ids = _Ids();
  final t = DateTime(2026, 10, 20, 9, 30);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    ledger = LedgerService(db);
    repo = DriftAnlikRepository(db);
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  Future<_Run> kocum(List<String> args, {Map<String, String> env = const {}}) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runKocum(
      args,
      db: db,
      out: out.writeln,
      err: err.writeln,
      now: () => t,
      env: env,
      ids: ids,
    );
    return _Run(code, out.toString(), err.toString());
  }

  Future<void> insertCard(String id) => db.customStatement(
      "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, created_at) "
      "VALUES (?, 'wrong', 'independent', 'x', 'TYT Matematik', 3, '', 1767225600)",
      [id]);

  test('yardım ve bilinmeyen komut', () async {
    expect((await kocum(['yardim'])).code, 0);
    expect((await kocum([])).code, 2);
    final r = await kocum(['uc']);
    expect(r.code, 2);
    expect(r.error, contains('Bilinmeyen komut'));
  });

  group('sorgu', () {
    test('SELECT çalışır, JSON döner; limit uygulanır', () async {
      await kocum(['not-ekle', 'bir']);
      await kocum(['not-ekle', 'iki']);
      final r = await kocum(['sorgu', 'SELECT body FROM anlik_notes ORDER BY body']);
      expect(r.code, 0);
      expect([for (final x in r.json['satirlar'] as List) x['body']], ['bir', 'iki']);
      final lim = await kocum(['sorgu', 'select body from anlik_notes', '--limit', '1']);
      expect(lim.json['sayi'], 1);
      final cte = await kocum(['sorgu', 'WITH x AS (SELECT 1 AS a) SELECT a FROM x']);
      expect(cte.json['satirlar'], [{'a': 1}]);
    });

    test('yazan ya da çoklu sorgu reddedilir; veri değişmez', () async {
      await kocum(['not-ekle', 'kalsın']);
      for (final bad in ['DELETE FROM anlik_notes', 'SELECT 1; DELETE FROM anlik_notes', 'UPDATE anlik_notes SET body = 1', 'PRAGMA user_version = 1', "INSERT INTO tags VALUES (1)"]) {
        final r = await kocum(['sorgu', bad]);
        expect(r.code, isNot(0), reason: bad);
      }
      expect((await db.select(db.anlikNotes).get()).length, 1);
      // Salt okunur kip kapanır: sonraki yazma çalışır.
      expect((await kocum(['not-ekle', 'yine'])).code, 0);
    });
  });

  group('yazma: hepsi kaynak claude + oturum ile deftere geçer', () {
    test('not-ekle: oturum bilgisi, etiket ve kişi yalnızca --olustur ile oluşur', () async {
      final refused = await kocum(['not-ekle', 'Bugün', '((his))', 've', '@Şule', '--oturum', 'o1']);
      expect(refused.code, 1);
      expect(refused.error, contains('--olustur'));
      expect(await db.select(db.anlikNotes).get(), isEmpty);
      expect(await db.select(db.tags).get(), isEmpty);

      final ok = await kocum(['not-ekle', 'Bugün', '((his))', 've', '@Şule', '--olustur', '--oturum', 'o1', '--ruh', '4', '--ders', 'TYT Matematik']);
      expect(ok.code, 0, reason: ok.err);
      expect(ok.json['oturum'], 'o1');
      expect(ok.json['degisiklik'], greaterThan(0));
      final h = await ledger.history(session: 'o1');
      expect(h.every((c) => c.source == 'claude'), isTrue);
      expect(h.map((c) => c.table).toSet(), containsAll(['anlik_notes', 'tags', 'people', 'anlik_note_tags', 'anlik_note_people']));
      final note = (await repo.allNotes()).single;
      expect(note.mood, 4);
      expect((await repo.allTags()).single.source, Source.claude);
      // Bağlam varsayılana döndü: sonraki uygulama yazması claude sayılmaz.
      await db.customStatement("INSERT INTO anlik_notes (id, created_at, updated_at, body, kind, search_text) VALUES ('el', 1, 1, 'elle', 'anlik', 'elle')");
      expect((await ledger.history()).first.source, 'pc');
    });

    test('oturum önceliği: --oturum, KOCUM_OTURUM, claude-<gün>', () async {
      expect((await kocum(['not-ekle', 'a'])).json['oturum'], 'claude-2026-10-20');
      expect((await kocum(['not-ekle', 'b'], env: {'KOCUM_OTURUM': 'ortam'})).json['oturum'], 'ortam');
      expect((await kocum(['not-ekle', 'c', '--oturum', 'bayrak'], env: {'KOCUM_OTURUM': 'ortam'})).json['oturum'], 'bayrak');
    });

    test('etiket-ekle / etiket-kaldir: not ve soru kartı', () async {
      final id = (await kocum(['not-ekle', 'etiketlenecek'])).json['not'] as String;
      await insertCard('k1');
      expect((await kocum(['etiket-ekle', 'not:$id', 'dikkat'])).code, 1); // olmayan etiket
      expect((await kocum(['etiket-ekle', 'not:$id', 'hata > dikkat', '--olustur'])).code, 0);
      expect((await kocum(['etiket-ekle', 'soru:k1', 'dikkat'])).code, 0); // var olan
      expect((await repo.findNote(id))!.tagIds.length, 1);
      expect((await repo.watchCardTags().first)['k1'], isNotNull);
      expect((await kocum(['etiket-kaldir', id, 'dikkat'])).code, 0); // yalın kimlik
      expect((await repo.findNote(id))!.tagIds, isEmpty);
      expect((await kocum(['etiket-ekle', 'not:yok', 'dikkat'])).code, 1);
    });

    test('kisi-ekle, kisi-bagla, bagla', () async {
      final a = (await kocum(['not-ekle', 'birinci'])).json['not'] as String;
      final b = (await kocum(['not-ekle', 'ikinci'])).json['not'] as String;
      await insertCard('k1');
      expect((await kocum(['kisi-ekle', 'İrem', '--takma', 'Iremcik,İre', '--not', 'sınıf arkadaşı'])).code, 0);
      expect((await kocum(['kisi-ekle', 'irem'])).code, 1); // zaten var
      expect((await kocum(['kisi-bagla', a, 'ıremcik'])).code, 0); // takma ad, İ/ı farkı
      expect((await kocum(['kisi-bagla', a, 'Ece'])).code, 1);
      expect((await kocum(['bagla', a, 'not:$b'])).code, 0);
      expect((await kocum(['bagla', b, 'soru:k1'])).code, 0);
      final n = (await repo.findNote(a))!;
      expect(n.personIds.length, 1);
      expect(n.linkedNoteIds, {b});
      expect((await repo.findNote(b))!.linkedCardIds, {'k1'});
      expect((await repo.allPeople()).single.source, Source.claude);
    });

    test('duzelt: alan türüne göre; kimlik, bilinmeyen tablo ve alan reddedilir; arama metni güncellenir', () async {
      final id = (await kocum(['not-ekle', 'eski metin'])).json['not'] as String;
      expect((await kocum(['duzelt', 'anlik_notes', id, 'body', 'Yeni İŞLEM metni'])).code, 0);
      final row = (await db.select(db.anlikNotes).get()).single;
      expect(row.body, 'Yeni İŞLEM metni');
      expect(row.searchText, 'yeni islem metni');
      expect((await kocum(['duzelt', 'anlik_notes', id, 'mood', '3'])).code, 0);
      expect((await db.select(db.anlikNotes).get()).single.mood, 3);
      expect((await kocum(['duzelt', 'anlik_notes', id, 'mood', 'null'])).code, 0);
      expect((await db.select(db.anlikNotes).get()).single.mood, isNull);
      expect((await kocum(['duzelt', 'anlik_notes', id, 'mood', 'çok'])).code, 1);
      expect((await kocum(['duzelt', 'anlik_notes', id, 'id', 'x'])).code, 1);
      expect((await kocum(['duzelt', 'anlik_notes', id, 'yok', 'x'])).code, 1);
      expect((await kocum(['duzelt', 'app_meta', 'x', 'meta_value', 'y'])).code, 1);
      expect((await kocum(['duzelt', 'degisiklikler', 'x', 'islem', 'sil'])).code, 1); // defter düzeltilemez
      expect((await kocum(['duzelt', 'anlik_notes', 'yok', 'body', 'x'])).code, 1);
      // Düzeltme geri alınabilir.
      final last = (await ledger.history(source: 'claude')).first;
      expect(last.op, 'degistir');
    });

    test('sil-oner silmez, yalnızca işaretler', () async {
      final id = (await kocum(['not-ekle', 'silinmesin'])).json['not'] as String;
      final r = await kocum(['sil-oner', 'anlik_notes', id, '--neden', 'tekrar eden not']);
      expect(r.code, 0);
      expect((await db.select(db.anlikNotes).get()).length, 1);
      final s = (await db.select(db.silmeOnerileri).get()).single;
      expect((s.tablo, s.satirId, s.durum, s.neden, s.oneren), ('anlik_notes', id, 'bekliyor', 'tekrar eden not', 'claude'));
      expect((await kocum(['sil-oner', 'anlik_notes', 'yok'])).code, 1);
    });
  });

  group('oturumlar ve geri alma', () {
    test('oturumlar listesi; geri-al değişiklik ve --oturum', () async {
      final id = (await kocum(['not-ekle', 'x', '--oturum', 'A'])).json['not'] as String;
      await kocum(['duzelt', 'anlik_notes', id, 'body', 'y', '--oturum', 'A']);
      await kocum(['not-ekle', 'z', '--oturum', 'B']);

      final list = (await kocum(['oturumlar'])).json['oturumlar'] as List;
      expect({for (final o in list) o['oturum']: o['degisiklik']}, {'A': 3, 'B': 1}); // not + düzeltme + updated_at/search_text
      // Not: düzeltme iki satırlık UPDATE (alan + arama metni) olduğu için 2 değişiklik.

      final undo = await kocum(['geri-al', '--oturum', 'A']);
      expect(undo.code, 0);
      expect(undo.json['geriAlinan'], 3);
      expect((await db.select(db.anlikNotes).get()).map((n) => n.body), ['z']);

      final one = (await ledger.history(session: 'B')).first;
      expect((await kocum(['geri-al', one.id])).json['sonuc'], 'done');
      expect(await db.select(db.anlikNotes).get(), isEmpty);
      expect((await kocum(['geri-al', one.id])).json['sonuc'], 'already');
      expect((await kocum(['geri-al', 'yok'])).code, 1);
    });
  });

  group('Markdown dışa aktarma', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('kocum_md'));
    tearDown(() => dir.delete(recursive: true));

    test('dosya yolu, YAML başlık, günlük özet', () async {
      await kocum(['not-ekle', 'Kantinde ((his > tiksinti)) hissettim: "tırnak" ve iki nokta', '--olustur', '--kisi', 'Şule', '--ruh', '2', '--zaman', '2026-10-20T08:30', '--ders', 'TYT Matematik']);
      await kocum(['not-ekle', '', '--zaman', '2026-10-20T08:30']).then((_) {}); // boş not reddedilir
      final r = await kocum(['disa-aktar', dir.path]);
      expect(r.code, 0, reason: r.err);
      expect(r.json['not'], 1);

      final note = (await repo.allNotes()).single;
      final file = File('${dir.path}/${notePath(note)}');
      expect(file.existsSync(), isTrue);
      expect(notePath(note), matches(RegExp(r'^anlik/2026/10/2026-10-20_0830_[A-Za-z0-9_-]+\.md$')));
      final text = await file.readAsString();
      expect(text, startsWith('---\nid: '));
      expect(text, contains('zaman: 2026-10-20T08:30:00'));
      expect(text, contains('tur: anlik'));
      expect(text, contains('ruh: 2'));
      expect(text, contains('ders: TYT Matematik'));
      expect(text, contains('etiketler: ["his > tiksinti"]'));
      expect(text, contains('kisiler: [Şule]'));
      expect(text, contains('baglar: []'));
      expect(text, contains('Kantinde ((his > tiksinti)) hissettim: "tırnak" ve iki nokta'));

      final daily = File('${dir.path}/gunluk/2026-10-20.md');
      expect(daily.existsSync(), isTrue);
      final d = await daily.readAsString();
      expect(d, contains('tarih: 2026-10-20'));
      expect(d, contains('not_sayisi: 1'));
      expect(d, contains('ruh_ortalama: 2.0'));
      expect(d, contains('# 20 Ekim 2026'));
      expect(d, contains('08:30 — Kantinde'));
    });
  });

  group('Markdown saf fonksiyonlar', () {
    test('YAML metin kaçışı', () {
      expect(yamlScalar('TYT Matematik'), 'TYT Matematik');
      expect(yamlScalar('his > tiksinti'), '"his > tiksinti"'); // > özel karakter: tırnaklı
      expect(yamlScalar('a: b'), '"a: b"');
      expect(yamlScalar('say"ı'), r'"say\"ı"');
      expect(yamlScalar('true'), '"true"');
      expect(yamlScalar('123'), '"123"');
      expect(yamlScalar(''), '""');
      expect(yamlScalar('İş ve Işık'), 'İş ve Işık');
    });

    test('günlük özet: uyku gece yarısını aşsa da eşleşir', () {
      AnlikNote n(String id, DateTime at, AnlikKind k) =>
          AnlikNote(id: id, createdAt: at, updatedAt: at, body: k == AnlikKind.yattim ? 'Yattım' : 'Kalktım', kind: k);
      final notes = [
        n('a', DateTime(2026, 10, 20, 23, 30), AnlikKind.yattim),
        n('b', DateTime(2026, 10, 21, 7, 0), AnlikKind.kalktim),
      ];
      final s = renderDailySummary(DateTime(2026, 10, 21), notes, tags: const [], people: const []);
      expect(s, contains('kalktim: 2026-10-21T07:00:00'));
      expect(s, contains('sure: 7 sa 30 dk'));
      expect(s, contains('not_sayisi: 0'));
      expect(s, contains('Bu gün not yok.'));
    });
  });
}
