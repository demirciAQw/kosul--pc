import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/pdf_rules.dart';
import '../domain/sync_protocol.dart';
import 'sync_client.dart';

class PdfPullResult {
  const PdfPullResult({
    this.enabled = true,
    this.fetched = 0,
    this.notOnComputer = 0,
    this.failed = 0,
    this.cancelled = false,
    this.bytes = 0,
  });

  /// Kullanıcı ayarı ("PDF'leri bilgisayardan al") kapalıydı: hiçbir istek yapılmadı.
  final bool enabled;
  final int fetched;

  /// Satır var ama dosya bilgisayarda yok (bilgisayara hiç yüklenmemiş).
  final int notOnComputer;
  final int failed;
  final bool cancelled;
  final int bytes;

  String get summary {
    if (!enabled) return '';
    return [
      if (fetched > 0) '$fetched PDF bilgisayardan alındı (${formatPdfSize(bytes)})',
      if (notOnComputer > 0) '$notOnComputer PDF bilgisayarda da dosya olarak yok',
      if (failed > 0) '$failed PDF alınamadı',
      if (cancelled) 'PDF alma iptal edildi',
    ].join(', ');
  }
}

/// Bilgisayardaki PDF dosyalarından bu cihazda eksik olanları indirir (`pdf-al`).
/// İsteğe bağlıdır: [enabled] kapalıysa hiçbir istek yapılmaz. Defter satırları
/// (belge, çizgi, soru) bundan bağımsız gelir; dosya inmezse yalnızca sayfa görünmez.
class PdfPull {
  PdfPull({required this.client, required this.pdfDir, required this.enabled, this.onProgress, this.cancel});

  final SyncClient client;

  /// `<veri klasörü>/pdfs`: dosyalar `<sha256>.pdf` adıyla.
  final Directory pdfDir;
  final Future<bool> Function() enabled;

  /// (kaçıncı dosya, toplam dosya, ad, inen bayt, dosya toplamı)
  final void Function(int index, int count, String name, int received, int total)? onProgress;
  final SyncCancelToken? cancel;

  /// [shas]: bu cihazdaki (silinmemiş) belge satırlarının özetleri.
  Future<PdfPullResult> run(SyncConnection connection, Iterable<String> shas) async {
    if (!await enabled()) return const PdfPullResult(enabled: false);
    final missing = <String>[];
    for (final sha in shas) {
      final name = pdfNameOfSha(sha);
      if (name == null) continue;
      final stat = await FileStat.stat(p.join(pdfDir.path, name));
      if (stat.type != FileSystemEntityType.file) missing.add(sha);
    }
    var fetched = 0, none = 0, failed = 0, bytes = 0;
    for (var i = 0; i < missing.length; i++) {
      if (cancel?.cancelled == true) {
        return PdfPullResult(fetched: fetched, notOnComputer: none, failed: failed, cancelled: true, bytes: bytes);
      }
      final name = '${missing[i]}.pdf';
      final target = File(p.join(pdfDir.path, name));
      try {
        await client.fetchPdf(
          connection,
          missing[i],
          target,
          cancel: cancel,
          onProgress: (r, t) => onProgress?.call(i + 1, missing.length, name, r, t),
        );
        fetched++;
        bytes += (await target.stat()).size;
      } on SyncCancelledException {
        return PdfPullResult(fetched: fetched, notOnComputer: none, failed: failed, cancelled: true, bytes: bytes);
      } on PdfNotOnComputer {
        none++;
      } on SyncException catch (e) {
        failed++; // özet tutmadı, imza hatası vb.: öbür dosyalar denenir
        if (e.status == 401) break; // oturum kapandı: gerisi de reddedilir
      }
    }
    return PdfPullResult(fetched: fetched, notOnComputer: none, failed: failed, bytes: bytes);
  }
}
