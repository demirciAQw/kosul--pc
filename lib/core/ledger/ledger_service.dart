import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import 'hlc.dart';
import 'ledger_triggers.dart';

/// Defterdeki bir değişiklik; iki cihaz arasında bu biçimde gider.
/// `eski` ve `yeni` JSON metni olarak taşınır (yeniden yazılmaz): iki cihazda
/// satır karşılaştırması harfi harfine aynı olsun diye.
class LedgerChange {
  const LedgerChange({
    required this.id,
    required this.device,
    required this.source,
    required this.table,
    required this.rowId,
    required this.op,
    required this.clock,
    this.session,
    this.old,
    this.neu,
    this.undoes,
    this.seq = 0,
  });

  final int seq; // gönderen cihazdaki yerel sıra
  final String id;
  final String device;
  final String source;
  final String? session;
  final String table;
  final String rowId;
  final String op; // ekle | degistir | sil
  final String? old;
  final String? neu;
  final String clock;
  final String? undoes;

  Map<String, Object?> toJson() => {
        'sira': seq,
        'id': id,
        'cihaz': device,
        'kaynak': source,
        if (session != null) 'oturum': session,
        'tablo': table,
        'satir': rowId,
        'islem': op,
        if (old != null) 'eski': old,
        if (neu != null) 'yeni': neu,
        'saat': clock,
        if (undoes != null) 'gerial': undoes,
      };

  static LedgerChange? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], dev = j['cihaz'], src = j['kaynak'], table = j['tablo'], row = j['satir'], op = j['islem'], clock = j['saat'];
    if (id is! String || dev is! String || src is! String || table is! String || row is! String || op is! String || clock is! String) {
      return null;
    }
    if (!const {'ekle', 'degistir', 'sil'}.contains(op) || Hlc.tryParse(clock) == null) return null;
    String? opt(String k) => j[k] is String ? j[k] as String : null;
    return LedgerChange(
      seq: j['sira'] is int ? j['sira'] as int : 0,
      id: id,
      device: dev,
      source: src,
      session: opt('oturum'),
      table: table,
      rowId: row,
      op: op,
      old: opt('eski'),
      neu: opt('yeni'),
      clock: clock,
      undoes: opt('gerial'),
    );
  }
}

/// Uygulanan bir toplunun özeti.
class ApplyResult {
  const ApplyResult({this.applied = 0, this.duplicates = 0, this.alreadySame = 0, this.conflicts = 0, this.failed = 0});

  final int applied;
  final int duplicates;
  final int alreadySame;
  final int conflicts;
  final int failed;

  ApplyResult operator +(ApplyResult o) => ApplyResult(
        applied: applied + o.applied,
        duplicates: duplicates + o.duplicates,
        alreadySame: alreadySame + o.alreadySame,
        conflicts: conflicts + o.conflicts,
        failed: failed + o.failed,
      );
}

enum UndoResult { done, conflict, notFound, already }

/// Değişiklik defterinin yönetimi: bağlam, uygulama, çakışma ve geri alma.
class LedgerService {
  LedgerService(this._db);

  final AppDatabase _db;

  /// customStatement ile yazılan tablolar: Drift bunları kendiliğinden bilmez;
  /// işlem bitince akışlara (liste ekranları) haber verilir.
  final _touched = <String>{};

  void _flushTouched() {
    if (_touched.isEmpty) return;
    final names = {..._touched};
    _touched.clear();
    _db.notifyUpdates({
      for (final t in _db.allTables)
        if (names.contains(t.actualTableName)) TableUpdate.onTable(t),
    });
  }

  static const keySentSeq = 'gonderilen_sira'; // karşı cihazın gördüğü kendi sıram
  static const keyReceivedSeq = 'alinan_sira'; // karşıdan aldığım son sıra
  static const keyStarted = 'defter_basladi';

  /// v9.10: bilgisayar artık tablet satırlarını da aktarır; eski sürüm `uzak=1`
  /// satırları atlayıp imleci ilerletmişti. İlk eşitlemede `alinan_sira` bir kez
  /// sıfırlanır (tekrar gelen satırlar kimlikten atlanır). İşaret bir kez yazılır.
  static const keyRelayReset = 'aktarma_imleci_sifirlandi';

  /// Veritabanının hangi uygulama kurulumuna (`esitleme.json` kimliği) ait olduğu.
  static const keyInstall = 'kurulum_kimligi';

  // ───────────── Kurulum ─────────────

