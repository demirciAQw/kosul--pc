import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../cli/kocum_cli.dart';
import '../core/database/app_database.dart';
import '../core/database/health_tables.dart';
import '../core/text/turkish_text.dart';
import 'mcp_server.dart';

/// Açıldıktan sonra bağlantıyı salt okunur yapar. Açılışta Drift göç/defter
/// kurulumu yazabildiği için PRAGMA ÖNCE bir sorguyla veritabanı açılır, SONRA kilitlenir.
Future<void> lockReadOnly(AppDatabase db) async {
  await db.customSelect('SELECT 1').get();
  await db.customStatement('PRAGMA query_only = ON');
}

const _maxLimit = 100;

/// Araçların dokunabileceği tablolar (belgeleme + test için). Sağlık tabloları
/// ([healthTables]) burada ve hiçbir sorguda geçmez.
const mcpReadTables = {
  'question_cards',
  'curriculum_nodes',
  'mock_exams',
  'mock_exam_sections',
  'books',
  'content_nodes',
  'test_results',
  'study_sessions',
  'anlik_notes',
};

int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

String? _str(Map<String, Object?> a, String k) {
  final v = a[k];
  if (v == null) return null;
  if (v is! String) throw McpToolError('"$k" metin olmalı.');
  final t = v.trim();
  // `kocum` aracının bayrak ayrıştırıcısına değer olarak bayrak sızdırılamaz.
  if (t.startsWith('--')) throw McpToolError('"$k" değeri "--" ile başlayamaz.');
  return t.isEmpty ? null : t;
}

int _limit(Map<String, Object?> a, {int def = 20}) {
  final v = a['en_cok'];
  if (v == null) return def;
  final n = _int(v);
  if (n == null || n < 1) throw const McpToolError('"en_cok" 1 ile $_maxLimit arasında bir sayı olmalı.');
  return n > _maxLimit ? _maxLimit : n;
}

int _offset(Map<String, Object?> a) {
  final n = a['sayfa'] == null ? 0 : _int(a['sayfa']);
  if (n == null || n < 0) throw const McpToolError('"sayfa" 0 ya da büyük bir sayı olmalı.');
  return n;
}

/// "2026-10-20" → yerel gün başı, epoch saniye.
int? _day(Map<String, Object?> a, String k, {bool endExclusive = false}) {
  final s = _str(a, k);
  if (s == null) return null;
  final d = DateTime.tryParse(s);
  if (d == null || !RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
    throw McpToolError('"$k" biçimi YYYY-AA-GG olmalı.');
  }
  final local = DateTime(d.year, d.month, d.day + (endExclusive ? 1 : 0));
  return local.millisecondsSinceEpoch ~/ 1000;
}

String _likeEscape(String s) => s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

String _clipText(String? s, [int max = 300]) {
  final t = (s ?? '').replaceAll('\n', ' ').trim();
  return t.length > max ? '${t.substring(0, max)}…' : t;
}

