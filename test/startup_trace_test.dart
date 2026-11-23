import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/notifications/reminder_service.dart';
import 'package:kocum/core/notifications/session_chronometer.dart';
import 'package:kocum/core/startup_trace.dart';

class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final calls = <String>[];

  @override
  Future<bool?> initialize(InitializationSettings initializationSettings,
      {onDidReceiveNotificationResponse, onDidReceiveBackgroundNotificationResponse}) async {
    calls.add('initialize');
    return true;
  }

  @override
  Future<void> cancel(int id, {String? tag}) async => calls.add('cancel');

  @override
  Future<void> show(int id, String? title, String? body, NotificationDetails? notificationDetails,
      {String? payload}) async =>
      calls.add('show');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('StartupTrace', () {
    test('açıkken aşamaları sırayla ve bir kez yazar', () {
      final lines = <String>[];
      final t = StartupTrace(enabled: true, sink: lines.add);
      t.mark('main-basi');
      t.mark('db-hazir');
      t.mark('db-hazir');
      expect(t.marks.keys, ['main-basi', 'db-hazir']);
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('KocumStart main-basi '));
      expect(t.marks['db-hazir']! >= t.marks['main-basi']!, isTrue);
    });

    test('kapalıyken (release) hiçbir şey yazmaz ve kaydetmez', () {
      final lines = <String>[];
      final t = StartupTrace(enabled: false, sink: lines.add);
      t.mark('main-basi');
      expect(lines, isEmpty);
      expect(t.marks, isEmpty);
    });
  });

  group('ertelenen bildirim başlatması', () {
    test('ReminderService: init bir kez; kullanım init beklemeden de çalışır', () async {
      final p = _FakePlugin();
      final s = ReminderService(p);
      expect(p.calls, isEmpty); // açılışta başlatılmaz
      await s.cancel(1); // erken kullanım önce init eder
      await s.init();
      await s.init();
      expect(p.calls, ['initialize', 'cancel']);
    });

    test('SessionChronometer: hide/show öncesi init edilir, tek sefer', () async {
      final p = _FakePlugin();
      final c = SessionChronometer(p);
      await c.hide();
      await c.show(startedAt: DateTime(2026), itemCount: 2);
      expect(p.calls, ['initialize', 'cancel', 'show']);
    });
  });
}
