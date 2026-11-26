import 'dart:convert';
import 'dart:io';

import '../../../core/database/health_tables.dart';
import '../../../core/export/zip_reader.dart';
import '../domain/health_aggregate.dart';
import '../domain/huawei_zip_parser.dart';
import 'health_repository.dart';

/// Huawei ZIP (ya da klasör) dosyalarını okur ve içe aktarır.
/// Şifreli ZIP ve ZIP64 desteklenmez (açık hata verilir).
class HuaweiImportService {
  HuaweiImportService(this._repo);
  final HealthRepository _repo;

  static const _maxEntry = 60 * 1024 * 1024;

  Future<List<HuaweiFile>> readZip(File zip) async {
    final z = await ZipFileReader.open(zip);
    try {
      final out = <HuaweiFile>[];
      for (final e in z.entries) {
        if (e.isDirectory || !isSafeZipPath(e.name)) continue;
        final lower = e.name.toLowerCase();
        final textual = lower.endsWith('.json') || lower.endsWith('.jsonl') || lower.endsWith('.csv') || lower.endsWith('.tsv');
        if (!textual || e.size > _maxEntry) {
          out.add(HuaweiFile(e.name, e.size, null));
          continue;
        }
        final bytes = await z.read(e);
        out.add(HuaweiFile(e.name, e.size, utf8.decode(bytes, allowMalformed: true)));
      }
      return out;
    } finally {
      await z.close();
    }
  }

  Future<List<HuaweiFile>> readFolder(Directory dir) async {
    final out = <HuaweiFile>[];
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is! File) continue;
      final name = f.path.substring(dir.path.length).replaceFirst(RegExp(r'^[\\/]+'), '');
      final lower = name.toLowerCase();
      final size = await f.length();
      final textual = lower.endsWith('.json') || lower.endsWith('.jsonl') || lower.endsWith('.csv') || lower.endsWith('.tsv');
      out.add(HuaweiFile(name, size, textual && size <= _maxEntry ? utf8.decode(await f.readAsBytes(), allowMalformed: true) : null));
    }
    return out;
  }

  /// Onaylanan sonucu kaydeder (idempotent). Yazılan gün sayısı döner.
  Future<int> import(HuaweiParseResult r) async {
    await _repo.upsertSessions(r.sleep);
    await _repo.upsertStress(r.stress);
    final days = [
      ...buildHealthDays(source: healthSourceHuaweiZip, sessions: r.sleep, stress: r.stress),
      ...r.days,
    ];
    return _repo.upsertDays(days);
  }
}
