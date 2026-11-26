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
    this.snapshotRows = 0,
    this.snapshotPending = false,
    this.duplicates = 0,
    this.pushedRows = 0,
    this.pushPending = false,
  });

  /// Tam durumdan eklenen (cihazda eksik olan) satır sayısı.
  final int snapshotRows;

  /// Tam durum henüz bitmedi (tur sınırı ya da kopma); bir sonraki eşitleme sürdürür.
  final bool snapshotPending;

  /// Zaten bilinen (kimlikten atlanan) gelen satır: yankı/üçgen yolu göstergesi.
  final int duplicates;

  /// Android alıcıya verilen (itilen) kendi tam durum satırı sayısı; itme sürüyor mu?
  final int pushedRows;
  final bool pushPending;

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
        if (snapshotRows > 0) 'karşıdan $snapshotRows eski kayıt alındı',
        if (pushedRows > 0) 'karşıya $pushedRows eski kayıt verildi',
        if (snapshotPending) 'tam durum sürüyor (yeniden eşitle)',
        if (pushPending) 'tam durum itmesi sürüyor (yeniden eşitle)',
        if (conflicts > 0) '$conflicts çakışma (Çakışmalar listesinde)',
        if (failed > 0) '$failed değişiklik uygulanamadı',
      ].join(', ');
}

/// İstemci tarafı alışveriş (istemci bu cihazdır): kendi defter satırlarını yollar,
/// cevapta alıcının bu cihazın görmediği satırlarını alır.
///
/// Sıra önemli: fotoğraflar satırlardan ÖNCE taşınır. Karşıya giden
/// satırın fotoğrafı önce yüklenir; bu cihaza gelen satırın fotoğrafı önce
/// indirilir. Böylece satır uygulanınca fotoğraf hazırdır (metin okuma
/// kuyruğu eksik dosyayı "okunamadı" yazmaz). İmleçler yalnızca uygulama
/// bitince ilerler; yarıda kopan alışveriş aynı satırları yeniden yollar ve
/// alıcı kimliğe bakarak çift kayıt yapmaz.
///
/// Çok eş (v9.23): [scope] (eş kimliği) verilirse imleçler ve tam durum durumu o eşe
/// özgüdür (`gonderilen_sira:<kimlik>` …) ve bu cihaz ARACI da olur: eşten alınan
/// satırlar, eşin KENDİ yazdıkları hariç, öbür eşlere aktarılır (`relayExcept`);
/// eşten az önce alınan satırlar ona geri yollanmaz (yankı); aynı değişiklik üçgenin
/// başka yolundan gelirse kimlikten atlanır. [scope] null ise v9.22 davranışı: genel
/// imleçler, yalnızca kendi satırları (tek eş; eski testler ve eski kayıtlar).
class LedgerSync {
  LedgerSync({
    required this.ledger,
    required this.client,
    required this.schemaVersion,
    required this.mediaFile,
    this.onProgress,
    this.maxRounds = 100,
    this.scope,
  });

  final LedgerService ledger;
  final SyncClient client;
  final int schemaVersion;
  final File Function(String path) mediaFile;
  final void Function(String message)? onProgress;
  final int maxRounds;

  /// Eş kimliği (alıcının eşleşme kimliği); null = eski tek eş (genel imleçler).
  final String? scope;

  String _k(String base) => scope == null ? base : '$base:$scope';

  /// Eş başına durum anahtarları (`:<kimlik>` eklenerek).
  static const keyPeerLedger = 'es_defter_kimligi';
  static const keyPushNeed = 'anlik_ver_gerek';
  static const keyPushCursor = 'anlik_ver_imlec';
  static const keyPushMarker = 'anlik_ver_sira';

  /// Eski (eş kimliksiz) imleçleri [scope] eşine bir kez kopyalar (eşin kendi kaydı yoksa).
  static Future<void> migrateLegacyCursors(LedgerService ledger, String scope) async {
    for (final base in const [
      LedgerService.keySentSeq,
      LedgerService.keyReceivedSeq,
      LedgerService.keyNeedSnapshot,
      LedgerService.keySnapshotCursor,
      LedgerService.keySnapshotMarker,
      LedgerService.keyStarted,
    ]) {
      final legacy = await ledger.textState(base);
      if (legacy != null && await ledger.textState('$base:$scope') == null) {
        await ledger.setTextState('$base:$scope', legacy);
      }
    }
  }

  /// Yeni eşleşen eş için başlangıç: karşının tam durumunu al ([pull]) ve (yalnız Android
  /// alıcıya) kendi tam durumunu ver ([push]). Tam durum satır geçmişini yeniden oynatmaz.
  static Future<void> markNewPeer(LedgerService ledger, String scope, {required bool push}) async {
    await ledger.setIntState('${LedgerService.keyNeedSnapshot}:$scope', 1);
    await ledger.setTextState('${LedgerService.keySnapshotCursor}:$scope', '');
    await ledger.setIntState('${LedgerService.keySnapshotMarker}:$scope', 0);
    await ledger.setIntState('$keyPushNeed:$scope', push ? 1 : 0);
    await ledger.setTextState('$keyPushCursor:$scope', '');
    await ledger.setIntState('$keyPushMarker:$scope', 0);
  }

