import 'package:flutter/material.dart';

import '../../../app/platform.dart';
import '../data/ink_a_controller.dart';
import '../data/ink_b_controller.dart';
import '../data/ink_surface_a.dart';
import '../data/ink_surface_b.dart';
import '../domain/ink_models.dart';
import 'ink_viewport.dart';

/// Kalem denemesi: A (Android yerel) ile B (saf Flutter) arasında geçiş.
/// Kalem çizer, parmak kaydırır/yakınlaştırır. Gecikme ölçümü logcat'te
/// "KocumInk" etiketiyle görünür.
class InkLabPage extends StatefulWidget {
  /// [androidAvailable]: A seçeneği var mı (varsayılan: yalnızca Android).
  const InkLabPage({super.key, bool? androidAvailable})
    : _androidAvailable = androidAvailable;

  final bool? _androidAvailable;

  @override
  State<InkLabPage> createState() => _InkLabPageState();
}

const _colors = <int>[
  0xFF1B1B1F,
  0xFF1565C0,
  0xFFC62828,
  0xFF2E7D32,
  0xFFF9A825,
];

class _InkLabPageState extends State<InkLabPage> {
  late final bool _hasA = widget._androidAvailable ?? isAndroid;
  final _b = InkBController();
  final _a = InkAController();
  bool _useA = false;
  bool _stylusOnly = true;
  InkBrush _brush = const InkBrush();

  InkSurface get _active => _useA ? _a : _b;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _setBrush(InkBrush b) {
    setState(() => _brush = b);
    _a.setBrush(b);
    _b.setBrush(b);
  }

  void _sendTransformToA(Matrix4 m) => _a.setTransform(
    scale: m.getMaxScaleOnAxis(),
    dx: m.storage[12],
    dy: m.storage[13],
  );

  void _setStylusOnly(bool v) {
    setState(() => _stylusOnly = v);
    _a.setInputMode(stylusOnly: v);
    _b.setInputMode(stylusOnly: v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kalem denemesi'),
        actions: [
          IconButton(
            key: const Key('ink-clear'),
            tooltip: 'Temizle',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _active.clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_hasA)
                  SegmentedButton<bool>(
                    key: const Key('ink-impl'),
                    segments: const [
                      ButtonSegment(value: true, label: Text('A (yerel)')),
                      ButtonSegment(value: false, label: Text('B (Flutter)')),
                    ],
                    selected: {_useA},
                    onSelectionChanged: (s) {
                      setState(() => _useA = s.first);
                      // A'da silgi yok: seçiliyse kaleme dön.
                      if (_useA && _brush.tool == InkTool.eraser) {
                        _setBrush(_brush.copyWith(tool: InkTool.pen, width: 3));
                      }
                    },
                  ),
                SegmentedButton<InkTool>(
                  key: const Key('ink-tool'),
                  segments: [
                    const ButtonSegment(
                      value: InkTool.pen,
                      icon: Icon(Icons.edit_rounded),
                      label: Text('Kalem'),
                    ),
                    const ButtonSegment(
                      value: InkTool.highlighter,
                      icon: Icon(Icons.border_color_rounded),
                      label: Text('Fosforlu'),
                    ),
                    ButtonSegment(
                      value: InkTool.eraser,
                      icon: const Icon(Icons.auto_fix_normal_rounded),
                      label: const Text('Silgi'),
                      enabled: !_useA,
                      tooltip: _useA ? "A'da silgi yok" : null,
                    ),
                  ],
                  selected: {_brush.tool},
                  onSelectionChanged: (s) => _setBrush(
                    _brush.copyWith(
                      tool: s.first,
                      width: s.first == InkTool.highlighter
                          ? 14
                          : (s.first == InkTool.eraser ? 12 : 3),
                    ),
                  ),
                ),
                for (final c in _colors)
                  GestureDetector(
                    key: Key('ink-color-${c.toRadixString(16)}'),
                    onTap: () => _setBrush(_brush.copyWith(color: c)),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _brush.color == c
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: _brush.color == c ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  width: 160,
                  child: Slider(
                    key: const Key('ink-width'),
                    min: 1,
                    max: 30,
                    value: _brush.width.clamp(1, 30),
                    onChanged: (v) => _setBrush(_brush.copyWith(width: v)),
                  ),
                ),
                FilterChip(
                  key: const Key('ink-stylus-only'),
                  label: const Text('Yalnız kalem'),
                  selected: _stylusOnly,
                  onSelected: _setStylusOnly,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ColoredBox(
              color: Colors.white,
              child: _useA
                  // A: yerel görünüm sabit kalır; parmak kaydırma/yakınlaştırmayı Flutter
                  // yapar, matrisi yerele iletir (çizgiler dünya koordinatında, vektör kalır).
                  ? InkViewport(
                      transformChild: false,
                      onMatrixChanged: _sendTransformToA,
                      child: InkSurfaceAView(controller: _a),
                    )
                  : InkViewport(
                      drawingActive: () => _b.liveStrokeId != null,
                      child: InkSurfaceBView(controller: _b),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
