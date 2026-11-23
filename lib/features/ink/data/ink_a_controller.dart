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
  ({double scale, double dx, double dy}) _transform = (scale: 1, dx: 0, dy: 0);

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
    // Yeni görünümün varsayılanı kimlik dönüşümüdür; yalnız farklıysa gönder.
    if (_transform != (scale: 1.0, dx: 0.0, dy: 0.0)) _sendTransform();
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

  /// Görünüm dönüşümü (parmakla kaydırma/yakınlaştırma): görünüm = dünya * scale +
  /// (dx, dy). Yerel görünüm sabit kalır, çizgileri bu matrisle yeniden çizer.
  void setTransform({
    required double scale,
    required double dx,
    required double dy,
  }) {
    final next = (scale: scale, dx: dx, dy: dy);
    if (next == _transform) return;
    _transform = next;
    _sendTransform();
  }

  void _sendTransform() {
    final t = _transform;
    _invoke(
      inkMethodSetTransform,
      encodeTransform(scale: t.scale, dx: t.dx, dy: t.dy),
    );
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
