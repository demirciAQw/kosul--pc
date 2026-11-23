import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../features/sync/domain/media_rules.dart';
import '../../../features/sync/domain/network_rules.dart';
import '../../../features/sync/domain/pairing_window.dart';
import '../../../features/sync/domain/pdf_rules.dart';
import '../../../features/sync/domain/sync_crypto.dart';
import '../../../features/sync/domain/sync_protocol.dart';
import '../../../features/sync/domain/sync_session.dart';
import '../../../features/sync/data/ledger_exchange.dart';
import '../../../features/sync/domain/ledger_protocol.dart';
import 'desktop_sync_store.dart';

/// Gelen yedeği (fotoğrafsız ZIP) içe aktarır, kısa özet döner.
/// Kullanıcıya gösterilecek hatalar [SyncException] olarak fırlatılır.
typedef BackupImporter = Future<String> Function(File zip);

enum SyncEventKind { paired, pairingClosed, session, photo, pdf, backupReceived, imported, rejected, warning }

class SyncEvent {
  const SyncEvent(this.kind, this.message);

  final SyncEventKind kind;
  final String message;
}

/// Bilgisayarın yerel ağdaki küçük HTTP sunucusu ve bulma yanıtlayıcısı.
///
/// Neye dokunur: yalnızca fotoğraf klasörü (doğrulanmış yollar) ve kendi
/// geçici klasörü; veriyi içe aktarma her zamanki birleştirmeden geçer.
/// Telefona genel dosya okutmaz; listeleme isteği yoktur. Üç dar istisna:
/// bilgisayarın kendi değişikliklerinde geçen fotoğrafların verilmesi (`_photoGet`),
/// imzalı "bu PDF özeti var mı?" sorusu (`_pdf`, gövdesiz PUT) ve bilgisayarın
/// `pdf_documents` satırında geçen PDF'in verilmesi (`_pdfGet`, `pdf-al`).
///
/// Çok cihaz (v9.15): en çok [SyncLimits.maxDevices] telefon/tablet aynı anda
/// eşleşik olur; her birinin ayrı kimliği, anahtarı, oturumu ve sıra sayacı vardır.
/// Cihazlar eşzamanlı istek yapabilir; yalnızca veritabanına dokunan bölümler
/// (defter alışverişi, yedek içe aktarma) sırayla çalışır, bekleyen istek hata
/// almaz, sırasını bekler.
class SyncServer {
  SyncServer({
    required this.store,
    required this.mediaRoot,
    required this.workDir,
    required this.importBackup,
    required this.platform,
    this.ledger,
    this.pdfRoot,
    Random? random,
    DateTime Function()? now,
    this.allowLoopback = false,
    this.lockWait = const Duration(seconds: 20),
  })  : _random = random ?? Random.secure(),
        _now = now ?? DateTime.now {
    _pairing = PairingWindow(random: _random, now: _now);
    _challenges = ChallengeBook(random: _random, now: _now);
    _guard = FailureGuard(now: _now);
  }

  final DesktopSyncStore store;
  final Directory mediaRoot;
  final Directory workDir;
  final BackupImporter importBackup;

  /// Bu bilgisayarın platformu (telefona bildirilir; yalnızca "linux" kabul edilir).
  final String platform;

  /// İki yönlü değişiklik alışverişi (yoksa yalnızca yedek alınır).
  final LedgerExchange? ledger;

  /// PDF dosyalarının klasörü (`<veri klasörü>/pdfs`, masaüstü okuyucunun baktığı
  /// yer). Null ise PDF aktarımı kapalıdır (404).
  final Directory? pdfRoot;

  /// Yalnızca testler: aynı bilgisayardan (127.0.0.1) gelen isteği kabul et.
  final bool allowLoopback;

  /// Veritabanı kilidini en çok bu kadar bekler; geçerse 409 "meşgul" (istemci zaman
  /// aşımından kısa: kopmuş isteğin işi sonradan uygulanmaz).
  final Duration lockWait;

  final Random _random;
  final DateTime Function() _now;
  late final PairingWindow _pairing;
  late final ChallengeBook _challenges;
  late final FailureGuard _guard;
  final _events = StreamController<SyncEvent>.broadcast();

  HttpServer? _http;
  RawDatagramSocket? _udp;
  DhKeyPair? _dh;

  /// Açık oturumlar (oturum kimliği → oturum); her cihazın en çok bir oturumu.
  final _sessions = <String, SyncSession>{};

  /// Veritabanına yazan işler (defter, yedek) sırayla; cihazlar birbirini bekler.
  final _dbLock = _Mutex();

  /// Büyük yedek içe aktarılırken (kilit uzun sürer) defter istekleri bekletilmez: 409 "meşgul".
  bool _backupRunning = false;

  /// Yanıtı süren istekler (cihaz kaldırılınca iptal edilir).
  final _open = <_Ctx>{};
  final _photoProgress = <String, ({int expected, int received})>{};
  String _computerId = '';
  String _computerName = '';
  late Directory _incoming;

