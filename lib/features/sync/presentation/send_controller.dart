import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/platform.dart';
import '../../../core/di/core_providers.dart';
import '../../tools/data/full_export.dart';
import '../../tools/full_backup.dart';
import '../../../core/ledger/ledger_service.dart';
import '../data/ledger_sync.dart';
import '../data/pdf_pull.dart';
import '../data/pdf_sync.dart';
import '../data/phone_sync_store.dart';
import '../data/sync_client.dart';
import '../domain/media_rules.dart';
import '../domain/pdf_rules.dart';
import '../domain/sync_protocol.dart';
import '../sync_providers.dart';

enum SendStage { idle, connecting, photos, uploading, pdfs, done, failed }

class SendState {
  const SendState({this.stage = SendStage.idle, this.done = 0, this.total = 0, this.message});

  final SendStage stage;
  final int done;
  final int total;
  final String? message;

  bool get busy =>
      stage == SendStage.connecting || stage == SendStage.photos || stage == SendStage.uploading || stage == SendStage.pdfs;
}

/// Bilgisayara gönderme. Ekrandan çıkılsa da iş sürer. Bağlantı koparsa iki
/// kez daha denenir; her denemede bilgisayar eksik fotoğrafları yeniden
/// söyler, yani gönderim kaldığı yerden devam eder.
class SendController extends Notifier<SendState> {
  static const _attempts = 3;

  @override
  SendState build() => const SendState();

  PhoneSyncStore get _store => ref.read(phoneSyncStoreProvider);

  SyncCancelToken? _pdfCancel;

  /// Süren PDF gönderimini durdurur (istek yarıda kesilir; bilgisayar geçici dosyayı siler).
  void cancelPdf() => _pdfCancel?.cancel();

  Future<void> setSendPdfs(bool value) async {
    await _store.setSendPdfs(value);
    ref.invalidate(sendPdfsProvider);
  }

  Future<void> setPullPdfs(bool value) async {
    await _store.setPullPdfs(value);
    ref.invalidate(pullPdfsProvider);
  }

  /// "Eşten her şeyi yeniden al": bu eşin bir sonraki eşitlemesi tam durumu ister
  /// (yalnızca eksik satırlar eklenir; var olana ve sildiklerine dokunulmaz).
  Future<void> requestFullState(String peerId) async {
    final ledger = ref.read(ledgerServiceProvider);
    await ledger.setIntState('${LedgerService.keyNeedSnapshot}:$peerId', 1);
    await ledger.setTextState('${LedgerService.keySnapshotCursor}:$peerId', '');
    await ledger.setIntState('${LedgerService.keySnapshotMarker}:$peerId', 0);
  }

  // ───────────── Eşleştirme ─────────────

  Future<List<DiscoveredComputer>> discover() async {
    final client = SyncClient();
    try {
      return await client.discover();
    } finally {
      client.close();
    }
  }

  /// Hata olursa [SyncException] (ya da ağ hatası) fırlatır; ekran gösterir.
  /// Yeni eş eklenir (en çok [SyncLimits.maxPeers]); öbür eşlerin kaydı ve imleçleri değişmez.
  Future<PairedComputer> pair({
    required String host,
    required int port,
    required String code,
    bool isTablet = false,
    String? deviceName,
  }) async {
    if ((await _store.computers()).length >= SyncLimits.maxPeers) {
      throw const SyncException('Bu cihaz en çok ${SyncLimits.maxPeers} eşle eşleşebilir. Önce birini kaldır.');
    }
    final client = SyncClient();
    try {
      final phoneId = await _store.phoneId();
      final computer = await client.pair(
        host: host,
        port: port,
        code: code,
        phoneId: phoneId,
        phoneName: cleanDeviceName(
          deviceName ?? deviceLabel(isTablet ? 'Tablet' : 'Telefon', phoneId),
        ),
        platform: platformName,
        kind: isTablet ? deviceKindTablet : deviceKindPhone,
      );
      if (deviceName != null) await _store.setDeviceName(deviceName);
      await _store.saveComputer(computer);
      // Yeni eş: karşıdaki tüm güncel kayıtları alır (eski yedekle gelenler dahil); Android eşe
      // ayrıca kendi tam durumunu verir (bilgisayara bunun yerine ilk eşitlemede tam yedek gider).
      await LedgerSync.markNewPeer(ref.read(ledgerServiceProvider), computer.id, push: computer.isAndroid);
      ref.invalidate(pairedPeersProvider);
      ref.invalidate(pairedComputerProvider);
      return computer;
    } finally {
      client.close();
    }
  }

