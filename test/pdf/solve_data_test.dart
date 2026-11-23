import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/pdf/presentation/solve_time_section.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/pdf/domain/solve.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';

final _pts = [const StrokePoint(1, 2, t: 0), const StrokePoint(3, 4, t: 40)];
const _doc = PdfPageOwner('belge', 2);

class _Ids implements IdGenerator {
  var n = 0;
  @override
  String next() => 'k${n++}';
}

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

void main() {
  group('depo', () {
    test('questionId + denemeNo ile okunur; serbest çizgiler ayrı kalır', () async {
      final db = await _open();
      final repo = InkStrokeRepository(db);
      final free = await repo.add(owner: _doc, points: _pts, startedAtMs: 1, attemptNo: 1);
      final q1a1 = await repo.add(owner: _doc, points: _pts, startedAtMs: 2, attemptNo: 1, questionId: 'q1');
      final q1a2 = await repo.add(owner: _doc, points: _pts, startedAtMs: 3, attemptNo: 2, questionId: 'q1');
      final q2a1 = await repo.add(owner: _doc, points: _pts, startedAtMs: 4, attemptNo: 1, questionId: 'q2');

      expect((await repo.forPage(_doc, questionId: 'q1', attemptNo: 1)).map((s) => s.id), [q1a1]);
      expect((await repo.forPage(_doc, questionId: 'q1', attemptNo: 2)).single.questionId, 'q1');
      expect((await repo.forPage(_doc, questionId: 'q1')).map((s) => s.id), [q1a1, q1a2]);
      expect((await repo.forPage(_doc, questionId: 'q2')).map((s) => s.id), [q2a1]);
      // Okuyucunun serbest çizgileri: soruya bağlı olanlar karışmaz.
      final f = await repo.forPage(_doc, noQuestion: true, attemptNo: 1);
      expect(f.map((s) => s.id), [free]);
      expect(f.single.questionId, isNull);
      // Hiç filtre yok: eskisi gibi hepsi.
      expect(await repo.forPage(_doc), hasLength(4));
    });

    test('kart silinince çizgileri yumuşak silinir (satır kalır), başka sorunun çizgisi kalır', () async {
      final db = await _open();
      final repo = InkStrokeRepository(db);
      final cards = DriftQuestionCardRepository(db);
      await cards.insert(QuestionCard(
        id: 'q1',
        status: QuestionStatus.wrong,
        origin: QuestionOrigin.independent,
        sourceName: 'x',
        subject: 'TYT Matematik',
        difficulty: 5,
        createdAt: DateTime(2026),
      ));
      await repo.add(owner: _doc, points: _pts, startedAtMs: 1, attemptNo: 1, questionId: 'q1');
      await repo.add(owner: _doc, points: _pts, startedAtMs: 2, attemptNo: 2, questionId: 'q1');
      final other = await repo.add(owner: _doc, points: _pts, startedAtMs: 3, questionId: 'q2');
      await cards.delete('q1');
      expect(await repo.forPage(_doc, questionId: 'q1'), isEmpty);
      expect((await repo.forPage(_doc, questionId: 'q2')).map((s) => s.id), [other]);
      final rows = await (db.select(db.inkStrokes)..where((r) => r.questionId.equals('q1'))).get();
      expect(rows, hasLength(2)); // veri silinmedi
      expect(rows.every((r) => r.deleted), isTrue);
    });

    test('çizgi zamanları: silinenler hariç, yalnızca o soru', () async {
      final db = await _open();
      final repo = InkStrokeRepository(db);
      await repo.add(owner: _doc, points: _pts, startedAtMs: 1000, attemptNo: 1, questionId: 'q1');
      final gone = await repo.add(owner: _doc, points: _pts, startedAtMs: 2000, attemptNo: 1, questionId: 'q1');
      await repo.add(owner: _doc, points: _pts, startedAtMs: 90000, attemptNo: 2, questionId: 'q1');
      await repo.add(owner: _doc, points: _pts, startedAtMs: 5, attemptNo: 1, questionId: 'q2');
      await repo.softDelete(gone);
      final times = await repo.watchSolveTimes('q1').first;
      expect(times, hasLength(2));
      final a = solveAttempts(times);
      expect(a.map((e) => (e.no, e.strokeCount)), [(1, 1), (2, 1)]);
      expect(a.first.duration, const Duration(milliseconds: 40));
      expect(await repo.watchSolveTimes('yok').first, isEmpty);
    });
  });

  group('göç', () {
    /// Eski sürümü taklit eder: question_id sütunu ve indeksi yok.
    Future<void> migrate(int from) async {
      final dir = await Directory.systemTemp.createTemp('solve_goc');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/k.sqlite');
      var d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      final old = InkStrokeRepository(d);
      await old.add(owner: _doc, points: _pts, startedAtMs: 7, attemptNo: 1);
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      await d.customStatement('DROP INDEX ix_ink_question');
      await d.customStatement('ALTER TABLE ink_strokes DROP COLUMN question_id');
      if (from < 15) {
        await d.customStatement('DROP TABLE ink_strokes');
      }
      await d.customStatement('PRAGMA user_version = $from');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      addTearDown(d.close);
      final cols = {for (final c in await d.customSelect('PRAGMA table_info(ink_strokes)').get()) c.read<String>('name')};
      expect(cols, contains('question_id'));
      expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 22);
      final idx = {
        for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'index'").get())
          r.read<String>('name'),
      };
      expect(idx, contains('ix_ink_question'));
      final repo = InkStrokeRepository(d);
      if (from >= 15) {
        // Eski çizgi korunur, questionId null kalır.
        final s = (await repo.forPage(_doc)).single;
        expect((s.questionId, s.startedAtMs), (null, 7));
      }
      // Yeni sütunlu çizgi yazılır ve tetikleyici onu kapsar.
      final id = await repo.add(owner: _doc, points: _pts, startedAtMs: 9, attemptNo: 1, questionId: 'q1');
      final h = (await LedgerService(d).history()).where((c) => c.table == 'ink_strokes' && c.rowId == id);
      expect(h, hasLength(1));
      expect((jsonDecode(h.single.neu!) as Map)['question_id'], 'q1');
    }

    test('v17 -> v18', () => migrate(17));
    test('v16 -> v18', () => migrate(16));
    test('v15 -> v18', () => migrate(15));
    test('v14 -> v18 (tablo güncel tanımla kurulur)', () => migrate(14));

    test('sütun zaten varsa göç çift eklemez', () async {
      final dir = await Directory.systemTemp.createTemp('solve_goc2');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/k.sqlite');
      var d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      await d.customStatement('PRAGMA user_version = 17');
      await d.close();
      d = AppDatabase(NativeDatabase(file));
      addTearDown(d.close);
      expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 22);
    });
  });

  group('ledger, birleştirici, CLI', () {
    test('tetikleyici questionId güncellemesini kaydeder ve geri alınır', () async {
      final db = await _open();
      final ledger = LedgerService(db);
      final id = await InkStrokeRepository(db).add(owner: _doc, points: _pts, startedAtMs: 1, attemptNo: 1);
      await db.customStatement("UPDATE ink_strokes SET question_id = 'q9' WHERE id = '$id'");
      final ch = (await ledger.history()).firstWhere((c) => c.op == 'degistir' && c.table == 'ink_strokes');
      expect((jsonDecode(ch.old!) as Map)['question_id'], isNull);
      expect((jsonDecode(ch.neu!) as Map)['question_id'], 'q9');
      await ledger.undoChange(ch.id);
      expect((await db.select(db.inkStrokes).getSingle()).questionId, isNull);
    });

    test('defter başka cihaza questionId ile gider', () async {
      final a = await _open('telefon');
      final b = await _open('pc');
      await InkStrokeRepository(a).add(owner: _doc, points: _pts, startedAtMs: 1, attemptNo: 3, questionId: 'q1');
      await LedgerService(b).applyRemote(await LedgerService(a).pendingFor(0));
      final row = await b.select(b.inkStrokes).getSingle();
      expect((row.questionId, row.attemptNo), ('q1', 3));
    });

    test('masaüstü birleştirici: yeni ve eski (v17) telefon kopyası', () async {
      final dir = await Directory.systemTemp.createTemp('solve_birles');
      addTearDown(() => dir.delete(recursive: true));
      final desktop = await _open('pc');
      Future<File> phone(String name, {required bool old}) async {
        final f = File('${dir.path}/$name');
        final d = AppDatabase(NativeDatabase(f));
        await InkStrokeRepository(d)
            .add(owner: _doc, points: _pts, startedAtMs: 5, attemptNo: 1, questionId: old ? null : 'q1');
        if (old) {
          for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'").get()) {
            await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
          }
          await d.customStatement('DROP INDEX ix_ink_question');
          await d.customStatement('ALTER TABLE ink_strokes DROP COLUMN question_id');
          await d.customStatement('PRAGMA user_version = 17');
        }
        await d.close();
        return f;
      }

      final yeni = await phone('yeni.db', old: false);
      await SnapshotMerger(desktop).merge(yeni);
      expect((await desktop.select(desktop.inkStrokes).getSingle()).questionId, 'q1');
      final r = await SnapshotMerger(desktop).merge(await phone('eski.db', old: true));
      expect(r.firstWhere((t) => t.table == 'ink_strokes').added, 1);
      final rows = await desktop.select(desktop.inkStrokes).get();
      expect(rows, hasLength(2));
      expect(rows.where((x) => x.questionId == null), hasLength(1));
      // İkinci birleştirmede değişen yok.
      await SnapshotMerger(desktop).merge(yeni);
      expect(await desktop.select(desktop.inkStrokes).get(), hasLength(2));
    });

    test('kocum CLI: question_id düzeltilir ve sorgulanır', () async {
      final db = AppDatabase(NativeDatabase.memory(), 'pc');
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      final id = await InkStrokeRepository(db).add(owner: _doc, points: _pts, startedAtMs: 1, attemptNo: 2, questionId: 'q1');
      Future<(int, Map<String, dynamic>)> run(List<String> args) async {
        final out = StringBuffer();
        final code = await runKocum(args,
            db: db, out: out.writeln, err: (_) {}, now: () => DateTime(2026, 11, 1), env: const {}, ids: _Ids());
        return (code, jsonDecode(out.toString().isEmpty ? '{}' : out.toString()) as Map<String, dynamic>);
      }

      expect((await run(['duzelt', 'ink_strokes', id, 'question_id', 'q2'])).$1, 0);
      expect((await db.select(db.inkStrokes).getSingle()).questionId, 'q2');
      final q = await run(['sorgu', 'SELECT question_id, attempt_no FROM ink_strokes']);
      expect(q.$2['satirlar'], [
        {'question_id': 'q2', 'attempt_no': 2},
      ]);
    });
  });

  testWidgets('soru ayrıntısında çözüm süresi deneme başına görünür; çizgi yoksa görünmez', (t) async {
    late AppDatabase db;
    await t.runAsync(() async {
      db = await _open();
      final repo = InkStrokeRepository(db);
      await repo.add(owner: _doc, points: _pts, startedAtMs: 1000, attemptNo: 1, questionId: 'q1', durationMs: 65000);
      await repo.add(owner: _doc, points: _pts, startedAtMs: 900000, attemptNo: 2, questionId: 'q1', durationMs: 5000);
    });
    Widget app(String q) => ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: MaterialApp(home: Scaffold(body: SolveTimeSection(questionId: q))),
        );
    await t.pumpWidget(app('q1'));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    expect(find.text('Çözüm süresi'), findsOneWidget);
    expect(find.text('1. deneme: 1 dk 5 sn'), findsOneWidget);
    expect(find.text('2. deneme: 5 sn'), findsOneWidget);
    await t.pumpWidget(app('yok'));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await t.pump();
    expect(find.byKey(const Key('solve-time-section')), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}
