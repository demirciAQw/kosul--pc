import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../features/sync/domain/media_rules.dart';
import '../../../features/sync/domain/network_rules.dart';
import '../../../features/sync/domain/pairing_window.dart';
import '../../../features/sync/domain/sync_crypto.dart';
import '../../../features/sync/domain/sync_protocol.dart';
import '../../../features/sync/domain/sync_session.dart';
import 'desktop_sync_store.dart';

/// Gelen yedeği (fotoğrafsız ZIP) içe aktarır, kısa özet döner.
/// Kullanıcıya gösterilecek hatalar [SyncException] olarak fırlatılır.
typedef BackupImporter = Future<String> Function(File zip);

enum SyncEventKind { paired, pairingClosed, session, photo, backupReceived, imported, rejected, warning }

class SyncEvent {
  const SyncEvent(this.kind, this.message);

  final SyncEventKind kind;
  final String message;
}

/// Bilgisayarın yerel ağdaki küçük HTTP sunucusu ve bulma yanıtlayıcısı.
///
/// Neye dokunur: yalnızca fotoğraf klasörü (doğrulanmış yollar) ve kendi
/// geçici klasörü; veriyi içe aktarma her zamanki birleştirmeden geçer.
/// Telefona hiçbir dosya okutmaz; listeleme ya da indirme isteği yoktur.
class SyncServer {
  SyncServer({
    required this.store,
    required this.mediaRoot,
    required this.workDir,
    required this.importBackup,
    required this.platform,
    Random? random,
    DateTime Function()? now,
    this.allowLoopback = false,
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

  /// Yalnızca testler: aynı bilgisayardan (127.0.0.1) gelen isteği kabul et.
  final bool allowLoopback;

  final Random _random;
  final DateTime Function() _now;
  late final PairingWindow _pairing;
  late final ChallengeBook _challenges;
  late final FailureGuard _guard;
  final _events = StreamController<SyncEvent>.broadcast();

  HttpServer? _http;
  RawDatagramSocket? _udp;
  DhKeyPair? _dh;
  SyncSession? _session;
  bool _importing = false;
  int _expected = 0;
  int _received = 0;
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
    _session = null;
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

  /// Kod ekranını açar. Eşleşmiş telefon varken açılmaz: en fazla bir telefon.
  Future<PairingCode> openPairing() async {
    if (_http == null) throw const SyncException('Önce kablosuz almayı aç.');
    if (await store.phone() != null) {
      throw const SyncException('Bu bilgisayar zaten bir telefonla eşleşmiş. Yeni telefon için önce eşleşmeyi kaldır.');
    }
    _dh = DhKeyPair.generate(_random);
    return _pairing.open();
  }

  void closePairing() {
    _pairing.close();
    _dh = null;
  }

  Future<void> forgetPhone() async {
    _session = null;
    await store.removePhone();
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
      final handlers = <String, Future<Map<String, Object?>> Function()>{
        'GET ${SyncPaths.hello}': _hello,
        'POST ${SyncPaths.pair}': () => _pair(ctx),
        'POST ${SyncPaths.session}': () => _startSession(ctx),
        'POST ${SyncPaths.photoList}': () => _photoList(ctx),
        'PUT ${SyncPaths.photo}': () => _photo(ctx),
        'PUT ${SyncPaths.backup}': () => _backup(ctx),
      };
      final handler = handlers['${request.method} ${request.uri.path}'];
      if (handler == null) throw const _Reject(404, 'Bilinmeyen istek.');
      await _respond(request, 200, await handler());
    } on _Reject catch (e) {
      if (e.counts && address.isNotEmpty) _guard.record(address);
      await _drain(ctx);
      await _respond(request, e.status, syncErrorJson(e.message));
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
    final phone = await store.phone();
    final code = pairing;
    final dh = _dh;
    final open = code != null && dh != null && phone == null;
    return SyncHello(
      id: _computerId,
      name: _computerName,
      platform: platform,
      pairingOpen: open,
      paired: phone != null,
      challenge: _challenges.issue(),
      dhPublic: open ? dh.publicHex : null,
    ).toJson();
  }

  Future<Map<String, Object?>> _pair(_Ctx ctx) async {
    final json = _decode(await _readBytes(ctx, SyncLimits.jsonBody));
    final req = _parse(() => PairRequest.fromJson(json));
    if (await store.phone() != null) {
      throw const _Reject(
        409,
        'Bu bilgisayar zaten bir telefonla eşleşmiş. Yeni telefon için önce bilgisayarda '
        'Ayarlar → Kablosuz alma → Eşleşmeyi kaldır.',
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
    final phone = PairedPhone(
      id: req.phoneId,
      name: cleanDeviceName(req.name),
      platform: req.platform,
      key: key,
      pairedAt: _now(),
    );
    await store.savePhone(phone);
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
    final phone = await store.phone();
    if (phone == null || !safeEquals(req.phoneId, phone.id)) {
      throw const _Reject(401, 'Bu telefon bu bilgisayarla eşleşmemiş. Telefonda eşleşmeyi kaldırıp yeniden eşleştir.');
    }
    if (!_challenges.consume(req.challenge)) throw const _Reject(401, 'İsteğin süresi geçti; yeniden dene.');
    if (!safeEquals(proofOf(phone.key, ProofLabels.phoneSession, [req.challenge, phone.id]), req.proof)) {
      _emit(SyncEventKind.rejected, 'Anahtarı tutmayan bir bağlanma denemesi reddedildi.');
      throw const _Reject(401, 'Anahtar tutmadı. Telefonda eşleşmeyi kaldırıp yeniden eşleştir.');
    }
    final session = SyncSession(id: randomToken(_random), phoneId: phone.id, now: _now());
    _session = session;
    _emit(SyncEventKind.session, '${phone.name} bağlandı.');
    return SessionResponse(
      session: session.id,
      proof: proofOf(phone.key, ProofLabels.computerSession, [req.challenge, session.id]),
    ).toJson();
  }

  Future<Map<String, Object?>> _photoList(_Ctx ctx) async {
    final signed = await _claim(ctx.request);
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
    _expected = result.missing.length;
    _received = 0;
    _emit(SyncEventKind.photo, 'Telefonda ${req.photos.length} fotoğraf var; ${result.missing.length} tanesi gelecek.');
    return PhotoListResponse(missing: result.missing, rejected: result.rejected).toJson();
  }

  Future<Map<String, Object?>> _photo(_Ctx ctx) async {
    final signed = await _claim(ctx.request);
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
    _received++;
    _emit(SyncEventKind.photo, 'Fotoğraf alındı: $_received / $_expected');
    return {'tamam': true};
  }

  Future<Map<String, Object?>> _backup(_Ctx ctx) async {
    final signed = await _claim(ctx.request);
    if (_importing) {
      throw const _Reject(409, 'Bilgisayar şu an bir yedeği içe aktarıyor; biraz sonra tekrar gönder.', counts: false);
    }
    _importing = true;
    final zip = File(p.join(_incoming.path, 'Kablosuz_${_stamp(_now())}.zip'));
    try {
      final hash = await _readToFile(ctx, zip, SyncLimits.backup);
      _verify(ctx.request, signed, hash);
      _emit(SyncEventKind.backupReceived, 'Telefondan veri geldi; içe aktarılıyor…');
      final summary = await importBackup(zip);
      _emit(SyncEventKind.imported, summary);
      return BackupResponse(summary).toJson();
    } finally {
      _importing = false;
      if (await zip.exists()) await zip.delete();
    }
  }

  // ───────────── Yardımcılar ─────────────

  /// Oturum ve sıra numarası gövde okunmadan denetlenir ve sıra ayrılır.
  Future<_Signed> _claim(HttpRequest request) async {
    final session = _session;
    final id = request.headers.value(SyncHeaders.session);
    final sequence = int.tryParse(request.headers.value(SyncHeaders.sequence) ?? '');
    final now = _now();
    if (session == null || id == null || sequence == null || !safeEquals(id, session.id) || session.isExpired(now)) {
      throw const _Reject(401, 'Oturum geçersiz ya da süresi doldu; yeniden bağlan.');
    }
    if (!session.claim(sequence, now)) {
      _session = null;
      throw const _Reject(401, 'Sıra numarası tutmadı (aynı istek ikinci kez mi geldi?); oturum kapatıldı.');
    }
    final phone = await store.phone();
    if (phone == null || phone.id != session.phoneId) {
      _session = null;
      throw const _Reject(401, 'Bu telefonun eşleşmesi kaldırılmış.');
    }
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
      if (identical(_session, signed.session)) _session = null;
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
  Future<void> _ensureInsideMedia(File target) async {
    final root = await mediaRoot.resolveSymbolicLinks();
    final dir = await target.parent.resolveSymbolicLinks();
    if (!p.isWithin(root, dir) || await FileSystemEntity.isLink(target.path)) {
      throw const _Reject(403, 'Fotoğraf klasörü uygulamanın alanı dışını gösteriyor; alınmadı.');
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

  /// Okunmamış gövde boşaltılır ki telefon hata mesajını alabilsin (gönderim
  /// yarıda kesilmesin). Çok büyükse bağlantı kapanır.
  Future<void> _drain(_Ctx ctx) async {
    if (ctx.bodyTaken) return;
    ctx.bodyTaken = true;
    final length = ctx.request.contentLength;
    if (length <= 0 || length > SyncLimits.photo) return;
    try {
      await ctx.request.drain<void>().timeout(const Duration(seconds: 30));
    } on Exception {
      // Bağlantı koptu ya da zaman aşımı: yanıt yine denenir.
    }
  }

  Future<void> _respond(HttpRequest request, int status, Map<String, Object?> body) async {
    final response = request.response;
    try {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
        ..write(jsonEncode(body));
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
}

class _Signed {
  const _Signed(this.session, this.sequence, this.phone);

  final SyncSession session;
  final int sequence;
  final PairedPhone phone;
}

class _Reject implements Exception {
  const _Reject(this.status, this.message, {this.counts = true});

  final int status;
  final String message;

  /// Adresin hata sayacına yazılsın mı? ("Meşgul" gibi durumlar yazılmaz.)
  final bool counts;
}
