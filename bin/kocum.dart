import 'dart:io';

import 'package:drift/native.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';

/// Koçum komut satırı aracı. Ayrıntı: docs/KOCUM_ARACI.md
///
///   dart run bin/kocum.dart <komut> …
///
/// Masaüstü uygulamasının veritabanını açar (WAL + busy_timeout: uygulama
/// açıkken de güvenli). Başka bir dosya için `KOCUM_DB=/yol/kocum.sqlite`.
Future<void> main(List<String> args) async {
  final home = Platform.environment['HOME'] ?? '.';
  final path = Platform.environment['KOCUM_DB'] ?? '$home/.local/share/com.kocum.kocum/kocum.sqlite';
  final file = File(path);
  if (args.isNotEmpty && args.first != 'yardim' && !await file.exists()) {
    stderr.writeln('{"hata": "Veritabanı yok: $path. Önce bilgisayardaki Koçum\'u bir kez aç."}');
    exit(1);
  }
  final db = AppDatabase(
    NativeDatabase(file, setup: (raw) {
      raw.execute('PRAGMA journal_mode = WAL');
      raw.execute('PRAGMA busy_timeout = 5000');
    }),
    'pc',
  );
  try {
    exitCode = await runKocum(
      args,
      db: db,
      out: stdout.writeln,
      err: stderr.writeln,
      env: Platform.environment,
    );
  } finally {
    await db.close();
  }
}