  /// Eşin kaydı kaldırılınca o eşe özgü durumu siler (veri silinmez, yalnızca imleçler).
  static Future<void> forgetPeer(LedgerService ledger, String scope) async {
    for (final base in const [
      LedgerService.keySentSeq,
      LedgerService.keyReceivedSeq,
      LedgerService.keyNeedSnapshot,
      LedgerService.keySnapshotCursor,
      LedgerService.keySnapshotMarker,
      LedgerService.keyStarted,
      keyPeerLedger,
      keyPushNeed,
      keyPushCursor,
      keyPushMarker,
    ]) {
      await ledger.deleteState('$base:$scope');
    }
  }

  Future<LedgerSyncResult> run(SyncConnection connection) async {
    final relay = scope != null;
    // Tek seferlik (v9.10, yalnız eski tek eş): eski sürümden kalan alınan-sıra imleci
    // bilgisayarın aktarmadığı tablet satırlarını atlamış olabilir; bir kez sıfırlanır.
    if (!relay && await ledger.intState(LedgerService.keyRelayReset) == 0) {
      await ledger.setIntState(LedgerService.keyReceivedSeq, 0);
      await ledger.setIntState(LedgerService.keyRelayReset, 1);
    }
    final device = await ledger.deviceId();
    // Tam durum (v9.15): yeni eşleşen cihaz karşıdaki tüm güncel satırları ister;
    // bitene dek defter geçmişi yeniden oynatılmaz (sahte çakışma çıkmasın).
    var snapshotWanted = await ledger.intState(_k(LedgerService.keyNeedSnapshot)) == 1;
    // Tam durum İTMESİ (v9.23, yalnız Android alıcı): kendi güncel satırlarım karşıya.
    var pushWanted = relay && await ledger.intState(_k(keyPushNeed)) == 1;
    var snapshotRows = 0;
    var pushedRows = 0;
    var doneNow = false;
    var result = const LedgerSyncResult();
    var peerLedger = relay ? await ledger.textState(_k(keyPeerLedger)) : null;
    for (var round = 1; round <= maxRounds; round++) {
      final sentCursor = await ledger.intState(_k(LedgerService.keySentSeq));
      final receivedCursor = await ledger.intState(_k(LedgerService.keyReceivedSeq));
      // Aracı (çok eş) kipinde eşin defter kimliği bilinmeden satır yollanmaz (yankı olmasın):
      // ilk tur yalnız alır ve kimliği öğrenir. İtme sürerken değişiklik gitmez (geçmiş
      // tam durumla kapsanır; bitince gönderilen sıra işarete çekilir).
      final canSend = !pushWanted && (!relay || peerLedger != null);
      final out = canSend
          ? await ledger.pendingFor(sentCursor, limit: ledgerBatch, relayExcept: relay ? peerLedger : null)
          : const <LedgerChange>[];
      final lastOut = out.isEmpty ? sentCursor : out.last.seq;

      var pushPage = const <LedgerChange>[];
      String? pushNext;
      if (pushWanted) {
        final pc = await ledger.textState(_k(keyPushCursor)) ?? '';
        // Sıra işareti ilk sayfadan ÖNCE alınır: sonrası normal alışverişle gider.
        if (pc.isEmpty && await ledger.intState(_k(keyPushMarker)) == 0) {
          await ledger.setIntState(_k(keyPushMarker), await ledger.maxSeq() + 1); // +1: 0 "yok" demek
        }
        final page = await ledger.snapshotPage(pc);
        pushPage = page.rows;
        pushNext = page.next;
      }

      onProgress?.call('Fotoğraflar kontrol ediliyor…');
      final photosSent = await _uploadPhotos(connection, [...out, ...pushPage]);

      onProgress?.call('Değişiklikler gönderiliyor ($round. tur)…');
      final snapCursor = snapshotWanted ? (await ledger.textState(_k(LedgerService.keySnapshotCursor)) ?? '') : null;
      if (snapCursor != null) onProgress?.call('Karşıdaki kayıtlar alınıyor…');
      final response = await client.exchangeLedger(
        connection,
        LedgerRequest(
          schema: schemaVersion,
          device: device,
          received: receivedCursor,
          changes: out,
          lastSeq: lastOut,
          snapshotCursor: snapCursor,
          pushSnapshot: pushPage,
        ),
      );

      var learned = false;
      final responder = response.device;
      if (relay && responder != null && responder != peerLedger) {
        await ledger.setTextState(_k(keyPeerLedger), responder);
        peerLedger = responder;
        learned = true;
      }

      var photosReceived = 0;
      for (final photo in response.photos) {
        final file = mediaFile(photo.path);
        final stat = await file.stat();
        if (stat.type == FileSystemEntityType.file && stat.size == photo.size) continue;
        onProgress?.call('Fotoğraf alınıyor: ${photo.path.split('/').last}');
        await client.fetchPhoto(connection, photo, file);
        photosReceived++;
      }

      final ranged = await ledger.applyRemoteRanged(response.changes);
      final applied = ranged.result;
      // Uygulama bitti: imleçler ilerler.
      var newSent = sentCursor;
      if (response.acked > sentCursor) {
        newSent = response.acked;
        await ledger.setIntState(_k(LedgerService.keySentSeq), newSent);
      }
      if (response.lastSeq > receivedCursor) await ledger.setIntState(_k(LedgerService.keyReceivedSeq), response.lastSeq);
      // Yankı önleme (aracı kipi): bu turda eşten uygulanan satırlar (from, to] aralığındadır;
      // eşe geri gitmemeleri için, aralığa kadar gönderilecek başka satır kalmadıysa gönderilen
      // imleç aralığın sonuna çekilir. (Aralık eşten geldiği için eşe verilecek bir şey içermez.)
      if (relay && peerLedger != null && ranged.to > ranged.from && !pushWanted) {
        final rest = await ledger.pendingFor(newSent,
            limit: 1, relayExcept: peerLedger, skipAfter: ranged.from, skipUpTo: ranged.to);
        if ((rest.isEmpty || rest.first.seq > ranged.to) && ranged.to > newSent) {
          await ledger.setIntState(_k(LedgerService.keySentSeq), ranged.to);
        }
      }
      if (snapCursor != null) {
        // Alıcının defter sırası ilk sayfada kaydedilir; tam durum bitince alınan-sıra oraya çekilir.
        if (await ledger.intState(_k(LedgerService.keySnapshotMarker)) == 0 && response.snapshotMarker > 0) {
          await ledger.setIntState(_k(LedgerService.keySnapshotMarker), response.snapshotMarker);
        }
        snapshotRows += (await ledger.applySnapshot(response.snapshot)).applied;
        final next = response.snapshotNext;
        if (next == null) {
          final marker = await ledger.intState(_k(LedgerService.keySnapshotMarker));
          // YALNIZ boş imleçte (alınan sıra 0: yeni eş ya da boş cihaz) imleç işarete çekilir.
          // Dolu imleçte KORUNUR: tam durum var olan satıra dokunmaz, silineni bilmez; N+1..M arası
          // güncelleme ve silmeler normal akışla gelir (yeniden oynatma "aynıysa atla" ile güvenlidir).
          if (await ledger.intState(_k(LedgerService.keyReceivedSeq)) == 0 && marker > 0) {
            await ledger.setIntState(_k(LedgerService.keyReceivedSeq), marker);
          }
          await ledger.setIntState(_k(LedgerService.keySnapshotMarker), 0);
          await ledger.setTextState(_k(LedgerService.keySnapshotCursor), '');
          await ledger.setIntState(_k(LedgerService.keyNeedSnapshot), 0);
          snapshotWanted = false;
          doneNow = true;
        } else {
          await ledger.setTextState(_k(LedgerService.keySnapshotCursor), next);
        }
      }
      if (pushWanted) {
        pushedRows += pushPage.length;
        if (pushNext == null) {
          // İtme bitti: yeni eşte gönderilen sıra, itmenin başladığı işarete çekilir (bundan sonrası
          // normal alışveriş); dolu imleçte korunur.
          final marker = await ledger.intState(_k(keyPushMarker)) - 1;
          if (await ledger.intState(_k(LedgerService.keySentSeq)) == 0 && marker > 0) {
            await ledger.setIntState(_k(LedgerService.keySentSeq), marker);
          }
          await ledger.setIntState(_k(keyPushMarker), 0);
          await ledger.setTextState(_k(keyPushCursor), '');
          await ledger.setIntState(_k(keyPushNeed), 0);
          pushWanted = false;
          doneNow = true;
        } else {
          await ledger.setTextState(_k(keyPushCursor), pushNext);
        }
      }

      result = LedgerSyncResult(
        sent: result.sent + out.length,
        received: result.received + applied.applied,
        conflicts: result.conflicts + applied.conflicts,
        failed: result.failed + applied.failed,
        photosSent: result.photosSent + photosSent,
        photosReceived: result.photosReceived + photosReceived,
        rounds: round,
        snapshotRows: snapshotRows,
        snapshotPending: snapshotWanted,
        duplicates: result.duplicates + applied.duplicates,
        pushedRows: pushedRows,
        pushPending: pushWanted,
      );
      final moreHere = out.length >= ledgerBatch;
      // Tam durum/itme az önce bitti ya da eşin kimliği yeni öğrenildi: sıradan değişiklikler için bir tur daha.
      if (!moreHere && !response.more && !snapshotWanted && !pushWanted && !doneNow && !learned) break;
      doneNow = false;
    }
    return result;
  }

  /// [changes]'ın başvurduğu fotoğraflardan karşıda eksik olanları yükler.
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
