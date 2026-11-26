/// Telefon → bilgisayar kablosuz aktarımın ortak sözleşmesi (sürüm 1).
/// İki taraf da adları, sınırları ve mesajları yalnızca buradan alır.
///
/// Akış:
///  1. Bulma: telefon yerel ağa UDP ile [discoveryProbe] yollar; Linux'taki
///     Koçum [DiscoveryReply] ile yanıtlar. Bulamazsa IP elle yazılır.
///  2. Eşleştirme: bilgisayar ekranında 6 haneli kod. Anahtar Diffie-Hellman
///     ile iki tarafta ayrı ayrı hesaplanır; ağdan hiç geçmez.
///  3. Oturum: her bağlantıda iki taraf anahtarı bildiğini kanıtlar.
///  4. Aktarım: her istek imzalı ve sıra numaralı; aynı istek iki kez
///     kabul edilmez.
library;

import 'dart:convert';

const syncProtocolVersion = 1;
const syncAppName = 'kocum';

/// Bilgisayarın dinlediği TCP portu (HTTP) ve bulma portu (UDP).
const syncDefaultPort = 47321;
const syncDiscoveryPort = 47322;

abstract final class SyncPaths {
  static const prefix = '/kocum/v1';
  static const hello = '$prefix/merhaba';
  static const pair = '$prefix/eslesme';
  static const session = '$prefix/oturum';
  static const photoList = '$prefix/fotograflar';
  static const photo = '$prefix/fotograf';
  static const backup = '$prefix/yedek';

  /// İki yönlü senkron (v8.8): değişiklik defteri alışverişi ve bilgisayarın
  /// telefona gönderdiği fotoğraflar (yalnızca kendi değişikliklerinde geçenler).
  static const ledger = '$prefix/degisiklikler';
  static const photoGet = '$prefix/fotograf-al';

  /// PDF dosyası (T7): yalnızca telefon/tablet → bilgisayar, `PUT`, isteğe bağlı.
  /// Ad `x-kocum-yol` başlığında `<sha256>.pdf`; imzaya girer.
  static const pdf = '$prefix/pdf';

  /// PDF dosyasını bilgisayardan alma (v9.15, isteğe bağlı, ayar varsayılan KAPALI):
  /// yalnızca bilgisayarın `pdf_documents` satırında geçen özet. Bkz. `SyncServer._pdfGet`.
  static const pdfGet = '$prefix/pdf-al';
}

/// İmzalı isteklerin başlıkları (küçük harf; HTTP başlıkları harf duyarsız).
abstract final class SyncHeaders {
  static const session = 'x-kocum-oturum';
  static const sequence = 'x-kocum-sira';
  static const signature = 'x-kocum-imza';
  static const mediaPath = 'x-kocum-yol';

  /// Bilgisayarın yanıt imzası (telefon doğrular; ağdaki biri yanıtı değiştiremez).
  static const responseSignature = 'x-kocum-yanit-imza';
}

abstract final class SyncLimits {
  /// JSON istek ve yanıtları (fotoğraf listesi dahil).
  static const jsonBody = 8 * 1024 * 1024;

  /// Tek fotoğraf.
  static const photo = 40 * 1024 * 1024;

  /// Fotoğrafsız yedek ZIP (JSON + veritabanı kopyası).
  static const backup = 512 * 1024 * 1024;

  /// Tek PDF dosyası (T7).
  static const pdf = 300 * 1024 * 1024;

  static const photoListLength = 200000;
  static const pairingCodeTtl = Duration(minutes: 5);
  static const pairingAttempts = 5;
  static const challengeTtl = Duration(minutes: 2);
  static const openChallenges = 32;
  static const sessionIdle = Duration(minutes: 10);

  /// Aynı adresten bu kadar hatalı istek gelirse adres bir süre yasaklanır.
  static const failuresPerAddress = 20;
  static const failureWindow = Duration(minutes: 10);
  static const banDuration = Duration(minutes: 10);

  static const nameLength = 40;

  /// Bir alıcıya (bilgisayar ya da ekranı açık Android) aynı anda eşleşebilecek
  /// cihaz sayısı (v9.15). v9.23: her cihaz hem alıcı hem istemci olabilir.
  static const maxDevices = 4;

  /// Bir istemcinin aynı anda eşleşebileceği alıcı (eş) sayısı (v9.23).
  static const maxPeers = 4;
}

/// Eşleşen cihazın türü (ekranda simge ve ad için; güvenlikte rolü yok).
const deviceKindPhone = 'telefon';
const deviceKindTablet = 'tablet';

