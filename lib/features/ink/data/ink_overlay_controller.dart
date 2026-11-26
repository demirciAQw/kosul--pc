import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';

import 'ink_overlay_codec.dart';

/// Ink katmanının Dart denetleyicisi (kanal `kocum/ink_overlay`). Aynı değeri art arda
/// göndermez (kare başına çağrı sayısı düşük kalır); [invalidate] önbelleği unutturur
/// (sahip değişince her şey yeniden gider). Kanal yoksa (eski Android, hata) çağrılar sessizce
/// boşa gider ve [available] false olur: çağıran Flutter yoluna döner.
class InkOverlayController {
  InkOverlayController([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(inkOverlayChannelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  final MethodChannel _channel;
  final _events = StreamController<InkOverlayEvent>.broadcast();

  bool _available = false;

  /// Yerel katman var ve çalışıyor (son [probe] sonucu).
  bool get available => _available;

  Stream<InkOverlayEvent> get events => _events.stream;

  InkOverlayMode? _mode;
  ({InkOverlayFamily family, int argb, double sizePx, double epsilon})? _brush;
  List<Rect>? _regions;
  List<Rect>? _mask;

  /// Yerelde katman var mı; sonucu [available]'a yazar.
  Future<bool> probe() async {
    try {
      _available = await _channel.invokeMethod<bool>(inkOverlayPing) ?? false;
    } on MissingPluginException {
      _available = false;
    } on PlatformException {
      _available = false;
    }
    return _available;
  }

  /// Gönderilmiş durumu unutur: sonraki her çağrı yeniden gider.
  void invalidate() {
    _mode = null;
    _brush = null;
    _regions = null;
    _mask = null;
  }

  Future<void> _onNativeCall(MethodCall call) async {
    try {
      final e = decodeOverlayCall(call.method, call.arguments);
      if (e != null) _events.add(e);
    } on FormatException {
      // Bozuk ileti çizimi düşürmesin: yok say.
    }
  }

  void _invoke(String method, [Object? args]) {
    unawaited(
      _channel.invokeMethod<void>(method, args).catchError((Object e) {
        if (e is MissingPluginException) _available = false;
      }),
    );
  }

  void setMode(InkOverlayMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _invoke(inkOverlaySetMode, encodeSetMode(mode));
  }

  void setBrush({
    required InkOverlayFamily family,
    required int argb,
    required double sizePx,
    double epsilon = 0.1,
  }) {
    final next = (family: family, argb: argb, sizePx: sizePx, epsilon: epsilon);
    if (_brush == next) return;
    _brush = next;
    _invoke(
      inkOverlaySetBrush,
      encodeSetBrush(family: family, argb: argb, sizePx: sizePx, epsilon: epsilon),
    );
  }

  /// Sayfa dikdörtgenleri (fiziksel piksel, pencere koordinatı). Değişmediyse gitmez.
  void setRegions(List<Rect> rects) {
    if (_regions != null && listEquals(_regions, rects)) return;
    _regions = List.of(rects);
    _invoke(inkOverlaySetRegions, encodeRects(rects));
  }

  /// Flutter arayüz bölgeleri: kalem burada çizmez, ıslak çizgi bunların üstünde görünmez.
  void setMask(List<Rect> rects) {
    if (_mask != null && listEquals(_mask, rects)) return;
    _mask = List.of(rects);
    _invoke(inkOverlaySetMask, encodeRects(rects));
  }

  /// Flutter kuru çizgiyi çizdikten sonra ıslak çizgiyi bırakır (titreşimsiz el değiştirme).
  void releaseStrokes(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _invoke(inkOverlayReleaseStrokes, encodeRelease(list));
  }

  /// Süren çizgiyi at (kaydedilmez).
  void cancelCurrent() => _invoke(inkOverlayCancelCurrent);

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_events.close());
  }
}