  Stream<SyncEvent> get events => _events.stream;
  bool get isRunning => _http != null;
  int? get port => _http?.port;
  int? get discoveryPort => _udp?.port;

  /// Açık eşleştirme kodu; süresi dolduysa null.
  PairingCode? get pairing {
    final code = _pairing.current;
    if (code == null) _dh = null;
    return code;
  }

  Future<void> start({int port = syncDefaultPort, int? discoveryPort = syncDiscoveryPort}) async {
    if (_http != null) return;
    _computerId = await store.computerId();
    _computerName = await store.computerName();
    await mediaRoot.create(recursive: true);
    // Yarım kalmış aktarımların geçici dosyaları (yalnızca bu klasör).
    _incoming = Directory(p.join(workDir.path, 'kablosuz'));
    if (await _incoming.exists()) await _incoming.delete(recursive: true);
    await _incoming.create(recursive: true);

    final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    http
      ..autoCompress = false
      ..idleTimeout = const Duration(seconds: 30)
      ..serverHeader = null;
    _http = http;
    http.listen((r) => unawaited(_handle(r)), onError: (Object _) {});

    if (discoveryPort != null) {
      try {
        final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort);
        _udp = udp;
        udp.listen(_onDatagram, onError: (Object _) {});
      } on SocketException catch (e) {
        _emit(SyncEventKind.warning, 'Otomatik bulma açılamadı (${e.message}); telefonda IP adresini elle yaz.');
      }
    }
  }

  Future<void> stop() async {
    closePairing();
    _sessions.clear();
    _udp?.close();
    _udp = null;
    final http = _http;
    _http = null;
    await http?.close(force: true);
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  /// Kod ekranını açar. Mevcut cihazlar kopmaz; yalnızca yuvalar doluysa açılmaz.
  Future<PairingCode> openPairing() async {
    if (_http == null) throw const SyncException('Önce kablosuz almayı aç.');
    if ((await store.devices()).length >= SyncLimits.maxDevices) {
      throw const SyncException(
          'Bu bilgisayar en çok ${SyncLimits.maxDevices} cihazla eşleşebilir. Yeni cihaz için önce birini kaldır.');
    }
    _dh = DhKeyPair.generate(_random);
    return _pairing.open();
  }

  void closePairing() {
    _pairing.close();
    _dh = null;
  }

  /// Yalnızca bu cihazın eşleşmesi ve oturumu kalkar; diğerleri etkilenmez.
  Future<void> forgetDevice(String id) async {
    _sessions.removeWhere((_, s) => s.phoneId == id);
    for (final c in _open.where((c) => c.deviceId == id)) {
      c.aborted = true;
    }
    await store.removeDevice(id);
  }

  Future<void> forgetAllDevices() async {
    _sessions.clear();
    for (final c in _open) {
      c.aborted = true;
    }
    await store.removeAllDevices();
  }

  void _emit(SyncEventKind kind, String message) {
    if (!_events.isClosed) _events.add(SyncEvent(kind, message));
  }

  // ───────────── Bulma (UDP) ─────────────

  void _onDatagram(RawSocketEvent event) {
    final socket = _udp;
    if (event != RawSocketEvent.read || socket == null) return;
    for (var d = socket.receive(); d != null; d = socket.receive()) {
      final port = _http?.port;
      if (port == null) return;
      if (!isAcceptedPeer(d.address.rawAddress, allowLoopback: allowLoopback) || !isDiscoveryProbe(d.data)) continue;
      final reply = DiscoveryReply(id: _computerId, name: _computerName, port: port, platform: platform);
      try {
        socket.send(utf8.encode(jsonEncode(reply.toJson())), d.address, d.port);
      } on SocketException {
        // Yanıt gidemezse telefon yeniden dener ya da IP elle yazılır.
      }
    }
  }

  // ───────────── HTTP ─────────────

  Future<void> _handle(HttpRequest request) async {
    final ctx = _Ctx(request);
    _open.add(ctx);
    // Bağlantı kopunca (yanıt tamamlanmadan) iş kilitten çıkınca uygulanmaz (en iyi çaba).
    unawaited(request.response.done.then<void>((_) => ctx.gone = true, onError: (Object _) => ctx.gone = true));
    try {
      await _handleInner(ctx);
    } finally {
      _open.remove(ctx);
    }
  }

  Future<void> _handleInner(_Ctx ctx) async {
    final request = ctx.request;
    final remote = request.connectionInfo?.remoteAddress;
    final address = remote?.address ?? '';
    try {
      if (remote == null || !isAcceptedPeer(remote.rawAddress, allowLoopback: allowLoopback)) {
        throw const _Reject(403, 'Yalnızca yerel ağdan istek kabul edilir.', counts: false);
      }
      if (_guard.isBanned(address)) {
        throw const _Reject(429, 'Çok fazla hatalı istek. Biraz sonra tekrar dene.', counts: false);
      }
      if (looksLikeBrowserRequest(request.headers.value)) {
        throw const _Reject(403, 'Tarayıcıdan gelen istek kabul edilmez.');
      }
      if (!isIpLiteralHost(request.headers.value(HttpHeaders.hostHeader))) {
        throw const _Reject(403, 'Bilgisayara IP adresiyle bağlanılmalı.');
      }
      if (request.method == 'POST' && request.uri.path == SyncPaths.photoGet) {
        await _photoGet(ctx);
        return;
      }
      if (request.method == 'POST' && request.uri.path == SyncPaths.pdfGet) {
        await _pdfGet(ctx);
        return;
      }
      final handlers = <String, Future<Map<String, Object?>> Function()>{
        'GET ${SyncPaths.hello}': _hello,
        'POST ${SyncPaths.pair}': () => _pair(ctx),
        'POST ${SyncPaths.session}': () => _startSession(ctx),
        'POST ${SyncPaths.photoList}': () => _photoList(ctx),
        'PUT ${SyncPaths.photo}': () => _photo(ctx),
        'PUT ${SyncPaths.pdf}': () => _pdf(ctx),
        'PUT ${SyncPaths.backup}': () => _backup(ctx),
        'POST ${SyncPaths.ledger}': () => _ledger(ctx),
      };
      final handler = handlers['${request.method} ${request.uri.path}'];
      if (handler == null) throw const _Reject(404, 'Bilinmeyen istek.');
      final body = await handler();
      await _respond(request, 200, body, sign: ctx.signed, close: ctx.closeAfter);
    } on _Reject catch (e) {
      if (e.counts && address.isNotEmpty) _guard.record(address);
      await _drain(ctx);
      await _respond(request, e.status, syncErrorJson(e.message), close: ctx.closeAfter);
    } on SyncException catch (e) {
      await _drain(ctx);
      await _respond(request, e.status ?? 409, syncErrorJson(e.message));
    } catch (e) {
      // Beklenmeyen her hata da yanıtlanır; telefon zaman aşımına kadar beklemesin.
      await _drain(ctx);
      await _respond(request, 500, syncErrorJson('Bilgisayarda beklenmeyen hata: $e'));
    }
  }

  Future<Map<String, Object?>> _hello() async {
    final full = (await store.devices()).length >= SyncLimits.maxDevices;
    final code = pairing;
    final dh = _dh;
    final open = code != null && dh != null && !full;
    return SyncHello(
      id: _computerId,
      name: _computerName,
      platform: platform,
      pairingOpen: open,
      paired: full,
      challenge: _challenges.issue(),
      dhPublic: open ? dh.publicHex : null,
    ).toJson();
  }

  Future<Map<String, Object?>> _pair(_Ctx ctx) async {
    final json = _decode(await _readBytes(ctx, SyncLimits.jsonBody));
    final req = _parse(() => PairRequest.fromJson(json));
    final existing = await store.devices();
    if (existing.length >= SyncLimits.maxDevices && !existing.any((d) => d.id == req.phoneId)) {
      throw const _Reject(
        409,
        'Bu bilgisayar en çok ${SyncLimits.maxDevices} cihazla eşleşebilir. Yeni cihaz için önce bilgisayarda '
        'Ayarlar → Cihaz eşleştirme → bir cihazı kaldır.',
        counts: false,
      );
    }
    final code = pairing;
    final dh = _dh;
    if (code == null || dh == null) {
      throw const _Reject(403, 'Eşleştirme kapalı. Bilgisayarda "Telefon eşleştir"e bas ve ekrandaki kodu yaz.');
    }
    if (!_challenges.consume(req.challenge)) throw const _Reject(401, 'İsteğin süresi geçti; yeniden dene.');
    if (!acceptedPhonePlatforms.contains(req.platform)) {
      _emit(SyncEventKind.rejected, '"${cleanDeviceName(req.platform)}" cihazından gelen eşleşme isteği reddedildi.');
      throw const _Reject(403, 'Bu cihaz türü kabul edilmiyor: yalnızca Android telefon ve tablet eşleşebilir.');
    }
    if (!isValidDeviceId(req.phoneId)) throw const _Reject(400, 'Geçersiz telefon kimliği.');
    final shared = dh.sharedSecret(req.dhPublic);
    if (shared == null) throw const _Reject(400, 'Geçersiz anahtar değişimi.');
    final key = derivePairingKey(
      sharedSecret: shared,
      code: code.code,
      computerId: _computerId,
      phoneId: req.phoneId,
      challenge: req.challenge,
      phonePublic: req.dhPublic,
      computerPublic: dh.publicHex,
    );
    if (!safeEquals(proofOf(key, ProofLabels.phonePair, [req.challenge, req.phoneId]), req.proof)) {
      if (_pairing.registerFailure() == PairingFailure.exhausted) {
        _dh = null;
        _emit(SyncEventKind.pairingClosed, 'Çok fazla yanlış kod girildi; eşleştirme kapandı.');
        throw const _Reject(403, 'Çok fazla yanlış kod. Bilgisayarda yeni kod al.');
      }
      throw _Reject(403, 'Kod yanlış. Kalan hak: ${code.attemptsLeft}.');
    }
    final phone = PairedDevice(
      id: req.phoneId,
      name: cleanDeviceName(req.name),
      platform: req.platform,
      kind: req.kind,
      key: key,
      pairedAt: _now(),
    );
    await store.saveDevice(phone);
    _sessions.removeWhere((_, s) => s.phoneId == phone.id); // yeniden eşleşen cihazın eski oturumu geçersiz
    closePairing();
    _emit(SyncEventKind.paired, phone.name);
    return PairResponse(
      id: _computerId,
      name: _computerName,
      platform: platform,
      proof: proofOf(key, ProofLabels.computerPair, [req.challenge, req.phoneId]),
    ).toJson();
  }

  Future<Map<String, Object?>> _startSession(_Ctx ctx) async {
    final json = _decode(await _readBytes(ctx, SyncLimits.jsonBody));
    final req = _parse(() => SessionRequest.fromJson(json));
    final phone = await store.device(req.phoneId);
    if (phone == null) {
      throw const _Reject(401, 'Bu cihaz bu bilgisayarla eşleşmemiş. Cihazda eşleşmeyi kaldırıp yeniden eşleştir.');
    }
    if (!_challenges.consume(req.challenge)) throw const _Reject(401, 'İsteğin süresi geçti; yeniden dene.');
    if (!safeEquals(proofOf(phone.key, ProofLabels.phoneSession, [req.challenge, phone.id]), req.proof)) {
      _emit(SyncEventKind.rejected, 'Anahtarı tutmayan bir bağlanma denemesi reddedildi.');
      throw const _Reject(401, 'Anahtar tutmadı. Telefonda eşleşmeyi kaldırıp yeniden eşleştir.');
    }
    final now = _now();
    _sessions.removeWhere((_, s) => s.phoneId == phone.id || s.isExpired(now)); // cihaz başına tek oturum
    final session = SyncSession(id: randomToken(_random), phoneId: phone.id, now: now);
    _sessions[session.id] = session;
    _emit(SyncEventKind.session, '${phone.name} bağlandı.');
    return SessionResponse(
      session: session.id,
      proof: proofOf(phone.key, ProofLabels.computerSession, [req.challenge, session.id]),
    ).toJson();
  }

  Future<Map<String, Object?>> _photoList(_Ctx ctx) async {
    final signed = await _claim(ctx);
    final bytes = await _readBytes(ctx, SyncLimits.jsonBody);
    _verify(ctx.request, signed, sha256Hex(bytes));
    final json = _decode(bytes);
    final req = _parse(() => PhotoListRequest.fromJson(json));
    final sizes = <String, int?>{};
    for (final e in req.photos) {
      if (!isTransferableMediaPath(e.path) || sizes.containsKey(e.path)) continue;
      sizes[e.path] = await _localSize(e.path);
    }
    final result = selectMissingMedia(req.photos, sizes);
    _photoProgress[signed.phone.id] = (expected: result.missing.length, received: 0);
    _emit(SyncEventKind.photo, 'Telefonda ${req.photos.length} fotoğraf var; ${result.missing.length} tanesi gelecek.');
    return PhotoListResponse(missing: result.missing, rejected: result.rejected).toJson();
  }

  Future<Map<String, Object?>> _photo(_Ctx ctx) async {
    final signed = await _claim(ctx);
    final path = ctx.request.headers.value(SyncHeaders.mediaPath) ?? '';
    if (!isTransferableMediaPath(path)) throw const _Reject(400, 'Fotoğraf yolu kurallara uymuyor; alınmadı.');
    final temp = File(p.join(_incoming.path, '${randomToken(_random)}.part'));
    try {
      final hash = await _readToFile(ctx, temp, SyncLimits.photo);
      _verify(ctx.request, signed, hash, mediaPath: path);
      final target = _mediaFile(path);
      await target.parent.create(recursive: true);
      await _ensureInsideMedia(target);
      try {
        await temp.rename(target.path);
      } on FileSystemException {
        // Farklı disk bölümü: kopyala (hedefin bağlantı olmadığı yukarıda denetlendi).
        await temp.copy(target.path);
      }
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    final progress = _photoProgress[signed.phone.id] ?? (expected: 0, received: 0);
    _photoProgress[signed.phone.id] = (expected: progress.expected, received: progress.received + 1);
    _emit(SyncEventKind.photo,
        '${signed.phone.name}: fotoğraf alındı: ${progress.received + 1} / ${progress.expected}');
    return {'tamam': true};
  }

  /// PDF dosyası (T7, isteğe bağlı): `pdfs/<sha256>.pdf`.
  ///
  /// İki biçim, ikisi de `PUT`, ikisi de imzalı:
  ///  - **Gövdesiz (Content-Length 0) = "bu özet sende var mı?"** Gönderen kendi
  ///    elindeki tek bir özeti sorar; listeleme ya da okuma değildir. Yanıt
  ///    `zatenVar`. İmza geçerli değilse varlık bilgisi sızmaz. (dart:io, gövde
  ///    okunmadan verilen yanıtı güvenle iletemez; bu yüzden önce soru, sonra yükleme.)
  ///  - **Gövdeli = yükleme.** İmza, gövde okunmadan ADIN özetiyle doğrulanır
  ///    (dürüst istemcide gövde özeti = adın özeti). Gövde `.part` dosyasına
  ///    akıtılır; özeti adla (ve imzayla) tutmazsa reddedilir ve silinir; tutarsa
  ///    atomik yeniden adlandırılır. Dosya aradan varsa yeniden yazılmaz.
  ///    Boyut üst sınırı [SyncLimits.pdf].
  Future<Map<String, Object?>> _pdf(_Ctx ctx) async {
    final root = pdfRoot;
    if (root == null) throw const _Reject(404, 'Bu bilgisayar PDF almıyor.', counts: false);
    final request = ctx.request;
    final signed = await _claim(ctx);
    final name = request.headers.value(SyncHeaders.mediaPath) ?? '';
    final sha = shaOfPdfName(name);
    if (sha == null) throw const _Reject(400, 'PDF adı kurallara uymuyor; alınmadı.');
    final length = request.contentLength;
    if (length < 0) throw const _Reject(411, 'PDF boyutu bildirilmedi.');
    final probe = length == 0;
    _verify(request, signed, probe ? sha256Hex(const <int>[]) : sha, mediaPath: name);
    ctx.signed = signed;
    if (length > SyncLimits.pdf) {
      throw _Reject(413, 'PDF çok büyük (en çok ${formatPdfSize(SyncLimits.pdf)}).', counts: false);
    }
    final target = File(p.join(root.path, name));
    var exists = false;
    if (await root.exists()) {
      await _ensureInside(root, target, 'PDF klasörü uygulamanın alanı dışını gösteriyor; alınmadı.');
      exists = await FileSystemEntity.type(target.path, followLinks: false) == FileSystemEntityType.file;
    }
    if (probe) return {'tamam': true, 'zatenVar': exists};
    if (exists) {
      // Aradan başka yoldan gelmiş: yeniden yazılmaz; gövde okunmaz, yanıttan sonra bağlantı kapanır.
      _abandonBody(ctx);
      _emit(SyncEventKind.pdf, 'PDF bilgisayarda zaten var; yeniden alınmadı.');
      return {'tamam': true, 'zatenVar': true};
    }
    final temp = File(p.join(_incoming.path, '${randomToken(_random)}.part'));
    File? sideCopy;
    try {
      final hash = await _readToFile(ctx, temp, SyncLimits.pdf);
      if (hash != sha) throw const _Reject(400, 'PDF içeriği adındaki özetle uyuşmuyor; alınmadı.');
      await root.create(recursive: true);
      await _ensureInside(root, target, 'PDF klasörü uygulamanın alanı dışını gösteriyor; alınmadı.');
      try {
        await temp.rename(target.path);
      } on FileSystemException {
        // Farklı disk bölümü: hedef klasöre geçici kopya, sonra atomik yeniden adlandırma.
        sideCopy = File('${target.path}.${randomToken(_random)}.part');
        await temp.copy(sideCopy.path);
        await sideCopy.rename(target.path);
      }
    } finally {
      if (await temp.exists()) await temp.delete();
      if (sideCopy != null && await sideCopy.exists()) await sideCopy.delete();
    }
    _emit(SyncEventKind.pdf, 'PDF alındı (${formatPdfSize(length)}).');
    return {'tamam': true, 'zatenVar': false};
  }

  /// Değişiklik defteri alışverişi: telefonun satırlarını uygular, kendi
  /// satırlarını döner. Yanıt imzalıdır; telefon doğrulamadan uygulamaz.
  Future<Map<String, Object?>> _ledger(_Ctx ctx) async {
    final exchange = ledger;
    if (exchange == null) throw const _Reject(404, 'Bu bilgisayar değişiklik alışverişini desteklemiyor.', counts: false);
    final signed = await _claim(ctx);
    final bytes = await _readBytes(ctx, SyncLimits.jsonBody);
    _verify(ctx.request, signed, sha256Hex(bytes));
    ctx.signed = signed;
    final req = _parse(() => LedgerRequest.fromJson(_decode(bytes)));
    // Başka bir cihazın alışverişi ya da yedeği sürüyorsa sırayı bekler (hata almaz).
    if (_backupRunning) throw const _Reject(409, 'Bilgisayar büyük bir veriyi içe aktarıyor (meşgul); biraz sonra tekrar dene.', counts: false);
    final response = await _locked(ctx, signed, () => exchange.handle(req, peer: signed.phone.id));
    unawaited(store.touchDevice(signed.phone.id, _now()));
    _emit(SyncEventKind.imported,
        '${signed.phone.name}: ${response.summary}; ${response.changes.length} değişiklik cihaza gidiyor.');
    return response.toJson();
  }

  /// Bilgisayarın telefona vereceği fotoğraf: yalnızca bilgisayarın kendi
  /// değişikliğinde geçen, kurala uyan yol. Genel dosya okuma değildir.
  Future<void> _photoGet(_Ctx ctx) async {
    final exchange = ledger;
    if (exchange == null) throw const _Reject(404, 'Bilinmeyen istek.');
    final signed = await _claim(ctx);
    final bytes = await _readBytes(ctx, SyncLimits.jsonBody);
    _verify(ctx.request, signed, sha256Hex(bytes));
    final path = _parse(() => PhotoGetRequest.fromJson(_decode(bytes))).path;
    if (!await exchange.maySend(path, device: signed.phone.id)) throw const _Reject(404, 'Bu fotoğraf verilemez.');
    final file = _mediaFile(path);
    await _ensureInsideMedia(file);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size > SyncLimits.photo) {
      throw const _Reject(404, 'Fotoğraf bilgisayarda yok.', counts: false);
    }
    final hash = StreamingSha256();
    await for (final chunk in file.openRead()) {
      hash.add(chunk);
    }
    final signature = responseSignature(signed.phone.key,
        session: signed.session.id, sequence: signed.sequence, bodyHash: hash.close());
    final response = ctx.request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.binary
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set(SyncHeaders.responseSignature, signature)
      ..contentLength = stat.size;
    try {
      await response.addStream(file.openRead(0, stat.size));
      await response.close();
    } on Exception {
      // Telefon bağlantıyı kapatmış olabilir; yeniden ister.
    }
  }

  /// PDF'i cihaza verir (`pdf-al`, v9.15, isteğe bağlı: cihazda ayar varsayılan KAPALI).
  ///
  /// Üçüncü dar istisna. Genel dosya okuma değildir: imza şart; ad yalnızca
  /// `^[0-9a-f]{64}\.pdf$`; özet bilgisayarın `pdf_documents` satırında geçmek
  /// zorunda (yoksa 404, varlık bilgisi sızmaz); hedef `pdfs/` altında gerçek
  /// dosya olmalı (symlink reddi); boyut en çok [SyncLimits.pdf]. Gövde
  /// `baslangic` bayttan itibaren akıtılır (kopan indirme kaldığı yerden sürer).
  /// Yanıt imzası "ad|başlangıç|toplam" üzerindedir (dosyayı iki kez okumayız);
  /// asıl bütünlük kanıtı ADIN kendisidir: istemci baytların SHA-256'sını adla
  /// karşılaştırır, tutmazsa atar.
  Future<void> _pdfGet(_Ctx ctx) async {
    final root = pdfRoot;
    final exchange = ledger;
    if (root == null || exchange == null) throw const _Reject(404, 'Bu bilgisayar PDF vermiyor.', counts: false);
    final signed = await _claim(ctx);
    final bytes = await _readBytes(ctx, SyncLimits.jsonBody);
    _verify(ctx.request, signed, sha256Hex(bytes));
    final req = _parse(() => PdfGetRequest.fromJson(_decode(bytes)));
    final sha = shaOfPdfName(req.name);
    if (sha == null) throw const _Reject(400, 'PDF adı kurallara uymuyor.');
    if (!await exchange.hasPdfDocument(sha)) throw const _Reject(404, 'Bu PDF bilgisayarda yok.', counts: false);
    final target = File(p.join(root.path, req.name));
    if (!await root.exists()) throw const _Reject(404, 'Bu PDF bilgisayarda yok.', counts: false);
    await _ensureInside(root, target, 'PDF klasörü uygulamanın alanı dışını gösteriyor; verilmedi.');
    final stat = await FileStat.stat(target.path);
    if (await FileSystemEntity.type(target.path, followLinks: false) != FileSystemEntityType.file) {
      throw const _Reject(404, 'Bu PDF bilgisayarda yok.', counts: false);
    }
    if (stat.size > SyncLimits.pdf) throw _Reject(413, 'PDF çok büyük (en çok ${formatPdfSize(SyncLimits.pdf)}).', counts: false);
    if (req.start < 0 || req.start > stat.size) throw const _Reject(400, 'Başlangıç konumu geçersiz.');
    final signature = responseSignature(signed.phone.key,
        session: signed.session.id,
        sequence: signed.sequence,
        bodyHash: sha256Hex(utf8.encode(pdfGetMeta(req.name, req.start, stat.size))));
    final response = ctx.request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.binary
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set(SyncHeaders.responseSignature, signature)
      ..contentLength = stat.size - req.start;
    ctx.bodyTaken = true;
    _emit(SyncEventKind.pdf, '${signed.phone.name}: PDF veriliyor (${formatPdfSize(stat.size)}).');
    try {
      await for (final chunk in target.openRead(req.start, stat.size)) {
        if (ctx.aborted || ctx.gone) break;
        response.add(chunk);
        await response.flush();
      }
      // Cihaz kaldırıldıysa gövde eksik kalır: Content-Length tutmadığı için close() hata verir
      // ve bağlantı yok edilir (istemci yarım gövdeyi zaten adın özetiyle reddeder).
      await response.close();
    } catch (_) {
      // Cihaz bağlantıyı kapatmış olabilir (iptal); yeniden isterse kaldığı yerden sürer.
    }
  }

  Future<Map<String, Object?>> _backup(_Ctx ctx) async {
    final signed = await _claim(ctx);
    // Dosya adı cihaza özgü: iki cihaz aynı anda yedek gönderse de çakışmaz.
    final zip = File(p.join(_incoming.path, 'Kablosuz_${_stamp(_now())}_${randomToken(_random).substring(0, 8)}.zip'));
    try {
      final hash = await _readToFile(ctx, zip, SyncLimits.backup);
      _verify(ctx.request, signed, hash);
      _emit(SyncEventKind.backupReceived, '${signed.phone.name}: veri geldi; içe aktarılıyor…');
      final summary = await _locked(ctx, signed, () async {
        _backupRunning = true;
        try {
          return await importBackup(zip);
        } finally {
          _backupRunning = false;
        }
      });
      _emit(SyncEventKind.imported, summary);
      return BackupResponse(summary).toJson();
    } finally {
      if (await zip.exists()) await zip.delete();
    }
  }

  // ───────────── Yardımcılar ─────────────

  /// Veritabanı kilidine girer. Bekleme [lockWait] ile sınırlı (aşılırsa 409 meşgul).
  /// Kilitten çıkınca bağlantı koptuysa, cihaz kaldırıldıysa ya da eşleşmesi gittiyse iş
  /// UYGULANMAZ (yanıt kaybolacağı için istemci yeniden gönderirdi).
  Future<T> _locked<T>(_Ctx ctx, _Signed signed, Future<T> Function() body) async {
    try {
      return await _dbLock.run(() async {
        if (ctx.aborted || ctx.gone || await store.device(signed.phone.id) == null) {
          throw ctx.gone && !ctx.aborted
              ? const _Reject(499, 'İstemci bağlantısı koptu; iş uygulanmadı.', counts: false)
              : const _Reject(401, 'Bu cihazın eşleşmesi kaldırılmış.', counts: false);
        }
        return body();
      }, wait: lockWait);
    } on TimeoutException {
      throw const _Reject(409, 'Bilgisayar başka bir işle meşgul; biraz sonra tekrar dene.', counts: false);
    }
  }

  /// Oturum ve sıra numarası gövde okunmadan denetlenir ve sıra ayrılır.
  Future<_Signed> _claim(_Ctx ctx) async {
    final request = ctx.request;
    final id = request.headers.value(SyncHeaders.session);
    final sequence = int.tryParse(request.headers.value(SyncHeaders.sequence) ?? '');
    final now = _now();
    final session = id == null ? null : _sessions[id];
    if (session == null || sequence == null || session.isExpired(now)) {
      if (session != null) _sessions.remove(session.id);
      throw const _Reject(401, 'Oturum geçersiz ya da süresi doldu; yeniden bağlan.');
    }
    if (!session.claim(sequence, now)) {
      _sessions.remove(session.id);
      throw const _Reject(401, 'Sıra numarası tutmadı (aynı istek ikinci kez mi geldi?); oturum kapatıldı.');
    }
    final phone = await store.device(session.phoneId);
    if (phone == null) {
      _sessions.remove(session.id);
      throw const _Reject(401, 'Bu cihazın eşleşmesi kaldırılmış.');
    }
    ctx.deviceId = phone.id;
    return _Signed(session, sequence, phone);
  }

  void _verify(HttpRequest request, _Signed signed, String bodyHash, {String mediaPath = ''}) {
    final expected = requestSignature(
      signed.phone.key,
      method: request.method,
      path: request.uri.path,
      session: signed.session.id,
      sequence: signed.sequence,
      mediaPath: mediaPath,
      bodyHash: bodyHash,
    );
    if (!safeEquals(expected, request.headers.value(SyncHeaders.signature) ?? '')) {
      _sessions.remove(signed.session.id);
      _emit(SyncEventKind.rejected, 'İmzası tutmayan bir istek reddedildi.');
      throw const _Reject(401, 'İmza tutmadı; oturum kapatıldı.');
    }
  }

  File _mediaFile(String path) => File(p.joinAll([mediaRoot.path, ...p.posix.split(path)]));

  Future<int?> _localSize(String path) async {
    final stat = await FileStat.stat(_mediaFile(path).path);
    return stat.type == FileSystemEntityType.file ? stat.size : null;
  }

  /// Yol kurallara uysa da klasörlerden biri bağlantıyla (symlink) dışarıyı
  /// gösteriyorsa yazılmaz; hedefin kendisi bağlantıysa da.
  Future<void> _ensureInsideMedia(File target) => _ensureInside(
      mediaRoot, target, 'Fotoğraf klasörü uygulamanın alanı dışını gösteriyor; alınmadı.');

  Future<void> _ensureInside(Directory rootDir, File target, String message) async {
    final root = await rootDir.resolveSymbolicLinks();
    final dir = await target.parent.resolveSymbolicLinks();
    if ((!p.isWithin(root, dir) && root != dir) || await FileSystemEntity.isLink(target.path)) {
      throw _Reject(403, message);
    }
  }

  Future<Uint8List> _readBytes(_Ctx ctx, int limit) async {
    final request = ctx.request;
    if (request.contentLength > limit) throw const _Reject(413, 'İstek çok büyük.');
    ctx.bodyTaken = true;
    final out = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (out.length + chunk.length > limit) throw const _Reject(413, 'İstek çok büyük.');
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// Gövdeyi diske akıtır (belleğe almadan), SHA-256 özetini döner.
  Future<String> _readToFile(_Ctx ctx, File target, int limit) async {
    final request = ctx.request;
    if (request.contentLength > limit) throw const _Reject(413, 'Dosya çok büyük.');
    ctx.bodyTaken = true;
    final hash = StreamingSha256();
    final sink = target.openWrite();
    var total = 0;
    try {
      await for (final chunk in request) {
        total += chunk.length;
        if (total > limit) throw const _Reject(413, 'Dosya çok büyük.');
        hash.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return hash.close();
  }

  /// Gövde hiç okunmayacak: yanıt yazılırken dinleme bırakılır (dart:io yanıtı
  /// ancak gövde bitince ya da dinleme bırakılınca yollar) ve yanıttan sonra
  /// bağlantı kapanır; kalan baytlar kabul edilmez. Bkz. `_respond`.
  void _abandonBody(_Ctx ctx) {
    ctx.bodyTaken = true;
    ctx.closeAfter = true;
  }

  /// Okunmamış gövde boşaltılır ki telefon hata mesajını alabilsin (gönderim
  /// yarıda kesilmesin). Çok büyükse bağlantı kapanır.
  Future<void> _drain(_Ctx ctx) async {
    if (ctx.bodyTaken) return;
    ctx.bodyTaken = true;
    final length = ctx.request.contentLength;
    if (length <= 0) return;
    if (length > SyncLimits.photo) {
      _abandonBody(ctx); // büyük gövde okunmaz
      return;
    }
    try {
      await ctx.request.drain<void>().timeout(const Duration(seconds: 30));
    } on Exception {
      // Bağlantı koptu ya da zaman aşımı: yanıt yine denenir.
    }
  }

  Future<void> _respond(HttpRequest request, int status, Map<String, Object?> body,
      {_Signed? sign, bool close = false}) async {
    final response = request.response;
    try {
      if (close) {
        response.persistentConnection = false;
        // Aynı eşzamanlı blokta: yanıt yazılmadan bağlantı kapanmasın.
        try {
          unawaited(request.listen((_) {}, onError: (Object _) {}).cancel());
        } on StateError {
          // Gövde zaten okunmuş.
        }
      }
      final bytes = utf8.encode(jsonEncode(body));
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentLength = bytes.length;
      if (sign != null && status == 200) {
        response.headers.set(
          SyncHeaders.responseSignature,
          responseSignature(sign.phone.key, session: sign.session.id, sequence: sign.sequence, bodyHash: sha256Hex(bytes)),
        );
      }
      response.add(bytes);
      await response.close();
    } on Exception {
      // Telefon bağlantıyı kapatmış olabilir.
    }
  }

  static Object? _decode(List<int> bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const _Reject(400, 'Bozuk istek.');
    }
  }

  static T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on SyncException catch (e) {
      throw _Reject(400, e.message);
    }
  }

  static String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}_${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }
}