String cleanDeviceKind(Object? kind) => kind == deviceKindTablet ? deviceKindTablet : deviceKindPhone;

/// Eş (karşı uç) türü: bilgisayar de olabilir (yalnızca gösterim; güvenlikte rolü yok).
const deviceKindComputer = 'bilgisayar';

/// Eş türü: bilinmeyen/eksik ise platformdan tahmin edilir (eski sürüm bilgisayar
/// `tur` göndermez: linux → bilgisayar, android → telefon).
String cleanPeerKind(Object? kind, {String? platform}) {
  if (kind == deviceKindComputer || kind == deviceKindTablet || kind == deviceKindPhone) return kind! as String;
  return platform == 'android' ? deviceKindPhone : deviceKindComputer;
}

/// Eşleşebilen telefon/tablet platformları. Windows ve diğerleri reddedilir.
/// Not: platform karşı tarafın kendi beyanıdır; asıl kilit ekrandaki kod ve
/// ondan türeyen anahtardır.
const acceptedPhonePlatforms = {'android'};

/// Bir cihazın veri gönderdiği ALICI (sunucu) platformları: Linux bilgisayar ve
/// (v9.23) ekranı açıkken alıcı olabilen Android telefon/tablet. Windows ve
/// diğerleri reddedilir. Alıcı Android'in ek kuralları: yalnızca Android istemci
/// eşleşir (`acceptedPhonePlatforms`), arka plan servisi yoktur, tam yedek (ZIP)
/// içe aktarmaz (404); kayıtlar defter ve tam durumla taşınır.
const acceptedComputerPlatforms = {'linux', 'android'};

/// Kanıt etiketleri: aynı anahtarla üretilen imzalar birbirinin yerine
/// kullanılamasın diye her biri ayrı etiketle başlar.
abstract final class ProofLabels {
  static const phonePair = 'telefon-eslesme';
  static const computerPair = 'bilgisayar-eslesme';
  static const phoneSession = 'telefon-oturum';
  static const computerSession = 'bilgisayar-oturum';
  static const request = 'istek';
  static const response = 'yanit';
}

class SyncException implements Exception {
  const SyncException(this.message, {this.status});

  /// Kullanıcıya gösterilecek Türkçe açıklama.
  final String message;

  /// HTTP durum kodu (varsa).
  final int? status;

  @override
  String toString() => message;
}

// ───────────── Bulma (UDP) ─────────────

const discoveryProbeTag = 'KOCUM-ARA/1';

/// Bulma isteği yanıttan uzun olsun diye boşlukla doldurulur: bilgisayar,
/// sahte adresli küçük bir istekle başka bir cihaza büyütülmüş trafik
/// yollamaya alet edilemez.
const discoveryProbeLength = 512;

List<int> discoveryProbe() {
  final tag = ascii.encode(discoveryProbeTag);
  return [...tag, ...List<int>.filled(discoveryProbeLength - tag.length, 0x20)];
}

bool isDiscoveryProbe(List<int> data) {
  if (data.length != discoveryProbeLength) return false;
  final tag = ascii.encode(discoveryProbeTag);
  for (var i = 0; i < tag.length; i++) {
    if (data[i] != tag[i]) return false;
  }
  return true;
}

/// Bilgisayarın bulma yanıtı.
class DiscoveryReply {
  const DiscoveryReply({required this.id, required this.name, required this.port, required this.platform});

  final String id;
  final String name;
  final int port;
  final String platform;

  Map<String, Object?> toJson() => {
        'uygulama': syncAppName,
        'surum': syncProtocolVersion,
        'id': id,
        'ad': name,
        'port': port,
        'platform': platform,
      };

  /// Bozuk ya da başka bir uygulamadan gelen yanıt → null.
  static DiscoveryReply? tryParse(List<int> data) {
    if (data.length > 2048) return null;
    try {
      final j = jsonDecode(utf8.decode(data));
      if (j is! Map) return null;
      final m = j.cast<String, Object?>();
      if (m['uygulama'] != syncAppName || m['surum'] != syncProtocolVersion) return null;
      final id = m['id'], name = m['ad'], port = m['port'], platform = m['platform'];
      if (id is! String || !isValidDeviceId(id)) return null;
      if (name is! String || port is! int || port <= 0 || port > 65535 || platform is! String) return null;
      return DiscoveryReply(id: id, name: cleanDeviceName(name), port: port, platform: platform);
    } on FormatException {
      return null;
    }
  }
}

