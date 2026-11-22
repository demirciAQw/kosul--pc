import 'dart:io';

import '../../../core/ledger/ledger_service.dart';
import '../domain/ledger_protocol.dart';
import '../domain/media_rules.dart';
import '../domain/sync_protocol.dart';

/// Bilgisayar tarafı: telefondan gelen değişiklikleri uygular, telefonun
/// görmediği kendi değişikliklerini döner. Telefon yine istemcidir.
///
/// Okuma ya da listeleme ucu yoktur: telefon bilgisayarın tamamını
/// göremez; yalnızca kendi gönderdiğine karşılık, bilgisayarın telefona
/// vermesi gereken değişiklikleri (ve içlerinde geçen fotoğrafları) alır.
class LedgerExchange {
  LedgerExchange({required this.ledger, required this.schemaVersion, required this.mediaFile});

  final LedgerService ledger;
  final int schemaVersion;

  /// Medya köküne göre göreli yolun dosyası.
  final File Function(String path) mediaFile;

  Future<LedgerResponse> handle(LedgerRequest req) async {
    if (req.schema != schemaVersion) {
      throw SyncException(
        'Telefon ve bilgisayardaki Koçum farklı sürümde (veri şeması ${req.schema} ve $schemaVersion). '
        'İkisini de güncelle.',
        status: 409,
      );
    }
    final result = await ledger.applyRemote(req.changes);

    var out = await ledger.pendingFor(req.received, limit: ledgerBatch);
    // Yanıt gövde sınırını aşmasın.
    var bytes = 0;
    final keep = <LedgerChange>[];
    for (final c in out) {
      bytes += (c.old?.length ?? 0) + (c.neu?.length ?? 0) + 300;
      if (bytes > ledgerBatchBytes && keep.isNotEmpty) break;
      keep.add(c);
    }
    out = keep;
    final lastOut = out.isEmpty ? req.received : out.last.seq;
    final more = (await ledger.pendingFor(lastOut, limit: 1)).isNotEmpty;

    final photos = <MediaEntry>[];
    for (final path in mediaPathsOfChanges(out)) {
      final stat = await FileStat.stat(mediaFile(path).path);
      if (stat.type == FileSystemEntityType.file && stat.size <= SyncLimits.photo) photos.add(MediaEntry(path, stat.size));
    }

    return LedgerResponse(
      acked: req.lastSeq,
      changes: out,
      lastSeq: lastOut,
      more: more,
      photos: photos,
      summary: _summary(result),
    );
  }

  /// Telefon bu fotoğrafı isteyebilir mi? Yalnızca yol kurala uyuyorsa ve
  /// bilgisayarın kendi bir değişikliğinde geçiyorsa (genel dosya okuma yok).
  Future<bool> maySend(String path) async => isTransferableMediaPath(path) && await ledger.mentionsOwnPhoto(path);

  static String _summary(ApplyResult r) => [
        '${r.applied} uygulandı',
        if (r.conflicts > 0) '${r.conflicts} çakışma',
        if (r.duplicates > 0) '${r.duplicates} zaten vardı',
        if (r.failed > 0) '${r.failed} uygulanamadı',
      ].join(', ');
}
