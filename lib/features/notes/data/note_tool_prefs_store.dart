import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/platform.dart';
import '../../../core/database/app_database.dart';
import '../../../core/di/core_providers.dart';
import '../presentation/note_tool_settings.dart';

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

/// [NoteToolSettings]i kalıcı ayara bağlar (defter ve PDF ekranları aynı anahtarı
/// paylaşır): açılışta okur, değişince kısa gecikmeyle yazar, [dispose]'ta yazar.
class NoteToolPrefsBinding {
  NoteToolPrefsBinding(this._store, this._tools) {
    _tools.addListener(_changed);
    _load();
  }
  final NoteToolPrefsStore _store;
  final NoteToolSettings _tools;
  Timer? _timer;
  Map<String, Object?>? _saved;
  bool _loaded = false;
  bool _disposed = false;

  Future<void> _load() async {
    try {
      final m = await _store.load();
      if (_disposed) return;
      _tools.restoreSizes(m);
      _saved = _tools.toPrefs();
    } catch (_) {
      // Okunamazsa varsayılanlarla devam; ayar yalnızca kolaylıktır.
    }
    _loaded = true;
  }

  void _changed() {
    if (!_loaded) return;
    final now = _tools.toPrefs();
    if (_saved != null && mapEquals(_saved, now)) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 500), _save);
  }

  void _save() {
    _timer?.cancel();
    _timer = null;
    final now = _tools.toPrefs();
    if (mapEquals(_saved, now)) return;
    _saved = now;
    _store.save(now).catchError((_) {});
  }

  /// Dinleyiciyi bırakır, bekleyen değişikliği yazar. [NoteToolSettings] sonra atılır.
  void dispose() {
    _disposed = true;
    _tools.removeListener(_changed);
    if (_loaded) _save();
    _timer?.cancel();
  }
}
