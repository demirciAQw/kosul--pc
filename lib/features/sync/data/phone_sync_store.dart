import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/sync_crypto.dart';
import '../domain/sync_protocol.dart';

/// İstemcinin eşleştiği bir eş (alıcı): bilgisayar ya da ekranı açık Android
/// telefon/tablet. Sınıf adı eski sürümden kaldı; her eşin kendi anahtarı,
/// kimliği ve adresi vardır, imleçler eş kimliğiyle ayrı tutulur.
class PairedComputer {
  const PairedComputer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.key,
    required this.pairedAt,
    this.lastSentAt,
    this.platform = 'linux',
    this.kind = deviceKindComputer,
    this.legacyCursors = false,
  });

  final String id;
  final String name;

  /// Eşin platformu (`linux` ya da `android`): tam yedek yalnızca Linux alıcıya gider.
  final String platform;

  /// `bilgisayar | telefon | tablet` (yalnızca gösterim).
  final String kind;

  /// v9.22'den göçen eş: genel (eş kimliksiz) imleçler ilk eşitlemede bu eşin
  /// imleçlerine kopyalanır (bir kez), sonra bayrak kalkar.
  final bool legacyCursors;

  bool get isAndroid => platform == 'android';

  /// Son bilinen adres; değişirse bulma ile kimliğe göre yeniden bulunur.
  final String host;
  final int port;

  /// Eşleştirmede iki tarafta ayrı ayrı türetilen anahtar (32 bayt).
  final List<int> key;
  final DateTime pairedAt;
  final DateTime? lastSentAt;

  String get address => '$host:$port';

  PairedComputer copyWith({String? host, int? port, DateTime? lastSentAt, bool? legacyCursors}) => PairedComputer(
        id: id,
        name: name,
        host: host ?? this.host,
        port: port ?? this.port,
        key: key,
        pairedAt: pairedAt,
        lastSentAt: lastSentAt ?? this.lastSentAt,
        platform: platform,
        kind: kind,
        legacyCursors: legacyCursors ?? this.legacyCursors,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'ad': name,
        'adres': host,
        'port': port,
        'anahtar': base64.encode(key),
        'eslesme': pairedAt.toIso8601String(),
        if (lastSentAt != null) 'sonGonderim': lastSentAt!.toIso8601String(),
        'platform': platform,
        'tur': kind,
        if (legacyCursors) 'eskiImlec': true,
      };

  static PairedComputer? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['ad'], host = json['adres'], port = json['port'], key = json['anahtar'];
    final at = DateTime.tryParse('${json['eslesme']}');
    if (id is! String || name is! String || host is! String || port is! int || key is! String || at == null) {
      return null;
    }
    try {
      final bytes = base64.decode(key);
      if (bytes.length != 32) return null;
      return PairedComputer(
        id: id,
        name: name,
        host: host,
        port: port,
        key: bytes,
        pairedAt: at,
        lastSentAt: DateTime.tryParse('${json['sonGonderim']}'),
        platform: json['platform'] is String ? json['platform'] as String : 'linux',
        kind: cleanPeerKind(json['tur'], platform: json['platform'] is String ? json['platform'] as String : 'linux'),
        legacyCursors: json['eskiImlec'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}

/// Telefonun kablosuz aktarım durumu: kendi kimliği ve eşleştiği bilgisayar.
/// Uygulamanın kendi klasöründe ayrı bir dosyada durur (veritabanında değil):
/// anahtar, paylaşılan yedeklere ve bilgisayara giden veritabanı kopyasına
/// hiç karışmaz.
class PhoneSyncStore {
  PhoneSyncStore(this._file, {Random? random}) : _random = random ?? Random.secure();

  final Future<File> Function() _file;
  final Random _random;
  Map<String, Object?>? _cache;

  Future<Map<String, Object?>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final file = await _file();
    Map<String, Object?> data = {};
    if (await file.exists()) {
      try {
        final v = jsonDecode(await file.readAsString());
        if (v is Map) data = v.cast<String, Object?>();
      } on FormatException {
        // Bozuk dosya: yeni kimlikle başlanır; bilgisayarla yeniden eşleşilir.
      }
    }
    final id = data['id'];
    if (id is! String || !isValidDeviceId(id)) {
      data['id'] = toHex(randomBytes(_random, 12));
      _cache = data;
      await _save();
    }
    return _cache = data;
  }

  Future<void> _save() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.yaziliyor');
    await temp.writeAsString(jsonEncode(_cache ?? {}), flush: true);
    await temp.rename(file.path);
  }

  Future<String> phoneId() async => (await _load())['id']! as String;

  /// PDF dosyalarını da bilgisayara gönder (T7). Varsayılan KAPALI: dosyalar
  /// büyük olabilir; kullanıcı kendi açar. Satırlar (belge, çizgi) bundan bağımsız gider.
  Future<bool> sendPdfs() async => (await _load())['pdfGonder'] == true;

  Future<void> setSendPdfs(bool value) async {
    (await _load())['pdfGonder'] = value;
    await _save();
  }

  /// "PDF'leri bilgisayardan al" (v9.15): bilgisayarda olup bu cihazda olmayan PDF
  /// dosyalarını eşitlemede indir. Varsayılan KAPALI (dosyalar büyük olabilir).
  Future<bool> pullPdfs() async => (await _load())['pdfAl'] == true;

  Future<void> setPullPdfs(bool value) async {
    (await _load())['pdfAl'] = value;
    await _save();
  }

  /// Bu cihazın bilgisayarda görünen adı; kullanıcı yazmadıysa null.
  Future<String?> deviceName() async {
    final v = (await _load())['cihazAdi'];
    return v is String && v.trim().isNotEmpty ? v : null;
  }

  Future<void> setDeviceName(String name) async {
    (await _load())['cihazAdi'] = cleanDeviceName(name);
    await _save();
  }

  /// Eşler (eşleşme sırasıyla). Eski tek bilgisayar kaydı (`bilgisayar:`) okunurken
  /// `esler` listesine taşınır ve `eskiImlec` bayrağı alır (eşleşme bozulmaz).
  Future<List<PairedComputer>> computers() async {
    final data = await _load();
    var dirty = false;
    final legacy = PairedComputer.tryParse(data['bilgisayar']);
    if (data.containsKey('bilgisayar')) {
      final list = _rawPeers(data);
      if (legacy != null && !list.any((e) => e['id'] == legacy.id)) {
        list.add(legacy.copyWith(legacyCursors: true).toJson());
      }
      data['esler'] = list;
      data.remove('bilgisayar');
      dirty = true;
    }
    if (dirty) await _save();
    return [
      for (final e in _rawPeers(data))
        if (PairedComputer.tryParse(e) case final c?) c,
    ];
  }

  static List<Map<String, Object?>> _rawPeers(Map<String, Object?> data) {
    final v = data['esler'];
    return [
      if (v is List)
        for (final e in v)
          if (e is Map) e.cast<String, Object?>(),
    ];
  }

  /// Eski ad: ilk eş ya da null.
  Future<PairedComputer?> computer() async => (await computers()).firstOrNull;

  Future<PairedComputer?> peer(String id) async {
    for (final c in await computers()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Eşi kaydeder; aynı kimlik varsa güncellenir (adres, son eşitleme). Yeni eş,
  /// [SyncLimits.maxPeers] doluysa [SyncException].
  Future<void> saveComputer(PairedComputer computer) async {
    final existing = await computers(); // eski kaydı da taşır
    final data = await _load();
    final list = _rawPeers(data);
    final at = list.indexWhere((e) => e['id'] == computer.id);
    if (at < 0 && existing.length >= SyncLimits.maxPeers) {
      throw const SyncException('Bu cihaz en çok ${SyncLimits.maxPeers} eşle eşleşebilir. Önce birini kaldır.');
    }
    if (at < 0) {
      list.add(computer.toJson());
    } else {
      list[at] = computer.toJson();
    }
    data['esler'] = list;
    await _save();
  }

  /// [id] verilirse yalnızca o eş, verilmezse hepsi kalkar (eski davranış).
  Future<void> removeComputer([String? id]) async {
    await computers();
    final data = await _load();
    data['esler'] = id == null ? <Object?>[] : (_rawPeers(data)..removeWhere((e) => e['id'] == id));
    await _save();
  }
}
