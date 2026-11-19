import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/features/anlik/data/anlik_repository_impl.dart';
import 'package:kocum/features/anlik/domain/anlik.dart';
import 'package:kocum/features/anlik/domain/anlik_search.dart';
import 'package:kocum/features/anlik/domain/mentions.dart';
import 'package:kocum/features/anlik/domain/save_anlik.dart';
import 'package:kocum/features/anlik/domain/tag_tree.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'id${_n++}';
}

final _t0 = DateTime(2026, 10, 18, 9);

Tag _tag(String id, String label, {String? parent}) =>
    Tag(id: id, name: tagKey(label), label: label, parentId: parent, createdAt: _t0);

AnlikNote _note(String id, String body, DateTime at,
        {Set<String> tags = const {}, Set<String> people = const {}, AnlikKind kind = AnlikKind.anlik, String? subject}) =>
    AnlikNote(
        id: id, createdAt: at, updatedAt: at, body: body, tagIds: tags, personIds: people, kind: kind, subject: subject);

void main() {
  group('ayrıştırma', () {
    test('((etiket)) bulunur, yinelenenler tek sayılır, İ/ı ayrımı yapılmaz', () {
      final p = parseTagMentions('Bugün ((Tiksinti)) vardı, ((TİKSİNTİ)) ve ((his > korku)) ile (( )) boş');
      expect(p, [
        ['Tiksinti'],
        ['his', 'korku'],
      ]);
      expect(tagKey('TİKSİNTİ'), tagKey('tiksinti'));
      expect(tagKey('IŞIK'), tagKey('ışık'));
    });

    test('@kişi: Türkçe harfler, parantezli çok kelimeli ad, e-posta sayılmaz', () {
      expect(parsePersonMentions('@Şule ile @(Ayşe Nur) konuştum, a@b.com değil, @şule yine'), ['Şule', 'Ayşe Nur']);
      expect(parsePersonMentions('mail: ali@okul.com'), isEmpty);
    });

    test('takma ad ve büyük/küçük harf eşleşmesi', () {
      final people = [
        Person(id: 'p1', name: 'İrem', aliases: const ['Iremcik', 'Işıl'], createdAt: _t0),
      ];
      expect(matchPerson('irem', people)?.id, 'p1');
      expect(matchPerson('İREM', people)?.id, 'p1');
      expect(matchPerson('ıremcik', people)?.id, 'p1');
      expect(matchPerson('ışıl', people)?.id, 'p1');
      expect(matchPerson('Ece', people), isNull);
    });

    test('yazarken öneri bağlamı ve yerine koyma', () {
      var text = 'Bugün ((tik';
      final c = mentionAt(text, text.length)!;
      expect(c.isTag, isTrue);
      expect(c.prefix, 'tik');
      final r = applyMention(text, text.length, c, 'Tiksinti');
      expect(r.text, 'Bugün ((Tiksinti))');
      expect(r.cursor, r.text.length);

      text = 'Ders sonrası @şu';
      final p = mentionAt(text, text.length)!;
      expect(p.isTag, isFalse);
      expect(p.prefix, 'şu');
      expect(applyMention(text, text.length, p, 'Şule').text, 'Ders sonrası @Şule');
      expect(applyMention(text, text.length, p, 'Ayşe Nur').text, 'Ders sonrası @(Ayşe Nur)');

      expect(mentionAt('kapalı ((etiket)) sonra', 23), isNull);
      expect(mentionAt('ali@okul', 8), isNull);
    });

    test('öneri sıralaması: önek önce, içinde geçen sonra', () {
      final s = suggestNames('is', ['Tiksinti', 'İş', 'Işık', 'Mola']);
      expect(s.first, anyOf('İş', 'Işık'));
      expect(s, isNot(contains('Mola')));
      expect(suggestNames('', ['b', 'a']), ['a', 'b']);
    });
  });

  group('etiket ağacı', () {
    final tags = [
      _tag('his', 'his'),
      _tag('tik', 'tiksinti', parent: 'his'),
      _tag('kor', 'korku', parent: 'his'),
      _tag('ders', 'ders'),
    ];

    test('alt etiketler dahil, döngüde sonsuza gitmez', () {
      expect(tagWithDescendants(tags, 'his'), {'his', 'tik', 'kor'});
      expect(tagWithDescendants(tags, 'tik'), {'tik'});
      final loop = [_tag('a', 'a', parent: 'b'), _tag('b', 'b', parent: 'a')];
      expect(tagWithDescendants(loop, 'a'), {'a', 'b'});
      expect(tagPathLabel(loop, 'a').split(' > ').length, 2);
    });

    test('yol, üst seçme koruması ve ağaç sırası', () {
      expect(tagPathLabel(tags, 'tik'), 'his > tiksinti');
      expect(canSetParent(tags, 'his', 'tik'), isFalse);
      expect(canSetParent(tags, 'his', 'his'), isFalse);
      expect(canSetParent(tags, 'tik', 'ders'), isTrue);
      expect(canSetParent(tags, 'tik', null), isTrue);
      expect([for (final (t, d) in tagTreeOrder(tags)) '$d${t.id}'], ['0ders', '0his', '1kor', '1tik']);
    });
  });

  group('arama', () {
    final tags = [_tag('his', 'his'), _tag('tik', 'tiksinti', parent: 'his'), _tag('ders', 'ders')];
    final notes = [
      _note('1', 'Kantinde İŞLEM yaptım', DateTime(2026, 10, 1, 10), tags: {'tik'}, people: {'p1'}),
      _note('2', 'Ders çalıştım', DateTime(2026, 10, 5, 23, 59), tags: {'ders'}, subject: 'TYT Matematik'),
      _note('3', 'Yattım', DateTime(2026, 10, 6, 0, 5), kind: AnlikKind.yattim),
    ];

    test('kelime Türkçe harften bağımsız, hepsi geçmeli', () {
      expect(filterAnlik(notes, const AnlikFilter(query: 'islem')).map((n) => n.id), ['1']);
      expect(filterAnlik(notes, const AnlikFilter(query: 'İŞLEM kantin')).map((n) => n.id), ['1']);
      expect(filterAnlik(notes, const AnlikFilter(query: 'işlem ders')), isEmpty);
    });

    test('üst etiket alt etiketlilerini de getirir', () {
      expect(filterAnlik(notes, const AnlikFilter(tagId: 'his'), tags: tags).map((n) => n.id), ['1']);
      expect(filterAnlik(notes, const AnlikFilter(tagId: 'tik'), tags: tags).map((n) => n.id), ['1']);
      expect(filterAnlik(notes, const AnlikFilter(tagId: 'ders'), tags: tags).map((n) => n.id), ['2']);
    });

    test('kişi, ders, tür ve tarih aralığı (uç günler dahil)', () {
      expect(filterAnlik(notes, const AnlikFilter(personId: 'p1')).map((n) => n.id), ['1']);
      expect(filterAnlik(notes, const AnlikFilter(subject: 'TYT Matematik')).map((n) => n.id), ['2']);
      expect(filterAnlik(notes, const AnlikFilter(kind: AnlikKind.yattim)).map((n) => n.id), ['3']);
      final r = filterAnlik(notes, AnlikFilter(from: DateTime(2026, 10, 5), to: DateTime(2026, 10, 5)));
      expect(r.map((n) => n.id), ['2']);
      expect(filterAnlik(notes, const AnlikFilter()).map((n) => n.id), ['3', '2', '1']); // en yeni başta
    });

    test('uyku geceleri: yattım-kalktım eşleşir, kalkmayı unutan gece açık kalır', () {
      final s = [
        _note('a', 'Yattım', DateTime(2026, 10, 1, 23), kind: AnlikKind.yattim),
        _note('b', 'Kalktım', DateTime(2026, 10, 2, 7), kind: AnlikKind.kalktim),
        _note('c', 'Yattım', DateTime(2026, 10, 2, 23), kind: AnlikKind.yattim),
        _note('d', 'Yattım', DateTime(2026, 10, 3, 23, 30), kind: AnlikKind.yattim),
        _note('e', 'Kalktım', DateTime(2026, 10, 4, 8), kind: AnlikKind.kalktim),
        _note('f', 'Kalktım', DateTime(2026, 10, 5, 8), kind: AnlikKind.kalktim), // yatışsız
      ];
      final n = sleepNights(s);
      expect(n.length, 3);
      expect(n[0].length, const Duration(hours: 8));
      expect(n[1].wake, isNull);
      expect(n[2].length, const Duration(hours: 8, minutes: 30));
    });
  });

  group('kaydetme', () {
    late AppDatabase db;
    late DriftAnlikRepository repo;
    late SaveAnlik save;
    var now = _t0;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = DriftAnlikRepository(db);
      now = _t0;
      save = SaveAnlik(
        repo,
        _Ids(),
        () => now,
        lexicon: TopicLexicon.fromJson({
          'subjects': {'matematik': ['mat']},
          'families': {
            'mat': {
              'Türev': ['turev', 'zincir kurali'],
              'Limit': ['limit'],
            },
          },
        }),
      );
    });
    tearDown(() => db.close());

    test('olmayan etiket ve kişi onaysız oluşmaz, hiçbir şey yazılmaz', () async {
      await expectLater(
        save(body: 'Bugün ((his > tiksinti)) vardı, @Şule gördü'),
        throwsA(isA<UnknownMentionsException>()
            .having((e) => e.tags, 'etiketler', ['his'])
            .having((e) => e.people, 'kişiler', ['Şule'])),
      );
      expect(await repo.allNotes(), isEmpty);
      expect(await repo.allTags(), isEmpty);
      expect(await repo.allPeople(), isEmpty);
    });

    test('onaylanınca etiket ağacı, kişi ve not birlikte yazılır', () async {
      final n = await save(
        body: 'Bugün ((his > tiksinti)) vardı, @Şule gördü',
        approvedTags: {'his', 'tiksinti'},
        approvedPeople: {'şule'},
      );
      final tags = {for (final t in await repo.allTags()) t.name: t};
      expect(tags.keys, {'his', 'tiksinti'});
      expect(tags['tiksinti']!.parentId, tags['his']!.id);
      expect((await repo.allPeople()).single.name, 'Şule');
      final got = (await repo.findNote(n.id))!;
      expect(got.tagIds, {tags['tiksinti']!.id});
      expect(got.personIds.length, 1);
      expect(got.searchText, contains('bugun'));
    });

    test('var olan etiket ve takma adla kişi sessizce bağlanır', () async {
      await repo.savePerson(Person(id: 'p1', name: 'Şule', aliases: const ['Şulo'], createdAt: _t0));
      await repo.saveTag(_tag('t1', 'Tiksinti'));
      final n = await save(body: '((tiksinti)) hakkında @şulo ile konuştum');
      expect(n.tagIds, {'t1'});
      expect(n.personIds, {'p1'});
      expect((await repo.allTags()).length, 1);
    });

    test('konu otomatik etiketlenir; kullanıcı kaldırınca düzenlemede geri gelmez', () async {
      final n = await save(body: 'Zincir kuralında içerinin türevi', subject: 'TYT Matematik');
      final tag = (await repo.allTags()).single;
      expect(tag.label, 'Türev');
      expect(tag.source, Source.otomatik);
      expect(n.autoTagIds, {tag.id});

      // Kullanıcı etiketi çubuktan çıkarır, metin değişmez.
      now = now.add(const Duration(minutes: 5));
      final kept = await save(existing: n, body: n.body, subject: 'TYT Matematik', tagIds: {});
      expect(kept.tagIds, isEmpty);
      // Metin değişse bile kaldırılan konu yeniden eklenmez.
      final edited = await save(
        existing: kept,
        body: 'Türev ile zincir kuralı',
        subject: 'TYT Matematik',
        dismissedAutoKeys: {tagKey('Türev')},
      );
      expect(edited.tagIds, isEmpty);
      expect(edited.createdAt, _t0);
      expect(edited.updatedAt, now);
    });

    test('uyku kaydı gövdesiz yazılır, ruh hâli sınırı denetlenir, boş not reddedilir', () async {
      final s = await save(body: '', kind: AnlikKind.yattim);
      expect(s.body, 'Yattım');
      expect(s.isSleep, isTrue);
      await expectLater(save(body: '   '), throwsA(isA<AnlikException>()));
      await expectLater(save(body: 'x', mood: 6), throwsA(isA<AnlikException>()));
    });

    test('düzenlenebilir tarih ve bağlar; not silinince bağlar da gider', () async {
      final a = await save(body: 'birinci', at: DateTime(2026, 9, 1, 8));
      expect(a.createdAt, DateTime(2026, 9, 1, 8));
      final b = await save(body: 'ikinci', linkedNoteIds: {a.id});
      expect((await repo.findNote(b.id))!.linkedNoteIds, {a.id});
      await repo.deleteNote(a.id);
      expect((await repo.findNote(b.id))!.linkedNoteIds, isEmpty);
    });

    test('etiket birleştirme: notlar ve kartlar geçer, alt etiketler taşınır, çift kayıt olmaz', () async {
      await repo.saveTag(_tag('x', 'x'));
      await repo.saveTag(_tag('y', 'y'));
      await repo.saveTag(_tag('alt', 'alt', parent: 'x'));
      final n = await save(body: 'not', tagIds: {'x', 'y'});
      await repo.mergeTags('x', 'y');
      expect((await repo.findNote(n.id))!.tagIds, {'y'});
      final tags = {for (final t in await repo.allTags()) t.id: t};
      expect(tags.containsKey('x'), isFalse);
      expect(tags['alt']!.parentId, 'y');
    });

    test('birleştirme: hedef kaynağın altındaysa kendi üstü olmaz', () async {
      await repo.saveTag(_tag('ust', 'ust'));
      await repo.saveTag(_tag('x', 'x', parent: 'ust'));
      await repo.saveTag(_tag('y', 'y', parent: 'x'));
      await repo.mergeTags('x', 'y');
      final tags = {for (final t in await repo.allTags()) t.id: t};
      expect(tags['y']!.parentId, 'ust');
    });

    test('soru kartına serbest etiket eklenir ve kart silinince etiket bağı gider', () async {
      await db.customStatement('PRAGMA foreign_keys = ON');
      await repo.saveTag(_tag('t', 't'));
      await db.into(db.questionCards).insert(QuestionCardsCompanion.insert(
            id: 'c1',
            status: 'wrong',
            origin: 'independent',
            sourceName: 'Kitap dışı',
            subject: 'TYT Matematik',
            difficulty: 3,
            searchText: '',
            createdAt: _t0,
          ));
      await repo.setCardTags('c1', {'t'});
      expect(await repo.watchCardTags().first, {'c1': {'t'}});
      await (db.delete(db.questionCards)..where((c) => c.id.equals('c1'))).go();
      expect(await repo.watchCardTags().first, isEmpty);
      expect((await repo.allTags()).length, 1); // etiket kalır
    });
  });

  test('v11 veritabanı v12\'ye yükselir: yeni tablolar oluşur, eski veri durur', () async {
    final dir = await Directory.systemTemp.createTemp('anlik_goc');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    await db.customStatement('SELECT 1'); // oluştur
    await db.into(db.studyNotes).insert(StudyNotesCompanion.insert(
        id: 'n', subject: 'TYT', body: 'eski not', createdAt: _t0, updatedAt: _t0));
    for (final t in ['anlik_note_tags', 'anlik_note_people', 'anlik_links', 'question_card_tags', 'anlik_notes', 'people', 'tags']) {
      await db.customStatement('DROP TABLE $t');
    }
    await db.customStatement('PRAGMA user_version = 11');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final repo = DriftAnlikRepository(db);
    await SaveAnlik(repo, _Ids(), () => _t0)(body: 'yeni');
    expect((await repo.allNotes()).length, 1);
    expect((await db.select(db.studyNotes).get()).single.body, 'eski not');
  });
}
