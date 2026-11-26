import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Axis;

import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_object.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../ink/domain/shape_recognizer.dart' show ShapeTool;
import '../../pdf/presentation/pdf_ink_session.dart';

/// Araç yuvasının ekranda durduğu kenar (kullanıcı değiştirir, kalıcıdır).
enum DockPosition { top, bottom, left, right }

/// Sayfa öğesi araçları (yuvada Metin ve Alt sayfa; Foto tek seferlik eylemdir).
/// Seçiliyken kalem sayfaya çizmez: dokunuş öğe oluşturur/seçer.
enum ItemTool { none, text, child }

/// Sürükleyip bırakılan nokta [p] (ekran [area] içinde) için en yakın kenar.
/// Uzaklıklar boyuta oranlanır (uzun tablette sol/sağ haksız kazanmasın).
DockPosition nearestDockPosition(Offset p, Size area) {
  if (area.isEmpty) return DockPosition.bottom;
  final w = area.width, h = area.height;
  final d = {
    DockPosition.top: (p.dy / h).abs(),
    DockPosition.bottom: ((h - p.dy) / h).abs(),
    DockPosition.left: (p.dx / w).abs(),
    DockPosition.right: ((w - p.dx) / w).abs(),
  };
  var best = DockPosition.bottom;
  for (final e in d.entries) {
    if (e.value < d[best]!) best = e.key;
  }
  return best;
}

/// Defter araç durumu (kalem türü, renk, kalınlık, sertlik, silgi). Sayfa değişince
/// kaybolmaması için ekran tutar; her sayfa oturumuna [apply] ile uygulanır.
class NoteToolSettings extends ChangeNotifier {
  /// Yeni oturumların başlangıç çubuğu (varsayılan: sol çubuk). Testte eski yuva için false.
  @visibleForTesting
  static bool defaultRail = true;

  PenKind _kind = PenKind.ballpoint;

  /// Son seçilen kalem (fosforlu hariç): yuvadaki "Kalem" düğmesi buna döner.
  PenKind _lastPen = PenKind.ballpoint;

  /// Araç yuvasının kenarı (varsayılan alt).
  DockPosition _dockPos = DockPosition.bottom;

  /// Serbest yuva (defter): yuva herhangi bir yerde durur. [_dockFx]/[_dockFy] yuvanın
  /// gidebileceği alan içindeki ORAN (0..1); ekran boyutu değişince yuva kendiliğinden sığar.
  /// Serbestken [_dockPos] son kenarı tutar (PDF okuyucu ve "Kenara yapıştır" buna döner).
  bool _dockFree = false;
  double _dockFx = 0.5;
  double _dockFy = 1;

  /// Serbest yuvanın yönü (kenardan serbeste geçerken önceki yön korunur).
  bool _dockFreeVertical = false;
  ItemTool _itemTool = ItemTool.none;

  /// Sol dikey araç çubuğu (Google PDF Okuyucu tarzı); kapalıysa eski taşınabilir yuva.
  bool _rail = defaultRail;
  bool _eraser = false;
  bool _lasso = false;
  bool _shapeSnap = true;

  /// Kement kopyası (sayfalar arası yapıştırma için ekran tutar).
  List<InkObject> clipboard = const [];

  /// Yapıştırma hedefi sayfa numarası (oturum içi sayfa dizini): tek sayfada 0, akışta görünen sayfa.
  int pastePage = 0;

  /// Varsayılan: kısmi silgi (kalınlık); çizginin tamamını silmek ayrı moddur.
  EraseMode _eraseMode = EraseMode.area;
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

  /// Yuvanın bulunduğu kenar: üst, alt, sol, sağ.
  DockPosition get dockPosition => _dockPos;
  bool get dockAtTop => _dockPos == DockPosition.top;

  bool get dockFree => _dockFree;
  double get dockFx => _dockFx;
  double get dockFy => _dockFy;
  bool get dockFreeVertical => _dockFreeVertical;
  ItemTool get itemTool => _itemTool;

  /// Yeni sol çubuk açık mı (varsayılan evet); false: eski yuva ([dockPosition] geçerli).
  bool get rail => _rail;
  void setRail(bool v) {
    if (_rail == v) return;
    _rail = v;
    notifyListeners();
  }

  /// Yuvanın şu anki yönü: serbestte kendi yönü, kenarda kenara göre.
  Axis get dockAxis => _dockFree
      ? (_dockFreeVertical ? Axis.vertical : Axis.horizontal)
      : (_dockPos == DockPosition.left || _dockPos == DockPosition.right
            ? Axis.vertical
            : Axis.horizontal);

  /// Yuvayı serbest konuma alır ([fx], [fy]: gidebileceği alandaki 0..1 oran).
  /// Yön değişmez (kenardaysa o kenarın yönü korunur).
  void setDockFree(double fx, double fy) {
    final x = fx.isFinite ? fx.clamp(0.0, 1.0).toDouble() : 0.5;
    final y = fy.isFinite ? fy.clamp(0.0, 1.0).toDouble() : 1.0;
    if (!_dockFree) _dockFreeVertical = dockAxis == Axis.vertical;
    if (_dockFree && _dockFx == x && _dockFy == y) return;
    _dockFree = true;
    _dockFx = x;
    _dockFy = y;
    notifyListeners();
  }

  void setDockFreeVertical(bool v) {
    if (_dockFreeVertical == v) return;
    _dockFreeVertical = v;
    notifyListeners();
  }

