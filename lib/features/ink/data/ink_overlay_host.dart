import 'package:flutter/foundation.dart';

import '../../../app/platform.dart';
import '../../../core/database/app_database.dart';
import 'ink_overlay_codec.dart' show InkOverlayMode;
import 'ink_overlay_controller.dart';

/// `app_meta` anahtarı: yerel Ink kalemi (varsayılan AÇIK, yalnız Android). '0' = kapalı.
const inkNativeMetaKey = 'ink.yerel';

/// Pencere başına tek Ink katmanı vardır; bu sınıf onun denetleyicisini tembel kurar, "yerel Ink
/// kalemi" anahtarını tutar ve katmanı kullanmak isteyen oturumlar arasında sahipliği belirler
/// (en son isteyen sahip; o bırakınca bir öncekine geçer).
class InkOverlayHost {
  InkOverlayHost._();
  static final InkOverlayHost instance = InkOverlayHost._();

  /// Ayarlar > Araçlar anahtarı. Kapalıyken oturumlar Flutter B yoluna döner.
  static final ValueNotifier<bool> nativeEnabled = ValueNotifier<bool>(true);

  /// Test: sahte denetleyici (Android dışında da etkin sayılır).
  @visibleForTesting
  InkOverlayController? testController;

  InkOverlayController? _controller;
  bool _probing = false;

  /// Bu platformda Ink katmanı denenir mi (Android ya da test).
  bool get supported => testController != null || isAndroid;

  /// Anahtar açık, platform destekliyor ve yerel katman yanıt veriyor.
  bool get usable => nativeEnabled.value && (controller?.available ?? false);

  /// Denetleyici (desteklenmeyen platformda null). İlk çağrıda katman yoklanır; sonuç gelince
  /// [availability] bildirir.
  InkOverlayController? get controller {
    if (!supported) return null;
    final test = testController;
    if (test != null) return test;
    final c = _controller ??= InkOverlayController();
    if (!c.available && !_probing) {
      _probing = true;
      c.probe().whenComplete(() {
        _probing = false;
        availability.value++;
      });
    }
    return c;
  }

  /// Yoklama bitince artar (dinleyen oturumlar durumu yeniden okur).
  final ValueNotifier<int> availability = ValueNotifier<int>(0);

  final List<Object> _owners = [];
  final ValueNotifier<int> ownership = ValueNotifier<int>(0);

  Object? get owner => _owners.isEmpty ? null : _owners.last;

  void claim(Object o) {
    if (_owners.isNotEmpty && identical(_owners.last, o)) return;
    _owners.remove(o);
    _owners.add(o);
    controller?.invalidate();
    ownership.value++;
  }

  void release(Object o) {
    if (!_owners.remove(o)) return;
    controller?.invalidate();
    // Sahipsiz kaldıysa yerel katmanı kapat (kalem alttaki görünüme gitsin).
    if (_owners.isEmpty) controller?.setMode(InkOverlayMode.off);
    ownership.value++;
  }

  bool isOwner(Object o) => identical(owner, o);

  @visibleForTesting
  void resetForTest() {
    _owners.clear();
    testController = null;
    nativeEnabled.value = true;
  }
}

/// Anahtarı veritabanından okur (hata ya da kayıt yoksa AÇIK).
Future<bool> loadInkNative(AppDatabase db) async {
  var on = true;
  try {
    final row = await (db.select(db.appMeta)..where((m) => m.metaKey.equals(inkNativeMetaKey))).getSingleOrNull();
    on = row?.metaValue != '0';
  } catch (_) {
    on = true;
  }
  InkOverlayHost.nativeEnabled.value = on;
  return on;
}

Future<void> saveInkNative(AppDatabase db, bool on) async {
  InkOverlayHost.nativeEnabled.value = on;
  try {
    await db
        .into(db.appMeta)
        .insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: inkNativeMetaKey, metaValue: on ? '1' : '0'));
  } catch (_) {}
}