class _Ctx {
  _Ctx(this.request);

  final HttpRequest request;
  bool bodyTaken = false;

  /// İmzalı bir istek kabul edildiyse: yanıt da imzalanır.
  _Signed? signed;

  /// Gövde okunmadan yanıtlandı: yanıttan sonra bağlantı kapatılır.
  bool closeAfter = false;

  /// İmzalı istekte cihaz kimliği (cihaz kaldırılınca bu istek iptal edilir).
  String? deviceId;

  /// Cihaz kaldırıldı: akış kesilir, kilitte bekleyen iş uygulanmaz.
  bool aborted = false;

  /// İstemci bağlantısı koptu.
  bool gone = false;
}

class _Signed {
  const _Signed(this.session, this.sequence, this.phone);

  final SyncSession session;
  final int sequence;
  final PairedDevice phone;
}

class _Reject implements Exception {
  const _Reject(this.status, this.message, {this.counts = true});

  final int status;
  final String message;

  /// Adresin hata sayacına yazılsın mı? ("Meşgul" gibi durumlar yazılmaz.)
  final bool counts;
}

/// Eşzamanlı çağıranları sıraya dizer: biri bitmeden öbürü başlamaz.
class _Mutex {
  Future<void> _tail = Future<void>.value();

  /// [wait] verilirse sıra beklemesi bununla sınırlıdır (TimeoutException); beklemeyi
  /// bırakan iş hiç başlamaz, zincir bozulmaz.
  Future<T> run<T>(Future<T> Function() body, {Duration? wait}) async {
    final prev = _tail;
    final turn = Completer<void>();
    _tail = turn.future;
    try {
      await (wait == null ? prev : prev.timeout(wait));
    } on TimeoutException {
      unawaited(prev.whenComplete(turn.complete));
      rethrow;
    }
    try {
      return await body();
    } finally {
      turn.complete();
    }
  }
}