  /// Bağlam satırını ve tetikleyicileri hazırlar; her açılışta çalışır.
  Future<void> ensureReady({required String defaultSource}) async {
    final rows = await _db.customSelect('SELECT cihaz_id FROM _baglam WHERE id = 1').get();
    if (rows.isEmpty) {
      await _db.customStatement(
        'INSERT INTO _baglam (id, cihaz_id, kaynak, varsayilan) VALUES (1, ?, ?, ?)',
        [_newDeviceId(), defaultSource, defaultSource],
      );
    } else {
      await _db.customStatement('UPDATE _baglam SET varsayilan = ?, kaynak = ? WHERE id = 1', [defaultSource, defaultSource]);
    }
    await installTriggers();
  }

  /// Bu veritabanını bir uygulama kurulumuna bağlar. Veritabanı başka bir
  /// kurulumdan geldiyse (yedekten geri yükleme, kopya) defter cihaz kimliği
  /// ÇİFT olabilir: bilgisayar `cihaz_id <> gönderen` ile süzdüğünden öbür
  /// cihazın satırları sessizce atlanırdı. Bu yüzden kimlik yenilenir.
  /// [installId] veritabanının DIŞINDA (ayrı dosyada) durmalıdır. Yenilendiyse true.
  Future<bool> bindToInstall(String installId) async {
    final rows = await _db.customSelect('SELECT value FROM esitleme_durum WHERE key = ?', variables: [Variable<String>(keyInstall)]).get();
    final known = rows.isEmpty ? null : rows.first.read<String>('value');
    var renewed = false;
    if (known != null && known != installId) {
      await _db.customStatement('UPDATE _baglam SET cihaz_id = ? WHERE id = 1', [_newDeviceId()]);
      renewed = true;
    }
    if (known != installId) {
      await _db.customStatement(
          'INSERT INTO esitleme_durum (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [keyInstall, installId]);
    }
    return renewed;
  }

  static String _newDeviceId() {
    final r = Random.secure();
    return List.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Iterable<TableInfo<Table, Object?>> get syncTables =>
      _db.allTables.where((t) => !ledgerExcludedTables.contains(t.actualTableName));

  /// Eksik tetikleyicileri kurar. [rebuild]: önce hepsini kaldırır (şema değişince).
  Future<void> installTriggers({bool rebuild = false}) async {
    if (rebuild) {
      final all = await _db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '$ledgerTriggerPrefix%'")
          .get();
      for (final r in all) {
        await _db.customStatement('DROP TRIGGER IF EXISTS "${r.read<String>('name')}"');
      }
    }
    final have = {
      for (final r in await _db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '$ledgerTriggerPrefix%'")
          .get())
        r.read<String>('name'),
    };
    for (final t in syncTables) {
      final names = ledgerTriggerNames(t.actualTableName);
      if (names.every(have.contains)) continue;
      final cols = [for (final c in t.$columns) c.$name];
      final pk = t.$primaryKey.length == 1 ? t.$primaryKey.single.$name : null;
      if (pk == null) continue; // bileşik anahtarlı tablo yok; varsa deftere girmez
      final sql = ledgerTriggerSql(t.actualTableName, cols, pk, blobs: _blobColumns(t));
      for (var i = 0; i < 3; i++) {
        if (!have.contains(names[i])) await _db.customStatement(sql[i]);
      }
    }
  }

  static Set<String> _blobColumns(TableInfo<Table, Object?> t) =>
      {for (final c in t.$columns) if (c.type == DriftSqlType.blob) c.$name};

  Future<String> deviceId() async =>
      (await _db.customSelect('SELECT cihaz_id FROM _baglam WHERE id = 1').getSingle()).read<String>('cihaz_id');

  // ───────────── Yazanın kimliği ─────────────

  /// [body] içindeki yazmalar [source] (ve [session]) adına deftere geçer.
  /// Tek işlemdir; bittiğinde bağlam varsayılana döner. Dışarıdan çağıran
  /// araçlar (kocum) başka bir işlem açmadan bunu kullanmalı.
  Future<T> withSource<T>(String source, {String? session, required Future<T> Function() body}) {
    return _db.transaction(() async {
      await _db.customStatement('UPDATE _baglam SET kaynak = ?, oturum_id = ? WHERE id = 1', [source, session]);
      try {
        return await body();
      } finally {
        await _db.customStatement('UPDATE _baglam SET kaynak = varsayilan, oturum_id = NULL WHERE id = 1');
      }
    });
  }

  /// Tetikleyicileri susturur (yedek birleştirme, senkron uygulaması).
  Future<T> silently<T>(Future<T> Function() body) async {
    await _db.customStatement('UPDATE _baglam SET bastir = 1 WHERE id = 1');
    try {
      return await body();
    } finally {
      await _db.customStatement('UPDATE _baglam SET bastir = 0 WHERE id = 1');
    }
  }

  /// Yalnızca testler: saati sabitler (ms); null gerçek saate döner.
  Future<void> setTestClock(int? ms) => _db.customStatement('UPDATE _baglam SET saat_ms = ? WHERE id = 1', [ms]);

  // ───────────── Okuma ─────────────

  LedgerChange _fromRow(QueryRow r) => LedgerChange(
        seq: r.read<int>('yerel_sira'),
        id: r.read<String>('id'),
        device: r.read<String>('cihaz_id'),
        source: r.read<String>('kaynak'),
        session: r.readNullable<String>('oturum_id'),
        table: r.read<String>('tablo'),
        rowId: r.read<String>('satir_id'),
        op: r.read<String>('islem'),
        old: r.readNullable<String>('eski'),
        neu: r.readNullable<String>('yeni'),
        clock: r.read<String>('saat'),
        undoes: r.readNullable<String>('geri_alinan'),
      );

  /// Karşıya gönderilecek değişiklikler: [afterSeq]'ten sonrakiler; karşıdan
  /// gelenler ve yedek birleştirmesinden doğanlar gönderilmez.
  ///
  /// [relayExcept] (yalnızca bilgisayar, yani merkez): karşıdan gelen satırlar
  /// da, KARŞI cihazın kendi yazdıkları hariç, aktarılır. Böylece telefon ve
  /// tablet birbirini görmeden de bilgisayar üzerinden aynı satırlara yakınsar.
  /// Kimlikler değişmediği için alan cihaz çift kayıt yapmaz. Yalnızca
  /// bilgisayarda UYGULANAN satırlar aktarılır: çakışmayı kaybeden ya da
  /// uygulanamayan satır `kaynak = 'senkron'` ile işlenir (bkz. `_logRemote`) ve öbür cihaza gitmez (orada ayrı çakışma/ayrışma çıkmasın).
  ///
  /// [skipAfter]/[skipUpTo] (v9.23): bu sıra aralığındaki (skipAfter, skipUpTo] satırlar
  /// verilmez. Karşıdan az önce uygulanan satırlar ona geri yankılanmasın diye.
  Future<List<LedgerChange>> pendingFor(
    int afterSeq, {
    int limit = 300,
    String? relayExcept,
    int? skipAfter,
    int? skipUpTo,
  }) async {
    final skip = skipAfter != null && skipUpTo != null;
    final where = relayExcept == null
        ? "yerel_sira > ? AND uzak = 0 AND kaynak <> 'senkron' "
        : "yerel_sira > ? AND kaynak <> 'senkron' AND cihaz_id <> ? ";
    final rows = await _db.customSelect(
      'SELECT * FROM degisiklikler WHERE $where'
      '${skip ? 'AND NOT (yerel_sira > ? AND yerel_sira <= ?) ' : ''}'
      'ORDER BY yerel_sira LIMIT ?',
      variables: [
        Variable<int>(afterSeq),
        if (relayExcept != null) Variable<String>(relayExcept),
        if (skip) ...[Variable<int>(skipAfter), Variable<int>(skipUpTo)],
        Variable<int>(limit),
      ],
    ).get();
    return [for (final r in rows) _fromRow(r)];
  }

  /// Bu fotoğraf yolu, bu cihazın kendi değişikliklerinden birinde geçiyor mu?
  /// (Karşıya yalnızca bu cihazın eklediği fotoğraflar verilir.)
  /// [relayed]: merkez olarak, öbür eşleşmiş cihazdan gelen satırlar da sayılır.
  Future<bool> mentionsOwnPhoto(String path, {bool relayed = false}) async {
    final r = await _db.customSelect(
      "SELECT 1 FROM degisiklikler WHERE ${relayed ? '' : 'uzak = 0 AND '}kaynak <> 'senkron' AND yeni LIKE ? ESCAPE '\\' LIMIT 1",
      variables: [Variable<String>('%"${path.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}"%')],
    ).get();
    return r.isNotEmpty;
  }

  /// Bu özet bir `pdf_documents` satırında geçiyor mu? (`pdf-al` yalnızca
  /// bilgisayarın kendi belge kayıtlarında geçen PDF'i verir.)
  Future<bool> hasPdfDocument(String sha256) async =>
      (await (_db.select(_db.pdfDocuments)..where((d) => d.sha256.equals(sha256) & d.deleted.equals(false))).get()).isNotEmpty;

  /// Gönderilmeyecek olanlar dahil defterin en büyük yerel sırası.
  Future<int> maxSeq() async {
    final r = await _db.customSelect('SELECT COALESCE(MAX(yerel_sira), 0) AS n FROM degisiklikler').getSingle();
    return r.read<int>('n');
  }

  Future<int> intState(String key) async {
    final r = await _db.customSelect('SELECT value FROM esitleme_durum WHERE key = ?', variables: [Variable<String>(key)]).get();
    return r.isEmpty ? 0 : int.tryParse(r.first.read<String>('value')) ?? 0;
  }

  Future<void> setIntState(String key, int value) => _db.customStatement(
      'INSERT INTO esitleme_durum (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, '$value']);

  Future<String?> textState(String key) async {
    final r = await _db.customSelect('SELECT value FROM esitleme_durum WHERE key = ?', variables: [Variable<String>(key)]).get();
    return r.isEmpty ? null : r.first.read<String>('value');
  }

  Future<void> deleteState(String key) => _db.customStatement('DELETE FROM esitleme_durum WHERE key = ?', [key]);

  Future<void> setTextState(String key, String value) => _db.customStatement(
      'INSERT INTO esitleme_durum (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value]);

  // ───────────── Tam durum (v9.15) ─────────────

  /// Yeni eşleşen cihaz bilgisayardaki TÜM güncel satırları ister mi? (1 = evet.)
  /// Bilgisayara ilk tam yedekle gelen eski veri deftere girmediği için `pendingFor`
  /// onu hiç taşımaz; bu yol onu "anlık görüntü" kayıtlarıyla tamamlar.
  static const keyNeedSnapshot = 'tam_durum_gerek';

  /// Tam durum indirmesinin imleci (`snapshotPage` biçimi) ve başladığındaki
  /// bilgisayar defteri sırası (bittiğinde `alinan_sira` bu değere çekilir).
  static const keySnapshotCursor = 'tam_durum_imlec';
  static const keySnapshotMarker = 'tam_durum_sira';

  /// Bilgisayar tarafı: senkron tablolarının güncel satırlarını sayfa sayfa verir
  /// (yeni genel okuma ucu YOK: aynı imzalı `degisiklikler` alışverişinde, yalnızca
  /// cihaz isterse). [cursor] boş = baştan. Satırlar `ekle` kaydı gibi görünür,
  /// `yeni` = satırın tam JSON'u (tetikleyiciyle aynı biçim). [maxBytes] aşılınca
  /// sayfa kapanır (en az bir satır gider). `next` null ise bitti.
  Future<({List<LedgerChange> rows, String? next})> snapshotPage(
    String cursor, {
    int maxRows = 400,
    int maxBytes = 1500 * 1024,
  }) async {
    final tables = [for (final t in syncTables) if (t.$primaryKey.length == 1) t]
      ..sort((a, b) => a.actualTableName.compareTo(b.actualTableName));
    var ti = 0;
    String? after;
    if (cursor.isNotEmpty) {
      try {
        final c = jsonDecode(cursor);
        if (c is! List || c.length != 2 || c[0] is! String || c[1] is! String) throw const FormatException();
        ti = tables.indexWhere((t) => t.actualTableName == c[0]);
        if (ti < 0) throw const FormatException();
        after = c[1] as String;
      } on FormatException {
        throw ArgumentError('Bozuk tam durum imleci.');
      }
    }
    final device = await deviceId();
    final clock = await _clockNow();
    final rows = <LedgerChange>[];
    var bytes = 0;
    String? lastTable, lastKey;
    var full = false;
    for (; ti < tables.length && !full; ti++, after = null) {
      final t = tables[ti];
      final name = t.actualTableName;
      final cols = [for (final c in t.$columns) c.$name];
      final pkCol = t.$primaryKey.single;
      final pk = pkCol.$name;
      final isText = pkCol.type == DriftSqlType.string;
      final Variable<Object>? param = after == null
          ? null
          : isText
              ? Variable<String>(after)
              : (int.tryParse(after) == null ? null : Variable<int>(int.parse(after)));
      final result = await _db
          .customSelect(
            'SELECT ${rowJson('"$name"', cols, blobs: _blobColumns(t))} AS j, CAST("$pk" AS TEXT) AS k FROM "$name" '
            '${param == null ? '' : 'WHERE "$pk" > ? '}ORDER BY "$pk" LIMIT ?',
            variables: [
              if (param != null) param,
              Variable<int>(maxRows - rows.length),
            ],
          )
          .get();
      for (final r in result) {
        final json = r.read<String>('j');
        if (rows.isNotEmpty && bytes + json.length > maxBytes) {
          full = true;
          break;
        }
        bytes += json.length + 200;
        final key = r.read<String>('k');
        rows.add(LedgerChange(
            id: 'anlik-$name-$key', device: device, source: 'pc', table: name, rowId: key, op: 'ekle', clock: clock, neu: json));
        lastTable = name;
        lastKey = key;
        if (rows.length >= maxRows) {
          full = true;
          break;
        }
      }
      if (full) break;
    }
    if (!full) return (rows: rows, next: null);
    return (rows: rows, next: jsonEncode([lastTable, lastKey]));
  }

  /// Cihaz tarafı: bilgisayarın tam durum satırlarını yazar. YALNIZCA eksik
  /// satır eklenir; var olan satıra dokunulmaz (çakışma çıkmaz), cihazda silinmiş
  /// (`sil` kaydı olan) satır geri gelmez. Satırlar deftere işlenmez (yedekle gelmiş
  /// veri gibi): cihaz sonradan değiştirirse `eski` değer bilgisayardakiyle tutar.
  /// Yabancı anahtar denetimi sayfa boyunca kapalıdır (sayfa sırası tablo adına göredir,
  /// ana kayıt sonraki sayfada gelebilir); bütün sayfalar gelince tutarlıdır.
  Future<ApplyResult> applySnapshot(List<LedgerChange> changes) async {
    var result = const ApplyResult();
    if (changes.isEmpty) return result;
    // DİKKAT: `PRAGMA foreign_keys` bağlantı geneldir (işlem içinde değiştirilemez); bu kısa
    // pencerede aynı bağlantıdan gelen arayüz yazımları da FK denetimsiz çalışır. Pencere
    // yalnızca bir sayfalık (en çok birkaç yüz satır) tam durum işlemi kadardır.
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        await _db.customStatement('UPDATE _baglam SET bastir = 1 WHERE id = 1');
        try {
          for (final c in changes) {
            if (c.op != 'ekle' || c.neu == null || _table(c.table) == null) {
              result += const ApplyResult(failed: 1);
              continue;
            }
            try {
              final cur = await currentRowJson(c.table, c.rowId);
              if (cur != null) {
                result += cur == c.neu ? const ApplyResult(alreadySame: 1) : const ApplyResult(duplicates: 1);
                continue;
              }
              final deleted = await _db.customSelect(
                "SELECT 1 FROM degisiklikler WHERE tablo = ? AND satir_id = ? AND islem = 'sil' LIMIT 1",
                variables: [Variable<String>(c.table), Variable<String>(c.rowId)],
              ).get();
              if (deleted.isNotEmpty) {
                result += const ApplyResult(duplicates: 1);
                continue;
              }
              await _writeRow(c.table, c.rowId, c.neu);
              result += const ApplyResult(applied: 1);
            } catch (_) {
              result += const ApplyResult(failed: 1);
            }
          }
        } finally {
          await _db.customStatement('UPDATE _baglam SET bastir = 0 WHERE id = 1');
        }
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
    _flushTouched();
    return result;
  }

  Future<List<LedgerChange>> history({String? session, String? source, int limit = 500}) async => [
        for (final r in await _db.customSelect(
          'SELECT * FROM degisiklikler WHERE 1 = 1 '
          '${session == null ? '' : 'AND oturum_id = ? '}'
          '${source == null ? '' : 'AND kaynak = ? '}'
          'ORDER BY yerel_sira DESC LIMIT ?',
          variables: [
            if (session != null) Variable<String>(session),
            if (source != null) Variable<String>(source),
            Variable<int>(limit),
          ],
        ).get())
          _fromRow(r),
      ];

  /// [history] ile aynı, defter değiştikçe yeniden yayılır.
  Stream<List<LedgerChange>> watchHistory({String? source, int limit = 500}) => _db
      .customSelect(
        'SELECT * FROM degisiklikler ${source == null ? '' : 'WHERE kaynak = ? '}ORDER BY yerel_sira DESC LIMIT ?',
        variables: [if (source != null) Variable<String>(source), Variable<int>(limit)],
        readsFrom: {_db.degisiklikler, ...syncTables},
      )
      .watch()
      .map((rows) => [for (final r in rows) _fromRow(r)]);

  Stream<Set<String>> watchUndone() => _db
      .customSelect('SELECT geri_alinan FROM degisiklikler WHERE geri_alinan IS NOT NULL', readsFrom: {_db.degisiklikler, ...syncTables})
      .watch()
      .map((rows) => {for (final r in rows) r.read<String>('geri_alinan')});

  /// Çakışmada kaybeden sürümü geri getirir (satır olduğu gibi yazılır; bu
  /// da normal bir değişiklik olarak deftere ve karşıya geçer) ve çakışmayı
  /// çözülmüş sayar. Kaybeden sürüm yoksa (satır silinmişti) satır silinir.
  Future<void> restoreLoser(String conflictId) async {
    final c = await (_db.select(_db.cakismalar)..where((x) => x.id.equals(conflictId))).getSingleOrNull();
    if (c == null || _table(c.tablo) == null) return;
    await _db.transaction(() async {
      await _writeRow(c.tablo, c.satirId, c.kaybeden);
      await resolveConflict(conflictId);
    });
    _flushTouched();
  }

  /// Geri alınmış değişikliklerin kimlikleri.
  Future<Set<String>> undoneIds() async => {
        for (final r in await _db.customSelect('SELECT geri_alinan FROM degisiklikler WHERE geri_alinan IS NOT NULL').get())
          r.read<String>('geri_alinan'),
      };

  // ───────────── Satır erişimi ─────────────

  TableInfo<Table, Object?>? _table(String name) => syncTables.where((t) => t.actualTableName == name).firstOrNull;

  Future<String?> currentRowJson(String table, String rowId) async {
    final t = _table(table);
    if (t == null) return null;
    final cols = [for (final c in t.$columns) c.$name];
    final pk = t.$primaryKey.single.$name;
    final r = await _db
        .customSelect('SELECT ${rowJson('"$table"', cols, blobs: _blobColumns(t))} AS j FROM "$table" WHERE "$pk" = ?',
            variables: [Variable<String>(rowId)])
        .get();
    return r.isEmpty ? null : r.first.read<String>('j');
  }

  Future<void> _writeRow(String table, String rowId, String? json) async {
    final t = _table(table)!;
    _touched.add(table);
    final pk = t.$primaryKey.single.$name;
    if (json == null) {
      await _db.customStatement('DELETE FROM "$table" WHERE "$pk" = ?', [rowId]);
      return;
    }
    final m = jsonDecode(json) as Map<String, Object?>;
    final blobs = _blobColumns(t);
    final cols = [for (final c in t.$columns) c.$name];
    final set = [for (final c in cols) if (c != pk) '"$c" = excluded."$c"'];
    await _db.customStatement(
      'INSERT INTO "$table" (${cols.map((c) => '"$c"').join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')}) '
      'ON CONFLICT("$pk") DO ${set.isEmpty ? 'NOTHING' : 'UPDATE SET ${set.join(', ')}'}',
      [for (final c in cols) blobs.contains(c) && m[c] is String ? unhex(m[c]! as String) : m[c]],
    );
  }

  /// `hex()` ile yazılmış BLOB'u çözer (bkz. `rowJson`). Boş BLOB `''` olur.
  /// Tek haneli ya da geçersiz karakterde [FormatException] fırlatır.
  static Uint8List unhex(String h) {
    if (h.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(h)) throw FormatException('Bozuk onaltılık BLOB', h);
    return Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
  }

  Future<String?> _latestLocalClock(String table, String rowId) async {
    final r = await _db.customSelect(
      'SELECT saat FROM degisiklikler WHERE tablo = ? AND satir_id = ? ORDER BY saat DESC LIMIT 1',
      variables: [Variable<String>(table), Variable<String>(rowId)],
    ).get();
    return r.isEmpty ? null : r.first.read<String>('saat');
  }

  /// Karşıdan gelen satırı deftere işler (kimlikten tekrar atlanır; `uzak = 1`).
  /// [applied] false ise (çakışmayı kaybetti, uygulanamadı, bilinmeyen tablo)
  /// `kaynak` 'senkron' yazılır: bu değer zaten "aktarılmaz" demektir
  /// (`pendingFor`, `mentionsOwnPhoto` süzer). `uzak` sütunu Drift'te
  /// `CHECK (uzak IN (0, 1))` olduğundan üçüncü bir değer yazılamaz (INSERT OR
  /// IGNORE sessizce düşürürdü); şema değişmeden bu yol seçildi.
  Future<void> _logRemote(LedgerChange c, {bool applied = true}) => _db.customStatement(
        'INSERT OR IGNORE INTO degisiklikler '
        '(id, cihaz_id, kaynak, oturum_id, tablo, satir_id, islem, eski, yeni, saat, uzak, geri_alinan) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)',
        [c.id, c.device, applied ? c.source : 'senkron', c.session, c.table, c.rowId, c.op, c.old, c.neu, c.clock, c.undoes],
      );

  Future<void> _recordConflict({
    required String table,
    required String rowId,
    required String? winner,
    required String? loser,
    required String side,
    required String clock,
  }) async {
    final id = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_newDeviceId().substring(0, 6)}';
    await _db.into(_db.cakismalar).insert(CakismalarCompanion.insert(
          id: id,
          tablo: table,
          satirId: rowId,
          kazanan: Value(winner),
          kaybeden: Value(loser),
          taraf: side,
          saat: clock,
          createdAt: DateTime.now(),
        ));
  }

