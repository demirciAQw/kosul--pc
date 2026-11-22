import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;

import '../core/database/app_database.dart';
import '../core/ledger/ledger_service.dart';
import '../core/text/turkish_text.dart';
import '../core/utils/id_generator.dart';
import '../features/anlik/data/anlik_repository_impl.dart';
import '../features/anlik/domain/anlik.dart';
import '../features/anlik/domain/markdown_export.dart';
import '../features/anlik/domain/mentions.dart';
import '../features/anlik/domain/save_anlik.dart';
import '../features/ledger/domain/change_view.dart';

/// `kocum` komut satırı aracı: Claude'un Koçum verisine eli. Her yazma
/// `kaynak: claude` ve oturum kimliğiyle deftere geçer; böylece geri alınabilir.
/// Çıktı JSON'dur (stdout); hata iletisi stderr'e `{"hata": …}` olarak gider.
/// Dönüş kodu: 0 tamam, 1 işlem hatası, 2 kullanım hatası.

class CliException implements Exception {
  const CliException(this.message, {this.usage = false});
  final String message;
  final bool usage;
}

const kocumUsage = '''
kocum <komut> [argümanlar]

Okuma:
  sorgu "<SELECT …>"            salt okunur sorgu, JSON çıktı (--limit N)
  oturumlar                     Claude oturumları ve değişiklik sayıları
  disa-aktar <klasör>           notları ve günlük özetleri Markdown yaz

Yazma (hepsi kaynak: claude, geri alınabilir):
  not-ekle <metin> [--etiket a,b] [--kisi ad,ad] [--ders D] [--konu K] [--zaman 2026-10-20T08:30] [--ruh 1-5] [--olustur]
  etiket-ekle <hedef> <etiket> [--olustur]      hedef: not:<id> | soru:<id>
  etiket-kaldir <hedef> <etiket>
  kisi-ekle <ad> [--takma a,b] [--not "kim"]
  kisi-bagla <not> <kişi>
  bagla <not> <not:<id> | soru:<id>>
  duzelt <tablo> <id> <alan> <değer>
  sil-oner <tablo> <id> [--neden "…"]           silmez, yalnızca işaretler
  geri-al <değişiklik-id> | geri-al --oturum X

Genel: --oturum X (ya da KOCUM_OTURUM) yazmaları bir oturuma toplar; yoksa claude-<bugün>.
Yeni etiket ve kişi yalnızca --olustur ile oluşur.
''';

class _Args {
  _Args(List<String> raw) {
    const withValue = {'etiket', 'kisi', 'takma', 'ders', 'konu', 'zaman', 'ruh', 'oturum', 'neden', 'limit', 'not'};
    for (var i = 0; i < raw.length; i++) {
      final a = raw[i];
      if (a.startsWith('--') && a.length > 2) {
        final name = a.substring(2);
        if (withValue.contains(name)) {
          if (i + 1 >= raw.length) throw CliException('--$name için bir değer gerekli.', usage: true);
          opts[name] = raw[++i];
        } else {
          flags.add(name);
        }
      } else {
        pos.add(a);
      }
    }
  }

  final pos = <String>[];
  final opts = <String, String>{};
  final flags = <String>{};

  String need(int i, String what) {
    if (i >= pos.length) throw CliException('Eksik argüman: $what.', usage: true);
    return pos[i];
  }
}

List<String> _csv(String? s) => s == null ? const [] : [for (final p in s.split(',')) if (p.trim().isNotEmpty) p.trim()];

Object? _jsonSafe(Object? v) => switch (v) {
      DateTime d => isoDateTime(d),
      List<int> b => 'blob:${b.length}',
      _ => v,
    };

