import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/sync_crypto.dart';
import '../domain/sync_protocol.dart';

/// Alıcıyla (bilgisayar ya da ekranı açık Android) eşleşmiş bir cihaz. Her cihazın kendi kimliği
/// ve kendi anahtarı vardır (anahtarlar birbirinden bağımsız türetilir).
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.key,
    required this.pairedAt,
    this.kind = deviceKindPhone,
    this.lastSyncAt,
  });

  final String id;
  final String name;
  final String platform;

  /// `telefon` ya da `tablet` (yalnızca gösterim).
  final String kind;

  /// Eşleştirmede iki tarafta ayrı ayrı türetilen anahtar (32 bayt).
  final List<int> key;
  final DateTime pairedAt;

  /// Son başarılı değişiklik alışverişi.
  final DateTime? lastSyncAt;

  bool get isTablet => kind == deviceKindTablet;

  PairedDevice copyWith({DateTime? lastSyncAt}) => PairedDevice(
        id: id,
        name: name,
        platform: platform,
        key: key,
        pairedAt: pairedAt,
        kind: kind,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'ad': name,
        'platform': platform,
        'tur': kind,
        'anahtar': base64.encode(key),
        'eslesme': pairedAt.toIso8601String(),
        if (lastSyncAt != null) 'sonEsitleme': lastSyncAt!.toIso8601String(),
      };

  static PairedDevice? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['ad'], platform = json['platform'], key = json['anahtar'];
    final at = DateTime.tryParse('${json['eslesme']}');
    if (id is! String || name is! String || platform is! String || key is! String || at == null) return null;
    try {
      final bytes = base64.decode(key);
      if (bytes.length != 32) return null;
      return PairedDevice(
        id: id,
        name: name,
        platform: platform,
        key: bytes,
        pairedAt: at,
        kind: cleanDeviceKind(json['tur']),
        lastSyncAt: DateTime.tryParse('${json['sonEsitleme']}'),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Eski ad (v9.14 ve öncesi tek telefon); yeni kod [PairedDevice] kullanır.
typedef PairedPhone = PairedDevice;

/// Kablosuz almanın kalıcı durumu: alıcının kimliği, açık/kapalı ve eşleşmiş
/// cihazlar (en çok [SyncLimits.maxDevices]). Veritabanında değil ayrı dosyada
/// durur (bilgisayar: ~/.local/share/…/esitleme.json; Android: uygulamanın kendi
/// klasöründe `alici.json`): anahtar hiçbir yedeğe ve kablosuz eşitlemeye karışmaz.
///
/// v9.23: bilgisayara özgü değildir; Android alıcı (ekran açıkken) de kullanır.
/// [label]: kullanıcı ad vermediyse kimlikten türeyen ad öneki ("Bilgisayar", "Tablet").
///
/// Biçim: `{id, acik, cihazlar: [...]}`. Eski tek cihazlı biçim (`telefon: {...}`)
/// okunurken `cihazlar` listesine taşınır; eşleşme bozulmaz.
class ServerSyncStore {
  ServerSyncStore(this.file, {Random? random, this.label = 'Bilgisayar'}) : _random = random ?? Random.secure();

  final File file;
  final String label;
  final Random _random;
  Map<String, Object?>? _cache;

  /// Eşzamanlı isteklerin dosyaya yazımı sırayla olur (ortak geçici dosya çakışmasın).
  Future<void> _tail = Future<void>.value();

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map<String, Object?>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    Map<String, Object?> data = {};
    if (await file.exists()) {
      try {
        final v = jsonDecode(await file.readAsString());
        if (v is Map) data = v.cast<String, Object?>();
      } on FormatException {
        // Bozuk dosya: yeni kimlik ve eşleşmesiz başlanır; dosya bir sonraki
        // yazmada düzelir. (Eski cihazlar yeniden eşleştirilmelidir.)
      }
    }
    var dirty = false;
    final id = data['id'];
    if (id is! String || !isValidDeviceId(id)) {
      data['id'] = toHex(randomBytes(_random, 12));
      dirty = true;
    }
    // Eski tek cihaz biçimi: `telefon` → `cihazlar`.
    final legacy = data['telefon'];
    if (legacy != null) {
      final list = _rawDevices(data);
      final old = PairedDevice.tryParse(legacy);
      if (old != null && !list.any((d) => d['id'] == old.id)) list.add(old.toJson());
      data['cihazlar'] = list;
      data.remove('telefon');
      dirty = true;
    }
    _cache = data;
    if (dirty) await _save();
    return data;
  }

  static List<Map<String, Object?>> _rawDevices(Map<String, Object?> data) {
    final v = data['cihazlar'];
    return [
      if (v is List)
        for (final e in v)
          if (e is Map) e.cast<String, Object?>(),
    ];
  }

  Future<void> _save() async {
    final data = _cache ?? {};
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.yaziliyor');
    await temp.writeAsString(const JsonEncoder.withIndent(' ').convert(data), flush: true);
    await _ownerOnly(temp);
    await temp.rename(file.path);
  }

  /// Anahtar dosyasını yalnızca bu kullanıcı okuyabilsin.
  static Future<void> _ownerOnly(File f) async {
    try {
      await Process.run('chmod', ['600', f.path]);
    } on ProcessException {
      // chmod yoksa dosya varsayılan izinlerle kalır.
    }
  }

  Future<String> computerId() => _exclusive(() async => (await _load())['id']! as String);

  /// Kullanıcının verdiği ad (varsa), yoksa kimlikten türeyen etiket.
  Future<String> computerName() async {
    final custom = (await _exclusive(() async => (await _load())['ad']));
    if (custom is String && custom.trim().isNotEmpty) return cleanDeviceName(custom);
    return deviceLabel(label, await computerId());
  }

  /// Alıcının türü (`telefon | tablet | bilgisayar`); yalnızca gösterim.
  Future<String> kind() async {
    final v = await _exclusive(() async => (await _load())['tur']);
    return cleanPeerKind(v, platform: label == 'Bilgisayar' ? 'linux' : 'android');
  }

  Future<void> setKind(String kind) => _exclusive(() async {
        (await _load())['tur'] = cleanPeerKind(kind);
        await _save();
      });

  Future<void> setName(String name) => _exclusive(() async {
        (await _load())['ad'] = cleanDeviceName(name);
        await _save();
      });

  Future<bool> enabled() => _exclusive(() async => (await _load())['acik'] == true);

  Future<void> setEnabled(bool value) => _exclusive(() async {
        (await _load())['acik'] = value;
        await _save();
      });

  /// Eşleşmiş cihazlar (eşleşme sırasıyla).
  Future<List<PairedDevice>> devices() => _exclusive(() async => _devicesOf(await _load()));

  static List<PairedDevice> _devicesOf(Map<String, Object?> data) => [
        for (final e in _rawDevices(data))
          if (PairedDevice.tryParse(e) case final d?) d,
      ];

  Future<PairedDevice?> device(String id) async {
    for (final d in await devices()) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// Eski ad: ilk eşleşmiş cihaz ya da null.
  Future<PairedDevice?> phone() async => (await devices()).firstOrNull;

  /// Yeni cihazı kaydeder. Aynı kimlik varsa yenilenir (yeniden eşleşme: kod
  /// bilindiği için anahtar değişir). Dolu ise ve cihaz yeniyse [SyncException].
  Future<void> saveDevice(PairedDevice device) => _exclusive(() async {
        final data = await _load();
        final list = _rawDevices(data);
        final at = list.indexWhere((d) => d['id'] == device.id);
        if (at < 0 && list.length >= SyncLimits.maxDevices) {
          throw const SyncException(
            'Bu cihaz en çok ${SyncLimits.maxDevices} cihazla eşleşebilir. Önce birini kaldır.',
            status: 409,
          );
        }
        if (at < 0) {
          list.add(device.toJson());
        } else {
          list[at] = device.toJson();
        }
        data['cihazlar'] = list;
        await _save();
      });

  /// Eski ad.
  Future<void> savePhone(PairedDevice device) => saveDevice(device);

  /// Yalnızca bu cihaz kalkar; öbürleri etkilenmez.
  Future<void> removeDevice(String id) => _exclusive(() async {
        final data = await _load();
        final list = _rawDevices(data)..removeWhere((d) => d['id'] == id);
        data['cihazlar'] = list;
        await _save();
      });

  Future<void> removeAllDevices() => _exclusive(() async {
        (await _load())['cihazlar'] = <Object?>[];
        await _save();
      });

  /// Eski ad: hepsini kaldırır.
  Future<void> removePhone() => removeAllDevices();

  /// Son eşitleme zamanını yazar (cihaz yoksa sessizce geçer).
  Future<void> touchDevice(String id, DateTime at) => _exclusive(() async {
        final data = await _load();
        final list = _rawDevices(data);
        final i = list.indexWhere((d) => d['id'] == id);
        if (i < 0) return;
        list[i] = {...list[i], 'sonEsitleme': at.toIso8601String()};
        data['cihazlar'] = list;
        await _save();
      });
}

/// Eski ad (v9.22 ve öncesi yalnızca bilgisayar); yeni kod [ServerSyncStore] kullanır.
typedef DesktopSyncStore = ServerSyncStore;
