import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../app/platform.dart';
import '../../../core/di/core_providers.dart';
import '../../tools/data/full_export.dart';
import '../../tools/full_backup.dart';
import '../data/phone_sync_store.dart';
import '../data/sync_client.dart';
import '../domain/media_rules.dart';
import '../domain/sync_protocol.dart';
import '../sync_providers.dart';

enum SendStage { idle, connecting, photos, uploading, done, failed }

class SendState {
  const SendState({this.stage = SendStage.idle, this.done = 0, this.total = 0, this.message});

  final SendStage stage;
  final int done;
  final int total;
  final String? message;

  bool get busy => stage == SendStage.connecting || stage == SendStage.photos || stage == SendStage.uploading;
}

/// Bilgisayara gönderme. Ekrandan çıkılsa da iş sürer. Bağlantı koparsa iki
/// kez daha denenir; her denemede bilgisayar eksik fotoğrafları yeniden
/// söyler, yani gönderim kaldığı yerden devam eder.
class SendController extends Notifier<SendState> {
  static const _attempts = 3;

  @override
  SendState build() => const SendState();

  PhoneSyncStore get _store => ref.read(phoneSyncStoreProvider);

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
  Future<PairedComputer> pair({required String host, required int port, required String code}) async {
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
        phoneName: deviceLabel(platformName == 'android' ? 'Android' : platformName, phoneId),
        platform: platformName,
      );
      await _store.saveComputer(computer);
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
      final temp = await getTemporaryDirectory();
      zipFile = File(p.join(temp.path, 'kocum_kablosuz.zip'));
      // Fotoğraf listesi ve veritabanı kopyası aynı anda alınır: birbirini tutar.
      final backup = await collectFullBackup(
        ref.read,
        scratch: File(p.join(temp.path, 'kocum_kablosuz.db')),
        withDataSets: false,
      );
      final database = backup.database;
      if (database == null) throw SyncException('Veritabanı kopyası alınamadı: ${backup.databaseError}');
      final media = ref.read(mediaStorageProvider);
      final offered = <MediaEntry>[];
      var notOnPhone = 0, skipped = 0;
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

      var computer = saved;
      var sent = 0;
      String summary;
      for (var attempt = 1;; attempt++) {
        try {
          _set(SendStage.connecting, '${computer.name} ile bağlantı kuruluyor…');
          final phoneId = await _store.phoneId();
          final (found, connection) = await _connect(client, computer, phoneId);
          computer = found;
          final missing = await client.missingPhotos(connection, offered);
          final toSend = requestedFromOffer(offered, missing.missing);
          for (var i = 0; i < toSend.length; i++) {
            _set(SendStage.photos, 'Fotoğraflar: $i / ${toSend.length}', done: i, total: toSend.length);
            await client.sendPhoto(connection, toSend[i], media.resolve(toSend[i].path));
            sent++;
          }
          _set(SendStage.uploading, 'Veriler gönderildi; bilgisayar içe aktarıyor…');
          summary = (await client.sendBackup(connection, zipFile)).summary;
          break;
        } on Object catch (e) {
          if (attempt >= _attempts || !_retryable(e)) rethrow;
          _set(SendStage.connecting, 'Bağlantı koptu; yeniden deneniyor ($attempt/${_attempts - 1})…');
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      await _store.saveComputer(computer.copyWith(lastSentAt: DateTime.now()));
      ref.invalidate(pairedComputerProvider);
      _set(SendStage.done, [
        sent == 0 ? 'Yeni fotoğraf yoktu.' : '$sent fotoğraf gönderildi.',
        'Bilgisayar: $summary',
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
