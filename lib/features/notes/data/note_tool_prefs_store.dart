import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/platform.dart';
import '../../../core/database/app_database.dart';
import '../../../core/di/core_providers.dart';

/// Defter araç ayarlarının (kalem/fosforlu/silgi boyutu, yuva konumu) kalıcı
/// saklanması: `app_meta` tablosunda tek JSON satırı. Cihaza özeldir (yedekle
/// birleşmez). Masaüstünde `masaustu.` önekli anahtar kullanılır.
class NoteToolPrefsStore {
  NoteToolPrefsStore(this._db, {String? key}) : _key = key ?? phoneKey;
  final AppDatabase _db;
  final String _key;

  static const phoneKey = 'defter.arac_ayari';
  static const desktopKey = 'masaustu.defter.arac_ayari';

  /// Kayıtlı ayarlar; yok ya da bozuksa boş harita.
  Future<Map<String, Object?>> load() async {
    final row = await (_db.select(_db.appMeta)..where((m) => m.metaKey.equals(_key))).getSingleOrNull();
    if (row == null) return const {};
    try {
      final v = jsonDecode(row.metaValue);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> save(Map<String, Object?> prefs) =>
      _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: _key, metaValue: jsonEncode(prefs)));
}

final noteToolPrefsStoreProvider = Provider(
  (ref) => NoteToolPrefsStore(
    ref.watch(appDatabaseProvider),
    key: isDesktop ? NoteToolPrefsStore.desktopKey : NoteToolPrefsStore.phoneKey,
  ),
);