// ───────────── Kimlik ve ad ─────────────

final _deviceId = RegExp(r'^[A-Za-z0-9_-]{8,64}$');

bool isValidDeviceId(String id) => _deviceId.hasMatch(id);

/// Ekranda gösterilecek cihaz adı: kontrol karakterleri atılır, kısaltılır.
String cleanDeviceName(String name) {
  final clean = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '').trim();
  if (clean.isEmpty) return 'Adsız cihaz';
  return clean.length <= SyncLimits.nameLength ? clean : clean.substring(0, SyncLimits.nameLength);
}

/// Gerçek ad yerine kimlikten türeyen kısa etiket ("Android · 4F2A").
String deviceLabel(String kind, String id) =>
    '$kind · ${(id.length >= 4 ? id.substring(0, 4) : id).toUpperCase()}';

// ───────────── Mesajlar ─────────────

Map<String, Object?> _map(Object? json) {
  if (json is Map) return json.cast<String, Object?>();
  throw const SyncException('Bozuk mesaj.');
}

String _str(Map<String, Object?> m, String key) {
  final v = m[key];
  if (v is String) return v;
  throw SyncException('Bozuk mesaj: "$key" eksik.');
}

String? _strOrNull(Map<String, Object?> m, String key) {
  final v = m[key];
  return v is String ? v : null;
}

bool _bool(Map<String, Object?> m, String key) => m[key] == true;

/// GET merhaba yanıtı: kimlik, durum ve tek kullanımlık meydan okuma.
class SyncHello {
  const SyncHello({
    required this.id,
    required this.name,
    required this.platform,
    required this.pairingOpen,
    required this.paired,
    required this.challenge,
    this.dhPublic,
    this.kind,
  });

  final String id;
  final String name;
  final String platform;

  /// Alıcının türü: `bilgisayar | telefon | tablet` (eski sürüm göndermez: null).
  final String? kind;

  /// Bilgisayarda kod ekranı açık mı?
  final bool pairingOpen;

  /// Bilgisayarın cihaz yuvaları dolu mu? (v9.15: en çok [SyncLimits.maxDevices] cihaz;
  /// anahtar adı eski sürümlerle uyum için `eslesmis` kaldı.) Doluysa yeni eşleşme olmaz.
  final bool paired;

  /// Bir sonraki istekte kullanılacak tek seferlik değer.
  final String challenge;

  /// Eşleştirme açıkken bilgisayarın Diffie-Hellman açık değeri.
  final String? dhPublic;

  Map<String, Object?> toJson() => {
        'uygulama': syncAppName,
        'surum': syncProtocolVersion,
        'id': id,
        'ad': name,
        'platform': platform,
        'eslesmeAcik': pairingOpen,
        'eslesmis': paired,
        'meydanOkuma': challenge,
        if (dhPublic != null) 'dh': dhPublic,
        if (kind != null) 'tur': kind,
      };

  factory SyncHello.fromJson(Object? json) {
    final m = _map(json);
    if (m['uygulama'] != syncAppName) throw const SyncException('Bu adreste Koçum yok.');
    if (m['surum'] != syncProtocolVersion) {
      throw const SyncException('Bilgisayardaki Koçum farklı sürümde; iki tarafı da güncelle.');
    }
    final id = _str(m, 'id');
    if (!isValidDeviceId(id)) throw const SyncException('Bozuk mesaj: kimlik.');
    return SyncHello(
      id: id,
      name: cleanDeviceName(_str(m, 'ad')),
      platform: _str(m, 'platform'),
      pairingOpen: _bool(m, 'eslesmeAcik'),
      paired: _bool(m, 'eslesmis'),
      challenge: _str(m, 'meydanOkuma'),
      dhPublic: _strOrNull(m, 'dh'),
      kind: _strOrNull(m, 'tur'),
    );
  }
}

class PairRequest {
  const PairRequest({
    required this.challenge,
    required this.phoneId,
    required this.name,
    required this.platform,
    required this.dhPublic,
    required this.proof,
    this.kind = deviceKindPhone,
  });

  final String challenge;
  final String phoneId;
  final String name;
  final String platform;
  final String dhPublic;

  /// `telefon` ya da `tablet` (yalnızca gösterim; imzaya girmez).
  final String kind;

  /// Telefonun, ekrandaki kodla türettiği anahtarı bildiğinin kanıtı.
  final String proof;

  Map<String, Object?> toJson() => {
        'meydanOkuma': challenge,
        'telefonId': phoneId,
        'ad': name,
        'platform': platform,
        'dh': dhPublic,
        'kanit': proof,
        'tur': kind,
      };