/// Aracı çalıştırır. [db] masaüstü veritabanıdır ('pc' kaynaklı açılmış olmalı).
Future<int> runKocum(
  List<String> argv, {
  required AppDatabase db,
  required void Function(String) out,
  required void Function(String) err,
  DateTime Function()? now,
  Map<String, String> env = const {},
  IdGenerator ids = const UuidV7Generator(),
}) async {
  try {
    if (argv.isEmpty || argv.first == 'yardim' || argv.first == '--help' || argv.first == '-h') {
      out(kocumUsage);
      return argv.isEmpty ? 2 : 0;
    }
    final cmd = argv.first;
    final args = _Args(argv.sublist(1));
    final clock = now ?? DateTime.now;
    final cli = _Cli(db, args, clock, ids, env);
    final result = await cli.run(cmd);
    out(const JsonEncoder.withIndent('  ').convert(result));
    return 0;
  } on CliException catch (e) {
    err(jsonEncode({'hata': e.message}));
    return e.usage ? 2 : 1;
  } on UnknownMentionsException catch (e) {
    err(jsonEncode({'hata': '${e.message}. Oluşturmak için --olustur ekle.'}));
    return 1;
  } on AnlikException catch (e) {
    err(jsonEncode({'hata': e.message}));
    return 1;
  } catch (e) {
    err(jsonEncode({'hata': 'Beklenmeyen hata: $e'}));
    return 1;
  }
}

class _Cli {
  _Cli(this.db, this.args, this.clock, this.ids, this.env)
      : ledger = LedgerService(db),
        repo = DriftAnlikRepository(db);

  final AppDatabase db;
  final _Args args;
  final DateTime Function() clock;
  final IdGenerator ids;
  final Map<String, String> env;
  final LedgerService ledger;
  final DriftAnlikRepository repo;

  String get session => args.opts['oturum'] ?? env['KOCUM_OTURUM'] ?? 'claude-${isoDate(clock())}';

  Future<Map<String, Object?>> run(String cmd) => switch (cmd) {
        'sorgu' => _query(),
        'oturumlar' => _sessions(),
        'disa-aktar' => _export(),
        'not-ekle' => _write(_addNote),
        'etiket-ekle' => _write(_addTag),
        'etiket-kaldir' => _write(_removeTag),
        'kisi-ekle' => _write(_addPerson),
        'kisi-bagla' => _write(_bindPerson),
        'bagla' => _write(_link),
        'duzelt' => _write(_fix),
        'sil-oner' => _write(_suggestDelete),
        'geri-al' => _undo(),
        _ => throw CliException('Bilinmeyen komut: $cmd. "kocum yardim" ile bak.', usage: true),
      };

  /// Yazma: tek işlemde, kaynak claude ve oturumla.
  Future<Map<String, Object?>> _write(Future<Map<String, Object?>> Function() body) async {
    await ledger.ensureReady(defaultSource: 'pc');
    final before = await ledger.maxSeq();
    final result = await ledger.withSource('claude', session: session, body: body);
    final changes = (await ledger.maxSeq()) - before;
    return {'tamam': true, 'oturum': session, 'degisiklik': changes, ...result};
  }

  // ───────────── okuma ─────────────

  Future<Map<String, Object?>> _query() async {
    var sql = args.need(0, 'SELECT sorgusu').trim();
    while (sql.endsWith(';')) {
      sql = sql.substring(0, sql.length - 1).trimRight();
    }
    if (sql.contains(';')) throw const CliException('Tek bir sorgu yaz (noktalı virgülle birden fazla değil).', usage: true);
    if (!RegExp(r'^(select|with)\b', caseSensitive: false).hasMatch(sql)) {
      throw const CliException('Yalnızca SELECT sorgusu çalışır (salt okunur).', usage: true);
    }
    final limit = int.tryParse(args.opts['limit'] ?? '') ?? 1000;
    await db.customStatement('PRAGMA query_only = ON');
    try {
      final rows = await db.customSelect('SELECT * FROM ($sql) LIMIT ?', variables: [Variable<int>(limit)]).get();
      return {
        'sayi': rows.length,
        'satirlar': [
          for (final r in rows) {for (final e in r.data.entries) e.key: _jsonSafe(e.value)},
        ],
      };
    } finally {
      await db.customStatement('PRAGMA query_only = OFF');
    }
  }