  /// Yalnızca bu eş kalkar; öbür eşler ve veri etkilenmez (yalnız bu eşin imleçleri silinir).
  Future<void> unpair(String peerId) async {
    await _store.removeComputer(peerId);
    await LedgerSync.forgetPeer(ref.read(ledgerServiceProvider), peerId);
    ref.invalidate(pairedPeersProvider);
    ref.invalidate(pairedComputerProvider);
    state = const SendState();
  }

  // ───────────── Gönderme ─────────────

  void _set(SendStage stage, String message, {int done = 0, int total = 0}) {
    if (ref.mounted) state = SendState(stage: stage, message: message, done: done, total: total);
  }

  /// Eşitler: [peerId] verilirse yalnızca o eş, verilmezse bütün eşler sırayla. Bir eşin
  /// hatası öbürlerini durdurmaz; özette her eş ayrı yazılır.
  Future<void> send({String? peerId}) async {
    if (state.busy) return;
    // Hemen "meşgul": art arda iki dokunuş iki gönderim başlatmasın.
    _set(SendStage.connecting, 'Veriler hazırlanıyor…');
    final client = SyncClient();
    try {
      final all = await _store.computers();
      final peers = peerId == null ? all : all.where((c) => c.id == peerId).toList();
      if (peers.isEmpty) throw const SyncException('Önce bir cihazla eşleş.');
      final lines = <String>[];
      var failures = 0;
      for (final peer in peers) {
        try {
          final summary = await _syncPeer(client, peer);
          lines.add(peers.length > 1 ? '${peer.name}: $summary' : summary);
        } on Object catch (e) {
          failures++;
          lines.add('${peer.name}: ${describeSyncError(e)}');
        }
      }
      ref.invalidate(pairedPeersProvider);
      ref.invalidate(pairedComputerProvider);
      _set(failures == peers.length ? SendStage.failed : SendStage.done, lines.join('\n'));
    } on Object catch (e) {
      _set(SendStage.failed, describeSyncError(e));
    } finally {
      client.close();
    }
  }

