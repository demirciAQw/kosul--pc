import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../domain/ledger_protocol.dart';
import '../domain/media_rules.dart';
import '../domain/network_rules.dart';
import '../domain/pdf_rules.dart';
import '../domain/sync_crypto.dart';
import '../domain/sync_protocol.dart';
import 'phone_sync_store.dart';

/// Yerel ağda bulunan bilgisayar.
class DiscoveredComputer {
  const DiscoveredComputer({required this.id, required this.name, required this.host, required this.port});

  final String id;
  final String name;
  final String host;
  final int port;

  String get address => '$host:$port';
}

/// Kullanıcı uzun bir aktarımı (PDF) durdurabilsin diye.
class SyncCancelToken {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;
}

class SyncCancelledException extends SyncException {
  const SyncCancelledException() : super('PDF gönderimi iptal edildi.');
}

/// [SyncClient.sendPdf] sonucu: bilgisayarda zaten varsa gövde gitmemiştir.
class PdfSendResult {
  const PdfSendResult({required this.alreadyThere});

  final bool alreadyThere;
}

/// Açık oturum: her imzalı istek bir sonraki sıra numarasını alır.
class SyncConnection {
  SyncConnection._(this.computer, this.session);

  final PairedComputer computer;
  final String session;
  int _sequence = 0;

  int _next() => ++_sequence;
}

/// Telefonun kablosuz aktarım istemcisi. Yalnızca yerel ağ adreslerine
/// bağlanır (vekil sunucu da kullanmaz); bilgisayar kimliğini kanıtlamadan
/// hiçbir veri göndermez; yalnızca kendi sunduğu fotoğrafları yollar.
class SyncClient {
  SyncClient({
    Random? random,
    this.allowLoopback = false,
    Duration connectTimeout = const Duration(seconds: 5),
  })  : _random = random ?? Random.secure(),
        _http = HttpClient()
          ..connectionTimeout = connectTimeout
          ..userAgent = null
          ..findProxy = ((_) => 'DIRECT');

  /// Yalnızca testler: aynı cihazdaki (127.0.0.1) bilgisayara bağlan.
  final bool allowLoopback;

  final Random _random;
  final HttpClient _http;

  static const _requestTimeout = Duration(seconds: 20);

  void close() => _http.close(force: true);

  // ───────────── Bulma ─────────────

