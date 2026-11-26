import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/claude_request.dart';

/// Anahtar deposu hatası. İleti sabittir (anahtar içermez).
class ApiKeyStoreException implements Exception {
  const ApiKeyStoreException(this.message);
  final String message;
  @override
  String toString() => 'ApiKeyStoreException: $message';
}

/// Anahtar veritabanında, `app_meta`'da, yedekte ve eşitlemede DEĞİL; yalnızca
/// burada (platforma özgü, uygulamaya özel) saklanır.
abstract class ApiKeyStore {
  Future<bool> exists();
  Future<ApiKey?> read();
  Future<void> save(ApiKey key);
  Future<void> delete();
}

/// Test için bellekte.
class FakeApiKeyStore implements ApiKeyStore {
  FakeApiKeyStore([this._key]);
  ApiKey? _key;
  @override
  Future<bool> exists() async => _key != null;
  @override
  Future<ApiKey?> read() async => _key;
  @override
  Future<void> save(ApiKey key) async => _key = key;
  @override
  Future<void> delete() async => _key = null;
}

/// Desteklenmeyen platform (Windows/macOS/web).
class UnsupportedApiKeyStore implements ApiKeyStore {
  const UnsupportedApiKeyStore();
  @override
  Future<bool> exists() async => false;
  @override
  Future<ApiKey?> read() async => null;
  @override
  Future<void> save(ApiKey key) => throw const ApiKeyStoreException('Bu platformda anahtar saklanamaz.');
  @override
  Future<void> delete() async {}
}

/// Android: Kotlin kanalı `kocum/secure` (tool/secure_store_patch.dart). Anahtar
/// Android Keystore'daki AES/GCM anahtarıyla şifrelenir, blob `noBackupFilesDir`
/// içindeki dosyadadır (otomatik yedeğe ve cihaz aktarımına girmez).
class AndroidApiKeyStore implements ApiKeyStore {
  AndroidApiKeyStore({MethodChannel? channel}) : _ch = channel ?? const MethodChannel('kocum/secure');
  final MethodChannel _ch;
  static const _name = 'claude';

  Never _fail() => throw const ApiKeyStoreException('Güvenli depo kullanılamadı.');

  @override
  Future<bool> exists() async {
    try {
      return await _ch.invokeMethod<bool>('varMi', {'ad': _name}) ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<ApiKey?> read() async {
    try {
      final v = await _ch.invokeMethod<String>('oku', {'ad': _name});
      return v == null || v.isEmpty ? null : ApiKey(v);
    } on PlatformException {
      _fail();
    }
  }

  @override
  Future<void> save(ApiKey key) async {
    try {
      await _ch.invokeMethod<void>('kaydet', {'ad': _name, 'deger': key.reveal()});
    } on PlatformException {
      _fail();
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _ch.invokeMethod<void>('sil', {'ad': _name});
    } on PlatformException {
      _fail();
    }
  }
}

/// Linux: `<yapılandırma>/kocum/claude_anahtar`, izin 0600 (klasör 0700).
/// Okurken dosya grup/diğer için okunabilir ya da sembolik bağsa REDDEDİLİR.
class LinuxFileApiKeyStore implements ApiKeyStore {
  LinuxFileApiKeyStore(this.dir);

  /// Varsayılan: `$XDG_CONFIG_HOME` ya da `~/.config` altında `kocum`.
  factory LinuxFileApiKeyStore.standard({Map<String, String>? env}) {
    final e = env ?? Platform.environment;
    final base = (e['XDG_CONFIG_HOME']?.isNotEmpty ?? false) ? e['XDG_CONFIG_HOME']! : '${e['HOME'] ?? '.'}/.config';
    return LinuxFileApiKeyStore(Directory('$base/kocum'));
  }

  final Directory dir;
  File get _file => File('${dir.path}/claude_anahtar');

  Future<void> _chmod(String mode, String path) async {
    final r = await Process.run('chmod', [mode, path]);
    if (r.exitCode != 0) throw const ApiKeyStoreException('Dosya izni ayarlanamadı.');
  }

  @override
  Future<bool> exists() async => await FileSystemEntity.type(_file.path, followLinks: false) == FileSystemEntityType.file;

  @override
  Future<ApiKey?> read() async {
    final type = await FileSystemEntity.type(_file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) throw const ApiKeyStoreException('Anahtar dosyası düz dosya değil; reddedildi.');
    final mode = (await _file.stat()).mode & 0x1ff;
    if (mode & 0x3f != 0) {
      throw ApiKeyStoreException(
          'Anahtar dosyasının izni çok geniş (${mode.toRadixString(8)}). "chmod 600" yap ya da anahtarı sil ve yeniden gir.');
    }
    final v = (await _file.readAsString()).trim();
    return v.isEmpty ? null : ApiKey(v);
  }

  @override
  Future<void> save(ApiKey key) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    await _chmod('700', dir.path); // dosya 0600 olana kadar başkası giremesin
    final tmp = File('${dir.path}/.claude_anahtar.$pid.tmp');
    try {
      await tmp.writeAsString('', flush: true); // boş oluştur
      await _chmod('600', tmp.path); // içerik ANCAK izinden sonra yazılır
      await tmp.writeAsString(key.reveal(), flush: true);
      await tmp.rename(_file.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  @override
  Future<void> delete() async {
    if (await FileSystemEntity.type(_file.path, followLinks: false) != FileSystemEntityType.notFound) {
      await _file.delete();
    }
  }
}