  /// Tek eşle tam eşitleme; özet metnini döner, hata fırlatır.
  Future<String> _syncPeer(SyncClient client, PairedComputer saved) async {
    File? zipFile;
    try {
      final ledger = ref.read(ledgerServiceProvider);
      final db = ref.read(appDatabaseProvider);
      final media = ref.read(mediaStorageProvider);
      var computer = saved;
      // v9.22'den göçen eş: genel imleçler bir kez bu eşe kopyalanır.
      if (computer.legacyCursors) {
        await LedgerSync.migrateLegacyCursors(ledger, computer.id);
        computer = computer.copyWith(legacyCursors: false);
        await _store.saveComputer(computer);
      }
      final startedKey = '${LedgerService.keyStarted}:${computer.id}';
      // Yalnızca Linux bilgisayara: ilk gönderim tam yedekle birleştirilir (bugünkü yol); defter
      // ondan sonrasını izler. Android alıcı yedek almaz (404): onunla tam durum alınıp verilir.
      final firstTime = !computer.isAndroid && await ledger.intState(startedKey) != 1;

      var offered = <MediaEntry>[];
      var notOnPhone = 0, skipped = 0;
      var snapSeq = 0;
      if (firstTime) {
        final temp = await getTemporaryDirectory();
        zipFile = File(p.join(temp.path, 'kocum_kablosuz.zip'));
        // Defter sırası yedekten ÖNCE alınır: yedeğe girenler bu sıraya kadardır.
        snapSeq = await ledger.maxSeq();
        // Fotoğraf listesi ve veritabanı kopyası aynı anda alınır: birbirini tutar.
        final backup = await collectFullBackup(
          ref.read,
          scratch: File(p.join(temp.path, 'kocum_kablosuz.db')),
          withDataSets: false,
        );
        final database = backup.database;
        if (database == null) throw SyncException('Veritabanı kopyası alınamadı: ${backup.databaseError}');
        for (final path in photoPathsOf(backup.cards, backup.notes)) {
          if (!isTransferableMediaPath(path)) {
            skipped++;
            continue;
          }
          final stat = await media.resolve(path).stat();
          if (stat.type != FileSystemEntityType.file) {
            notOnPhone++;
            continue;
          }
          offered.add(MediaEntry(path, stat.size));
        }
        final zip = await buildFullExportZip(
          data: backup.data,
          cards: backup.cards,
          notes: backup.notes,
          media: media,
          withPhotos: false,
          database: database,
        );
        await zipFile.writeAsBytes(zip.bytes, flush: true);
      }

      var sent = 0;
      var backupSummary = '';
      var firstDone = !firstTime;
      LedgerSyncResult? synced;
      for (var attempt = 1;; attempt++) {
        try {
          _set(SendStage.connecting, '${computer.name} ile bağlantı kuruluyor…');
          final phoneId = await _store.phoneId();
          final (found, connection) = await _connect(client, computer, phoneId);
          computer = found;
          await ledger.bindToInstall(phoneId); // başka kurulumdan gelen veritabanında defter kimliği yenilenir
          if (!firstDone) {
            final missing = await client.missingPhotos(connection, offered);
            final toSend = requestedFromOffer(offered, missing.missing);
            for (var i = 0; i < toSend.length; i++) {
              _set(SendStage.photos, 'Fotoğraflar: $i / ${toSend.length}', done: i, total: toSend.length);
              await client.sendPhoto(connection, toSend[i], media.resolve(toSend[i].path));
              sent++;
            }
            _set(SendStage.uploading, 'Veriler gönderildi; ${computer.name} içe aktarıyor…');
            backupSummary = (await client.sendBackup(connection, zipFile!)).summary;
            await ledger.setIntState('${LedgerService.keySentSeq}:${computer.id}', snapSeq);
            await ledger.setIntState(startedKey, 1);
            firstDone = true;
          }
          _set(SendStage.uploading, 'Değişiklikler eşitleniyor…');
          synced = await LedgerSync(
            ledger: ledger,
            client: client,
            schemaVersion: db.schemaVersion,
            mediaFile: media.resolve,
            onProgress: (m) => _set(SendStage.uploading, m),
            scope: computer.id,
          ).run(connection);
          break;
        } on Object catch (e) {
          if (attempt >= _attempts || !_retryable(e)) rethrow;
          _set(SendStage.connecting, 'Bağlantı koptu; yeniden deneniyor ($attempt/${_attempts - 1})…');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      // PDF dosyaları (isteğe bağlı, varsayılan kapalı). Satırlar zaten gitti; bu
      // aşama başarısız olsa da eşitleme bozulmaz, yalnızca dosya gitmez.
      var pdfSummary = '';
      try {
        pdfSummary = await _sendPdfs(client, computer);
      } on Object catch (e) {
        pdfSummary = 'PDF dosyaları gönderilemedi: ${describeSyncError(e)} Satırlar eşitlendi; PDF için yeniden eşitle.';
      }
      var pullSummary = '';
      try {
        pullSummary = await _pullPdfs(client, computer);
      } on Object catch (e) {
        pullSummary = 'PDF dosyaları alınamadı: ${describeSyncError(e)} Satırlar eşitlendi; PDF için yeniden eşitle.';
      }
      await _store.saveComputer(computer.copyWith(lastSentAt: DateTime.now()));
      return [
        if (backupSummary.isNotEmpty) ...[
          sent == 0 ? 'Yeni fotoğraf yoktu.' : '$sent fotoğraf gönderildi.',
          'Alıcı: $backupSummary',
        ],
        'Eşitleme: ${synced.summary}.',
        if (pdfSummary.isNotEmpty) pdfSummary.endsWith('.') ? pdfSummary : '$pdfSummary.',
        if (pullSummary.isNotEmpty) pullSummary.endsWith('.') ? pullSummary : '$pullSummary.',
        if (notOnPhone > 0) '$notOnPhone fotoğraf bu cihazda bulunamadı.',
        if (skipped > 0) '$skipped fotoğrafın adı kurallara uymadığı için gönderilmedi.',
      ].join(' ');
    } finally {
      if (zipFile != null && await zipFile.exists()) await zipFile.delete();
    }
  }

  Future<String> _sendPdfs(SyncClient client, PairedComputer computer) async {
    if (!await _store.sendPdfs()) return '';
    final phoneId = await _store.phoneId();
    final (_, connection) = await _connect(client, computer, phoneId);
    final db = ref.read(appDatabaseProvider);
    final shas = [
      for (final d in await (db.select(db.pdfDocuments)..where((t) => t.deleted.equals(false))).get()) d.sha256,
    ];
    if (shas.isEmpty) return '';
    final cancel = _pdfCancel = SyncCancelToken();
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'pdfs'));
    try {
      final result = await PdfSync(
        client: client,
        pdfDir: dir,
        enabled: _store.sendPdfs,
        cancel: cancel,
        onProgress: (i, n, name, sent, total) => _set(
          SendStage.pdfs,
          'PDF $i / $n: ${formatPdfSize(sent)} / ${formatPdfSize(total)}',
          done: sent,
          total: total,
        ),
      ).run(connection, shas);
      return result.summary;
    } finally {
      _pdfCancel = null;
    }
  }

