import 'database/app_database.dart';
import 'pen_diag.dart';

/// Tanı anahtarının kalıcılığı (app_meta). Hata sessizce yutulur: tanı bir kolaylıktır.
Future<bool> loadPenDiag(AppDatabase db) async {
  try {
    final row = await (db.select(db.appMeta)..where((m) => m.metaKey.equals(penDiagMetaKey))).getSingleOrNull();
    PenDiag.enabled = row?.metaValue == '1';
  } catch (_) {
    PenDiag.enabled = false;
  }
  return PenDiag.enabled;
}

Future<void> savePenDiag(AppDatabase db, bool on) async {
  PenDiag.enabled = on;
  PenDiag.resetCounters();
  try {
    await db
        .into(db.appMeta)
        .insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: penDiagMetaKey, metaValue: on ? '1' : '0'));
  } catch (_) {}
}
