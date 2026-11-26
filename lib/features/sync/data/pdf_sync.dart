import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/pdf_rules.dart';
import '../domain/sync_protocol.dart';
import 'sync_client.dart';

class PdfSyncResult {
  const PdfSyncResult({
    this.enabled = true,
    this.sent = 0,
    this.alreadyThere = 0,
    this.missingFile = 0,
    this.tooBig = 0,
    this.cancelled = false,
    this.bytesSent = 0,
  });

  /// Kullanıcı ayarı kapalıydı: hiçbir istek yapılmadı.
  final bool enabled;
  final int sent;
  final int alreadyThere;

  /// Belge satırı var, dosya bu cihazda yok (başka cihazdan gelmiş).
  final int missingFile;
  final int tooBig;
  final bool cancelled;
  final int bytesSent;

  String get summary {
    if (!enabled) return '';
    return [
      if (sent > 0) '$sent PDF gönderildi (${formatPdfSize(bytesSent)})',
      if (alreadyThere > 0) '$alreadyThere PDF bilgisayarda zaten vardı',
      if (missingFile > 0) '$missingFile PDF bu cihazda dosya olarak yok',
      if (tooBig > 0) '$tooBig PDF ${formatPdfSize(SyncLimits.pdf)} sınırını aştığı için gitmedi',
      if (cancelled) 'PDF gönderimi iptal edildi',
    ].join(', ');
  }
}

/// PDF dosyalarını bilgisayara yollar (telefon/tablet → bilgisayar; ters yön yok).
/// İsteğe bağlıdır: [enabled] kapalıysa hiçbir istek yapılmaz. Defter satırları
/// (belge, çizgi, soru) bundan bağımsız, her zamanki yoldan gider; PDF dosyası
/// bilgisayarda yoksa yalnızca sayfa görüntülenemez.
class PdfSync {
  PdfSync({
    required this.client,
    required this.pdfDir,
    required this.enabled,
    this.onProgress,
    this.cancel,
  });

  final SyncClient client;

  /// `<veri klasörü>/pdfs`: dosyalar `<sha256>.pdf` adıyla (`PdfImportService.fileOf`).
  final Directory pdfDir;
  final Future<bool> Function() enabled;

  /// (kaçıncı dosya, toplam dosya, ad, giden bayt, dosyanın bayt toplamı)
  final void Function(int index, int count, String name, int sent, int total)? onProgress;
  final SyncCancelToken? cancel;

  /// [shas]: bu cihazdaki (silinmemiş) belge satırlarının özetleri.
  Future<PdfSyncResult> run(SyncConnection connection, Iterable<String> shas) async {
    if (!await enabled()) return const PdfSyncResult(enabled: false);
    final sizes = <String, int?>{};
    for (final sha in shas) {
      final name = pdfNameOfSha(sha);
      if (name == null) continue;
      final stat = await FileStat.stat(p.join(pdfDir.path, name));
      sizes[sha] = stat.type == FileSystemEntityType.file ? stat.size : null;
    }
    final plan = selectPdfsToSend(sizes);
    var sent = 0, already = 0, bytes = 0;
    for (var i = 0; i < plan.send.length; i++) {
      final offer = plan.send[i];
      if (cancel?.cancelled == true) {
        return _result(plan, sent, already, bytes, cancelled: true);
      }
      try {
        final r = await client.sendPdf(
          connection,
          offer,
          File(p.join(pdfDir.path, offer.name)),
          cancel: cancel,
          onProgress: (s, t) => onProgress?.call(i + 1, plan.send.length, offer.name, s, t),
        );
        if (r.alreadyThere) {
          already++;
        } else {
          sent++;
          bytes += offer.size;
        }
      } on SyncCancelledException {
        return _result(plan, sent, already, bytes, cancelled: true);
      }
    }
    return _result(plan, sent, already, bytes);
  }

  PdfSyncResult _result(({List<PdfOffer> send, int missingFile, int tooBig}) plan, int sent, int already, int bytes,
          {bool cancelled = false}) =>
      PdfSyncResult(
        sent: sent,
        alreadyThere: already,
        missingFile: plan.missingFile,
        tooBig: plan.tooBig,
        cancelled: cancelled,
        bytesSent: bytes,
      );
}