  factory PairRequest.fromJson(Object? json) {
    final m = _map(json);
    return PairRequest(
      challenge: _str(m, 'meydanOkuma'),
      phoneId: _str(m, 'telefonId'),
      name: _str(m, 'ad'),
      platform: _str(m, 'platform'),
      dhPublic: _str(m, 'dh'),
      proof: _str(m, 'kanit'),
      kind: cleanDeviceKind(m['tur']),
    );
  }
}

class PairResponse {
  const PairResponse({required this.id, required this.name, required this.platform, required this.proof});

  final String id;
  final String name;
  final String platform;

  /// Bilgisayarın da aynı anahtarı (yani aynı kodu) bildiğinin kanıtı.
  final String proof;

  Map<String, Object?> toJson() => {'id': id, 'ad': name, 'platform': platform, 'kanit': proof};

  factory PairResponse.fromJson(Object? json) {
    final m = _map(json);
    return PairResponse(
      id: _str(m, 'id'),
      name: cleanDeviceName(_str(m, 'ad')),
      platform: _str(m, 'platform'),
      proof: _str(m, 'kanit'),
    );
  }
}

class SessionRequest {
  const SessionRequest({required this.phoneId, required this.challenge, required this.proof});

  final String phoneId;
  final String challenge;
  final String proof;

  Map<String, Object?> toJson() => {'telefonId': phoneId, 'meydanOkuma': challenge, 'kanit': proof};

  factory SessionRequest.fromJson(Object? json) {
    final m = _map(json);
    return SessionRequest(phoneId: _str(m, 'telefonId'), challenge: _str(m, 'meydanOkuma'), proof: _str(m, 'kanit'));
  }
}

class SessionResponse {
  const SessionResponse({required this.session, required this.proof});

  final String session;
  final String proof;

  Map<String, Object?> toJson() => {'oturum': session, 'kanit': proof};

  factory SessionResponse.fromJson(Object? json) {
    final m = _map(json);
    return SessionResponse(session: _str(m, 'oturum'), proof: _str(m, 'kanit'));
  }
}

/// Telefondaki bir fotoğraf: medya köküne göre yol ve bayt boyutu.
class MediaEntry {
  const MediaEntry(this.path, this.size);

  final String path;
  final int size;

  @override
  bool operator ==(Object other) => other is MediaEntry && other.path == path && other.size == size;

  @override
  int get hashCode => Object.hash(path, size);
}

class PhotoListRequest {
  const PhotoListRequest(this.photos);

  final List<MediaEntry> photos;

  Map<String, Object?> toJson() => {
        'fotograflar': [
          for (final e in photos) {'yol': e.path, 'boyut': e.size},
        ],
      };

  factory PhotoListRequest.fromJson(Object? json) {
    final list = _map(json)['fotograflar'];
    if (list is! List) throw const SyncException('Bozuk mesaj: fotoğraf listesi.');
    if (list.length > SyncLimits.photoListLength) throw const SyncException('Fotoğraf listesi çok uzun.');
    return PhotoListRequest([
      for (final e in list)
        if (e is Map && e['yol'] is String && e['boyut'] is int) MediaEntry(e['yol'] as String, e['boyut'] as int),
    ]);
  }
}

class PhotoListResponse {
  const PhotoListResponse({required this.missing, required this.rejected});

  /// Bilgisayarda olmayan (ya da yarım kalmış) fotoğraflar.
  final List<String> missing;

  /// Yolu kurallara uymadığı için alınmayacak olanlar.
  final int rejected;

  Map<String, Object?> toJson() => {'eksik': missing, 'reddedilen': rejected};

  factory PhotoListResponse.fromJson(Object? json) {
    final m = _map(json);
    final list = m['eksik'];
    if (list is! List) throw const SyncException('Bozuk mesaj: eksik listesi.');
    final rejected = m['reddedilen'];
    return PhotoListResponse(missing: [for (final e in list) if (e is String) e], rejected: rejected is int ? rejected : 0);
  }
}

class BackupResponse {
  const BackupResponse(this.summary);

  /// Bilgisayarın içe aktarma özeti ("12 yeni, 3 güncellenen…").
  final String summary;

  Map<String, Object?> toJson() => {'ozet': summary};

  factory BackupResponse.fromJson(Object? json) => BackupResponse(_str(_map(json), 'ozet'));
}

/// Hata yanıtının gövdesi.
Map<String, Object?> syncErrorJson(String message) => {'hata': message};
