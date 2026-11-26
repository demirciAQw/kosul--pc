import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/di/core_providers.dart';

/// Defter görünümü: sürekli dikey akış ya da tek sayfa.
enum NoteViewMode {
  flow('akis'),
  single('tek');

  const NoteViewMode(this.key);
  final String key;

  static NoteViewMode parse(String? v) => v == 'tek' ? single : flow;
}

/// Görünüm tercihi `app_meta` `defter.gorunum` (varsayılan akış). Cihaza özel; okunamazsa akış.
class NoteViewModeStore {
  NoteViewModeStore(this._db);
  final AppDatabase _db;

  static const metaKey = 'defter.gorunum';

  Future<NoteViewMode> load() async {
    try {
      final row = await (_db.select(_db.appMeta)..where((m) => m.metaKey.equals(metaKey))).getSingleOrNull();
      return NoteViewMode.parse(row?.metaValue);
    } catch (_) {
      return NoteViewMode.flow;
    }
  }

  Future<void> save(NoteViewMode m) =>
      _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: metaKey, metaValue: m.key));
}

final noteViewModeStoreProvider = Provider((ref) => NoteViewModeStore(ref.watch(appDatabaseProvider)));
