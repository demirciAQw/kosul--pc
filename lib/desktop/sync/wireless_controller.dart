import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../app/platform.dart';
import '../../core/di/core_providers.dart';
import '../../features/sync/data/ledger_exchange.dart';
import '../../features/sync/domain/network_rules.dart';
import '../../features/sync/domain/pairing_window.dart';
import '../../features/sync/domain/sync_protocol.dart';
import '../desktop_providers.dart';
import '../import/data/snapshot_merger.dart';
import '../import/import_providers.dart';
import '../import/presentation/import_flow.dart';
import 'data/desktop_sync_store.dart';
import 'data/sync_server.dart';

class WirelessState {
  const WirelessState({
    required this.supported,
    this.enabled = false,
    this.running = false,
    this.port,
    this.addresses = const [],
    this.computerName,
    this.pairing,
    this.phone,
    this.message,
    this.error,
  });

  /// Bu bilgisayarda kablosuz alma açılabilir mi? (Yalnızca Linux.)
  final bool supported;
  final bool enabled;
  final bool running;
  final int? port;

  /// Bu bilgisayarın yerel ağ adresleri (telefona elle yazmak için).
  final List<String> addresses;
  final String? computerName;
  final PairingCode? pairing;
  final PairedPhone? phone;
  final String? message;
  final String? error;
}

/// Kablosuz alma: sunucuyu açar/kapatır, eşleştirmeyi yönetir, gelen yedeği
/// her zamanki içe aktarmaya verir. Uygulama açılınca, kullanıcı daha önce
/// açtıysa kendiliğinden başlar.
class WirelessController extends Notifier<WirelessState> {
  late DesktopSyncStore _store;
  SyncServer? _server;
  StreamSubscription<SyncEvent>? _events;
  Timer? _ticker;
  int _ticks = 0;
  List<String> _addresses = const [];
  String? _message;
  String? _error;

  @override
  WirelessState build() {
    final dir = ref.read(desktopDataDirProvider);
    _store = DesktopSyncStore(File(p.join(dir.path, 'esitleme.json')));
    ref.onDispose(() {
      _ticker?.cancel();
      unawaited(_events?.cancel());
      unawaited(_server?.dispose());
    });
    unawaited(_restore());
    return WirelessState(supported: canReceiveWirelessly);
  }

  Future<void> _restore() async {
    if (canReceiveWirelessly && await _store.enabled()) {
      await _start();
    } else {
      await _publish();
    }
  }

  Future<void> setEnabled(bool on) async {
    if (!canReceiveWirelessly) return;
    await _store.setEnabled(on);
    if (on) {
      await _start();
    } else {
      await _stop('Telefon eşleştirme kapalı.');
    }
  }

  Future<void> startPairing() async {
    final server = _server;
    if (server == null) return;
    try {
      await server.openPairing();
      _error = null;
      _message = 'Telefonda Ayarlar → Araçlar → Bilgisayarla eşitle → kodu yaz.';
    } on SyncException catch (e) {
      _error = e.message;
    }
    await _publish();
  }

  Future<void> cancelPairing() async {
    _server?.closePairing();
    _message = null;
    await _publish();
  }

  Future<void> forgetPhone() async {
    final server = _server;
    if (server != null) {
      await server.forgetPhone();
    } else {
      await _store.removePhone();
    }
    _message = 'Eşleşme kaldırıldı. Yeni bir telefon eşleştirebilirsin.';
    await _publish();
  }

  Future<void> _start() async {
    if (_server != null) return;
    final dir = ref.read(desktopDataDirProvider);
    final server = SyncServer(
      store: _store,
      mediaRoot: Directory(p.join(dir.path, desktopMediaFolder)),
      pdfRoot: Directory(p.join(dir.path, 'pdfs')),
      workDir: dir,
      importBackup: _import,
      platform: platformName,
      ledger: LedgerExchange(
        ledger: ref.read(ledgerServiceProvider),
        schemaVersion: ref.read(appDatabaseProvider).schemaVersion,
        mediaFile: (path) => File(p.joinAll([dir.path, desktopMediaFolder, ...p.posix.split(path)])),
      ),
    );
    try {
      await server.start();
    } on SocketException catch (e) {
      await server.dispose();
      _error = 'Port $syncDefaultPort açılamadı (${e.message}). Başka bir Koçum açık olabilir.';
      await _publish();
      return;
    }
    if (!ref.mounted) {
      await server.dispose();
      return;
    }
    _server = server;
    _events = server.events.listen(_onEvent);
    _addresses = await _localAddresses();
    _error = null;
    _message = 'Telefon bekleniyor.';
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    await _publish();
  }

  Future<void> _stop(String message) async {
    _ticker?.cancel();
    _ticker = null;
    await _events?.cancel();
    _events = null;
    final server = _server;
    _server = null;
    await server?.dispose();
    _message = message;
    _error = null;
    await _publish();
  }

  /// Kodun süresi dolunca ekrandan kalksın; ağ değişirse adresler yenilensin.
  void _tick() {
    _ticks++;
    if (state.pairing != null && _server?.pairing == null) unawaited(_publish());
    if (_ticks % 15 == 0) {
      unawaited(() async {
        final now = await _localAddresses();
        if (now.join() != _addresses.join()) {
          _addresses = now;
          await _publish();
        }
      }());
    }
  }

  void _onEvent(SyncEvent event) {
    _message = event.message;
    if (event.kind == SyncEventKind.paired) {
      _message = 'Eşleşti: ${event.message}';
      _snack('Telefon eşleşti: ${event.message}');
    }
    unawaited(_publish());
  }

  /// Gelen yedek: elle ya da izlenen klasörden içe aktarma sürüyorsa telefon
  /// "biraz sonra" yanıtını alır; aynı anda tek içe aktarma olur.
  Future<String> _import(File zip) async {
    if (ref.read(importBusyProvider) != null) {
      throw const SyncException('Bilgisayar şu an başka bir yedeği içe aktarıyor; birazdan tekrar gönder.', status: 409);
    }
    final busy = ref.read(importBusyProvider.notifier);
    busy.set('Telefondan kablosuz veri alınıyor…');
    try {
      final service = ref.read(importServiceProvider);
      final job = await service.prepare(zip.path);
      final summary = await service.run(job, automatic: true);
      ref
        ..invalidate(importHistoryProvider)
        ..invalidate(tombstonesProvider);
      _snack('Telefondan kablosuz alındı: ${summary.shortText}');
      return summary.shortText;
    } on ImportException catch (e) {
      throw SyncException(e.message, status: 422);
    } finally {
      busy.set(null);
    }
  }

  void _snack(String text) =>
      desktopMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));

  Future<void> _publish() async {
    final server = _server;
    final enabled = canReceiveWirelessly && await _store.enabled();
    final name = await _store.computerName();
    final phone = await _store.phone();
    if (!ref.mounted) return;
    state = WirelessState(
      supported: canReceiveWirelessly,
      enabled: enabled,
      running: server?.isRunning ?? false,
      port: server?.port,
      addresses: _addresses,
      computerName: name,
      pairing: server?.pairing,
      phone: phone,
      message: _message,
      error: _error,
    );
  }

  static Future<List<String>> _localAddresses() async {
    try {
      return [
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses)
            if (isPrivateNetworkAddress(a.rawAddress)) a.address,
      ];
    } on SocketException {
      return const [];
    }
  }
}

final wirelessProvider = NotifierProvider<WirelessController, WirelessState>(WirelessController.new);
