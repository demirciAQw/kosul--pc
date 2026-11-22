import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/di/core_providers.dart';

/// Tablet sol menüsünün daraltılmış (dar ikon rayı) tercihi: `app_meta`
/// tablosunda `tablet.menu_dar` = 'true'/'false'. Cihaza özeldir. Varsayılan
/// genişletilmiş. Veritabanı yoksa/okunamazsa varsayılanla devam eder.
const tabletMenuNarrowKey = 'tablet.menu_dar';

class TabletMenuNarrow extends Notifier<bool> {
  bool _touched = false;

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final row = await (db.select(
        db.appMeta,
      )..where((m) => m.metaKey.equals(tabletMenuNarrowKey))).getSingleOrNull();
      if (!ref.mounted || _touched || row == null) return;
      state = row.metaValue == 'true';
    } catch (_) {
      // Ayar yalnızca kolaylıktır; varsayılanla devam.
    }
  }

  Future<void> set(bool narrow) async {
    _touched = true;
    state = narrow;
    try {
      final db = ref.read(appDatabaseProvider);
      await db
          .into(db.appMeta)
          .insertOnConflictUpdate(
            AppMetaCompanion.insert(
              metaKey: tabletMenuNarrowKey,
              metaValue: narrow ? 'true' : 'false',
            ),
          );
    } catch (_) {}
  }
}

final tabletMenuNarrowProvider = NotifierProvider<TabletMenuNarrow, bool>(
  TabletMenuNarrow.new,
);
