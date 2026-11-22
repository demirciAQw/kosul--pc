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
import 'desktop/desktop_main.dart';
import 'features/curriculum/data/curriculum_data.dart';
import 'features/settings/settings_providers.dart';

/// Kompozisyon kökü: asenkron altyapı burada kurulur ve DI'a verilir.
Future<void> main() async {
  // Bilgisayar uygulaması ayrı kökten başlar; telefon akışı aşağıda aynen kalır.
  if (isDesktop) return runDesktop();

  WidgetsFlutterBinding.ensureInitialized();

  // Android 15 uygulamaları kenardan kenara çizer. Bunu her sürümde aynı
  // yapıyoruz; üst ve alt boşlukları AppBar, SafeArea ve NavigationBar bırakır.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));

  final database = AppDatabase(driftDatabase(name: 'kocum'));
  final media = await LocalMediaStorage.open();
  final chronometer = SessionChronometer();
  final reminders = ReminderService();
  await Future.wait<void>([
    CurriculumSeeder(database).run(),
    chronometer.init(),
    reminders.init(),
  ]);

  runApp(ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      mediaStorageProvider.overrideWithValue(media),
      sessionChronometerProvider.overrideWithValue(chronometer),
      reminderServiceProvider.overrideWithValue(reminders),
    ],
    child: const KocumApp(),
  ));
}
