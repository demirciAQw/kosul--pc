import 'dart:io';

import 'package:drift/native.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/mcp/kocum_tools.dart';
import 'package:kocum/mcp/mcp_server.dart';

/// Koçum yerel MCP sunucusu (STDIO; ağ yok, anahtar yok). Ayrıntı: docs/CLAUDE_CODE.md
///
///   dart run bin/kocum_mcp.dart [--db <yol>] [--yaz] [--oturum X]
///
/// Varsayılan SALT OKUMA. `--yaz` verilirse yazma araçları listelenir; yazmalar
/// `kaynak: claude` ile deftere geçer ve geri alınabilir. Sağlık tabloları hiçbir araçta yok.
/// stdout YALNIZCA JSON-RPC içindir; tanı iletileri stderr'e gider.
Future<void> main(List<String> args) async {
  String? dbArg;
  String? sessionArg;
  var write = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--yaz':
        write = true;
      case '--db':
        if (i + 1 >= args.length) _die('--db için yol gerekli.');
        dbArg = args[++i];
      case '--oturum':
        if (i + 1 >= args.length) _die('--oturum için değer gerekli.');
        sessionArg = args[++i];
      default:
        _die('Bilinmeyen argüman: ${args[i]}\nKullanım: kocum_mcp [--db <yol>] [--yaz] [--oturum X]');
    }
  }
  final home = Platform.environment['HOME'] ?? '.';
  final path = dbArg ?? Platform.environment['KOCUM_DB'] ?? '$home/.local/share/com.kocum.kocum/kocum.sqlite';
  final file = File(path);
  if (!await file.exists()) _die('Veritabanı yok: $path. Önce bilgisayardaki Koçum\'u bir kez aç.');

  final db = AppDatabase(
    NativeDatabase(file, setup: (raw) {
      raw.execute('PRAGMA busy_timeout = 5000');
    }),
    'pc',
  );
  try {
    if (!write) await lockReadOnly(db);
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final session = sessionArg ?? 'claude-mcp-${now.year}-${two(now.month)}-${two(now.day)}';
    final server = McpServer(tools: buildKocumTools(db, write: write, session: session));
    stderr.writeln('kocum-mcp hazır (${write ? 'OKUMA+YAZMA' : 'salt okuma'}).');
    await server.serve(stdin, stdout.writeln);
  } finally {
    await db.close();
  }
}

Never _die(String msg) {
  stderr.writeln(msg);
  exit(2);
}
