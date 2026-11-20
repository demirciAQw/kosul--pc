import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/di/core_providers.dart';

/// Hoş geldin ekranının görülüp görülmediği. `app_meta` defter dışındadır
/// ve yedeğe karışmaz: her cihaz kendi ilk açılışını görür.
class WelcomeRepository {
  WelcomeRepository(this._db);
  final AppDatabase _db;

  static const _key = 'app.welcome_seen';

  Future<bool> seen() async {
    final row = await (_db.select(_db.appMeta)..where((m) => m.metaKey.equals(_key))).getSingleOrNull();
    return row?.metaValue == '1';
  }

  Future<void> set(bool value) => _db.into(_db.appMeta).insertOnConflictUpdate(
        AppMetaCompanion.insert(metaKey: _key, metaValue: value ? '1' : '0'),
      );
}

final welcomeRepositoryProvider = Provider((ref) => WelcomeRepository(ref.watch(appDatabaseProvider)));

class WelcomeNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref.watch(welcomeRepositoryProvider).seen();

  Future<void> markSeen() async {
    state = const AsyncData(true);
    await ref.read(welcomeRepositoryProvider).set(true);
  }

  /// Ayarlardan "Hoş geldin ekranını tekrar göster".
  Future<void> reset() async {
    state = const AsyncData(false);
    await ref.read(welcomeRepositoryProvider).set(false);
  }
}

/// `true`: görüldü.
final welcomeSeenProvider = AsyncNotifierProvider<WelcomeNotifier, bool>(WelcomeNotifier.new);
