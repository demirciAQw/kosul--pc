import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/export/zip_writer.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/desktop/import/data/import_service.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/desktop/import/domain/import_models.dart';
import 'package:kocum/desktop/import/domain/import_rules.dart';

/// Gerçek klasöre yazan, yalnızca [resolve] gerektiren medya deposu.
class _DirMedia implements MediaStorage {
  _DirMedia(this.root);
  final Directory root;

  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _book(String id, String title) =>
    'INSERT INTO books (id, title, exam_type, subject, page_count, avg_questions_per_page, created_at) '
    "VALUES ('$id', '$title', 'TYT', 'TYT Matematik', 100, 2.5, 1700000000)";
const _exam = 'INSERT INTO mock_exams (id, title, kind, taken_on, created_at) '
    "VALUES ('m1', 'Deneme 1', 'tyt', 1700000000, 1700000000)";
const _card = 'INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, '
    "created_at, mock_exam_id, question_no) VALUES ('q1', 'wrong', 'mockExam', 'Deneme 1', 'TYT Matematik', 5, '', "
    "1700000000, 'm1', 7)";

/// Telefondaki veritabanı: gerçek şemayla oluşturulmuş dosya.
Future<File> _phoneDb(Directory dir, String name, List<String> statements, {int? userVersion}) async {
  final file = File('${dir.path}/$name');
  final db = AppDatabase(NativeDatabase(file));
  await db.customSelect('SELECT 1').get(); // dosya ve şema oluşsun
  for (final s in statements) {
    await db.customStatement(s);
  }
  if (userVersion != null) await db.customStatement('PRAGMA user_version = $userVersion');
  await db.close();
  return file;
}

File _backupZip(Directory dir, String name, {File? database, String exportedAt = '2026-11-12T10:00:00.000'}) {
  final zip = ZipWriter()
    ..addText('kocum_yedek.json', jsonEncode({'format': 'kocum.backup', 'version': 1, 'exportedAt': exportedAt}));
  if (database != null) zip.add('kocum.db', database.readAsBytesSync());
  zip
    ..add('media/questions/2026/11/a.webp', [1, 2, 3])
    ..add('media/../kacak.txt', [6]);
  return File('${dir.path}/$name')..writeAsBytesSync(zip.finish());
}

Future<List<String>> _ids(AppDatabase db, String table) async =>
    [for (final r in await db.customSelect('SELECT id FROM $table ORDER BY id').get()) r.read<String>('id')];

void main() {
  late Directory dir;
  late AppDatabase desktop;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('kocum_ice');
    desktop = AppDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    await desktop.close();
    await dir.delete(recursive: true);
  });

  group('birleştirme', () {
    test('telefon kazanır; yeni eklenir; bilgisayardaki fazlalık silinmez, raporlanır', () async {
      await desktop.customStatement(_book('a', 'Eski A'));
      await desktop.customStatement(_book('c', 'Kitap C'));
      await desktop.customStatement("INSERT INTO app_meta (meta_key, meta_value) VALUES ('masaustu.x', '1')");
      final phone = await _phoneDb(dir, 'tel.db', [
        _book('a', 'Kitap A'),
        _book('b', 'Kitap B'),
        _exam,
        _card,
        "INSERT INTO app_meta (meta_key, meta_value) VALUES ('app.settings', '{}')",
      ]);

      final r = await SnapshotMerger(desktop).merge(phone);
      final books = r.firstWhere((t) => t.table == 'books');
      expect([books.total, books.added, books.updated], [2, 1, 1]);
      expect(books.missingIds, ['c']);
      // Soru, denemesinden önce işlenir: yabancı anahtar işlem sonunda denetlenir.
      expect(r.firstWhere((t) => t.table == 'question_cards').added, 1);
      expect(r.firstWhere((t) => t.table == 'mock_exams').added, 1);
      expect(r.any((t) => t.table == 'app_meta'), isFalse);

      expect(await _ids(desktop, 'books'), ['a', 'b', 'c']);
      final a = await desktop.customSelect("SELECT title FROM books WHERE id = 'a'").getSingle();
      expect(a.read<String>('title'), 'Kitap A');
      final meta = await desktop.customSelect('SELECT meta_key FROM app_meta ORDER BY meta_key').get();
      expect(meta.map((m) => m.read<String>('meta_key')), contains('masaustu.x'));
      expect(meta.map((m) => m.read<String>('meta_key')), isNot(contains('app.settings')));

      // Aynı kopya ikinci kez: değişiklik yok.
      final again = await SnapshotMerger(desktop).merge(phone);
      expect(again.fold<int>(0, (s, t) => s + t.added + t.updated), 0);
    });

    test('telefonda silinmiş koşan oturum yenisini engellemez', () async {
      await desktop.customStatement("INSERT INTO study_sessions (id, status, started_at) VALUES ('s1', 'running', 1)");
      final phone = await _phoneDb(
          dir, 'tel.db', ["INSERT INTO study_sessions (id, status, started_at) VALUES ('s2', 'running', 2)"]);
      final r = await SnapshotMerger(desktop).merge(phone);
      final sessions = r.firstWhere((t) => t.table == 'study_sessions');
      expect(sessions.added, 1);
      expect(sessions.missingIds, ['s1']);
    });

    test('telefondaki uygulama daha yeniyse içe aktarılmaz', () async {
      final phone = await _phoneDb(dir, 'tel.db', const [], userVersion: 99);
      await expectLater(SnapshotMerger(desktop).merge(phone), throwsA(isA<ImportException>()));
    });
  });

  group('içe aktarma', () {
    late ImportService service;
    late Directory media;
    setUp(() {
      media = Directory('${dir.path}/media');
      service = ImportService(
        db: desktop,
        media: _DirMedia(media),
        workDir: dir,
        now: () => DateTime(2026, 11, 12, 13),
      );
    });

    test('ZIP: veri, fotoğraflar, koç kopyası, geçmiş; güvensiz ad alınmaz', () async {
      await service.state.setCoachFolder('${dir.path}/kasa');
      final zip = _backupZip(dir, 'yedek.zip', database: await _phoneDb(dir, 'tel.db', [_exam, _card]));

      final job = await service.prepare(zip.path);
      expect(job.isOlder, isFalse);
      final s = await service.run(job);

      expect(s.table('question_cards')!.added, 1);
      expect([s.photosAdded, s.photosRejected], [1, 1]);
      expect(s.warnings, isNotEmpty);
      expect(File('${media.path}/questions/2026/11/a.webp').readAsBytesSync(), [1, 2, 3]);
      expect(File('${dir.path}/kacak.txt').existsSync(), isFalse);
      expect(File('${dir.path}/kasa/Koçum/kocum_yedek.json').existsSync(), isTrue);
      expect(await job.database.exists(), isFalse);
      expect((await service.state.history()).single.table('question_cards')!.added, 1);
      expect(await service.state.lastExportedAt(), DateTime.parse('2026-11-12T10:00:00.000'));

      // Fotoğraf ikinci kez gelirse atlanır.
      final second = await service.run(await service.prepare(zip.path));
      expect([second.photosAdded, second.photosSkipped], [0, 1]);
    });

    test('telefonda silinen soru işaretlenir, onayla silinir', () async {
      await service.run(await service.prepare(
          _backupZip(dir, '1.zip', database: await _phoneDb(dir, 'tel1.db', [_exam, _card])).path));
      final s = await service.run(await service.prepare(_backupZip(dir, '2.zip',
              database: await _phoneDb(dir, 'tel2.db', [_exam]), exportedAt: '2026-11-13T10:00:00.000')
          .path));
      expect(s.table('question_cards')!.missingIds, ['q1']);

      final views = await service.describeTombstones();
      expect(views.single.tombstone.key, 'question_cards/q1');
      expect(views.single.label, 'TYT Matematik · Deneme 1 · 7. soru');

      await service.deleteTombstoned([views.single.tombstone]);
      expect(await _ids(desktop, 'question_cards'), isEmpty);
      expect(await service.describeTombstones(), isEmpty);
    });

    test('eski yedek önce sorulur; veritabanı kopyası olmayan ya da yabancı dosya reddedilir', () async {
      await service.state.setLastExportedAt(DateTime.parse('2026-11-12T12:00:00.000'));
      final job = await service.prepare(_backupZip(dir, 'eski.zip', database: await _phoneDb(dir, 't.db', const [])).path);
      expect(job.isOlder, isTrue);
      await service.discard(job);
      expect(await job.database.exists(), isFalse);

      await expectLater(service.prepare(_backupZip(dir, 'json.zip').path), throwsA(isA<ImportException>()));
      final other = File('${dir.path}/baska.zip')
        ..writeAsBytesSync((ZipWriter()..addText('kocum_yedek.json', '{"format":"baska"}')).finish());
      await expectLater(service.prepare(other.path), throwsA(isA<ImportException>()));
    });
  });

  group('kurallar', () {
    final t0 = DateTime(2026, 11, 1), t1 = DateTime(2026, 11, 12);

    test('silinenler listesi: tarih korunur, geri gelen düşer, MEB konuları sayılmaz', () {
      final prev = [
        Tombstone(table: 'books', id: 'c', since: t0),
        Tombstone(table: 'books', id: 'geri', since: t0),
      ];
      final next = updateTombstones(prev, {
        'books': ['c'],
        'question_cards': ['q9'],
        'curriculum_nodes': ['tyt.x'],
      }, t1);
      expect(next.map((t) => t.key), ['question_cards/q9', 'books/c']);
      expect(next.last.since, t0);
      expect(next.first.since, t1);
    });

    test('eski yedek, dosya seçimi, dışa aktarma tarihi', () {
      expect(isOlderBackup(t0, t1), isTrue);
      expect(isOlderBackup(t1, t0), isFalse);
      expect(isOlderBackup(null, t1), isFalse);
      expect(isBackupCandidate('Kocum_Tum_Veri_20261112.zip'), isTrue);
      expect(isBackupCandidate('.syncthing.Kocum.zip.tmp'), isFalse);
      expect(isBackupCandidate('.gizli.zip'), isFalse);
      expect(isBackupCandidate('notlar.pdf'), isFalse);
      expect(exportedAtOf({'exportedAt': '2026-11-12T10:00:00.000'}), DateTime(2026, 11, 12, 10));
      expect(exportedAtOf(null), isNull);
    });

    test('özet JSON gidiş-dönüş', () {
      final s = ImportSummary(
        at: t1,
        source: 'yedek.zip',
        exportedAt: t0,
        tables: const [TableMerge(table: 'question_cards', total: 3, added: 2, updated: 1, missingIds: ['x'])],
        photosAdded: 4,
        warnings: const ['uyarı'],
      );
      final back = ImportSummary.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect([back.source, back.exportedAt, back.photosAdded, back.warnings], ['yedek.zip', t0, 4, ['uyarı']]);
      expect([back.totalAdded, back.totalUpdated, back.totalMissing], [2, 1, 1]);
    });
  });
}