  // ───────────── Karşıdan gelenleri uygula ─────────────

  /// Karşı cihazın değişikliklerini uygular. Aynı kimlik ikinci kez gelirse
  /// atlanır (bağlantı yarıda kopup yeniden gönderilirse çift kayıt olmaz).
  /// Aynı satır iki tarafta da değiştiyse HLC'si yeni olan kazanır; kaybeden
  /// sürüm Çakışmalar'a düşer. Tek işlemdir.
  Future<ApplyResult> applyRemote(List<LedgerChange> changes) async => (await applyRemoteRanged(changes)).result;

  /// [applyRemote] + bu işlemin deftere yazdığı yerel sıra aralığı `(from, to]`.
  /// Aralık AYNI işlem içinde okunur: yerel (arayüz) yazımları işlem bitene dek
  /// bekler, yani aralıkta yalnızca karşıdan gelen satırlar vardır. Eş, aralıktaki
  /// satırları kendisinden aldığı için ona geri yollanmaz (yankı).
  Future<({ApplyResult result, int from, int to})> applyRemoteRanged(List<LedgerChange> changes) async {
    var result = const ApplyResult();
    var from = 0, to = 0;
    await _db.transaction(() async {
      from = await maxSeq();
      await _db.customStatement('UPDATE _baglam SET bastir = 1 WHERE id = 1');
      try {
        for (final c in changes) {
          result += await _applyOne(c);
        }
      } finally {
        await _db.customStatement('UPDATE _baglam SET bastir = 0 WHERE id = 1');
      }
      to = await maxSeq();
    });
    _flushTouched();
    return (result: result, from: from, to: to);
  }

