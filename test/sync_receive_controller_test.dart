import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/features/sync/data/server_sync_store.dart';
import 'package:kocum/features/sync/data/sync_client.dart';
import 'package:kocum/features/sync/presentation/receive_controller.dart';
import 'package:kocum/features/sync/domain/sync_protocol.dart';

class _Media implements MediaStorage {
  _Media(this.root);
  final Directory root;
  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) => throw UnimplementedError();
  @override
  Future<void> delete(String relativePath) => throw UnimplementedError();
  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

/// Android alıcı: ekran açıkken çalışır, arka plana gidince durur, öne gelince (açık bırakıldıysa)
/// yeniden başlar; eşleşmeler kalıcıdır. Gerçek sunucu 127.0.0.1'de.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    HttpOverrides.global = null;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    tmp = await Directory.systemTemp.createTemp('kocum_alici_');
    db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      mediaStorageProvider.overrideWithValue(_Media(Directory('${tmp.path}/media'))),
      receiveEnvProvider.overrideWith((ref) async => ReceiveEnv(
            store: ServerSyncStore(File('${tmp.path}/alici.json'), label: 'Tablet'),
            mediaRoot: Directory('${tmp.path}/media'),
            pdfRoot: Directory('${tmp.path}/pdfs'),
            workDir: Directory('${tmp.path}/is'),
            platform: 'android',
            port: 0,
            discoveryPort: null,
          )),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(ok(), isTrue);
  }

  test('açılınca dinler ve kod verir; arka plana gidince durur, öne gelince yeniden başlar; eşleşme kalır', () async {
    final sub = container.listen(receiveControllerProvider, (_, _) {});
    final controller = container.read(receiveControllerProvider.notifier);
    await until(() => container.read(receiveControllerProvider).name != null);
    expect(container.read(receiveControllerProvider).enabled, isFalse);
    expect(container.read(receiveControllerProvider).running, isFalse);

    await controller.setEnabled(true, isTablet: true);
    await until(() => container.read(receiveControllerProvider).running);
    var s = container.read(receiveControllerProvider);
    expect(s.kind, deviceKindTablet);
    await controller.startPairing();
    s = container.read(receiveControllerProvider);
    expect(s.pairing?.code, matches(RegExp(r'^\d{6}$')));

    // Başka cihaz kodla eşleşir.
    final client = SyncClient(allowLoopback: true);
    final port = s.port!;
    // Test sunucusu yalnızca 127.0.0.1'i kabul etmez (allowLoopback kapalı): hello 403 olmalı.
    await expectLater(client.hello('127.0.0.1', port), throwsA(isA<SyncException>().having((e) => e.status, 'durum', 403)));
    client.close();

    // Arka plana geç: sunucu durur, "açık" tercihi ve eşleşmeler korunur.
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await until(() => !container.read(receiveControllerProvider).running);
    expect(container.read(receiveControllerProvider).enabled, isTrue);
    final probe = await Socket.connect('127.0.0.1', port).then<Object?>((s) => s..destroy(), onError: (Object e) => e);
    expect(probe, isA<SocketException>(), reason: 'arka planda dinleme yok');

    // Öne gel: yeniden başlar.
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(() => container.read(receiveControllerProvider).running);

    // Kapat: durur ve arka plana gidip gelmek yeniden başlatmaz.
    await controller.setEnabled(false);
    await until(() => !container.read(receiveControllerProvider).running);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(container.read(receiveControllerProvider).running, isFalse);
    sub.close();
  });
}
