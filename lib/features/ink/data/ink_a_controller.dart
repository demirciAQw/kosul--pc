import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/ink_channel_codec.dart';
import '../domain/ink_models.dart';

/// A uygulaması (Android yerel, PlatformView) denetleyicisi. Sözleşme:
/// `ink_channel_codec.dart`. Görünüm oluşmadan yapılan çağrılar saklanır,
/// [attach] ile iletilir.
class InkAController implements InkSurface {
  InkAController({InkBrush brush = const InkBrush(), bool stylusOnly = true})
    : _brush = brush,
      _stylusOnly = stylusOnly;

  final _events = StreamController<InkEvent>.broadcast();
  MethodChannel? _channel;
  InkBrush _brush;
  bool _stylusOnly;

  bool get attached => _channel != null;

  @override
  Stream<InkEvent> get events => _events.stream;
  @override
  InkBrush get brush => _brush;
  @override
  bool get stylusOnly => _stylusOnly;

  /// Görünüm oluştu: kanalı bağla, geçerli kipi yerele bildir.
  /// (Fırça, görünüm oluşturma parametreleriyle zaten gider.)
  void attach(int viewId) {
    detach();
    final ch = MethodChannel(inkChannelName(viewId));
    ch.setMethodCallHandler(_onNativeCall);
    _channel = ch;
    _invoke(inkMethodSetInputMode, encodeInputMode(stylusOnly: _stylusOnly));
  }

  void detach() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
  }

  Future<void> _onNativeCall(MethodCall call) async {
    try {
      final e = decodeInkCall(call.method, call.arguments);
      if (e != null) _events.add(e);
    } on FormatException {
      // Bozuk ileti: çizimi düşürmesin, yok say.
    }
  }

  void _invoke(String method, [Object? args]) {
    final ch = _channel;
    if (ch == null) return;
    unawaited(ch.invokeMethod<void>(method, args).catchError((Object _) {}));
  }

  @override
  void setBrush(InkBrush brush) {
    _brush = brush;
    _invoke(inkMethodSetBrush, encodeBrush(brush));
  }

  @override
  void clear() => _invoke(inkMethodClear);

  @override
  void setInputMode({required bool stylusOnly}) {
    _stylusOnly = stylusOnly;
    _invoke(inkMethodSetInputMode, encodeInputMode(stylusOnly: stylusOnly));
  }

  @override
  void dispose() {
    detach();
    _events.close();
  }
}
