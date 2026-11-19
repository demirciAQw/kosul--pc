import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/database/app_database.dart';
import '../core/di/core_providers.dart';
import '../core/media/local_media_storage.dart';
import '../features/curriculum/data/curriculum_data.dart';
import 'desktop_app.dart';
import 'desktop_providers.dart';

/// Bilgisayar uygulamasının kompozisyon kökü. Telefonun arka plan işleri
/// (metin okuma kuyruğu, kamera, hatırlatıcılar, oturum bildirimi) burada hiç
/// başlamaz; veritabanı ve analizler telefonla aynıdır.
Future<void> runDesktop() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ~/.local/share/<uygulama kimliği>: Belgeler klasörü kirlenmez.
  final root = await getApplicationSupportDirectory();
  await root.create(recursive: true);
  final database = AppDatabase(driftDatabase(
    name: 'kocum',
    native: DriftNativeOptions(databasePath: () async => p.join(root.path, 'kocum.sqlite')),
  ), 'pc');
  final media = await LocalMediaStorage.openAt(Directory(p.join(root.path, desktopMediaFolder)));
  await CurriculumSeeder(database).run();

  runApp(ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      mediaStorageProvider.overrideWithValue(media),
      desktopDataDirProvider.overrideWithValue(root),
    ],
    child: const DesktopApp(),
  ));
}