  /// Öğe aracını seçer (aynı araca yeniden dokunmak kapatır); kalem moduna döner.
  void setItemTool(ItemTool t) {
    final next = _itemTool == t ? ItemTool.none : t;
    _itemTool = next;
    if (next != ItemTool.none) {
      _eraser = false;
      _lasso = false;
      _shapeTool = null;
    }
    notifyListeners();
  }

  /// [k] türünün seçili rengi (yuvadaki renk noktası için).
  int colorFor(PenKind k) => _color[k]!;

  /// Yuvayı bir kenara yapıştırır (serbest konumdan çıkar).
  void setDockPosition(DockPosition p) {
    if (_dockPos == p && !_dockFree) return;
    _dockPos = p;
    _dockFree = false;
    notifyListeners();
  }

  /// Eski ikili API (üst/alt): yeni kodda [setDockPosition] kullan.
  void setDockAtTop(bool top) =>
      setDockPosition(top ? DockPosition.top : DockPosition.bottom);

  bool get eraser => _eraser;
  bool get lasso => _lasso;

  /// Basılı tutunca şekil düzeltme (varsayılan açık).
  bool get shapeSnap => _shapeSnap;
  EraseMode get eraseMode => _eraseMode;
  double get hardness => _hardness;
  int get color => _color[_kind]!;
  double get width => _width[_kind]!;
  List<int> get palette =>
      _kind == PenKind.highlighter ? highlighterPalette : penPalette;
  List<double> get widthLevels =>
      _kind == PenKind.highlighter ? highlighterWidthLevels : penWidthLevels;

  /// Silgi yarıçapı (görünüm pikseli; [eraserRadiusMin]..[eraserRadiusMax]).
  double get eraserRadius => _eraserRadius;

  /// Seçili doğrudan şekil aracı (null: yok). Kalem seçiliyken çalışır.
  ShapeTool? get shapeTool => _shapeTool;

  /// Fırça kalınlığı olarak silgi: oturum yarıçapı `max(8, kalınlık * 2)` hesaplar.
  static double eraserBrushWidth(double radius) =>
      clampEraserRadius(radius) / 2;

  /// Geçerli aracın boyutu: silgide yarıçap, kalemde kalınlık.
  double get size => _eraser ? _eraserRadius : width;
  double get sizeMin => _eraser
      ? eraserRadiusMin
      : (_kind == PenKind.highlighter ? highlighterWidthMin : penWidthMin);
  double get sizeMax => _eraser
      ? eraserRadiusMax
      : (_kind == PenKind.highlighter ? highlighterWidthMax : penWidthMax);
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
  Map<String, Object?> toPrefs() => {
    ...toSizes(),
    'erase.mode': _eraseMode.name,
    'dock.pos': _dockFree ? 'free' : _dockPos.name,
    'dock.edge': _dockPos.name,
    'dock.top': _dockPos == DockPosition.top, // eski sürümlerle uyum
    'dock.x': _dockFx,
    'dock.y': _dockFy,
    'dock.vertical': _dockFreeVertical,
    'rail': _rail,
  };

  /// [toPrefs]/[toSizes] çıktısını geri yükler (bilinmeyen/bozuk değerler yok sayılır).
  void restoreSizes(Map<String, Object?> m) {
    final pos = m['dock.pos'];
    final top = m['dock.top'];
    final edge = m['dock.edge'];
    if (edge is String) {
      for (final p in DockPosition.values) {
        if (p.name == edge) _dockPos = p;
      }
    }
    if (pos == 'free') {
      _dockFree = true;
    } else if (pos is String) {
      _dockFree = false;
      for (final p in DockPosition.values) {
        if (p.name == pos) _dockPos = p;
      }
    } else if (top is bool) {
      _dockPos = top ? DockPosition.top : DockPosition.bottom;
    }
    final fx = m['dock.x'], fy = m['dock.y'];
    if (fx is num && fx.isFinite) _dockFx = fx.toDouble().clamp(0.0, 1.0).toDouble();
    if (fy is num && fy.isFinite) _dockFy = fy.toDouble().clamp(0.0, 1.0).toDouble();
    if (m['rail'] is bool) _rail = m['rail'] as bool;
    if (m['dock.vertical'] is bool) _dockFreeVertical = m['dock.vertical'] as bool;
    final em = m['erase.mode'];
    if (em is String) {
      for (final e in EraseMode.values) {
        if (e.name == em) _eraseMode = e;
      }
    }
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
      _itemTool = ItemTool.none;
    }
    notifyListeners();
  }

  void setKind(PenKind k) {
    _kind = k;
    if (k != PenKind.highlighter) _lastPen = k;
    _eraser = false;
    _lasso = false;
    _shapeTool = null;
    _itemTool = ItemTool.none;
    notifyListeners();
  }

  void setEraser(bool on) {
    _eraser = on;
    if (on) {
      _lasso = false;
      _shapeTool = null;
      _itemTool = ItemTool.none;
    }
    notifyListeners();
  }

  void setLasso(bool on) {
    _lasso = on;
    if (on) {
      _eraser = false;
      _shapeTool = null;
      _itemTool = ItemTool.none;
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
    _itemTool = ItemTool.none;
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
          tool: _kind == PenKind.highlighter
              ? InkTool.highlighter
              : InkTool.pen,
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
    s.setInkInputOff(_itemTool != ItemTool.none);
  }
}
