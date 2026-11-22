import '../../../core/text/turkish_text.dart';
import 'anlik.dart';

/// Metindeki `((etiket))` ve `@kişi` yazımlarının ayrıştırılması.
/// Saf Dart; telefonda ve bilgisayarda aynı kural çalışır.

final _tagRe = RegExp(r'\(\(([^()\n]+?)\)\)');
// '@' sözcüğün ortasında olmaz (e-posta). Ad: harf/rakam/_ ; ya da @(Ayşe Nur).
final _personRe = RegExp(r'(?<![\p{L}\p{N}_.])@(?:\(([^()\n]+?)\)|([\p{L}\p{N}_]+))', unicode: true);

/// `((his > tiksinti))`: ">" ile üst etiket yolu. Boş parçalar atılır.
List<String> tagPath(String mention) =>
    [for (final p in mention.split('>')) if (p.trim().isNotEmpty) p.trim().replaceAll(RegExp(r'\s+'), ' ')];

/// Metindeki etiket yolları (yinelenenler tek sayılır; sıra korunur).
List<List<String>> parseTagMentions(String text) {
  final seen = <String>{};
  final out = <List<String>>[];
  for (final m in _tagRe.allMatches(text)) {
    final path = tagPath(m.group(1)!);
    if (path.isEmpty) continue;
    if (seen.add(path.map(tagKey).join('>'))) out.add(path);
  }
  return out;
}

/// Metindeki kişi adları, yazıldığı gibi (yinelenenler tek sayılır).
List<String> parsePersonMentions(String text) {
  final seen = <String>{};
  final out = <String>[];
  for (final m in _personRe.allMatches(text)) {
    final name = (m.group(1) ?? m.group(2))!.trim();
    if (name.isEmpty) continue;
    if (seen.add(normalizeTr(name))) out.add(name);
  }
  return out;
}

/// Ad ya da takma adla kişiyi bulur (İ/ı ve büyük/küçük harften bağımsız).
Person? matchPerson(String mention, Iterable<Person> people) {
  final k = normalizeTr(mention);
  if (k.isEmpty) return null;
  for (final p in people) {
    if (p.keys.contains(k)) return p;
  }
  return null;
}

/// Yazarken öneri: imleç açık bir `((` ya da `@` içindeyse.
class MentionContext {
  const MentionContext({required this.isTag, required this.prefix, required this.start});
  final bool isTag;

  /// Şimdiye kadar yazılan kısım (`((tik` → "tik").
  final String prefix;

  /// Yazımın başladığı indeks (`((` ya da `@` işaretinin yeri).
  final int start;
}

MentionContext? mentionAt(String text, int cursor) {
  if (cursor < 0 || cursor > text.length) return null;
  final before = text.substring(0, cursor);
  final open = before.lastIndexOf('((');
  if (open >= 0) {
    final rest = before.substring(open + 2);
    if (!rest.contains('))') && !rest.contains('\n') && !rest.contains('(')) {
      return MentionContext(isTag: true, prefix: rest, start: open);
    }
  }
  final m = RegExp(r'(?<![\p{L}\p{N}_.])@([\p{L}\p{N}_]*)$', unicode: true).firstMatch(before);
  if (m != null) return MentionContext(isTag: false, prefix: m.group(1)!, start: m.start);
  return null;
}

/// Seçilen öneriyi yazıya işler; yeni metin ve imleç yeri döner.
({String text, int cursor}) applyMention(String text, int cursor, MentionContext ctx, String name) {
  final insert = ctx.isTag ? '(($name))' : (RegExp(r'^[\p{L}\p{N}_]+$', unicode: true).hasMatch(name) ? '@$name' : '@($name)');
  final out = text.substring(0, ctx.start) + insert + text.substring(cursor);
  return (text: out, cursor: ctx.start + insert.length);
}

/// Öneri listesi: önek eşleşmesi önce, sonra içinde geçenler; en çok [limit].
List<String> suggestNames(String prefix, Iterable<String> candidates, {int limit = 6}) {
  final p = normalizeTr(prefix);
  final starts = <String>[];
  final contains = <String>[];
  for (final c in candidates) {
    final k = normalizeTr(c);
    if (p.isEmpty || k.startsWith(p)) {
      starts.add(c);
    } else if (k.contains(p)) {
      contains.add(c);
    }
  }
  starts.sort((a, b) => normalizeTr(a).compareTo(normalizeTr(b)));
  return [...starts, ...contains].take(limit).toList();
}