  Future<Map<String, Object?>> _sessions() async {
    final history = await ledger.history(source: 'claude', limit: 100000);
    final undone = await ledger.undoneIds();
    final bySession = <String, List<LedgerChange>>{};
    for (final c in history) {
      (bySession[c.session ?? ''] ??= []).add(c);
    }
    return {
      'oturumlar': [
        for (final e in bySession.entries)
          {
            'oturum': e.key.isEmpty ? null : e.key,
            'degisiklik': e.value.length,
            'geriAlinan': e.value.where((c) => undone.contains(c.id)).length,
            'ilk': isoDateTime(changeTime(e.value.last)),
            'son': isoDateTime(changeTime(e.value.first)),
          },
      ],
    };
  }

  Future<Map<String, Object?>> _export() async {
    final dir = Directory(args.need(0, 'klasör'));
    await dir.create(recursive: true);
    final notes = await repo.allNotes();
    final tags = await repo.allTags();
    final people = await repo.allPeople();
    var files = 0;
    for (final n in notes) {
      final f = File('${dir.path}/${notePath(n)}');
      await f.parent.create(recursive: true);
      await f.writeAsString(renderNote(n, tags: tags, people: people));
      files++;
    }
    final days = {for (final n in notes) DateTime(n.createdAt.year, n.createdAt.month, n.createdAt.day)};
    for (final d in days) {
      final f = File('${dir.path}/${dailyPath(d)}');
      await f.parent.create(recursive: true);
      await f.writeAsString(renderDailySummary(d, notes, tags: tags, people: people));
      files++;
    }
    return {'tamam': true, 'klasor': dir.path, 'not': notes.length, 'gun': days.length, 'dosya': files};
  }

  // ───────────── yardımcılar ─────────────

  /// "not:<id>", "soru:<id>" ya da yalın kimlik (önce not, sonra soru).
  Future<(String kind, String id)> _target(String raw) async {
    if (raw.startsWith('not:')) return ('not', raw.substring(4));
    if (raw.startsWith('soru:')) return ('soru', raw.substring(5));
    if (await repo.findNote(raw) != null) return ('not', raw);
    final c = await db.customSelect('SELECT 1 FROM question_cards WHERE id = ?', variables: [Variable<String>(raw)]).get();
    if (c.isNotEmpty) return ('soru', raw);
    throw CliException('Hedef bulunamadı: $raw (not:<id> ya da soru:<id> yaz).');
  }

  Future<void> _mustExist(String kind, String id) async {
    final ok = kind == 'not'
        ? await repo.findNote(id) != null
        : (await db.customSelect('SELECT 1 FROM question_cards WHERE id = ?', variables: [Variable<String>(id)]).get()).isNotEmpty;
    if (!ok) throw CliException('${kind == 'not' ? 'Not' : 'Soru'} bulunamadı: $id');
  }

  Future<String> _tagId(String path, {required bool create}) async {
    final parts = tagPath(path);
    if (parts.isEmpty) throw const CliException('Boş etiket.');
    final byKey = {for (final t in await repo.allTags()) t.name: t};
    String? parent;
    var last = '';
    for (final label in parts) {
      var t = byKey[tagKey(label)];
      if (t == null) {
        if (!create) throw UnknownMentionsException(tags: [label]);
        t = Tag(id: ids.next(), name: tagKey(label), label: label, parentId: parent, source: Source.claude, createdAt: clock());
        await repo.saveTag(t);
        byKey[t.name] = t;
      }
      parent = t.id;
      last = t.id;
    }
    return last;
  }

  Future<String> _personId(String nameOrId, {required bool create}) async {
    final people = await repo.allPeople();
    final byId = people.where((p) => p.id == nameOrId).firstOrNull;
    if (byId != null) return byId.id;
    final m = matchPerson(nameOrId, people);
    if (m != null) return m.id;
    if (!create) throw UnknownMentionsException(people: [nameOrId]);
    final p = Person(id: ids.next(), name: nameOrId.trim(), createdAt: clock(), source: Source.claude);
    await repo.savePerson(p);
    return p.id;
  }

  // ───────────── yazma ─────────────