  /// Yerel ağa bulma isteği yollar, [wait] boyunca gelen yanıtları toplar.
  /// Yalnızca Linux'taki Koçum'lar listelenir.
  Future<List<DiscoveredComputer>> discover({
    Duration wait = const Duration(seconds: 2),
    int port = syncDiscoveryPort,
    List<InternetAddress>? targets,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final found = <String, DiscoveredComputer>{};
    final sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        if (!isAcceptedPeer(d.address.rawAddress, allowLoopback: allowLoopback)) continue;
        final reply = DiscoveryReply.tryParse(d.data);
        if (reply == null || !acceptedComputerPlatforms.contains(reply.platform)) continue;
        found[reply.id] = DiscoveredComputer(id: reply.id, name: reply.name, host: d.address.address, port: reply.port);
      }
    });
    try {
      final to = targets ?? await _broadcastTargets();
      final probe = discoveryProbe();
      // UDP kaybolabilir: iki tur gönderilir.
      for (var round = 0; round < 2; round++) {
        for (final t in to) {
          try {
            socket.send(probe, t, port);
          } on SocketException {
            // Bu ağ arabirimi kapalı olabilir; diğerleri denenir.
          }
        }
        await Future<void>.delayed(wait ~/ 2);
      }
    } finally {
      await sub.cancel();
      socket.close();
    }
    return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  static Future<List<InternetAddress>> _broadcastTargets() async {
    final out = <String>{'255.255.255.255'};
    try {
      for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        for (final a in i.addresses) {
          final r = a.rawAddress;
          if (isPrivateNetworkAddress(r)) out.add('${r[0]}.${r[1]}.${r[2]}.255');
        }
      }
    } on SocketException {
      // Arabirimler okunamazsa genel yayın yeter.
    }
    return [for (final a in out) InternetAddress(a)];
  }

  // ───────────── Eşleştirme ve oturum ─────────────

  Future<SyncHello> hello(String host, int port) async {
    _checkHost(host);
    final request = await _http.getUrl(_uri(host, port, SyncPaths.hello)).timeout(_requestTimeout);
    final hello = SyncHello.fromJson(await _readJson(await request.close().timeout(_requestTimeout)));
    if (!acceptedComputerPlatforms.contains(hello.platform)) {
      throw SyncException('Bu bilgisayar "${cleanDeviceName(hello.platform)}". Koçum yalnızca Linux bilgisayara '
          'gönderir; Windows kabul edilmez.');
    }
    return hello;
  }

  /// Ekrandaki kodla eşleşir. Anahtar iki tarafta ayrı ayrı türetilir; ağdan
  /// yalnızca açık değerler ve kanıtlar geçer.
  Future<PairedComputer> pair({
    required String host,
    required int port,
    required String code,
    required String phoneId,
    required String phoneName,
    required String platform,
  }) async {
    final clean = code.replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^\d{6}$').hasMatch(clean)) throw const SyncException('Kod 6 haneli olmalı.');
    final hello = await this.hello(host, port);
    if (hello.paired) {
      throw const SyncException('Bu bilgisayar zaten bir telefonla eşleşmiş. Bilgisayarda Ayarlar → Telefon eşleştirme → '
          'Eşleşmeyi kaldır, sonra tekrar dene.');
    }
    final computerPublic = hello.dhPublic;
    if (!hello.pairingOpen || computerPublic == null) {
      throw const SyncException('Bilgisayarda eşleştirme açık değil. "Telefon eşleştir"e bas, çıkan kodu yaz.');
    }
    final dh = DhKeyPair.generate(_random);
    final shared = dh.sharedSecret(computerPublic);
    if (shared == null) throw const SyncException('Bilgisayardan geçersiz anahtar değeri geldi.');
    final key = derivePairingKey(
      sharedSecret: shared,
      code: clean,
      computerId: hello.id,
      phoneId: phoneId,
      challenge: hello.challenge,
      phonePublic: dh.publicHex,
      computerPublic: computerPublic,
    );
    final request = PairRequest(
      challenge: hello.challenge,
      phoneId: phoneId,
      name: phoneName,
      platform: platform,
      dhPublic: dh.publicHex,
      proof: proofOf(key, ProofLabels.phonePair, [hello.challenge, phoneId]),
    );
    final response = PairResponse.fromJson(await _postJson(host, port, SyncPaths.pair, request.toJson()));
    if (response.id != hello.id ||
        !safeEquals(response.proof, proofOf(key, ProofLabels.computerPair, [hello.challenge, phoneId]))) {
      throw const SyncException('Bilgisayar kimliğini kanıtlayamadı; eşleşme kaydedilmedi.');
    }
    return PairedComputer(id: hello.id, name: hello.name, host: host, port: port, key: key, pairedAt: DateTime.now());
  }

  /// Oturum açar. Bilgisayar anahtarı bildiğini kanıtlamazsa (ör. ağda
  /// kendini Koçum gibi gösteren başka bir cihaz) hiçbir şey gönderilmez.
  Future<SyncConnection> connect(PairedComputer computer, {required String phoneId}) async {
    final hello = await this.hello(computer.host, computer.port);
    if (hello.id != computer.id) {
      throw const SyncException('Bu adreste eşleştiğin bilgisayar yok.', status: wrongComputerStatus);
    }
    final request = SessionRequest(
      phoneId: phoneId,
      challenge: hello.challenge,
      proof: proofOf(computer.key, ProofLabels.phoneSession, [hello.challenge, phoneId]),
    );
    final response =
        SessionResponse.fromJson(await _postJson(computer.host, computer.port, SyncPaths.session, request.toJson()));
    if (!isValidDeviceId(response.session) ||
        !safeEquals(response.proof, proofOf(computer.key, ProofLabels.computerSession, [hello.challenge, response.session]))) {
      throw const SyncException('Bilgisayar kimliğini kanıtlayamadı; hiçbir şey gönderilmedi.');
    }
    return SyncConnection._(computer, response.session);
  }

  /// İstemci tarafı durum kodu: adreste başka bir bilgisayar var.
  static const wrongComputerStatus = -1;

  // ───────────── Aktarım ─────────────

  Future<PhotoListResponse> missingPhotos(SyncConnection connection, List<MediaEntry> photos) async {
    final body = utf8.encode(jsonEncode(PhotoListRequest(photos).toJson()));
    return PhotoListResponse.fromJson(await _signed(connection, 'POST', SyncPaths.photoList, body: body));
  }

  Future<void> sendPhoto(SyncConnection connection, MediaEntry entry, File file) async {
    if (!isTransferableMediaPath(entry.path)) throw SyncException('Fotoğraf yolu kurallara uymuyor: ${entry.path}');
    await _signed(connection, 'PUT', SyncPaths.photo, file: file, mediaPath: entry.path);
  }

  /// PDF'i bilgisayara yollar (`pdfs/<sha256>.pdf`). Önce bilgisayara "bu özet
  /// sende var mı?" diye (ad = içe aktarmada hesaplanmış özet) gövdesiz bir PUT
  /// ile sorulur; varsa dosya okunmaz bile. Yoksa dosya bir kez özetlenir ve
  /// ada uymuyorsa (bozuk dosya) yollanmaz. [onProgress]: (giden, toplam).
  /// [cancel] iptal edilirse istek yarıda kesilir; bilgisayar `.part` dosyasını siler.
  Future<PdfSendResult> sendPdf(
    SyncConnection connection,
    PdfOffer offer,
    File file, {
    void Function(int sent, int total)? onProgress,
    SyncCancelToken? cancel,
  }) async {
    final name = pdfNameOfSha(offer.sha256);
    if (name == null) throw SyncException('PDF adı kurallara uymuyor: ${offer.sha256}');
    if (offer.size <= 0 || offer.size > SyncLimits.pdf) {
      throw SyncException('PDF boyutu sınırı aşıyor (en çok ${formatPdfSize(SyncLimits.pdf)}).');
    }
    // Önce tek özetlik soru (gövdesiz PUT, ad = özet): bilgisayarda varsa dosya
    // hiç okunmaz ve özetlenmez, gövde hiç gitmez.
    final probe = await _signed(connection, 'PUT', SyncPaths.pdf, body: const <int>[], mediaPath: name, verifyResponse: true);
    if (probe is Map && probe['zatenVar'] == true) return const PdfSendResult(alreadyThere: true);
    // Yüklenecek: dosya BİR kez özetlenir; ad ve boyutla uyuşmazsa (bozuk ya da
    // değişmiş dosya) hiçbir şey yollanmaz.
    final hash = StreamingSha256();
    var n = 0;
    await for (final chunk in file.openRead()) {
      if (cancel?.cancelled == true) throw const SyncCancelledException();
      hash.add(chunk);
      n += chunk.length;
    }
    if (hash.close() != offer.sha256 || n != offer.size) {
      throw const SyncException('PDF dosyası değişmiş ya da bozuk; gönderilmedi.');
    }
    if (cancel?.cancelled == true) throw const SyncCancelledException();
    final json = await _signed(
      connection,
      'PUT',
      SyncPaths.pdf,
      file: file,
      mediaPath: name,
      fileHash: offer.sha256,
      fileLength: n,
      onBytes: onProgress,
      cancel: cancel,
      verifyResponse: true,
      timeout: const Duration(minutes: 30),
    );
    return PdfSendResult(alreadyThere: json is Map && json['zatenVar'] == true);
  }

  Future<BackupResponse> sendBackup(SyncConnection connection, File zip) async => BackupResponse.fromJson(
      await _signed(connection, 'PUT', SyncPaths.backup, file: zip, timeout: const Duration(minutes: 10)));

  /// Değişiklik defteri alışverişi. Yanıtın imzası doğrulanmadan hiçbir
  /// değişiklik döndürülmez (ağdaki biri yanıtı değiştirip veri sokamaz).
  Future<LedgerResponse> exchangeLedger(SyncConnection connection, LedgerRequest request) async {
    final body = utf8.encode(jsonEncode(request.toJson()));
    return LedgerResponse.fromJson(
        await _signed(connection, 'POST', SyncPaths.ledger, body: body, verifyResponse: true, timeout: const Duration(minutes: 5)));
  }

  /// Bilgisayarın verdiği bir fotoğrafı [target] yoluna indirir. Önce geçici
  /// dosyaya yazılır; imza ve boyut tutarsa yerine konur.
  Future<void> fetchPhoto(SyncConnection connection, MediaEntry entry, File target) async {
    if (!isTransferableMediaPath(entry.path)) throw SyncException('Fotoğraf yolu kurallara uymuyor: ${entry.path}');
    final computer = connection.computer;
    _checkHost(computer.host);
    final body = utf8.encode(jsonEncode(PhotoGetRequest(entry.path).toJson()));
    final sequence = connection._next();
    final request =
        await _http.openUrl('POST', _uri(computer.host, computer.port, SyncPaths.photoGet)).timeout(_requestTimeout);
    request.headers
      ..set(SyncHeaders.session, connection.session)
      ..set(SyncHeaders.sequence, '$sequence')
      ..set(
        SyncHeaders.signature,
        requestSignature(computer.key,
            method: 'POST',
            path: SyncPaths.photoGet,
            session: connection.session,
            sequence: sequence,
            mediaPath: '',
            bodyHash: sha256Hex(body)),
      );
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      await _readJson(response); // hata iletisini fırlatır
      throw SyncException('Bilgisayar fotoğrafı vermedi (${response.statusCode}).');
    }
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.part');
    final hash = StreamingSha256();
    final sink = temp.openWrite();
    var total = 0;
    try {
      await for (final chunk in response.timeout(const Duration(minutes: 2))) {
        total += chunk.length;
        if (total > SyncLimits.photo) throw const SyncException('Fotoğraf beklenenden büyük geldi.');
        hash.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    final expected = responseSignature(computer.key,
        session: connection.session, sequence: sequence, bodyHash: hash.close());
    if (!safeEquals(expected, response.headers.value(SyncHeaders.responseSignature) ?? '')) {
      await temp.delete();
      throw const SyncException('Fotoğrafın imzası tutmadı; alınmadı.');
    }
    await temp.rename(target.path);
  }

  // ───────────── Yardımcılar ─────────────

  void _checkHost(String host) {
    final raw = parseIpv4(host);
    if (raw == null || !isAcceptedPeer(raw, allowLoopback: allowLoopback)) {
      throw const SyncException('Bilgisayar adresi yerel ağda olmalı (192.168…, 10…, 172.16–31…).');
    }
  }

  Uri _uri(String host, int port, String path) => Uri(scheme: 'http', host: host, port: port, path: path);

  Future<Object?> _postJson(String host, int port, String path, Map<String, Object?> body) async {
    _checkHost(host);
    final bytes = utf8.encode(jsonEncode(body));
    final request = await _http.postUrl(_uri(host, port, path)).timeout(_requestTimeout);
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    return _readJson(await request.close().timeout(_requestTimeout));
  }

  Future<Object?> _signed(
    SyncConnection connection,
    String method,
    String path, {
    List<int>? body,
    File? file,
    String mediaPath = '',
    Duration timeout = const Duration(minutes: 2),
    bool verifyResponse = false,
    String? fileHash,
    int? fileLength,
    void Function(int sent, int total)? onBytes,
    SyncCancelToken? cancel,
  }) async {
    final computer = connection.computer;
    _checkHost(computer.host);
    final String hash;
    final int length;
    if (file != null && fileHash != null && fileLength != null) {
      hash = fileHash; // çağıran dosyayı zaten özetledi (büyük PDF'i iki kez okumayalım)
      length = fileLength;
    } else if (file != null) {
      final h = StreamingSha256();
      var n = 0;
      await for (final chunk in file.openRead()) {
        h.add(chunk);
        n += chunk.length;
      }
      hash = h.close();
      length = n;
    } else {
      final b = body ?? const <int>[];
      hash = sha256Hex(b);
      length = b.length;
    }
    final sequence = connection._next();
    final request = await _http.openUrl(method, _uri(computer.host, computer.port, path)).timeout(_requestTimeout);
    request.headers
      ..set(SyncHeaders.session, connection.session)
      ..set(SyncHeaders.sequence, '$sequence')
      ..set(
        SyncHeaders.signature,
        requestSignature(
          computer.key,
          method: method,
          path: path,
          session: connection.session,
          sequence: sequence,
          mediaPath: mediaPath,
          bodyHash: hash,
        ),
      );
    if (mediaPath.isNotEmpty) request.headers.set(SyncHeaders.mediaPath, mediaPath);
    request.contentLength = length;
    if (file != null) {
      var sent = 0;
      final stream = file.openRead(0, length).map((chunk) {
        if (cancel?.cancelled == true) throw const SyncCancelledException();
        sent += chunk.length;
        onBytes?.call(sent, length);
        return chunk;
      });
      try {
        await request.addStream(stream);
      } on SyncCancelledException {
        request.abort();
        rethrow;
      } on Object {
        // Bilgisayar gövdeyi beklemeden yanıtladı ve bağlantıyı kapattı ("zaten var"
        // ya da ret); asıl yanıt aşağıda okunur, okunamazsa hata fırlar.
        if (fileHash == null) rethrow;
      }
    } else if (body != null) {
      request.add(body);
    }
    return _readJson(
      await request.close().timeout(timeout),
      verify: verifyResponse ? (key: computer.key, session: connection.session, sequence: sequence) : null,
    );
  }

  Future<Object?> _readJson(
    HttpClientResponse response, {
    ({List<int> key, String session, int sequence})? verify,
  }) async {
    final out = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (out.length + chunk.length > SyncLimits.jsonBody) {
        throw const SyncException('Bilgisayardan beklenmedik büyüklükte yanıt geldi.');
      }
      out.add(chunk);
    }
    final raw = out.takeBytes();
    if (verify != null && response.statusCode == HttpStatus.ok) {
      final expected = responseSignature(verify.key,
          session: verify.session, sequence: verify.sequence, bodyHash: sha256Hex(raw));
      if (!safeEquals(expected, response.headers.value(SyncHeaders.responseSignature) ?? '')) {
        throw const SyncException('Bilgisayarın yanıtının imzası tutmadı; hiçbir şey uygulanmadı.');
      }
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      json = null;
    }
    if (response.statusCode != HttpStatus.ok) {
      final message = json is Map ? json['hata'] : null;
      throw SyncException(
        message is String ? message : 'Bilgisayar isteği reddetti (${response.statusCode}).',
        status: response.statusCode,
      );
    }
    if (json == null) throw const SyncException('Bilgisayardan bozuk yanıt geldi.');
    return json;
  }
}

