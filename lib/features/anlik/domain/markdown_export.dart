import 'anlik.dart';
import 'anlik_search.dart';
import 'tag_tree.dart';

/// Anlık notların Markdown dışa aktarımı (saf Dart). Her not bir dosya:
/// YAML başlık + gövde; her gün için ayrıca bir günlük özet.

String _two(int v) => v.toString().padLeft(2, '0');
String isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
String isoDateTime(DateTime d) => '${isoDate(d)}T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';

/// YAML'da güvenli metin: özel karakter varsa çift tırnak ve kaçış.
String yamlScalar(String s) {
  final plain = RegExp(r'^[\p{L}\p{N}][\p{L}\p{N} ._/()-]*$', unicode: true);
  const reserved = {'null', 'true', 'false', 'yes', 'no', '~'};
  if (s.isNotEmpty && plain.hasMatch(s) && !reserved.contains(s.toLowerCase()) && !s.endsWith(' ') && num.tryParse(s) == null) {
    return s;
  }
  final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n').replaceAll('\r', '');
  return '"$escaped"';
}

String yamlList(Iterable<String> items) => '[${items.map(yamlScalar).join(', ')}]';

/// Notun dosya yolu: `anlik/YYYY/MM/YYYY-MM-DD_HHmm_<kimlik>.md`.
String notePath(AnlikNote n) {
  final d = n.createdAt;
  final safeId = n.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
  final short = safeId.length > 12 ? safeId.substring(safeId.length - 12) : safeId;
  return 'anlik/${d.year.toString().padLeft(4, '0')}/${_two(d.month)}/${isoDate(d)}_${_two(d.hour)}${_two(d.minute)}_$short.md';
}

String dailyPath(DateTime day) => 'gunluk/${isoDate(day)}.md';

String renderNote(
  AnlikNote n, {
  required Iterable<Tag> tags,
  required Iterable<Person> people,
}) {
  final tagLabels = [for (final id in n.tagIds) if (tags.any((t) => t.id == id)) tagPathLabel(tags, id)]..sort();
  final names = [for (final p in people) if (n.personIds.contains(p.id)) p.name]..sort();
  final links = [
    for (final id in n.linkedNoteIds.toList()..sort()) 'not:$id',
    for (final id in n.linkedCardIds.toList()..sort()) 'soru:$id',
  ];
  final b = StringBuffer()
    ..writeln('---')
    ..writeln('id: ${yamlScalar(n.id)}')
    ..writeln('zaman: ${isoDateTime(n.createdAt)}')
    ..writeln('tur: ${n.kind.key}');
  if (n.mood != null) b.writeln('ruh: ${n.mood}');
  if (n.subject != null) b.writeln('ders: ${yamlScalar(n.subject!)}');
  final topic = n.topicText ?? n.mebNodeId;
  if (topic != null && topic.trim().isNotEmpty) b.writeln('konu: ${yamlScalar(topic.trim())}');
  b
    ..writeln('etiketler: ${yamlList(tagLabels)}')
    ..writeln('kisiler: ${yamlList(names)}')
    ..writeln('baglar: ${yamlList(links)}')
    ..writeln('---')
    ..writeln()
    ..writeln(n.body.trimRight());
  return b.toString();
}

const _months = ['Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran', 'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'];

String _duration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60;
  return h == 0 ? '$m dk' : (m == 0 ? '$h sa' : '$h sa $m dk');
}

/// [day] gününün özeti: not sayısı, uyku, ruh hâli ortalaması, etiket ve kişiler.
/// [allNotes]: uyku eşleştirmesi gece yarısını aşabildiği için tüm notlar verilir.
String renderDailySummary(
  DateTime day,
  List<AnlikNote> allNotes, {
  required Iterable<Tag> tags,
  required Iterable<Person> people,
}) {
  bool sameDay(DateTime d) => d.year == day.year && d.month == day.month && d.day == day.day;
  final notes = [for (final n in allNotes) if (sameDay(n.createdAt)) n]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final plain = [for (final n in notes) if (!n.isSleep) n];
  final moods = [for (final n in plain) if (n.mood != null) n.mood!];
  final nights = [for (final s in sleepNights(allNotes)) if (sameDay(s.bed) || (s.wake != null && sameDay(s.wake!))) s];
  final tagLabels = {
    for (final n in plain)
      for (final id in n.tagIds)
        if (tags.any((t) => t.id == id)) tagPathLabel(tags, id),
  }.toList()
    ..sort();
  final names = {
    for (final n in plain)
      for (final p in people)
        if (n.personIds.contains(p.id)) p.name,
  }.toList()
    ..sort();

  final b = StringBuffer()
    ..writeln('---')
    ..writeln('tarih: ${isoDate(day)}')
    ..writeln('not_sayisi: ${plain.length}');
  if (moods.isNotEmpty) b.writeln('ruh_ortalama: ${(moods.reduce((a, c) => a + c) / moods.length).toStringAsFixed(1)}');
  for (final s in nights) {
    b.writeln('uyku: {yattim: ${isoDateTime(s.bed)}${s.wake == null ? '' : ', kalktim: ${isoDateTime(s.wake!)}, sure: ${yamlScalar(_duration(s.length!))}'}}');
  }
  b
    ..writeln('etiketler: ${yamlList(tagLabels)}')
    ..writeln('kisiler: ${yamlList(names)}')
    ..writeln('---')
    ..writeln()
    ..writeln('# ${day.day} ${_months[day.month - 1]} ${day.year}')
    ..writeln();
  if (plain.isEmpty) {
    b.writeln('Bu gün not yok.');
  } else {
    for (final n in plain) {
      final first = n.body.trim().split('\n').first.trim();
      b.writeln('- ${_two(n.createdAt.hour)}:${_two(n.createdAt.minute)} — ${first.length > 120 ? '${first.substring(0, 120)}…' : first}');
    }
  }
  return b.toString();
}
