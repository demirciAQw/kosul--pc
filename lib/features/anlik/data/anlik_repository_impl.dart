import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/anlik.dart';
import '../domain/anlik_repository.dart';

class DriftAnlikRepository implements AnlikRepository {
  DriftAnlikRepository(this._db);
  final AppDatabase _db;

  Set<TableInfo> get _noteTables =>
      {_db.anlikNotes, _db.anlikNoteTags, _db.anlikNotePeople, _db.anlikLinks};

  Tag _tag(TagRow r) => Tag(
        id: r.id,
        name: r.name,
        label: r.label,
        parentId: r.parentId,
        source: r.source,
        createdAt: r.createdAt,
      );

  Person _person(PersonRow r) =>
      Person(id: r.id, name: r.name, aliases: r.aliases, about: r.about, source: r.source, createdAt: r.createdAt);

  @override
  Stream<List<AnlikNote>> watchNotes() =>
      _db.customSelect("SELECT 'watchAnlikNotes'", readsFrom: _noteTables).watch().asyncMap((_) => allNotes());

  @override
  Future<List<AnlikNote>> allNotes() async {
    final rows = await (_db.select(_db.anlikNotes)..orderBy([(n) => OrderingTerm.desc(n.createdAt)])).get();
    final tagRows = await _db.select(_db.anlikNoteTags).get();
    final personRows = await _db.select(_db.anlikNotePeople).get();
    final linkRows = await _db.select(_db.anlikLinks).get();
    final tags = <String, Set<String>>{};
    final autos = <String, Set<String>>{};
    for (final r in tagRows) {
      (tags[r.noteId] ??= {}).add(r.tagId);
      if (r.source == Source.otomatik) (autos[r.noteId] ??= {}).add(r.tagId);
    }
    final people = <String, Set<String>>{};
    for (final r in personRows) {
      (people[r.noteId] ??= {}).add(r.personId);
    }
    final linkedNotes = <String, Set<String>>{};
    final linkedCards = <String, Set<String>>{};
    for (final r in linkRows) {
      if (r.toNoteId != null) (linkedNotes[r.fromNoteId] ??= {}).add(r.toNoteId!);
      if (r.toCardId != null) (linkedCards[r.fromNoteId] ??= {}).add(r.toCardId!);
    }
    return [
      for (final r in rows)
        AnlikNote(
          id: r.id,
          createdAt: r.createdAt,
          updatedAt: r.updatedAt,
          body: r.body,
          kind: AnlikKind.fromKey(r.kind),
          mood: r.mood,
          subject: r.subject,
          mebNodeId: r.mebNodeId,
          topicText: r.topicText,
          tagIds: tags[r.id] ?? const {},
          autoTagIds: autos[r.id] ?? const {},
          personIds: people[r.id] ?? const {},
          linkedNoteIds: linkedNotes[r.id] ?? const {},
          linkedCardIds: linkedCards[r.id] ?? const {},
        ),
    ];
  }

  @override
  Future<AnlikNote?> findNote(String id) async => (await allNotes()).where((n) => n.id == id).firstOrNull;

  TagsCompanion _tagRow(Tag t) => TagsCompanion.insert(
        id: t.id,
        name: t.name,
        label: t.label,
        parentId: Value(t.parentId),
        source: Value(t.source),
        createdAt: t.createdAt,
      );

  PeopleCompanion _personRow(Person p) => PeopleCompanion.insert(
        id: p.id,
        name: p.name,
        aliases: Value(p.aliases),
        about: Value(p.about),
        source: Value(p.source),
        createdAt: p.createdAt,
      );

