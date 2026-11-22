import 'dart:io';

import '../../../core/ledger/ledger_service.dart';
import '../domain/ledger_protocol.dart';
import '../domain/media_rules.dart';
import '../domain/sync_protocol.dart';
import 'sync_client.dart';

class LedgerSyncResult {
  const LedgerSyncResult({
    this.sent = 0,
    this.received = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.photosSent = 0,
    this.photosReceived = 0,
    this.rounds = 0,
  });

  final int sent;
  final int received;
  final int conflicts;
  final int failed;
  final int photosSent;
  final int photosReceived;
  final int rounds;

  String get summary => [
        '$sent değişiklik gönderildi',
        '$received alındı',
        if (photosSent > 0) '$photosSent fotoğraf gitti',
        if (photosReceived > 0) '$photosReceived fotoğraf geldi',
        if (conflicts > 0) '$conflicts çakışma (Çakışmalar listesinde)',
        if (failed > 0) '$failed değişiklik uygulanamadı',
      ].join(', ');
}

/// Telefon tarafı alışveriş (telefon istemcidir): kendi defter satırlarını
/// yollar, cevapta bilgisayarın telefonun görmediği satırlarını alır.
///
/// Sıra önemli: fotoğraflar satırlardan ÖNCE taşınır. Bilgisayara giden
/// satırın fotoğrafı önce yüklenir; telefona gelen satırın fotoğrafı önce
/// indirilir. Böylece satır uygulanınca fotoğraf hazırdır (metin okuma
/// kuyruğu eksik dosyayı "okunamadı" yazmaz). İmleçler yalnızca uygulama
/// bitince ilerler; yarıda kopan alışveriş aynı satırları yeniden yollar ve
/// bilgisayar kimliğe bakarak çift kayıt yapmaz.
class LedgerSync {
  LedgerSync({
    required this.ledger,
    required this.client,
    required this.schemaVersion,
    required this.mediaFile,
    this.onProgress,
    this.maxRounds = 100,
  });

  final LedgerService ledger;
  final SyncClient client;
  final int schemaVersion;
  final File Function(String path) mediaFile;
  final void Function(String message)? onProgress;
  final int maxRounds;

  Future<LedgerSyncResult> run(SyncConnection connection) async {
    // Tek seferlik (v9.10): eski sürümden kalan alınan-sıra imleci bilgisayarın
    // aktarmadığı tablet satırlarını atlamış olabilir; bir kez sıfırlanır.
    if (await ledger.intState(LedgerService.keyRelayReset) == 0) {
      await ledger.setIntState(LedgerService.keyReceivedSeq, 0);
      await ledger.setIntState(LedgerService.keyRelayReset, 1);
    }
    final device = await ledger.deviceId();
    var result = const LedgerSyncResult();
    for (var round = 1; round <= maxRounds; round++) {
      final sentCursor = await ledger.intState(LedgerService.keySentSeq);
      final receivedCursor = await ledger.intState(LedgerService.keyReceivedSeq);
      final out = await ledger.pendingFor(sentCursor, limit: ledgerBatch);
      final lastOut = out.isEmpty ? sentCursor : out.last.seq;

      onProgress?.call('Fotoğraflar kontrol ediliyor…');
      final photosSent = await _uploadPhotos(connection, out);

      onProgress?.call('Değişiklikler gönderiliyor ($round. tur)…');
      final response = await client.exchangeLedger(
        connection,
        LedgerRequest(schema: schemaVersion, device: device, received: receivedCursor, changes: out, lastSeq: lastOut),
      );

      var photosReceived = 0;
      for (final photo in response.photos) {
        final file = mediaFile(photo.path);
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file && stat.size == photo.size) continue;
        onProgress?.call('Fotoğraf alınıyor: ${photo.path.split('/').last}');
        await client.fetchPhoto(connection, photo, file);
        photosReceived++;
      }

      final applied = await ledger.applyRemote(response.changes);
      // Uygulama bitti: imleçler ilerler.
      if (response.acked > sentCursor) await ledger.setIntState(LedgerService.keySentSeq, response.acked);
      if (response.lastSeq > receivedCursor) await ledger.setIntState(LedgerService.keyReceivedSeq, response.lastSeq);

      result = LedgerSyncResult(
        sent: result.sent + out.length,
        received: result.received + applied.applied,
        conflicts: result.conflicts + applied.conflicts,
        failed: result.failed + applied.failed,
        photosSent: result.photosSent + photosSent,
        photosReceived: result.photosReceived + photosReceived,
        rounds: round,
      );
      final moreHere = out.length >= ledgerBatch;
      if (!moreHere && !response.more) break;
    }
    return result;
  }

  /// [changes]'ın başvurduğu fotoğraflardan bilgisayarda eksik olanları yükler.
  Future<int> _uploadPhotos(SyncConnection connection, List<LedgerChange> changes) async {
    final offered = <MediaEntry>[];
    for (final path in mediaPathsOfChanges(changes)) {
      final stat = await mediaFile(path).stat();
      if (stat.type == FileSystemEntityType.file) offered.add(MediaEntry(path, stat.size));
    }
    if (offered.isEmpty) return 0;
    final missing = await client.missingPhotos(connection, offered);
    final toSend = requestedFromOffer(offered, missing.missing);
    for (final e in toSend) {
      await client.sendPhoto(connection, e, mediaFile(e.path));
    }
    return toSend.length;
  }
}
