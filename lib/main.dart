import 'core/pen_diag_store.dart';
import 'dart:async';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/platform.dart';
import 'core/database/app_database.dart';
import 'core/di/core_providers.dart';
import 'core/media/local_media_storage.dart';
import 'core/notifications/reminder_service.dart';
import 'core/notifications/session_chronometer.dart';
import 'core/startup_trace.dart';
import 'desktop/desktop_main.dart';
import 'features/curriculum/data/curriculum_data.dart';
import 'features/ink/data/ink_overlay_host.dart';
import 'features/settings/settings_providers.dart';

/// Kompozisyon kökü: asenkron altyapı burada kurulur ve DI'a verilir.
Future<void> main() async {
  // Bilgisayar uygulaması ayrı kökten başlar; telefon akışı aşağıda aynen kalır.
  if (isDesktop) return runDesktop();

  final trace = StartupTrace.instance..mark('main-basi');
  WidgetsFlutterBinding.ensureInitialized();

  // Android 15 uygulamaları kenardan kenara çizer. Bunu her sürümde aynı
  // yapıyoruz; üst ve alt boşlukları AppBar, SafeArea ve NavigationBar bırakır.
  // İlk kareyi bekletmez (platform kanalı yanıtı beklenmez).
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));

  // Veritabanı tembel açılır; açılışı burada başlatıp medya klasörüyle paralel bekletiriz.
  final database = AppDatabase(driftDatabase(name: 'kocum'));
  final dbReady = database.customSelect('SELECT 1').get().then((_) => trace.mark('db-hazir'));
  final media = await LocalMediaStorage.open();
  await dbReady;
  unawaited(loadPenDiag(database)); // kalem giriş tanısı (kapalı varsayılan)
  unawaited(loadInkNative(database)); // yerel Ink kalemi (açık varsayılan)
  final chronometer = SessionChronometer();
  final reminders = ReminderService();

  runApp(ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      mediaStorageProvider.overrideWithValue(media),
      sessionChronometerProvider.overrideWithValue(chronometer),
      reminderServiceProvider.overrideWithValue(reminders),
    ],
    child: const KocumApp(),
  ));

  // Ağır / ilk karede gereksiz işler ilk kareden SONRA: bildirim eklentileri
  // (kullanımdan önce zaten init() beklenir) ve MEB ağacı tohumu (yalnız sürüm
  // yükselince yazar; Drift akışları sonradan günceller).
  WidgetsBinding.instance.addPostFrameCallback((_) {
    trace.mark('ilk-kare');
    unawaited(Future.wait<void>([
      chronometer.init(),
      reminders.init(),
      CurriculumSeeder(database).run(),
    ]).then((_) => trace.mark('gec-baslatmalar-bitti')).catchError((Object _) {}));
  });
}