  @override
  Future<void> commit({
    required AnlikNote note,
    List<Tag> newTags = const [],
    List<Person> newPeople = const [],
    String source = Source.ben,
  }) =>
      _db.transaction(() async {
        // Üst etiket önce yazılır (yabancı anahtar).
        for (final t in newTags) {
          await _db.into(_db.tags).insert(_tagRow(t));
        }
        for (final p in newPeople) {
          await _db.into(_db.people).insert(_personRow(p));
        }
        await _db.into(_db.anlikNotes).insertOnConflictUpdate(AnlikNotesCompanion.insert(
              id: note.id,
              createdAt: note.createdAt,
              updatedAt: note.updatedAt,
              body: note.body,
              kind: Value(note.kind.key),
              mood: Value(note.mood),
              searchText: Value(note.searchText),
              subject: Value(note.subject),
              mebNodeId: Value(note.mebNodeId),
              topicText: Value(note.topicText),
            ));
        await (_db.delete(_db.anlikNoteTags)..where((r) => r.noteId.equals(note.id))).go();
        for (final id in note.tagIds) {
          await _db.into(_db.anlikNoteTags).insert(AnlikNoteTagsCompanion.insert(
                id: '${note.id}:$id',
                noteId: note.id,
                tagId: id,
                source: Value(note.autoTagIds.contains(id) ? Source.otomatik : source),
              ));
        }
        await (_db.delete(_db.anlikNotePeople)..where((r) => r.noteId.equals(note.id))).go();
        for (final id in note.personIds) {
          await _db.into(_db.anlikNotePeople).insert(
                AnlikNotePeopleCompanion.insert(id: '${note.id}:$id', noteId: note.id, personId: id, source: Value(source)),
              );
        }
        await (_db.delete(_db.anlikLinks)..where((r) => r.fromNoteId.equals(note.id))).go();
        for (final id in note.linkedNoteIds) {
          await _db.into(_db.anlikLinks).insert(AnlikLinksCompanion.insert(
                id: '${note.id}>n:$id',
                fromNoteId: note.id,
                toNoteId: Value(id),
                source: Value(source),
                createdAt: note.updatedAt,
              ));
        }
        for (final id in note.linkedCardIds) {
          await _db.into(_db.anlikLinks).insert(AnlikLinksCompanion.insert(
                id: '${note.id}>c:$id',
                fromNoteId: note.id,
                toCardId: Value(id),
                source: Value(source),
                createdAt: note.updatedAt,
              ));
        }
      });

  @override
  Future<void> deleteNote(String id) => (_db.delete(_db.anlikNotes)..where((n) => n.id.equals(id))).go();

  @override
  Future<void> linkNoteToCard(String noteId, String cardId, {String source = Source.ben}) =>
      _db.into(_db.anlikLinks).insertOnConflictUpdate(AnlikLinksCompanion.insert(
            id: '$noteId>c:$cardId',
            fromNoteId: noteId,
            toCardId: Value(cardId),
            source: Value(source),
            createdAt: DateTime.now(),
          ));

  @override
  Future<void> unlinkNoteFromCard(String noteId, String cardId) =>
      (_db.delete(_db.anlikLinks)..where((l) => l.id.equals('$noteId>c:$cardId'))).go();

  @override
  Future<void> addNoteTag(String noteId, String tagId, {String source = Source.ben}) =>
      _db.into(_db.anlikNoteTags).insert(
            AnlikNoteTagsCompanion.insert(id: '$noteId:$tagId', noteId: noteId, tagId: tagId, source: Value(source)),
            mode: InsertMode.insertOrIgnore,
          );

  @override
  Future<void> removeNoteTag(String noteId, String tagId) =>
      (_db.delete(_db.anlikNoteTags)..where((r) => r.noteId.equals(noteId) & r.tagId.equals(tagId))).go();

  @override
  Future<void> addCardTag(String cardId, String tagId, {String source = Source.ben}) =>
      _db.into(_db.questionCardTags).insert(
            QuestionCardTagsCompanion.insert(id: '$cardId:$tagId', cardId: cardId, tagId: tagId, source: Value(source)),
            mode: InsertMode.insertOrIgnore,
          );

  @override
  Future<void> removeCardTag(String cardId, String tagId) =>
      (_db.delete(_db.questionCardTags)..where((r) => r.cardId.equals(cardId) & r.tagId.equals(tagId))).go();

