import 'dart:async';
import 'dart:ui' as ui;

import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/ink_geometry.dart';
import '../domain/ink_models.dart';
import 'ink_outline.dart';

/// Biten çizgi: noktalar ve bir kez kaydedilmiş resim (Picture).
class InkFinishedStroke {
  InkFinishedStroke(this.id, this.brush, this.points, this.picture);
  final int id;
  final InkBrush brush;
  final List<InkPoint> points;
  final ui.Picture picture;
}

/// Biten çizgi listesi değişince (ekleme, silgi, temizle) haber verir; süren
/// çizginin her hareketinden bağımsızdır.
class InkFinishedChanges extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// B uygulaması (saf Flutter) denetleyicisi. Biten çizgiler `ui.Picture`
/// olarak önbelleğe alınır: her karede yalnızca SÜREN çizgi yeniden hesaplanır.
class InkBController extends ChangeNotifier implements InkSurface {
  InkBController({InkBrush brush = const InkBrush(), bool stylusOnly = true})
    : _brush = brush,
      _stylusOnly = stylusOnly;

  final _events = StreamController<InkEvent>.broadcast();
  final List<InkFinishedStroke> _finished = [];
  InkBrush _brush;
  bool _stylusOnly;
  int _nextId = 1;
  bool _disposed = false;

  /// Biten çizgiler değişince tetiklenir (süren çizgi tetiklemez).
  final finishedChanges = InkFinishedChanges();

  // Süren çizgi. Her karede tüm noktalara getStroke çalıştırmak O(n^2)
  // olurdu; bu yüzden süren çizgi [_chunkSize] noktada bir parçaya kesilip
  // Picture'a donar, yalnız kuyruk (en çok ~[_chunkSize] nokta) yeniden
  // hesaplanır. Parçalar [_overlap] nokta örtüşür (dikiş görünmesin).
  // Bitişte çizginin tamamı bir kez, temiz hesaplanır.
  static const _chunkSize = 96;
  static const _overlap = 4;
  int? _liveId;
  InkBrush? _liveBrush;
  final List<InkPoint> _live = [];
  final List<ui.Picture> _liveChunks = [];
  int _tailStart = 0;
  bool _livePressureFromDevice = true;
  ui.Path? _livePath;

  /// Deneme/test: tek seferde getStroke'a giden en çok nokta (süren çizgi).
  int maxLiveOutlinePoints = 0;

  /// Deneme/test sayacı: kaç kez çizgi yolu hesaplandı (önbellek kanıtı).
  int outlineComputeCount = 0;

  /// Kopyasız salt okunur görünüm (her karede çağrılabilir).
  late final List<InkFinishedStroke> finished = UnmodifiableListView(_finished);

  /// Süren çizginin donmuş parçaları (çizim sırasıyla).
  List<ui.Picture> get liveChunks => UnmodifiableListView(_liveChunks);
  bool get hasLive => _liveId != null && _liveBrush?.tool != InkTool.eraser;
  int? get liveStrokeId => _liveId;

  @override
  Stream<InkEvent> get events => _events.stream;
  @override
  InkBrush get brush => _brush;
  @override
  bool get stylusOnly => _stylusOnly;

  @override
  void setBrush(InkBrush brush) => _brush = brush;

  @override
  void setInputMode({required bool stylusOnly}) => _stylusOnly = stylusOnly;

  @override
  void clear() {
    if (_disposed) return;
    for (final f in _finished) {
      f.picture.dispose();
    }
    _finished.clear();
    _resetLive();
    finishedChanges.bump();
    notifyListeners();
  }

  void _resetLive() {
    _liveId = null;
    _liveBrush = null;
    _live.clear();
    for (final c in _liveChunks) {
      c.dispose();
    }
    _liveChunks.clear();
    _tailStart = 0;
    _livePath = null;
  }

