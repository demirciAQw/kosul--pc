/// A uygulaması (Android yerel) ile Dart arasındaki MethodChannel sözleşmesi
/// (saf Dart). Kanal adı: `kocum/ink/<viewId>`; görünüm türü
/// `kocum/ink_surface`.
///
/// Dart → yerel: `setBrush {tool,color,width}`, `clear`, `setInputMode {stylusOnly}`.
/// Yerel → Dart: `strokeStart|strokePoint|strokeEnd {id,x,y,pressure,tilt,t}` ve
/// iptalde `strokeCancel {id}`. x, y, width Flutter MANTIKSAL pikselidir; tilt RADYANdır (0 = dik).
/// Silgide yerel taraf çizmez, yalnız olay yollar; silmeyi Dart yönetir.
library;

import 'ink_models.dart';

const inkViewType = 'kocum/ink_surface';
String inkChannelName(int viewId) => 'kocum/ink/$viewId';

const inkMethodSetBrush = 'setBrush';
const inkMethodClear = 'clear';
const inkMethodSetInputMode = 'setInputMode';
const inkMethodStrokeStart = 'strokeStart';
const inkMethodStrokePoint = 'strokePoint';
const inkMethodStrokeEnd = 'strokeEnd';
const inkMethodStrokeCancel = 'strokeCancel';

/// `setBrush` bağımsız değişkenleri (ve görünüm oluşturma parametreleri).
Map<String, Object> encodeBrush(InkBrush b) => {
  'tool': b.tool.name,
  'color': b.color,
  'width': b.width,
};

Map<String, Object> encodeInputMode({required bool stylusOnly}) => {
  'stylusOnly': stylusOnly,
};

/// Yerelden gelen bir çağrıyı olaya çevirir. Bilinmeyen yöntem için null;
/// bozuk bağımsız değişken için [FormatException].
InkEvent? decodeInkCall(String method, Object? args) {
  if (method != inkMethodStrokeStart &&
      method != inkMethodStrokePoint &&
      method != inkMethodStrokeEnd &&
      method != inkMethodStrokeCancel) {
    return null;
  }
  if (args is! Map) {
    throw FormatException('$method: bağımsız değişken eşleme değil', args);
  }
  final id = args['id'];
  if (id is! num) throw FormatException('$method: id eksik', args);
  if (method == inkMethodStrokeCancel) return InkStrokeCancel(id.toInt());
  double req(String k) {
    final v = args[k];
    if (v is! num || v.isNaN || v.isInfinite) {
      throw FormatException('$method: $k geçersiz', args);
    }
    return v.toDouble();
  }

  double opt(String k, double fallback) {
    final v = args[k];
    return v is num && v.isFinite ? v.toDouble() : fallback;
  }

  final p = InkPoint(
    x: req('x'),
    y: req('y'),
    pressure: opt('pressure', 0.5).clamp(0.0, 1.0),
    tilt: opt('tilt', 0),
    tMs: opt('t', 0),
  );
  final sid = id.toInt();
  return switch (method) {
    inkMethodStrokeStart => InkStrokeStart(sid, p),
    inkMethodStrokePoint => InkStrokePoint(sid, p),
    _ => InkStrokeEnd(sid, p),
  };
}