  /// "PDF'leri bilgisayardan al" açıksa, bu cihazda dosyası olmayan belgelerin PDF'ini indirir.
  Future<String> _pullPdfs(SyncClient client, PairedComputer computer) async {
    if (!await _store.pullPdfs()) return '';
    final phoneId = await _store.phoneId();
    final (_, connection) = await _connect(client, computer, phoneId);
    final db = ref.read(appDatabaseProvider);
    final shas = [
      for (final d in await (db.select(db.pdfDocuments)..where((t) => t.deleted.equals(false))).get()) d.sha256,
    ];
    if (shas.isEmpty) return '';
    final cancel = _pdfCancel = SyncCancelToken();
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'pdfs'));
    try {
      final result = await PdfPull(
        client: client,
        pdfDir: dir,
        enabled: _store.pullPdfs,
        cancel: cancel,
        onProgress: (i, n, name, got, total) => _set(
          SendStage.pdfs,
          'PDF $i / $n indiriliyor: ${formatPdfSize(got)} / ${formatPdfSize(total)}',
          done: got,
          total: total,
        ),
      ).run(connection, shas);
      return result.summary;
    } finally {
      _pdfCancel = null;
    }
  }

  /// Önce kayıtlı adres; ulaşılamazsa ağda kimliğe göre aranır (bilgisayarın
  /// IP'si değişmiş olabilir).
  Future<(PairedComputer, SyncConnection)> _connect(SyncClient client, PairedComputer computer, String phoneId) async {
    try {
      return (computer, await client.connect(computer, phoneId: phoneId));
    } on Object catch (e) {
      if (!isUnreachable(e)) rethrow;
      _set(SendStage.connecting, 'Bilgisayar ağda aranıyor…');
      final found = (await client.discover()).where((c) => c.id == computer.id).firstOrNull;
      if (found == null) rethrow;
      final moved = computer.copyWith(host: found.host, port: found.port);
      final connection = await client.connect(moved, phoneId: phoneId);
      await _store.saveComputer(moved);
      return (moved, connection);
    }
  }

  static bool _retryable(Object e) => e is SocketException || e is HttpException || e is TimeoutException;
}

final sendControllerProvider = NotifierProvider<SendController, SendState>(SendController.new);
