import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/desktop/data/external_change_watcher.dart';

void main() {
  test('başka bağlantının yazması fark edilir ve akış yenilenir; kendi yazmamız etkilemez', () async {
    final dir = await Directory.systemTemp.createTemp('dis_degisiklik');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/k.sqlite');
    NativeDatabase open() => NativeDatabase(file, setup: (raw) {
          raw.execute('PRAGMA journal_mode = WAL');
          raw.execute('PRAGMA busy_timeout = 5000');
        });
    final app = AppDatabase(open(), 'pc');
    final tool = AppDatabase(open(), 'pc'); // kocum aracı: ayrı bağlantı
    addTearDown(app.close);
    addTearDown(tool.close);
    await app.customSelect('SELECT 1').get();
    await tool.customSelect('SELECT 1').get();

    final lengths = <int>[];
    final sub = app.select(app.anlikNotes).watch().listen((r) => lengths.add(r.length));
    addTearDown(sub.cancel);
    final watcher = ExternalChangeWatcher(app);
    await pumpEventQueue();
    expect(await watcher.check(), isFalse); // ilk bakış: yalnızca başlangıç değeri
    expect(lengths.last, 0);

    // Kendi yazmamız dış değişiklik sayılmaz.
    await app.into(app.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'a', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'uygulama'));
    expect(await watcher.check(), isFalse);

    // Araç, uygulama açıkken Claude adına yazar (WAL + busy_timeout).
    await LedgerService(tool).withSource('claude', session: 'o', body: () async {
      await tool.into(tool.anlikNotes).insert(AnlikNotesCompanion.insert(
          id: 'b', createdAt: DateTime(2026), updatedAt: DateTime(2026), body: 'araç', searchText: const Value('arac')));
    });
    expect(lengths.last, 1); // akış henüz bilmiyor
    expect(await watcher.check(), isTrue);
    await pumpEventQueue();
    expect(lengths.last, 2); // ekran yenilendi
    expect(await watcher.check(), isFalse); // değişiklik tek sefer bildirilir

    // Araç satırı uygulamanın defterinde de görünür (aynı dosya).
    expect((await LedgerService(app).history(source: 'claude')).single.session, 'o');
  });
}
