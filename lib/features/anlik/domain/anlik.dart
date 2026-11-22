import '../../../core/text/turkish_text.dart';

/// Anlık not türleri. Uyku kaydı da bir nottur (Yattım / Kalktım).
enum AnlikKind {
  anlik('anlik'),
  yattim('uyku_yattim'),
  kalktim('uyku_kalktim');

  const AnlikKind(this.key);
  final String key;

  static AnlikKind fromKey(String key) =>
      AnlikKind.values.firstWhere((k) => k.key == key, orElse: () => AnlikKind.anlik);
}

/// Etiketin ya da bağın kaynağı.
abstract final class Source {
  static const ben = 'ben';
  static const claude = 'claude';
  static const otomatik = 'otomatik';
}

class Tag {
  const Tag({
    required this.id,
    required this.name,
    required this.label,
    required this.createdAt,
    this.parentId,
    this.source = Source.ben,
  });

  final String id;

  /// `normalizeTr(label)`: benzersiz anahtar.
  final String name;
  final String label;
  final String? parentId;
  final String source;
  final DateTime createdAt;

  Tag copyWith({String? label, String? parentId, bool clearParent = false}) => Tag(
        id: id,
        name: label == null ? name : tagKey(label),
        label: label ?? this.label,
        parentId: clearParent ? null : (parentId ?? this.parentId),
        source: source,
        createdAt: createdAt,
      );
}

/// Etiketin benzersiz anahtarı: "Tiksinti", "tiksinti" ve "TİKSİNTİ" aynıdır.
String tagKey(String label) => normalizeTr(label);

class Person {
  const Person({
    required this.id,
    required this.name,
    required this.createdAt,
    this.aliases = const [],
    this.about = '',
    this.source = Source.ben,
  });

  final String id;
  final String name;
  final List<String> aliases;
  final String about;
  final String source;
  final DateTime createdAt;

  /// Adı ve takma adları, katlanmış.
  Set<String> get keys => {normalizeTr(name), for (final a in aliases) normalizeTr(a)}..remove('');
}

/// Bir anlık not ve ilişkileri (etiket, kişi, bağ).
class AnlikNote {
  const AnlikNote({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.body,
    this.kind = AnlikKind.anlik,
    this.mood,
    this.subject,
    this.mebNodeId,
    this.topicText,
    this.tagIds = const {},
    this.autoTagIds = const {},
    this.personIds = const {},
    this.linkedNoteIds = const {},
    this.linkedCardIds = const {},
  });

  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String body;
  final AnlikKind kind;
  final int? mood; // 1–5
  final String? subject;
  final String? mebNodeId;
  final String? topicText;

  /// Tüm etiketler (otomatik olanlar dahil).
  final Set<String> tagIds;

  /// `tagIds` içinde kaynağı "otomatik" olanlar.
  final Set<String> autoTagIds;
  final Set<String> personIds;
  final Set<String> linkedNoteIds;
  final Set<String> linkedCardIds;

  String get searchText => normalizeTr(body);
  bool get isSleep => kind != AnlikKind.anlik;
  bool get wasEdited => updatedAt.difference(createdAt).inMinutes >= 1;

  AnlikNote copyWith({
    DateTime? createdAt,
    DateTime? updatedAt,
    String? body,
    int? mood,
    Set<String>? tagIds,
    Set<String>? autoTagIds,
    Set<String>? personIds,
    Set<String>? linkedNoteIds,
    Set<String>? linkedCardIds,
  }) =>
      AnlikNote(
        id: id,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        body: body ?? this.body,
        kind: kind,
        mood: mood ?? this.mood,
        subject: subject,
        mebNodeId: mebNodeId,
        topicText: topicText,
        tagIds: tagIds ?? this.tagIds,
        autoTagIds: autoTagIds ?? this.autoTagIds,
        personIds: personIds ?? this.personIds,
        linkedNoteIds: linkedNoteIds ?? this.linkedNoteIds,
        linkedCardIds: linkedCardIds ?? this.linkedCardIds,
      );
}

class AnlikException implements Exception {
  const AnlikException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Metinde geçen ama henüz olmayan etiket ya da kişi: kullanıcı adını
/// onaylamadan oluşturulmaz.
class UnknownMentionsException implements AnlikException {
  const UnknownMentionsException({this.tags = const [], this.people = const []});
  final List<String> tags;
  final List<String> people;

  @override
  String get message => [
        if (tags.isNotEmpty) 'Yeni etiket: ${tags.join(', ')}',
        if (people.isNotEmpty) 'Yeni kişi: ${people.join(', ')}',
      ].join('. ');
  @override
  String toString() => message;
}