  Future<ApplyResult> _applyOne(LedgerChange c) async {
    final seen = await _db.customSelect('SELECT 1 FROM degisiklikler WHERE id = ?', variables: [Variable<String>(c.id)]).get();
    if (seen.isNotEmpty) return const ApplyResult(duplicates: 1);
    await _advanceClock(c.clock);
    if (_table(c.table) == null) {
      // Bilinmeyen tablo (daha yeni sürüm): kaydı tut, uygulama.
      await _logRemote(c, applied: false);
      return const ApplyResult(failed: 1);
    }
    String? cur;
    try {
      cur = await currentRowJson(c.table, c.rowId);
      if (cur == c.neu) {
        await _logRemote(c);
        return const ApplyResult(alreadySame: 1);
      }
      if (cur == c.old) {
        await _writeRow(c.table, c.rowId, c.neu);
        await _logRemote(c);
        return const ApplyResult(applied: 1);
      }
      // Çakışma: iki taraf da aynı satırı değiştirdi.
      final local = await _latestLocalClock(c.table, c.rowId);
      final remoteWins = local == null || compareHlcText(c.clock, local) > 0;
      if (remoteWins) {
        await _writeRow(c.table, c.rowId, c.neu);
        await _recordConflict(table: c.table, rowId: c.rowId, winner: c.neu, loser: cur, side: 'uzak', clock: c.clock);
      } else {
        await _recordConflict(table: c.table, rowId: c.rowId, winner: cur, loser: c.neu, side: 'yerel', clock: c.clock);
      }
      await _logRemote(c, applied: remoteWins);
      return const ApplyResult(conflicts: 1);
    } catch (_) {
      // Tek bir satır (ör. silinmiş bir ana kayda bağlı) tüm toplu bozmasın.
      // Uygulanamayan sürüm sessizce kaybolmasın: Çakışmalar'a düşer (kaybeden).
      try {
        await _recordConflict(table: c.table, rowId: c.rowId, winner: cur, loser: c.neu, side: 'uzak', clock: c.clock);
      } catch (_) {}
      await _logRemote(c, applied: false);
      return const ApplyResult(failed: 1);
    }
  }

