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

  /// "Bilgisayardaki her şeyi yeniden al": bir sonraki eşitleme tam durumu ister
  /// (yalnızca eksik satırlar eklenir; var olana ve sildiklerine dokunulmaz).
  Future<void> requestFullState() async {
    final ledger = ref.read(ledgerServiceProvider);
    await ledger.setIntState(LedgerService.keyNeedSnapshot, 1);
    await ledger.setTextState(LedgerService.keySnapshotCursor, '');
    await ledger.setIntState(LedgerService.keySnapshotMarker, 0);
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
  Future<PairedComputer> pair({
    required String host,
    required int port,
    required String code,
    bool isTablet = false,
    String? deviceName,
  }) async {
    if (await _store.computer() != null) {
      throw const SyncException('Telefon zaten bir bilgisayarla eşleşmiş. Önce o eşleşmeyi kaldır.');
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
      // Yeni eşleşen cihaz bilgisayardaki tüm güncel kayıtları alır (eski yedekle gelenler dahil).
      await requestFullState();
      ref.invalidate(pairedComputerProvider);
      return computer;
    } finally {
      client.close();
    }
  }

  Future<void> unpair() async {
    await _store.removeComputer();
    ref.invalidate(pairedComputerProvider);
    state = const SendState();
  }

  // ───────────── Gönderme ─────────────

  void _set(SendStage stage, String message, {int done = 0, int total = 0}) {
    if (ref.mounted) state = SendState(stage: stage, message: message, done: done, total: total);
  }

  Future<void> send() async {
    if (state.busy) return;
    // Hemen "meşgul": art arda iki dokunuş iki gönderim başlatmasın.
    _set(SendStage.connecting, 'Veriler hazırlanıyor…');
    final client = SyncClient();
    File? zipFile;
    try {
      final saved = await _store.computer();
      if (saved == null) throw const SyncException('Önce bir bilgisayarla eşleş.');
      final ledger = ref.read(ledgerServiceProvider);
      final db = ref.read(appDatabaseProvider);
      final media = ref.read(mediaStorageProvider);
      // İlk gönderim tam yedekle birleştirilir (bugünkü yol); defter ondan
      // sonrasını izler. Sonraki gönderimler yalnızca değişiklikleri taşır.
      final firstTime = await ledger.intState(LedgerService.keyStarted) != 1;

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

      var computer = saved;
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
            _set(SendStage.uploading, 'Veriler gönderildi; bilgisayar içe aktarıyor…');
            backupSummary = (await client.sendBackup(connection, zipFile!)).summary;
            await ledger.setIntState(LedgerService.keySentSeq, snapSeq);
            await ledger.setIntState(LedgerService.keyStarted, 1);
            firstDone = true;
          }
          _set(SendStage.uploading, 'Değişiklikler eşitleniyor…');
          synced = await LedgerSync(
            ledger: ledger,
            client: client,
            schemaVersion: db.schemaVersion,
            mediaFile: media.resolve,
            onProgress: (m) => _set(SendStage.uploading, m),
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
      ref.invalidate(pairedComputerProvider);
      _set(SendStage.done, [
        if (backupSummary.isNotEmpty) ...[
          sent == 0 ? 'Yeni fotoğraf yoktu.' : '$sent fotoğraf gönderildi.',
          'Bilgisayar: $backupSummary',
        ],
        'Eşitleme: ${synced.summary}.',
        if (pdfSummary.isNotEmpty) pdfSummary.endsWith('.') ? pdfSummary : '$pdfSummary.',
        if (pullSummary.isNotEmpty) pullSummary.endsWith('.') ? pullSummary : '$pullSummary.',
        if (notOnPhone > 0) '$notOnPhone fotoğraf telefonda bulunamadı.',
        if (skipped > 0) '$skipped fotoğrafın adı kurallara uymadığı için gönderilmedi.',
      ].join(' '));
    } on Object catch (e) {
      _set(SendStage.failed, describeSyncError(e));
    } finally {
      client.close();
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