/// Bağlantı hatası mı (adres değişmiş olabilir; bulma ile yeniden denenir)?
bool isUnreachable(Object error) =>
    error is SocketException ||
    error is TimeoutException ||
    (error is SyncException && error.status == SyncClient.wrongComputerStatus);

/// Hataları kullanıcıya anlaşılır Türkçe mesaja çevirir.
String describeSyncError(Object error) {
  if (error is SyncException) return error.message;
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    if (code == 1 || code == 13) {
      return 'Android yerel ağa erişim izni vermedi. Telefonun ayarlarında Koçum için "Yakındaki cihazlar" '
          'ya da "Yerel ağ" iznini aç.';
    }
    return 'Bilgisayara ulaşılamadı. İkisi aynı Wi-Fi\'da mı, bilgisayarda kablosuz alma açık mı? '
        '(Bilgisayarın güvenlik duvarı 47321/TCP\'yi engelliyor olabilir.)';
  }
  if (error is TimeoutException) return 'Bilgisayar yanıt vermedi (zaman aşımı).';
  if (error is HttpException) return 'Bağlantı yarıda kesildi. Tekrar gönder; kaldığı yerden devam eder.';
  if (error is FileSystemException) return 'Telefonda dosya okunamadı: ${error.path ?? error.message}';
  return 'Beklenmeyen hata: $error';
}
