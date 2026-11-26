import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/di/core_providers.dart';
import '../data/ledger_exchange.dart';
import '../data/server_sync_store.dart';
import '../data/sync_server.dart';
import '../domain/network_rules.dart';
import '../domain/pairing_window.dart';
import '../domain/sync_protocol.dart';

/// Android alıcının dosya yolları ve kalıcı deposu: masaüstüne özgü yol çözümü burada
/// soyutlanır (testte geçersiz kılınır).
class ReceiveEnv {
  const ReceiveEnv({required this.store, required this.mediaRoot, required this.pdfRoot, required this.workDir, required this.platform, this.port = syncDefaultPort, this.discoveryPort = syncDiscoveryPort});

  final ServerSyncStore store;
  final Directory mediaRoot;
  final Directory pdfRoot;
  final Directory workDir;
  final String platform;

  /// Dinleme portları (testte 0 / null).
  final int port;
  final int? discoveryPort;
}

/// Uygulamanın kendi klasörlerinde (`alici.json`, `media/`, `pdfs/`, geçici `kablosuz/`).
/// `alici.json` istemci deposundan (`esitleme.json`) ayrıdır: iki dosya aynı anda yazılmaz,
/// anahtarlar ikisinde de veritabanı DIŞINDA kalır (yedeğe ve kablosuz eşitlemeye girmez).
final receiveEnvProvider = FutureProvider<ReceiveEnv>((ref) async {
  final support = await getApplicationSupportDirectory();
  final docs = await getApplicationDocumentsDirectory();
  final temp = await getTemporaryDirectory();
  return ReceiveEnv(
    store: ServerSyncStore(File(p.join(support.path, 'alici.json')), label: 'Telefon'),
    mediaRoot: Directory(p.join(docs.path, 'media')),
    pdfRoot: Directory(p.join(support.path, 'pdfs')),
    workDir: Directory(p.join(temp.path, 'alici')),
    platform: Platform.operatingSystem,
  );
});

class ReceiveState {
  const ReceiveState({
    this.enabled = false,
    this.running = false,
    this.port,
    this.addresses = const [],
    this.name,
    this.kind = deviceKindPhone,
    this.pairing,
    this.devices = const [],
    this.message,
    this.error,
  });

  /// Kullanıcı "bu cihazda alıcıyı aç" dedi mi (kalıcı). Sunucu yalnızca ekran açıkken çalışır.
  final bool enabled;
  final bool running;
  final int? port;
  final List<String> addresses;
  final String? name;
  final String kind;
  final PairingCode? pairing;
  final List<PairedDevice> devices;
  final String? message;
  final String? error;
}

/// Android alıcı (v9.23): bu cihazda eşleştirme kodu gösterir ve başka bir telefon, tablet
/// ya da bilgisayardan gelen eşitlemeyi alır. ARKA PLAN SERVİSİ YOK: sunucu yalnızca uygulama
/// ön plandayken (ekran açık) çalışır; uygulama arka plana gidince ([AppLifecycleState.paused]/
/// hidden) durur, öne gelince (kullanıcı açık bıraktıysa) yeniden başlar. Eşleşmeler kalıcıdır.
class ReceiveController extends Notifier<ReceiveState> with WidgetsBindingObserver {
  ReceiveEnv? _env;
  SyncServer? _server;
  StreamSubscription<SyncEvent>? _events;
  Timer? _ticker;
  int _ticks = 0;
  List<String> _addresses = const [];
  String? _message;
  String? _error;
  bool _foreground = true;
  bool _starting = false;

  @override
  ReceiveState build() {
    WidgetsBinding.instance.addObserver(this);
    _foreground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;
    ref.onDispose(() {
      WidgetsBinding.instance.removeObserver(this);
      _ticker?.cancel();
      unawaited(_events?.cancel());
      unawaited(_server?.dispose());
    });
    unawaited(_restore());
    return const ReceiveState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state_) {
    final fg = state_ == AppLifecycleState.resumed || state_ == AppLifecycleState.inactive;
    if (fg == _foreground) return;
    _foreground = fg;
    unawaited(_syncRunning());
  }