String? _iso(Object? secs) {
  final n = _int(secs);
  if (n == null) return null;
  final d = DateTime.fromMillisecondsSinceEpoch(n * 1000);
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

Map<String, Object?> _obj(Map<String, Object?> props, {List<String> required = const []}) => {
      'type': 'object',
      'properties': props,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };

const _pageProps = <String, Object?>{
  'en_cok': {'type': 'integer', 'description': 'En çok kaç satır (1-100, varsayılan 20).'},
  'sayfa': {'type': 'integer', 'description': 'Sayfa numarası, 0\'dan (en_cok kadar atlar).'},
};

/// Araç listesi. [write] false iken yazan araçlar HİÇ listelenmez.
List<McpTool> buildKocumTools(
  AppDatabase db, {
  bool write = false,
  String session = 'claude-mcp',
  DateTime Function()? now,
}) {
  Future<List<Map<String, Object?>>> rows(String sql, List<Variable> vars) async {
    final r = await db.customSelect(sql, variables: vars).get();
    return [for (final x in r) Map<String, Object?>.from(x.data)];
  }

  final tools = <McpTool>[
    McpTool(
      name: 'ozet',
      description: 'Genel sayılar: soru kartları (durumlara göre), denemeler, çalışma oturumları, kitaplar, notlar.',
      inputSchema: _obj(const {}),
      run: (_) async {
        Future<int> count(String sql) async => _int((await rows(sql, const [])).first['n']) ?? 0;
        final byStatus = await rows('SELECT status, COUNT(*) AS n FROM question_cards GROUP BY status', const []);
        return {
          'sorular': {
            'toplam': await count('SELECT COUNT(*) AS n FROM question_cards'),
            'duruma_gore': {for (final r in byStatus) r['status'].toString(): r['n']},
          },
          'denemeler': await count('SELECT COUNT(*) AS n FROM mock_exams'),
          'oturumlar': await count('SELECT COUNT(*) AS n FROM study_sessions'),
          'kitaplar': await count('SELECT COUNT(*) AS n FROM books'),
          'anlik_notlar': await count('SELECT COUNT(*) AS n FROM anlik_notes'),
        };
      },
    ),
    McpTool(
      name: 'yanlis_sorular',
      description: 'Soru kartları (varsayılan yalnız yanlışlar), ders/konu/tarih süzgeçli, sayfalı, yeniden eskiye.',
      inputSchema: _obj({
        'ders': {'type': 'string', 'description': 'Tam ders adı, ör. "TYT Matematik".'},
        'konu': {'type': 'string', 'description': 'Konu adında geçen metin (Türkçe duyarsız).'},
        'baslangic': {'type': 'string', 'description': 'YYYY-AA-GG (dahil).'},
        'bitis': {'type': 'string', 'description': 'YYYY-AA-GG (dahil).'},
        'durum': {'type': 'string', 'enum': ['wrong', 'blank', 'correct', 'hepsi'], 'description': 'Varsayılan wrong.'},
        ..._pageProps,
      }),
      run: (a) async {
        final status = _str(a, 'durum') ?? 'wrong';
        if (!const {'wrong', 'blank', 'correct', 'hepsi'}.contains(status)) throw const McpToolError('Geçersiz durum.');
        final where = <String>[];
        final vars = <Variable>[];
        if (status != 'hepsi') {
          where.add('c.status = ?');
          vars.add(Variable<String>(status));
        }
        final ders = _str(a, 'ders');
        if (ders != null) {
          where.add('c.subject = ?');
          vars.add(Variable<String>(ders));
        }
        final konu = _str(a, 'konu');
        if (konu != null) {
          where.add("(c.search_text LIKE ? ESCAPE '\\' OR LOWER(COALESCE(c.topic_text,'')) LIKE ? ESCAPE '\\' "
              "OR LOWER(COALESCE(n.title,'')) LIKE ? ESCAPE '\\')");
          final p = '%${_likeEscape(normalizeTr(konu))}%';
          final q = '%${_likeEscape(konu.toLowerCase())}%';
          vars..add(Variable<String>(p))..add(Variable<String>(q))..add(Variable<String>(q));
        }
        final from = _day(a, 'baslangic');
        if (from != null) {
          where.add('c.created_at >= ?');
          vars.add(Variable<int>(from));
        }
        final to = _day(a, 'bitis', endExclusive: true);
        if (to != null) {
          where.add('c.created_at < ?');
          vars.add(Variable<int>(to));
        }
        final lim = _limit(a);
        final off = _offset(a) * lim;
        final r = await rows(
          'SELECT c.id, c.status, c.subject, COALESCE(c.topic_text, n.title) AS konu, c.reason, c.reason_note, '
          'c.source_name, c.test_label, c.question_no, c.difficulty, c.note, c.created_at '
          'FROM question_cards c LEFT JOIN curriculum_nodes n ON n.id = c.meb_node_id '
          '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
          'ORDER BY c.created_at DESC, c.id LIMIT ? OFFSET ?',
          [...vars, Variable<int>(lim), Variable<int>(off)],
        );
        return {
          'sayi': r.length,
          'sorular': [
            for (final x in r)
              {
                'id': x['id'],
                'durum': x['status'],
                'ders': x['subject'],
                'konu': x['konu'],
                'neden': x['reason'],
                'neden_notu': _clipText(x['reason_note'] as String?),
                'kaynak': x['source_name'],
                'test': x['test_label'],
                'soru_no': x['question_no'],
                'zorluk': x['difficulty'],
                'not': _clipText(x['note'] as String?),
                'tarih': _iso(x['created_at']),
              },
          ],
        };
      },
    ),
    McpTool(
      name: 'konu_analizi',
      description: 'Konu bazında doğru/yanlış/boş soru kartı sayıları; en çok yanlış yapılan konular önde.',
      inputSchema: _obj({
        'ders': {'type': 'string'},
        'en_cok': _pageProps['en_cok'],
      }),
      run: (a) async {
        final ders = _str(a, 'ders');
        final r = await rows(
          "SELECT c.subject AS ders, COALESCE(c.topic_text, n.title, '(konu yok)') AS konu, "
          "SUM(c.status = 'wrong') AS yanlis, SUM(c.status = 'blank') AS bos, SUM(c.status = 'correct') AS dogru, "
          'COUNT(*) AS toplam FROM question_cards c LEFT JOIN curriculum_nodes n ON n.id = c.meb_node_id '
          '${ders == null ? '' : 'WHERE c.subject = ?'} GROUP BY c.subject, konu '
          'ORDER BY yanlis DESC, toplam DESC LIMIT ?',
          [if (ders != null) Variable<String>(ders), Variable<int>(_limit(a, def: 30))],
        );
        return {'konular': r};
      },
    ),
    McpTool(
      name: 'deneme_sonuclari',
      description: 'Deneme sınavları ve ders bölümleri (doğru/yanlış/boş, net = D - Y/4), yeniden eskiye.',
      inputSchema: _obj({'en_cok': _pageProps['en_cok'], 'sayfa': _pageProps['sayfa']}),
      run: (a) async {
        final lim = _limit(a, def: 10);
        final exams = await rows(
          'SELECT id, title, kind, taken_on, duration_minutes FROM mock_exams ORDER BY taken_on DESC, id LIMIT ? OFFSET ?',
          [Variable<int>(lim), Variable<int>(_offset(a) * lim)],
        );
        final out = <Map<String, Object?>>[];
        for (final e in exams) {
          final secs = await rows(
            'SELECT subject, question_count, correct, wrong, blank FROM mock_exam_sections WHERE exam_id = ? ORDER BY sort_order',
            [Variable<String>(e['id'] as String)],
          );
          var net = 0.0;
          for (final s in secs) {
            net += (_int(s['correct']) ?? 0) - (_int(s['wrong']) ?? 0) / 4;
          }
          out.add({
            'id': e['id'],
            'baslik': e['title'],
            'tur': e['kind'],
            'tarih': _iso(e['taken_on']),
            'sure_dk': e['duration_minutes'],
            'net': double.parse(net.toStringAsFixed(2)),
            'dersler': secs,
          });
        }
        return {'denemeler': out};
      },
    ),
    McpTool(
      name: 'kitap_ilerlemesi',
      description: 'Kitap başına: testi olan konu sayısı, çözülen test sayısı ve toplam D/Y/B.',
      inputSchema: _obj(const {}),
      run: (_) async {
        final r = await rows(
          'SELECT b.id, b.title, b.subject, b.exam_type, '
          '(SELECT COUNT(*) FROM content_nodes n WHERE n.book_id = b.id AND n.question_count IS NOT NULL) AS test_sayisi, '
          '(SELECT COUNT(*) FROM test_results t WHERE t.book_id = b.id) AS cozulen, '
          '(SELECT COALESCE(SUM(t.correct),0) FROM test_results t WHERE t.book_id = b.id) AS dogru, '
          '(SELECT COALESCE(SUM(t.wrong),0) FROM test_results t WHERE t.book_id = b.id) AS yanlis, '
          '(SELECT COALESCE(SUM(t.blank),0) FROM test_results t WHERE t.book_id = b.id) AS bos '
          'FROM books b ORDER BY b.title',
          const [],
        );
        return {'kitaplar': r};
      },
    ),
    McpTool(
      name: 'ara',
      description: 'Soru kartlarında ve anlık notlarda metin arar (Türkçe duyarsız: İ/ı, büyük/küçük).',
      inputSchema: _obj({
        'sorgu': {'type': 'string', 'description': 'Aranacak metin.'},
        'en_cok': _pageProps['en_cok'],
      }, required: ['sorgu']),
      run: (a) async {
        final q = _str(a, 'sorgu');
        if (q == null) throw const McpToolError('"sorgu" gerekli.');
        final norm = normalizeTr(q);
        if (norm.trim().isEmpty) throw const McpToolError('Aranacak metin harf ya da rakam içermeli.');
        final p = '%${_likeEscape(norm)}%';
        final lim = _limit(a, def: 10);
        final cards = await rows(
          "SELECT id, status, subject, COALESCE(topic_text,'') AS konu, note, created_at FROM question_cards "
          "WHERE search_text LIKE ? ESCAPE '\\' ORDER BY created_at DESC LIMIT ?",
          [Variable<String>(p), Variable<int>(lim)],
        );
        final notes = await rows(
          "SELECT id, body, subject, created_at FROM anlik_notes WHERE search_text LIKE ? ESCAPE '\\' "
          'ORDER BY created_at DESC LIMIT ?',
          [Variable<String>(p), Variable<int>(lim)],
        );
        return {
          'sorular': [
            for (final x in cards)
              {
                'id': x['id'],
                'durum': x['status'],
                'ders': x['subject'],
                'konu': x['konu'],
                'not': _clipText(x['note'] as String?),
                'tarih': _iso(x['created_at']),
              },
          ],
          'notlar': [
            for (final x in notes)
              {'id': x['id'], 'ders': x['subject'], 'metin': _clipText(x['body'] as String?), 'tarih': _iso(x['created_at'])},
          ],
        };
      },
    ),
  ];

  if (!write) return tools;

  // ── YAZMA araçları: yalnızca `--yaz` ile. Hepsi `kocum` aracının (kaynak:
  // claude, oturum) yolundan geçer: "Claude'un değişiklikleri"nde görünür, geri alınır.
  Future<Object?> viaCli(List<String> argv) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runKocum(
      [...argv, '--oturum', session],
      db: db,
      out: out.writeln,
      err: err.writeln,
      now: now,
    );
    if (code != 0) {
      String msg;
      try {
        msg = (jsonDecode(err.toString()) as Map)['hata'].toString();
      } catch (_) {
        msg = 'İşlem yapılamadı.';
      }
      throw McpToolError(msg);
    }
    return jsonDecode(out.toString());
  }

  String need(Map<String, Object?> a, String k) => _str(a, k) ?? (throw McpToolError('"$k" gerekli.'));

  tools.addAll([
    McpTool(
      name: 'soru_konu_duzelt',
      description: 'Bir soru kartının serbest konu adını değiştirir (geri alınabilir; kaynak: claude).',
      readOnly: false,
      inputSchema: _obj({
        'id': {'type': 'string'},
        'konu': {'type': 'string'},
      }, required: ['id', 'konu']),
      run: (a) => viaCli(['duzelt', 'question_cards', need(a, 'id'), 'topic_text', need(a, 'konu')]),
    ),
    McpTool(
      name: 'soru_etiket_ekle',
      description: 'Soru kartına VAR OLAN bir etiketi ekler (yeni etiket oluşturmaz).',
      readOnly: false,
      inputSchema: _obj({
        'id': {'type': 'string'},
        'etiket': {'type': 'string'},
      }, required: ['id', 'etiket']),
      run: (a) => viaCli(['etiket-ekle', 'soru:${need(a, 'id')}', need(a, 'etiket')]),
    ),
    McpTool(
      name: 'not_ekle',
      description: 'Anlık not ekler (kaynak: claude). Bilinmeyen ((etiket)) ya da @kişi varsa hata verir.',
      readOnly: false,
      inputSchema: _obj({
        'metin': {'type': 'string'},
        'ders': {'type': 'string'},
        'konu': {'type': 'string'},
      }, required: ['metin']),
      run: (a) async {
        final ders = _str(a, 'ders');
        final konu = _str(a, 'konu');
        return viaCli([
          'not-ekle',
          need(a, 'metin'),
          if (ders != null) ...['--ders', ders],
          if (konu != null) ...['--konu', konu],
        ]);
      },
    ),
  ]);
  return tools;
}