  /// Süren çizginin yolu; yalnız yeni nokta geldiyse yeniden hesaplanır.
  ui.Path? livePath() {
    if (!hasLive) return null;
    final tail = _live.sublist(_tailStart);
    if (tail.length > maxLiveOutlinePoints) maxLiveOutlinePoints = tail.length;
    return _livePath ??= _compute(
      tail,
      _liveBrush!,
      complete: false,
      device: _livePressureFromDevice,
    );
  }

  InkBrush? get liveBrush => _liveBrush;

  ui.Path _compute(
    List<InkPoint> pts,
    InkBrush b, {
    required bool complete,
    required bool device,
  }) {
    outlineComputeCount++;
    return inkOutlinePath(
      pts,
      b,
      complete: complete,
      pressureFromDevice: device,
    );
  }

  /// [pressureFromDevice]: kalemde true, fare için false (baskı benzetilir).
  /// [eraser]: ters kalem ucu; seçili fırça ne olursa olsun silgi gibi davranır.
  void beginStroke(
    InkPoint p, {
    bool pressureFromDevice = true,
    bool eraser = false,
  }) {
    if (_disposed) return;
    if (_liveId != null) endStroke(p);
    final id = _nextId++;
    _liveId = id;
    _liveBrush = eraser
        ? _brush.copyWith(tool: InkTool.eraser, width: 12)
        : _brush;
    _livePressureFromDevice = pressureFromDevice;
    _live
      ..clear()
      ..add(p);
    _tailStart = 0;
    _livePath = null;
    _events.add(InkStrokeStart(id, p));
    if (_liveBrush!.tool == InkTool.eraser) _erase(p);
    notifyListeners();
  }

  void addPoint(InkPoint p) {
    final id = _liveId;
    if (id == null || _disposed) return;
    _live.add(p);
    _livePath = null;
    if (_liveBrush!.tool != InkTool.eraser &&
        _live.length - _tailStart >= _chunkSize) {
      _freezeTail();
    }
    _events.add(InkStrokePoint(id, p));
    if (_liveBrush!.tool == InkTool.eraser) _erase(p);
    notifyListeners();
  }

  void _freezeTail() {
    final path = _compute(
      _live.sublist(_tailStart),
      _liveBrush!,
      complete: false,
      device: _livePressureFromDevice,
    );
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawPath(path, inkPaintFor(_liveBrush!));
    _liveChunks.add(rec.endRecording());
    _tailStart = _live.length - _overlap;
  }

  /// Çizgi iptal (ACTION_CANCEL): yarım çizgi atılır, deftere girmez.
  void cancelStroke() {
    final id = _liveId;
    if (id == null || _disposed) return;
    _events.add(InkStrokeCancel(id));
    _resetLive();
    notifyListeners();
  }

  void endStroke(InkPoint p) {
    final id = _liveId;
    if (id == null || _disposed) return;
    _events.add(InkStrokeEnd(id, p));
    final b = _liveBrush!;
    if (b.tool != InkTool.eraser) {
      if (_live.last != p) _live.add(p);
      final path = _compute(
        _live,
        b,
        complete: true,
        device: _livePressureFromDevice,
      );
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawPath(path, inkPaintFor(b));
      _finished.add(
        InkFinishedStroke(id, b, List.of(_live), rec.endRecording()),
      );
      finishedChanges.bump();
    }
    _resetLive();
    notifyListeners();
  }

  /// Silgi: noktaya değen biten çizgileri kaldırır.
  void _erase(InkPoint p) {
    final radius = _liveBrush!.width;
    final hit = _finished
        .where(
          (f) => strokeHitsPoint(
            f.points,
            p.x,
            p.y,
            radius,
            halfWidth: f.brush.width / 2,
          ),
        )
        .toList();
    for (final f in hit) {
      _finished.remove(f);
      f.picture.dispose();
    }
    if (hit.isNotEmpty) finishedChanges.bump();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final f in _finished) {
      f.picture.dispose();
    }
    _finished.clear();
    _resetLive();
    _events.close();
    finishedChanges.dispose();
    super.dispose();
  }
}