  Future<ReceiveEnv> _environment() async {
    final known = _env;
    if (known != null) return known;
    final env = await ref.read(receiveEnvProvider.future);
    _env = env;
    return env;
  }

  Future<void> _restore() async {
    final env = await _environment();
    if (!ref.mounted) return;
    await _syncRunning();
    if (!await env.store.enabled()) await _publish();
  }

  /// Açık bırakılmışsa ve ön plandaysa çalışır; aksi halde durur.
  Future<void> _syncRunning() async {
    final env = await _environment();
    final wanted = await env.store.enabled() && _foreground;
    if (wanted) {
      await _start(env);
    } else {
      await _stop(
        await env.store.enabled() ? 'Uygulama arka planda: alıcı durdu. Öne gelince yeniden başlar.' : 'Alıcı kapalı.',
      );
    }
  }

  Future<void> setEnabled(bool on, {bool isTablet = false}) async {
    final env = await _environment();
    await env.store.setEnabled(on);
    if (on) await env.store.setKind(isTablet ? deviceKindTablet : deviceKindPhone);
    await _syncRunning();
  }

  Future<void> startPairing() async {
    final server = _server;
    if (server == null) return;
    try {
      await server.openPairing();
      _error = null;
      _message = 'Öbür cihazda Ayarlar → Bilgisayarla eşitle → "başka cihazın kodunu gir" → bu kodu yaz.';
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

  /// Yalnızca bu cihazın eşleşmesi kalkar; öbürleri bağlı kalır, veri silinmez.
  Future<void> forgetDevice(String id) async {
    final server = _server;
    if (server != null) {
      await server.forgetDevice(id);
    } else {
      await (await _environment()).store.removeDevice(id);
    }
    _message = 'Eşleşme kaldırıldı. Öbür cihazlar etkilenmedi.';
    await _publish();
  }

  Future<void> _start(ReceiveEnv env) async {
    if (_server != null || _starting) return;
    _starting = true;
    try {
      final db = ref.read(appDatabaseProvider);
      final media = ref.read(mediaStorageProvider);
      final server = SyncServer(
        store: env.store,
        mediaRoot: env.mediaRoot,
        pdfRoot: env.pdfRoot,
        workDir: env.workDir,
        platform: env.platform,
        kind: await env.store.kind(),
        // Tam yedek (ZIP) içe aktarma yalnızca bilgisayarda: burada importBackup yok (404).
        ledger: LedgerExchange(
          ledger: ref.read(ledgerServiceProvider),
          schemaVersion: db.schemaVersion,
          mediaFile: media.resolve,
        ),
      );
      try {
        await server.start(port: env.port, discoveryPort: env.discoveryPort);
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
      _message = 'Cihaz bekleniyor. Bu ekran açık kaldıkça alıcı çalışır.';
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      await _publish();
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop(String message) async {
    _ticker?.cancel();
    _ticker = null;
    await _events?.cancel();
    _events = null;
    final server = _server;
    _server = null;
    await server?.dispose(); // eşleşmeler dosyada kalır; yalnızca oturumlar ve dinleme biter
    _message = message;
    _error = null;
    if (ref.mounted) await _publish();
  }

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
    _message = event.kind == SyncEventKind.paired ? 'Eşleşti: ${event.message}' : event.message;
    unawaited(_publish());
  }

  Future<void> _publish() async {
    final env = _env;
    if (env == null || !ref.mounted) return;
    final server = _server;
    final enabled = await env.store.enabled();
    final name = await env.store.computerName();
    final kind = await env.store.kind();
    final devices = await env.store.devices();
    if (!ref.mounted) return;
    state = ReceiveState(
      enabled: enabled,
      running: server?.isRunning ?? false,
      port: server?.port,
      addresses: _addresses,
      name: name,
      kind: kind,
      pairing: server?.pairing,
      devices: devices,
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

final receiveControllerProvider = NotifierProvider<ReceiveController, ReceiveState>(ReceiveController.new);
