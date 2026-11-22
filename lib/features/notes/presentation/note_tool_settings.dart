import 'package:flutter/foundation.dart';

import '../../ink/domain/ink_models.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../pdf/presentation/pdf_ink_session.dart';

/// Defter araç durumu (kalem türü, renk, kalınlık, sertlik, silgi). Sayfa değişince
/// kaybolmaması için ekran tutar; her sayfa oturumuna [apply] ile uygulanır.
class NoteToolSettings extends ChangeNotifier {
  PenKind _kind = PenKind.ballpoint;
  bool _eraser = false;
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
    PenKind.highlighter: 16,
  };

  PenKind get kind => _kind;
  bool get eraser => _eraser;
  EraseMode get eraseMode => _eraseMode;
  double get hardness => _hardness;
  int get color => _color[_kind]!;
  double get width => _width[_kind]!;
  List<int> get palette => _kind == PenKind.highlighter ? highlighterPalette : penPalette;
  List<double> get widthLevels => _kind == PenKind.highlighter ? highlighterWidthLevels : penWidthLevels;

  /// Silgi kalınlığı (görünüm pikseli; silgi yarıçapı bunun iki katı, en az 8).
  static const eraserWidth = 8.0;

  void setKind(PenKind k) {
    _kind = k;
    _eraser = false;
    notifyListeners();
  }

  void setEraser(bool on) {
    _eraser = on;
    notifyListeners();
  }

  void setEraseMode(EraseMode m) {
    _eraseMode = m;
    _eraser = true;
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
      ? const InkBrush(tool: InkTool.eraser, width: eraserWidth)
      : InkBrush(
          tool: _kind == PenKind.highlighter ? InkTool.highlighter : InkTool.pen,
          color: color,
          width: width,
          kind: _kind,
        );

  void apply(PdfInkSession s) {
    s.setHardness(_hardness);
    s.setEraseMode(_eraseMode);
    s.setBrush(brush);
  }
}
