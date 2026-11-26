import 'dart:async';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';

/// Başka bir süreç (ör. `kocum` aracı) veritabanını değiştirince ekranlar
/// yenilensin: `PRAGMA data_version` yalnızca BAŞKA bağlantıların
/// değişikliğinde artar. Değişince tüm tablolara "güncellendi" haberi verilir.
class ExternalChangeWatcher {
  ExternalChangeWatcher(this._db, {this.interval = const Duration(seconds: 2)});

  final AppDatabase _db;
  final Duration interval;
  int? _last;
  Timer? _timer;
  bool _checking = false;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(check()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Bir kez bakar; dış değişiklik varsa akışlara haber verir ve true döner.
  Future<bool> check() async {
    if (_checking) return false;
    _checking = true;
    try {
      final r = await _db.customSelect('PRAGMA data_version').getSingle();
      final v = r.data.values.first as int;
      final changed = _last != null && v != _last;
      _last = v;
      if (changed) {
        _db.notifyUpdates({for (final t in _db.allTables) TableUpdate.onTable(t)});
      }
      return changed;
    } catch (_) {
      return false; // veritabanı kapanmış olabilir
    } finally {
      _checking = false;
    }
  }
}
