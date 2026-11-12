import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/database/database_snapshot.dart';

void main() {
  test('kopya tutarlı: aynı satırlar ve şema sürümü; geçici dosya silinir', () async {
    final dir = await Directory.systemTemp.createTemp('kocum_anlik');
    addTearDown(() => dir.delete(recursive: true));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement("INSERT INTO app_meta (meta_key, meta_value) VALUES ('k', 'v')");

    final scratch = File('${dir.path}/anlik.db');
    final bytes = await databaseSnapshot(db, scratch);
    expect(await scratch.exists(), isFalse);
    expect(sqliteUserVersion(bytes), db.schemaVersion);

    final copy = File('${dir.path}/kopya.db');
    await copy.writeAsBytes(bytes);
    final other = AppDatabase(NativeDatabase(copy));
    addTearDown(other.close);
    final rows = await other.customSelect("SELECT meta_value FROM app_meta WHERE meta_key = 'k'").get();
    expect(rows.single.read<String>('meta_value'), 'v');
  });

  test('SQLite olmayan dosyanın sürümü yok', () {
    expect(sqliteUserVersion(List.filled(100, 0)), isNull);
    expect(sqliteUserVersion(const [1, 2, 3]), isNull);
  });
}
