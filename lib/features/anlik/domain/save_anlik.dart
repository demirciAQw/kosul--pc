import '../../../core/text/turkish_text.dart';
import '../../../core/utils/id_generator.dart';
import '../../ocr/domain/auto_tags.dart';
import 'anlik.dart';
import 'anlik_repository.dart';
import 'mentions.dart';

/// Anlık notu kaydeder: metindeki `((etiket))` ve `@kişi` yazımlarını çözer,
/// konuyu otomatik etiketler. Olmayan etiket ve kişi, adı onaylanmadan
/// oluşmaz ([UnknownMentionsException]); hiçbir şey yazılmadan geri döner.
class SaveAnlik {
  SaveAnlik(this._repo, this._ids, this._clock, {this.lexicon});

  final AnlikRepository _repo;
  final IdGenerator _ids;
  final Clock _clock;

  /// Yoksa otomatik etiket çıkarılmaz.
  final TopicLexicon? lexicon;

  Future<AnlikNote> call({
    AnlikNote? existing,
    required String body,
    AnlikKind kind = AnlikKind.anlik,
    int? mood,
    DateTime? at,
    String? subject,
    String? mebNodeId,
    String? topicText,

    /// Etiket çubuğundakiler (kimlik). Çıkarılan otomatik etiket burada yoktur.
    Set<String> tagIds = const {},
    Set<String> personIds = const {},
    Set<String> linkedNoteIds = const {},
    Set<String> linkedCardIds = const {},

    /// Onaylanan yeni etiket adları ("his", "tiksinti") ve kişi adları.
    Set<String> approvedTags = const {},
    Set<String> approvedPeople = const {},

    /// Kullanıcının kaldırdığı otomatik etiketlerin anahtarı; yeniden eklenmez.
    Set<String> dismissedAutoKeys = const {},
    String source = Source.ben,
  }) async {
    var text = body.trim();
    if (text.isEmpty && kind != AnlikKind.anlik) {
      text = kind == AnlikKind.yattim ? 'Yattım' : 'Kalktım';
    }
    if (text.isEmpty) throw const AnlikException('Bir şeyler yaz.');
    if (mood != null && (mood < 1 || mood > 5)) throw const AnlikException('Ruh hâli 1 ile 5 arasında olmalı.');
    final now = _clock();

    final tags = await _repo.allTags();
    final people = await _repo.allPeople();
    final byKey = {for (final t in tags) t.name: t};

    final newTags = <Tag>[];
    final unknownTags = <String>[];
    final mentionTagIds = <String>{};
    for (final path in parseTagMentions(text)) {
      String? parent;
      for (var i = 0; i < path.length; i++) {
        final label = path[i];
        final key = tagKey(label);
        var t = byKey[key];
        if (t == null) {
          if (!approvedTags.map(tagKey).contains(key)) {
            if (!unknownTags.contains(label)) unknownTags.add(label);
            break; // altındakiler de onay bekler; üstü onaylanınca sorulur
          }
          t = Tag(id: _ids.next(), name: key, label: label, parentId: parent, source: source, createdAt: now);
          byKey[key] = t;
          newTags.add(t);
        }
        parent = t.id;
        if (i == path.length - 1) mentionTagIds.add(t.id);
      }
    }

    final newPeople = <Person>[];
    final unknownPeople = <String>[];
    final mentionPersonIds = <String>{};
    final allPeople = [...people];
    for (final name in parsePersonMentions(text)) {
      var p = matchPerson(name, allPeople);
      if (p == null) {
        if (!approvedPeople.map(normalizeTr).contains(normalizeTr(name))) {
          unknownPeople.add(name);
          continue;
        }
        p = Person(id: _ids.next(), name: name, createdAt: now, source: source);
        allPeople.add(p);
        newPeople.add(p);
      }
      mentionPersonIds.add(p.id);
    }
    if (unknownTags.isNotEmpty || unknownPeople.isNotEmpty) {
      throw UnknownMentionsException(tags: unknownTags, people: unknownPeople);
    }

    // Otomatik konu etiketi: yalnızca yeni notta ya da metin değişince.
    final autoIds = <String>{...tagIds.intersection(existing?.autoTagIds ?? const {})};
    final lex = lexicon;
    if (lex != null && kind == AnlikKind.anlik && (existing == null || existing.body != text)) {
      final pick = pickTopic(topicScores(lex, subject ?? '', text));
      final topic = pick.topic;
      if (topic != null && !dismissedAutoKeys.contains(tagKey(topic))) {
        var t = byKey[tagKey(topic)];
        if (t == null) {
          t = Tag(id: _ids.next(), name: tagKey(topic), label: topic, source: Source.otomatik, createdAt: now);
          byKey[t.name] = t;
          newTags.add(t);
        }
        if (!tagIds.contains(t.id) && !mentionTagIds.contains(t.id)) autoIds.add(t.id);
      }
    }

    final note = AnlikNote(
      id: existing?.id ?? _ids.next(),
      createdAt: at ?? existing?.createdAt ?? now,
      updatedAt: now,
      body: text,
      kind: existing?.kind ?? kind,
      mood: mood,
      subject: subject,
      mebNodeId: mebNodeId,
      topicText: topicText,
      tagIds: {...tagIds, ...mentionTagIds, ...autoIds},
      autoTagIds: autoIds,
      personIds: {...personIds, ...mentionPersonIds},
      linkedNoteIds: linkedNoteIds,
      linkedCardIds: linkedCardIds,
    );
    await _repo.commit(note: note, newTags: newTags, newPeople: newPeople, source: source);
    return note;
  }
}
