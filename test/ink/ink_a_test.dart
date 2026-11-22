import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/data/ink_a_controller.dart';
import 'package:kocum/features/ink/domain/ink_channel_codec.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> native(int view, String method, Object? args) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall(method, args));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(inkChannelName(view), data, (_) {});
  }

  test('Dart→yerel çağrılar sözleşmeye uyar; yerel→Dart olaylar akışa düşer', () async {
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(MethodChannel(inkChannelName(9)), (c) async {
      calls.add(c);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(inkChannelName(9)), null));

    final a = InkAController();
    addTearDown(a.dispose);
    // Görünüm oluşmadan: saklanır, çağrı gitmez.
    a.setBrush(const InkBrush(tool: InkTool.highlighter, color: 0x80FFEB3B, width: 12));
    a.clear();
    expect(calls, isEmpty);

    a.attach(9);
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'setInputMode');
    expect(calls.single.arguments, {'stylusOnly': true});

    a.setBrush(const InkBrush());
    a.clear();
    a.setInputMode(stylusOnly: false);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((c) => c.method), ['setInputMode', 'setBrush', 'clear', 'setInputMode']);
    expect(calls[1].arguments, {'tool': 'pen', 'color': 0xFF1B1B1F, 'width': 3.0});
    expect(calls[3].arguments, {'stylusOnly': false});
    expect(a.stylusOnly, isFalse);

    final got = <InkEvent>[];
    a.events.listen(got.add);
    await native(9, 'strokeStart', {'id': 1, 'x': 1.0, 'y': 2.0, 'pressure': 0.4, 'tilt': 0.1, 't': 10});
    await native(9, 'strokePoint', {'id': 1, 'x': 3.0, 'y': 4.0, 'pressure': 0.5, 'tilt': 0.1, 't': 20});
    await native(9, 'strokeEnd', {'id': 1, 'x': 5.0, 'y': 6.0, 'pressure': 0.0, 'tilt': 0.0, 't': 30});
    await native(9, 'strokePoint', {'id': 1}); // bozuk: yok sayılır
    await Future<void>.delayed(Duration.zero);
    expect(got.map((e) => e.runtimeType), [InkStrokeStart, InkStrokePoint, InkStrokeEnd]);
    expect(got.last.point!.x, 5.0);
    await native(9, 'strokeCancel', {'id': 2});
    await Future<void>.delayed(Duration.zero);
    expect(got.last, isA<InkStrokeCancel>());

    a.detach();
    expect(a.attached, isFalse);
  });
}