  Future<Map<String, Object?>> _addNote() async {
    final text = args.pos.join(' ').trim();
    final create = args.flags.contains('olustur');
    final mood = args.opts['ruh'] == null ? null : int.tryParse(args.opts['ruh']!);
    if (args.opts['ruh'] != null && mood == null) throw const CliException('--ruh 1 ile 5 arasında bir sayı olmalı.', usage: true);
    DateTime? at;
    if (args.opts['zaman'] != null) {
      at = DateTime.tryParse(args.opts['zaman']!);
      if (at == null) throw const CliException('--zaman biçimi: 2026-10-20T08:30', usage: true);
    }
    final tagIds = {for (final t in _csv(args.opts['etiket'])) await _tagId(t, create: create)};
    final personIds = {for (final p in _csv(args.opts['kisi'])) await _personId(p, create: create)};
    final save = SaveAnlik(repo, ids, clock);
    final note = await save(
      body: text,
      mood: mood,
      at: at,
      subject: args.opts['ders'],
      topicText: args.opts['konu'],
      tagIds: tagIds,
      personIds: personIds,
      approvedTags: create ? {for (final p in parseTagMentions(text)) ...p} : const {},
      approvedPeople: create ? parsePersonMentions(text).toSet() : const {},
      source: Source.claude,
    );
    return {'not': note.id};
  }

  Future<Map<String, Object?>> _addTag() async {
    final (kind, id) = await _target(args.need(0, 'hedef'));
    await _mustExist(kind, id);
    final tagId = await _tagId(args.need(1, 'etiket'), create: args.flags.contains('olustur'));
    kind == 'not' ? await repo.addNoteTag(id, tagId, source: Source.claude) : await repo.addCardTag(id, tagId, source: Source.claude);
    return {'hedef': '$kind:$id', 'etiket': tagId};
  }

  Future<Map<String, Object?>> _removeTag() async {
    final (kind, id) = await _target(args.need(0, 'hedef'));
    final tagId = await _tagId(args.need(1, 'etiket'), create: false);
    kind == 'not' ? await repo.removeNoteTag(id, tagId) : await repo.removeCardTag(id, tagId);
    return {'hedef': '$kind:$id', 'etiket': tagId};
  }

  Future<Map<String, Object?>> _addPerson() async {
    final name = args.need(0, 'ad').trim();
    if (name.isEmpty) throw const CliException('Ad boş olamaz.', usage: true);
    final existing = matchPerson(name, await repo.allPeople());
    if (existing != null) throw CliException('Bu kişi zaten var: ${existing.name} (${existing.id}).');
    final p = Person(
      id: ids.next(),
      name: name,
      aliases: _csv(args.opts['takma']),
      about: args.opts['not'] ?? '',
      source: Source.claude,
      createdAt: clock(),
    );
    await repo.savePerson(p);
    return {'kisi': p.id};
  }

  Future<Map<String, Object?>> _bindPerson() async {
    final (kind, noteId) = await _target(args.need(0, 'not'));
    if (kind != 'not') throw const CliException('Kişi yalnızca nota bağlanır.', usage: true);
    await _mustExist('not', noteId);
    final personId = await _personId(args.need(1, 'kişi'), create: false);
    await repo.addNotePerson(noteId, personId, source: Source.claude);
    return {'not': noteId, 'kisi': personId};
  }

  Future<Map<String, Object?>> _link() async {
    final (kind, from) = await _target(args.need(0, 'not'));
    if (kind != 'not') throw const CliException('Bağ bir nottan başlar.', usage: true);
    await _mustExist('not', from);
    final (toKind, to) = await _target(args.need(1, 'hedef'));
    await _mustExist(toKind, to);
    toKind == 'not'
        ? await repo.linkNoteToNote(from, to, source: Source.claude)
        : await repo.linkNoteToCard(from, to, source: Source.claude);
    return {'nereden': 'not:$from', 'nereye': '$toKind:$to'};
  }

