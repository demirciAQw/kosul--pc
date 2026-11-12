import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/import_models.dart';

/// Bilgisayar uygulamasının kendi durumu: app_meta tablosunda "masaustu."
/// önekiyle. İçe aktarma app_meta'yı hiç almadığı için telefondan gelen veri
/// bu ayarları ezmez.
class DesktopStateStore {
  DesktopStateStore(this._db);

  final AppDatabase _db;

  static const _lastExportedAt = 'masaustu.son_yedek_tarihi';
  static const _tombstones = 'masaustu.silinenler';
  static const _history = 'masaustu.gecmis';
  static const _watchedFolder = 'masaustu.izlenen_klasor';
  static const _coachFolder = 'masaustu.koc_klasoru';
  static const _processedFiles = 'masaustu.islenen_dosyalar';
  static const historyLimit = 30;

  Future<String?> _get(String key) async =>
      (await (_db.select(_db.appMeta)..where((m) => m.metaKey.equals(key))).getSingleOrNull())?.metaValue;

  Future<void> _set(String key, String? value) async {
    if (value == null) {
      await (_db.delete(_db.appMeta)..where((m) => m.metaKey.equals(key))).go();
    } else {
      await _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: key, metaValue: value));
    }
  }

  Future<Object?> _getJson(String key) async {
    final raw = await _get(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<DateTime?> lastExportedAt() async => DateTime.tryParse(await _get(_lastExportedAt) ?? '');
  Future<void> setLastExportedAt(DateTime at) => _set(_lastExportedAt, at.toIso8601String());

  Future<List<Object?>> _getList(String key) async {
    final v = await _getJson(key);
    return v is List ? v : const [];
  }

  Future<List<Tombstone>> tombstones() async => [
        for (final t in await _getList(_tombstones))
          if (t is Map) Tombstone.fromJson(t.cast<String, Object?>()),
      ];
  Future<void> saveTombstones(List<Tombstone> list) =>
      _set(_tombstones, jsonEncode([for (final t in list) t.toJson()]));

  Future<List<ImportSummary>> history() async => [
        for (final s in await _getList(_history))
          if (s is Map) ImportSummary.fromJson(s.cast<String, Object?>()),
      ];
  Future<void> addHistory(ImportSummary s) async {
    final list = [s, ...await history()].take(historyLimit).toList();
    await _set(_history, jsonEncode([for (final x in list) x.toJson()]));
  }

  Future<String?> watchedFolder() => _get(_watchedFolder);
  Future<void> setWatchedFolder(String? path) => _set(_watchedFolder, path);

  Future<String?> coachFolder() => _get(_coachFolder);
  Future<void> setCoachFolder(String? path) => _set(_coachFolder, path);

  /// İzlenen klasörde işlenmiş dosyalar: ad → parmak izi (boyut:değişim).
  Future<Map<String, String>> processedFiles() async {
    final v = await _getJson(_processedFiles);
    return v is Map ? v.map((k, v) => MapEntry('$k', '$v')) : <String, String>{};
  }
  Future<void> markProcessed(String name, String fingerprint) async {
    final all = {...await processedFiles(), name: fingerprint};
    // Klasörde çok dosya birikse de liste sınırlı kalsın.
    final kept = Map.fromEntries(all.entries.toList().reversed.take(200).toList().reversed);
    await _set(_processedFiles, jsonEncode(kept));
  }
}
