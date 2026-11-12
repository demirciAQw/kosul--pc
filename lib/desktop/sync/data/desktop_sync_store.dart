import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../../features/sync/domain/sync_crypto.dart';
import '../../../features/sync/domain/sync_protocol.dart';

/// Bilgisayarla eşleşmiş tek telefon (ya da tablet).
class PairedPhone {
  const PairedPhone({
    required this.id,
    required this.name,
    required this.platform,
    required this.key,
    required this.pairedAt,
  });

  final String id;
  final String name;
  final String platform;

  /// Eşleştirmede iki tarafta ayrı ayrı türetilen anahtar (32 bayt).
  final List<int> key;
  final DateTime pairedAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'ad': name,
        'platform': platform,
        'anahtar': base64.encode(key),
        'eslesme': pairedAt.toIso8601String(),
      };

  static PairedPhone? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['ad'], platform = json['platform'], key = json['anahtar'];
    final at = DateTime.tryParse('${json['eslesme']}');
    if (id is! String || name is! String || platform is! String || key is! String || at == null) return null;
    try {
      final bytes = base64.decode(key);
      if (bytes.length != 32) return null;
      return PairedPhone(id: id, name: name, platform: platform, key: bytes, pairedAt: at);
    } on FormatException {
      return null;
    }
  }
}

/// Kablosuz almanın kalıcı durumu: bilgisayarın kimliği, açık/kapalı ve
/// eşleşmiş telefon. Veritabanında değil ayrı dosyada durur
/// (~/.local/share/…/esitleme.json): anahtar hiçbir yedeğe karışmaz.
class DesktopSyncStore {
  DesktopSyncStore(this.file, {Random? random}) : _random = random ?? Random.secure();

  final File file;
  final Random _random;
  Map<String, Object?>? _cache;

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
        // yazmada düzelir. (Eski telefon yeniden eşleştirilmelidir.)
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

  Future<String> computerId() async => (await _load())['id']! as String;

  Future<String> computerName() async => deviceLabel('Bilgisayar', await computerId());

  Future<bool> enabled() async => (await _load())['acik'] == true;

  Future<void> setEnabled(bool value) async {
    (await _load())['acik'] = value;
    await _save();
  }

  Future<PairedPhone?> phone() async => PairedPhone.tryParse((await _load())['telefon']);

  /// En fazla bir telefon: varken yenisi kaydedilmez.
  Future<void> savePhone(PairedPhone phone) async {
    final data = await _load();
    if (PairedPhone.tryParse(data['telefon']) != null) {
      throw const SyncException('Bu bilgisayar zaten bir telefonla eşleşmiş.', status: 409);
    }
    data['telefon'] = phone.toJson();
    await _save();
  }

  Future<void> removePhone() async {
    (await _load()).remove('telefon');
    await _save();
  }
}
