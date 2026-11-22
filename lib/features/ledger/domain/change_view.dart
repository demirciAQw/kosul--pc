import 'dart:convert';

import '../../../core/ledger/hlc.dart';
import '../../../core/ledger/ledger_service.dart';

/// Defter satırlarının kullanıcıya gösterilen hâli (saf Dart).

const _tableTitles = <String, String>{
  'anlik_notes': 'Anlık not',
  'tags': 'Etiket',
  'anlik_note_tags': 'Not etiketi',
  'question_card_tags': 'Soru etiketi',
  'people': 'Kişi',
  'anlik_note_people': 'Not kişisi',
  'anlik_links': 'Not bağı',
  'ink_strokes': 'Çizgi',
  'question_cards': 'Soru',
  'study_notes': 'Ders notu',
  'note_photos': 'Not fotoğrafı',
  'books': 'Kitap',
  'content_nodes': 'Kitap bölümü',
  'test_results': 'Test sonucu',
  'study_sessions': 'Oturum',
  'session_items': 'Oturum maddesi',
  'mock_exams': 'Deneme',
  'mock_exam_sections': 'Deneme dersi',
  'study_plans': 'Plan',
  'plan_tasks': 'Plan görevi',
  'review_states': 'Tekrar durumu',
  'ocr_results': 'Okunan metin',
};

String tableTitle(String table) => _tableTitles[table] ?? table;

const _opVerbs = {'ekle': 'eklendi', 'degistir': 'değiştirildi', 'sil': 'silindi'};

/// Bir değişikliğin tek satırlık açıklaması.
class ChangeText {
  const ChangeText(this.title, this.detail);
  final String title; // "Anlık not eklendi"
  final String detail; // metin özeti ya da değişen alanlar
}

const _labelKeys = ['body', 'title', 'name', 'label', 'text', 'source_name', 'topic_text', 'subject'];

Map<String, Object?>? _map(String? json) {
  if (json == null) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

ChangeText describeChange(LedgerChange c) {
  final old = _map(c.old), neu = _map(c.neu);
  final base = neu ?? old;
  String detail = '';
  if (c.op == 'degistir' && old != null && neu != null) {
    final changed = [for (final k in neu.keys) if ('${neu[k]}' != '${old[k]}') k];
    detail = changed.length <= 4 ? changed.join(', ') : '${changed.length} alan';
    // Metin alanı değiştiyse yeni halini göster.
    for (final k in _labelKeys) {
      if (changed.contains(k) && neu[k] is String && (neu[k] as String).trim().isNotEmpty) {
        detail = _short('${neu[k]}');
        break;
      }
    }
  } else if (base != null) {
    for (final k in _labelKeys) {
      final v = base[k];
      if (v is String && v.trim().isNotEmpty) {
        detail = _short(v);
        break;
      }
    }
  }
  return ChangeText('${tableTitle(c.table)} ${_opVerbs[c.op] ?? c.op}', detail);
}

String _short(String s) {
  final one = s.trim().replaceAll(RegExp(r'\s+'), ' ');
  return one.length <= 80 ? one : '${one.substring(0, 80)}…';
}

/// Değişikliğin zamanı (saatin içindeki duvar saati).
DateTime changeTime(LedgerChange c) {
  final h = Hlc.tryParse(c.clock);
  return DateTime.fromMillisecondsSinceEpoch(h?.ms ?? 0);
}

/// Bir Claude oturumundaki değişiklikler (en yeni oturum başta; oturum içinde de en yeni başta).
class SessionGroup {
  const SessionGroup(this.session, this.changes);
  final String? session;
  final List<LedgerChange> changes;

  DateTime get at => changeTime(changes.first);
}

List<SessionGroup> groupBySession(Iterable<LedgerChange> changes) {
  final bySession = <String, List<LedgerChange>>{};
  final order = <String>[];
  for (final c in changes) {
    if (c.source != 'claude') continue;
    final key = c.session ?? '';
    if (!bySession.containsKey(key)) order.add(key);
    (bySession[key] ??= []).add(c);
  }
  return [for (final k in order) SessionGroup(k.isEmpty ? null : k, bySession[k]!)];
}
