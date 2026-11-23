import 'dart:io';

import '../../../core/ledger/ledger_service.dart';
import '../domain/ledger_protocol.dart';
import '../domain/media_rules.dart';
import '../domain/sync_protocol.dart';

/// Bilgisayar tarafı: telefondan (ya da tabletten) gelen değişiklikleri uygular,
/// karşının görmediği kendi değişikliklerini döner. Telefon yine istemcidir.
///
/// Bilgisayar MERKEZDİR: telefon ve tablet birbiriyle eşleşmez; sırayla
/// bilgisayarla alışveriş ederler. Bilgisayar bir cihazdan aldığı satırları
/// (kimlikleri değişmeden) öbürüne de aktarır; karşı cihazın kendi satırları
/// ona geri dönmez.
///
/// Okuma ya da listeleme ucu yoktur: telefon bilgisayarın tamamını
/// göremez; yalnızca kendi gönderdiğine karşılık, bilgisayarın telefona
/// vermesi gereken değişiklikleri (ve içlerinde geçen fotoğrafları) alır.
class LedgerExchange {
  LedgerExchange({
    required this.ledger,
    required this.schemaVersion,
    required this.mediaFile,
  });

  final LedgerService ledger;
  final int schemaVersion;

  /// Medya köküne göre göreli yolun dosyası.
  final File Function(String path) mediaFile;

  /// [peer]: oturumu doğrulanmış cihaz (eşleşme kimliği); tam durum fotoğraf izni bu kimliğe
  /// bağlanır (isteğin kendi bildirdiği `device` alanına değil). Verilmezse `req.device`.
  Future<LedgerResponse> handle(LedgerRequest req, {String? peer}) async {
    if (req.schema != schemaVersion) {
      throw SyncException(
        'Telefon ve bilgisayardaki Koçum farklı sürümde (veri şeması ${req.schema} ve $schemaVersion). '
        'İkisini de güncelle.',
        status: 409,
      );
    }
    final result = await ledger.applyRemote(req.changes);

    final snapCursor = req.snapshotCursor;
    if (snapCursor != null)
      return _snapshot(req, snapCursor, result, peer ?? req.device);

    var out = await ledger.pendingFor(
      req.received,
      limit: ledgerBatch,
      relayExcept: req.device,
    );
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
    final more = (await ledger.pendingFor(
      lastOut,
      limit: 1,
      relayExcept: req.device,
    )).isNotEmpty;

    final photos = <MediaEntry>[];
    for (final path in mediaPathsOfChanges(out)) {
      final stat = await FileStat.stat(mediaFile(path).path);
      if (stat.type == FileSystemEntityType.file &&
          stat.size <= SyncLimits.photo)
        photos.add(MediaEntry(path, stat.size));
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

  /// Tam durum (v9.15): yeni eşleşen cihaza bilgisayardaki güncel satırlar. Aynı imzalı
  /// alışverişin cevabıdır; yeni okuma ucu yoktur. Cihazın kendi satırları yine uygulanır.
  /// Sıra işareti, ilk sayfadan ÖNCE alınır: sonradan olan değişiklikler normal
  /// alışverişle gelir (yeniden oynatma güvenlidir: aynıysa atlanır).
  Future<LedgerResponse> _snapshot(
    LedgerRequest req,
    String cursor,
    ApplyResult result,
    String peer,
  ) async {
    final marker = await ledger.maxSeq();
    final page = await ledger.snapshotPage(cursor);
    final photos = <MediaEntry>[];
    for (final path in mediaPathsOfChanges(page.rows)) {
      final stat = await FileStat.stat(mediaFile(path).path);
      if (stat.type == FileSystemEntityType.file &&
          stat.size <= SyncLimits.photo) {
        photos.add(MediaEntry(path, stat.size));
        (_snapshotPhotos[peer] ??= <String>{}).add(path);
      }
    }
    // Bellek sınırı: çok büyük kümede en eskileri bırak.
    final mine = _snapshotPhotos[peer] ?? <String>{};
    while (mine.length > 50000) {
      mine.remove(mine.first);
    }
    return LedgerResponse(
      acked: req.lastSeq,
      changes: const [],
      lastSeq: req.received,
      more: false,
      photos: photos,
      summary: _summary(result),
      snapshot: page.rows,
      snapshotNext: page.next,
      snapshotMarker: marker,
    );
  }

  /// Tam durumda CİHAZA gösterilen (bilgisayarın satırlarında geçen) fotoğraflar; cihaz
  /// başına: bir cihazın tam durumu öbürüne izin açmaz.
  final _snapshotPhotos = <String, Set<String>>{};

  /// PDF `pdf-al` ile verilebilir mi? Yalnızca bilgisayarın `pdf_documents` satırında
  /// geçen özet (genel dosya okuma yok).
  Future<bool> hasPdfDocument(String sha256) => ledger.hasPdfDocument(sha256);

  /// Telefon bu fotoğrafı isteyebilir mi? Yalnızca yol kurala uyuyorsa ve
  /// bilgisayarın defterindeki bir değişiklikte (kendisinin ya da eşleşmiş
  /// öbür cihazın) geçiyorsa (genel dosya okuma yok).
  Future<bool> maySend(String path, {required String device}) async =>
      isTransferableMediaPath(path) &&
      ((_snapshotPhotos[device]?.contains(path) ?? false) ||
          await ledger.mentionsOwnPhoto(path, relayed: true));

  static String _summary(ApplyResult r) => [
    '${r.applied} uygulandı',
    if (r.conflicts > 0) '${r.conflicts} çakışma',
    if (r.duplicates > 0) '${r.duplicates} zaten vardı',
    if (r.failed > 0) '${r.failed} uygulanamadı',
  ].join(', ');
}