  Future<Map<String, Object?>> _fix() async {
    final table = args.need(0, 'tablo');
    final id = args.need(1, 'id');
    final field = args.need(2, 'alan');
    final raw = args.need(3, 'değer');
    final t = ledger.syncTables.where((t) => t.actualTableName == table).firstOrNull;
    if (t == null) throw CliException('Bu tablo düzeltilemez: $table');
    final pk = t.$primaryKey.single.$name;
    if (field == pk) throw const CliException('Kimlik değiştirilemez.');
    final info = await db.customSelect('PRAGMA table_info("$table")').get();
    final col = info.where((r) => r.read<String>('name') == field).firstOrNull;
    if (col == null) throw CliException('$table tablosunda "$field" alanı yok.');
    final exists = await db.customSelect('SELECT 1 FROM "$table" WHERE "$pk" = ?', variables: [Variable<String>(id)]).get();
    if (exists.isEmpty) throw CliException('$table içinde $id bulunamadı.');

    final type = col.read<String>('type').toUpperCase();
    Object? value;
    if (raw == 'null') {
      value = null;
    } else if (type.contains('INT') || type.contains('BOOL')) {
      value = int.tryParse(raw) ??
          (raw == 'true' ? 1 : raw == 'false' ? 0 : null) ??
          (DateTime.tryParse(raw) == null ? null : DateTime.parse(raw).millisecondsSinceEpoch ~/ 1000);
      if (value == null) throw CliException('"$field" bir sayı (ya da tarih) bekliyor: $raw');
    } else if (type.contains('REAL')) {
      value = double.tryParse(raw);
      if (value == null) throw CliException('"$field" bir ondalık sayı bekliyor: $raw');
    } else {
      value = raw;
    }
    await db.customStatement('UPDATE "$table" SET "$field" = ? WHERE "$pk" = ?', [value, id]);
    // Aranan metin ve güncelleme zamanı tutarlı kalsın.
    if (table == 'anlik_notes' && field == 'body') {
      await db.customStatement('UPDATE anlik_notes SET search_text = ?, updated_at = ? WHERE id = ?',
          [normalizeTr(raw), clock().millisecondsSinceEpoch ~/ 1000, id]);
    }
    return {'tablo': table, 'id': id, 'alan': field};
  }

  Future<Map<String, Object?>> _suggestDelete() async {
    final table = args.need(0, 'tablo');
    final id = args.need(1, 'id');
    final t = ledger.syncTables.where((t) => t.actualTableName == table).firstOrNull;
    if (t == null) throw CliException('Bu tablo için öneri yazılamaz: $table');
    final pk = t.$primaryKey.single.$name;
    final exists = await db.customSelect('SELECT 1 FROM "$table" WHERE "$pk" = ?', variables: [Variable<String>(id)]).get();
    if (exists.isEmpty) throw CliException('$table içinde $id bulunamadı.');
    final sid = ids.next();
    await db.customStatement(
      "INSERT INTO silme_onerileri (id, tablo, satir_id, neden, oneren, oturum_id, durum, created_at) "
      "VALUES (?, ?, ?, ?, 'claude', ?, 'bekliyor', ?)",
      [sid, table, id, args.opts['neden'] ?? '', session, clock().millisecondsSinceEpoch ~/ 1000],
    );
    return {'oneri': sid, 'not': 'Hiçbir şey silinmedi; kullanıcı onaylarsa silinir.'};
  }

  Future<Map<String, Object?>> _undo() async {
    await ledger.ensureReady(defaultSource: 'pc');
    final s = args.opts['oturum'];
    if (s != null) {
      final r = await ledger.undoSession(s);
      return {
        'tamam': true,
        'oturum': s,
        'geriAlinan': r[UndoResult.done] ?? 0,
        'cakisma': r[UndoResult.conflict] ?? 0,
      };
    }
    final id = args.need(0, 'değişiklik kimliği (ya da --oturum X)');
    final r = await ledger.undoChange(id);
    if (r == UndoResult.notFound) throw CliException('Değişiklik bulunamadı: $id');
    return {'tamam': r == UndoResult.done, 'sonuc': r.name};
  }
}