  @override
  Future<void> addNotePerson(String noteId, String personId, {String source = Source.ben}) =>
      _db.into(_db.anlikNotePeople).insert(
            AnlikNotePeopleCompanion.insert(id: '$noteId:$personId', noteId: noteId, personId: personId, source: Value(source)),
            mode: InsertMode.insertOrIgnore,
          );

  @override
  Future<void> linkNoteToNote(String fromId, String toId, {String source = Source.ben}) =>
      _db.into(_db.anlikLinks).insert(
            AnlikLinksCompanion.insert(
              id: '$fromId>n:$toId',
              fromNoteId: fromId,
              toNoteId: Value(toId),
              source: Value(source),
              createdAt: DateTime.now(),
            ),
            mode: InsertMode.insertOrIgnore,
          );

  @override
  Stream<List<Tag>> watchTags() => (_db.select(_db.tags)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch().map(
        (rows) => [for (final r in rows) _tag(r)],
      );

  @override
  Future<List<Tag>> allTags() async => [for (final r in await _db.select(_db.tags).get()) _tag(r)];

  @override
  Future<void> saveTag(Tag tag) => _db.into(_db.tags).insertOnConflictUpdate(_tagRow(tag));

  @override
  Future<void> mergeTags(String from, String into) {
    if (from == into) return Future.value();
    return _db.transaction(() async {
      // Aynı nota iki etiket de bağlıysa çift kayıt olmasın (INSERT OR IGNORE).
      await _db.customStatement(
        'INSERT OR IGNORE INTO anlik_note_tags (id, note_id, tag_id, source) '
        "SELECT note_id || ':' || ?1, note_id, ?1, source FROM anlik_note_tags WHERE tag_id = ?2",
        [into, from],
      );
      await _db.customStatement(
        'INSERT OR IGNORE INTO question_card_tags (id, card_id, tag_id, source) '
        "SELECT card_id || ':' || ?1, card_id, ?1, source FROM question_card_tags WHERE tag_id = ?2",
        [into, from],
      );
      final fromParent = await (_db.select(_db.tags)..where((t) => t.id.equals(from))).getSingleOrNull();
      await (_db.update(_db.tags)..where((t) => t.parentId.equals(from)))
          .write(TagsCompanion(parentId: Value(into)));
      // [into], [from]'un altındaysa kendi kendisinin üstü olmasın.
      await (_db.update(_db.tags)..where((t) => t.id.equals(into) & t.parentId.equals(into)))
          .write(TagsCompanion(parentId: Value(fromParent?.parentId)));
      await (_db.delete(_db.tags)..where((t) => t.id.equals(from))).go(); // bağlar cascade
    });
  }

  @override
  Stream<List<Person>> watchPeople() => (_db.select(_db.people)..orderBy([(p) => OrderingTerm.asc(p.name)])).watch().map(
        (rows) => [for (final r in rows) _person(r)],
      );

  @override
  Future<List<Person>> allPeople() async => [for (final r in await _db.select(_db.people).get()) _person(r)];

  @override
  Future<void> savePerson(Person p) => _db.into(_db.people).insertOnConflictUpdate(_personRow(p));

  @override
  Stream<Map<String, Set<String>>> watchCardTags() => _db.select(_db.questionCardTags).watch().map((rows) {
        final out = <String, Set<String>>{};
        for (final r in rows) {
          (out[r.cardId] ??= {}).add(r.tagId);
        }
        return out;
      });

  @override
  Future<void> setCardTags(String cardId, Set<String> tagIds, {String source = Source.ben}) => _db.transaction(() async {
        await (_db.delete(_db.questionCardTags)..where((r) => r.cardId.equals(cardId))).go();
        for (final id in tagIds) {
          await _db.into(_db.questionCardTags).insert(
                QuestionCardTagsCompanion.insert(id: '$cardId:$id', cardId: cardId, tagId: id, source: Value(source)),
              );
        }
      });
}
