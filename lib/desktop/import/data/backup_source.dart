import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/database/database_snapshot.dart';
import '../../../core/export/zip_reader.dart';

/// Yedek JSON'unun adı (telefondaki tüm veri dışa aktarımı).
const backupJsonName = 'kocum_yedek.json';

/// Bir Koçum yedeği: telefondan gelen ZIP ya da açılmış klasör. İçinde
/// kocum_yedek.json, kocum.db (veritabanı kopyası) ve media/ (fotoğraflar).
abstract class BackupSource {
  /// Ekranda gösterilecek ad (dosya ya da klasör adı).
  String get label;

  Future<List<int>?> readJson();

  /// Veritabanı kopyasını [target]'a yazar; yedekte yoksa false.
  Future<bool> extractDatabase(File target);

  /// media/ altındaki fotoğraflar: medya köküne göre göreli yol → boyut.
  Future<Map<String, int>> mediaFiles();

  Future<List<int>> readMedia(String relativePath);

  Future<void> close();

  static Future<BackupSource> open(String path) async {
    if (await FileSystemEntity.isDirectory(path)) return _FolderBackup(Directory(path));
    return _ZipBackup._(p.basename(path), await ZipFileReader.open(File(path)));
  }
}

class _ZipBackup implements BackupSource {
  _ZipBackup._(this.label, this._zip);

  @override
  final String label;
  final ZipFileReader _zip;
  static const _media = 'media/';

  @override
  Future<List<int>?> readJson() async {
    final e = _zip.find(backupJsonName);
    return e == null ? null : _zip.read(e);
  }

  @override
  Future<bool> extractDatabase(File target) async {
    final e = _zip.find(databaseSnapshotName);
    if (e == null) return false;
    await _zip.extractTo(e, target);
    return true;
  }

  @override
  Future<Map<String, int>> mediaFiles() async => {
        for (final e in _zip.entries)
          if (e.name.startsWith(_media) && !e.isDirectory) e.name.substring(_media.length): e.size,
      };

  @override
  Future<List<int>> readMedia(String relativePath) async {
    final e = _zip.find('$_media$relativePath');
    if (e == null) throw ZipFormatException('Fotoğraf bulunamadı: $relativePath');
    return _zip.read(e);
  }

  @override
  Future<void> close() => _zip.close();
}

class _FolderBackup implements BackupSource {
  _FolderBackup(this._dir);

  final Directory _dir;

  @override
  String get label => p.basename(_dir.path);

  @override
  Future<List<int>?> readJson() async {
    final f = File(p.join(_dir.path, backupJsonName));
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<bool> extractDatabase(File target) async {
    final f = File(p.join(_dir.path, databaseSnapshotName));
    if (!await f.exists()) return false;
    await target.parent.create(recursive: true);
    await f.copy(target.path);
    return true;
  }

  @override
  Future<Map<String, int>> mediaFiles() async {
    final media = Directory(p.join(_dir.path, 'media'));
    if (!await media.exists()) return const {};
    return {
      await for (final f in media.list(recursive: true, followLinks: false))
        if (f is File) p.posix.joinAll(p.split(p.relative(f.path, from: media.path))): await f.length(),
    };
  }

  @override
  Future<List<int>> readMedia(String relativePath) =>
      File(p.joinAll([_dir.path, 'media', ...p.posix.split(relativePath)])).readAsBytes();

  @override
  Future<void> close() async {}
}