  /// Karşıdan gelen saati görünce yerel saat onun üstüne taşınır.
  Future<void> _advanceClock(String remoteClock) async {
    final remote = Hlc.tryParse(remoteClock);
    if (remote == null) return;
    final r = await _db.customSelect('SELECT hlc_ms, hlc_n, cihaz_id, saat_ms FROM _baglam WHERE id = 1').getSingle();
    final local = Hlc(r.read<int>('hlc_ms'), r.read<int>('hlc_n'), r.read<String>('cihaz_id'));
    final now = r.readNullable<int>('saat_ms') ?? DateTime.now().millisecondsSinceEpoch;
    final next = local.receive(remote, now);
    // Tetikleyici bir sonraki olayda bir tık daha ilerletir; burada yalnızca yerel saati yükseltiriz.
    final ms = next.ms, n = next.counter;
    if (ms > local.ms || (ms == local.ms && n > local.counter)) {
      await _db.customStatement('UPDATE _baglam SET hlc_ms = ?, hlc_n = ? WHERE id = 1', [ms, n]);
    }
  }

  // ───────────── Geri alma ─────────────

  /// [id] değişikliğini geri alır: `eski` değer yeni bir değişiklik olarak
  /// yazılır (kaynak: geri_al), böylece geri alma da geri alınabilir. Satır o
  /// arada başkası tarafından değiştirildiyse üstüne yazılmaz, çakışma olarak
  /// gösterilir.
  Future<UndoResult> undoChange(String id) async {
    final rows = await _db.customSelect('SELECT * FROM degisiklikler WHERE id = ?', variables: [Variable<String>(id)]).get();
    if (rows.isEmpty) return UndoResult.notFound;
    final c = _fromRow(rows.first);
    if ((await undoneIds()).contains(id)) return UndoResult.already;
    if (_table(c.table) == null) return UndoResult.notFound;
    var result = UndoResult.done;
    await withSource('geri_al', body: () async {
      final cur = await currentRowJson(c.table, c.rowId);
      if (cur != c.neu) {
        await _recordConflict(
          table: c.table,
          rowId: c.rowId,
          winner: cur,
          loser: c.old,
          side: 'geri_al',
          clock: await _clockNow(),
        );
        result = UndoResult.conflict;
        return;
      }
      await _writeRow(c.table, c.rowId, c.old);
      // Az önce tetikleyicinin yazdığı geri alma kaydı bu değişikliği işaret etsin.
      await _db.customStatement(
        'UPDATE degisiklikler SET geri_alinan = ? WHERE yerel_sira = '
        "(SELECT MAX(yerel_sira) FROM degisiklikler WHERE tablo = ? AND satir_id = ? AND kaynak = 'geri_al' AND uzak = 0)",
        [id, c.table, c.rowId],
      );
    });
    _flushTouched();
    return result;
  }

