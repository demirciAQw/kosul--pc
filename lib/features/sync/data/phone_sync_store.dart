import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/sync_crypto.dart';
import '../domain/sync_protocol.dart';

/// Telefonun eşleştiği tek bilgisayar.
class PairedComputer {
  const PairedComputer({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.key,
    required this.pairedAt,
    this.lastSentAt,
  });

  final String id;
  final String name;

  /// Son bilinen adres; değişirse bulma ile kimliğe göre yeniden bulunur.
  final String host;
  final int port;

  /// Eşleştirmede iki tarafta ayrı ayrı türetilen anahtar (32 bayt).
  final List<int> key;
  final DateTime pairedAt;
  final DateTime? lastSentAt;

  String get address => '$host:$port';

  PairedComputer copyWith({String? host, int? port, DateTime? lastSentAt}) => PairedComputer(
        id: id,
        name: name,
        host: host ?? this.host,
        port: port ?? this.port,
        key: key,
        pairedAt: pairedAt,
        lastSentAt: lastSentAt ?? this.lastSentAt,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'ad': name,
        'adres': host,
        'port': port,
        'anahtar': base64.encode(key),
        'eslesme': pairedAt.toIso8601String(),
        if (lastSentAt != null) 'sonGonderim': lastSentAt!.toIso8601String(),
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

  Future<PairedComputer?> computer() async => PairedComputer.tryParse((await _load())['bilgisayar']);

  /// En fazla bir bilgisayar: başka bir bilgisayar varken yenisi kaydedilmez
  /// (aynı bilgisayarın adresi ya da son gönderim tarihi güncellenebilir).
  Future<void> saveComputer(PairedComputer computer) async {
    final data = await _load();
    final existing = PairedComputer.tryParse(data['bilgisayar']);
    if (existing != null && existing.id != computer.id) {
      throw const SyncException('Telefon zaten bir bilgisayarla eşleşmiş. Önce o eşleşmeyi kaldır.');
    }
    data['bilgisayar'] = computer.toJson();
    await _save();
  }

  Future<void> removeComputer() async {
    (await _load()).remove('bilgisayar');
    await _save();
  }
}
