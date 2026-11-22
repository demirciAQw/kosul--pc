import 'package:flutter/foundation.dart';

import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_object.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../ink/domain/shape_recognizer.dart' show ShapeTool;
import '../../pdf/presentation/pdf_ink_session.dart';

/// Defter araç durumu (kalem türü, renk, kalınlık, sertlik, silgi). Sayfa değişince
/// kaybolmaması için ekran tutar; her sayfa oturumuna [apply] ile uygulanır.
class NoteToolSettings extends ChangeNotifier {
  PenKind _kind = PenKind.ballpoint;

  /// Son seçilen kalem (fosforlu hariç): yuvadaki "Kalem" düğmesi buna döner.
  PenKind _lastPen = PenKind.ballpoint;

  /// Araç yuvası üstte mi (varsayılan altta).
  bool _dockTop = false;
  bool _eraser = false;
  bool _lasso = false;
  bool _shapeSnap = true;

  /// Kement kopyası (sayfalar arası yapıştırma için ekran tutar).
  List<InkObject> clipboard = const [];
  EraseMode _eraseMode = EraseMode.stroke;
  double _hardness = 0.5;
  final Map<PenKind, int> _color = {
    PenKind.ballpoint: penPalette.first,
    PenKind.fountain: penPalette[2],
    PenKind.pencil: penPalette[1],
    PenKind.highlighter: highlighterPalette.first,
  };
  final Map<PenKind, double> _width = {
    PenKind.ballpoint: 3,
    PenKind.fountain: 3,
    PenKind.pencil: 3,
    PenKind.highlighter: highlighterDefaultWidth,
  };
  double _eraserRadius = eraserRadiusDefault;
  ShapeTool? _shapeTool;

  PenKind get kind => _kind;
  PenKind get lastPenKind => _lastPen;
  bool get dockAtTop => _dockTop;

  /// [k] türünün seçili rengi (yuvadaki renk noktası için).
  int colorFor(PenKind k) => _color[k]!;

  void setDockAtTop(bool top) {
    if (_dockTop == top) return;
    _dockTop = top;
    notifyListeners();
  }
  bool get eraser => _eraser;
  bool get lasso => _lasso;

  /// Basılı tutunca şekil düzeltme (varsayılan açık).
  bool get shapeSnap => _shapeSnap;
  EraseMode get eraseMode => _eraseMode;
  double get hardness => _hardness;
  int get color => _color[_kind]!;
  double get width => _width[_kind]!;
  List<int> get palette => _kind == PenKind.highlighter ? highlighterPalette : penPalette;
  List<double> get widthLevels => _kind == PenKind.highlighter ? highlighterWidthLevels : penWidthLevels;

  /// Silgi yarıçapı (görünüm pikseli; [eraserRadiusMin]..[eraserRadiusMax]).
  double get eraserRadius => _eraserRadius;

  /// Seçili doğrudan şekil aracı (null: yok). Kalem seçiliyken çalışır.
  ShapeTool? get shapeTool => _shapeTool;

  /// Fırça kalınlığı olarak silgi: oturum yarıçapı `max(8, kalınlık * 2)` hesaplar.
  static double eraserBrushWidth(double radius) => clampEraserRadius(radius) / 2;

  /// Geçerli aracın boyutu: silgide yarıçap, kalemde kalınlık.
  double get size => _eraser ? _eraserRadius : width;
  double get sizeMin => _eraser ? eraserRadiusMin : (_kind == PenKind.highlighter ? highlighterWidthMin : penWidthMin);
  double get sizeMax => _eraser ? eraserRadiusMax : (_kind == PenKind.highlighter ? highlighterWidthMax : penWidthMax);
  List<double> get sizeLevels => _eraser ? eraserRadiusLevels : widthLevels;

  /// Geçerli aracın boyutunu sınırlar içinde ayarlar.
  void setSize(double v) {
    if (!v.isFinite) return;
    final c = v.clamp(sizeMin, sizeMax).toDouble();
    if (_eraser) {
      _eraserRadius = c;
    } else {
      _width[_kind] = c;
    }
    notifyListeners();
  }

  /// Araç boyutlarını kalıcı saklamak için (ayarlar katmanı yazar/okur).
  Map<String, double> toSizes() => {
    for (final k in PenKind.values) 'width.${k.name}': _width[k]!,
    'eraser': _eraserRadius,
  };

  /// Kalıcı saklanacak her şey: boyutlar ve yuva konumu.
  Map<String, Object?> toPrefs() => {...toSizes(), 'dock.top': _dockTop};

  /// [toPrefs]/[toSizes] çıktısını geri yükler (bilinmeyen/bozuk değerler yok sayılır).
  void restoreSizes(Map<String, Object?> m) {
    final top = m['dock.top'];
    if (top is bool) _dockTop = top;
    for (final k in PenKind.values) {
      final v = m['width.${k.name}'];
      if (v is num && v.isFinite) {
        final hi = k == PenKind.highlighter ? highlighterWidthMax : penWidthMax;
        final lo = k == PenKind.highlighter ? highlighterWidthMin : penWidthMin;
        _width[k] = v.toDouble().clamp(lo, hi).toDouble();
      }
    }
    final e = m['eraser'];
    if (e is num) _eraserRadius = clampEraserRadius(e.toDouble());
    notifyListeners();
  }

  /// Doğrudan şekil aracını seçer (aynı araca yeniden dokunmak kapatır); kalem moduna döner.
  void setShapeTool(ShapeTool? t) {
    _shapeTool = _shapeTool == t ? null : t;
    if (_shapeTool != null) {
      _eraser = false;
      _lasso = false;
    }
    notifyListeners();
  }

  void setKind(PenKind k) {
    _kind = k;
    if (k != PenKind.highlighter) _lastPen = k;
    _eraser = false;
    _lasso = false;
    _shapeTool = null;
    notifyListeners();
  }

  void setEraser(bool on) {
    _eraser = on;
    if (on) {
      _lasso = false;
      _shapeTool = null;
    }
    notifyListeners();
  }

  void setLasso(bool on) {
    _lasso = on;
    if (on) {
      _eraser = false;
      _shapeTool = null;
    }
    notifyListeners();
  }

  void setShapeSnap(bool on) {
    _shapeSnap = on;
    notifyListeners();
  }

  void setEraseMode(EraseMode m) {
    _eraseMode = m;
    _eraser = true;
    _lasso = false;
    _shapeTool = null;
    notifyListeners();
  }

  void setColor(int c) {
    _color[_kind] = c;
    notifyListeners();
  }

  void setWidth(double w) {
    _width[_kind] = w;
    notifyListeners();
  }

  void setHardness(double h) {
    _hardness = h.clamp(0.0, 1.0);
    notifyListeners();
  }

  InkBrush get brush => _eraser
      ? InkBrush(tool: InkTool.eraser, width: eraserBrushWidth(_eraserRadius))
      : InkBrush(
          tool: _kind == PenKind.highlighter ? InkTool.highlighter : InkTool.pen,
          color: color,
          width: width,
          kind: _kind,
        );

  void apply(PdfInkSession s) {
    s.setHardness(_hardness);
    s.setEraseMode(_eraseMode);
    s.setShapeSnap(_shapeSnap);
    s.setLassoMode(_lasso);
    s.setShapeTool(_eraser || _lasso ? null : _shapeTool);
    s.setBrush(brush);
  }
}