  Future<String> _clockNow() async {
    final r = await _db.customSelect("SELECT printf('%013d-%04d-%s', hlc_ms, hlc_n, cihaz_id) AS s FROM _baglam WHERE id = 1").getSingle();
    return r.read<String>('s');
  }

  /// Bir Claude oturumunun tüm değişikliklerini sondan başa geri alır.
  Future<Map<UndoResult, int>> undoSession(String session) async {
    final undone = await undoneIds();
    final todo = [
      for (final c in await history(session: session, limit: 100000))
        if (c.source == 'claude' && !undone.contains(c.id)) c,
    ]; // history zaten yeniden eskiye
    final out = <UndoResult, int>{};
    for (final c in todo) {
      final r = await undoChange(c.id);
      out[r] = (out[r] ?? 0) + 1;
    }
    return out;
  }

  // ───────────── Silme önerileri ─────────────

  Stream<List<SilmeOnerisiRow>> watchDeleteSuggestions() => (_db.select(_db.silmeOnerileri)
        ..where((s) => s.durum.equals('bekliyor'))
        ..orderBy([(s) => OrderingTerm.desc(s.createdAt)]))
      .watch();

  /// Kullanıcı onayladı: satır silinir (normal bir silme olarak deftere ve
  /// karşıya geçer; kaynak Claude değil kullanıcıdır).
  Future<void> approveDeletion(String id) async {
    final s = await (_db.select(_db.silmeOnerileri)..where((x) => x.id.equals(id))).getSingleOrNull();
    if (s == null || s.durum != 'bekliyor') return;
    await _db.transaction(() async {
      if (_table(s.tablo) != null) await _writeRow(s.tablo, s.satirId, null);
      await (_db.update(_db.silmeOnerileri)..where((x) => x.id.equals(id)))
          .write(const SilmeOnerileriCompanion(durum: Value('onaylandi')));
    });
    _flushTouched();
  }

  Future<void> rejectDeletion(String id) => (_db.update(_db.silmeOnerileri)..where((x) => x.id.equals(id)))
      .write(const SilmeOnerileriCompanion(durum: Value('reddedildi')));

  // ───────────── Çakışmalar ─────────────

  Future<void> resolveConflict(String id) =>
      (_db.update(_db.cakismalar)..where((c) => c.id.equals(id))).write(const CakismalarCompanion(cozuldu: Value(true)));

  Stream<List<CakismaRow>> watchConflicts() => (_db.select(_db.cakismalar)
        ..where((c) => c.cozuldu.equals(false))
        ..orderBy([(c) => OrderingTerm.desc(c.createdAt)]))
      .watch();
}
