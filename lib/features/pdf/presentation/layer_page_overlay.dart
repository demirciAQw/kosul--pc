import 'package:flutter/material.dart';

import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart' show PdfBox;
import 'layer_buttons.dart' show deleteLayerWithUndo;
import 'pdf_layer_state.dart';

/// Sayfa üstü soru katmanı arayüzü (kalem çizgilerinin ÜSTÜNDE): AKTİF katmanın bölge
/// çerçevesi, küçük yuvarlak düğmeler (aktif belirgin, diğerleri soluk ve dokununca o katmana
/// geçer), çift tık menüsü ve not sekmesi. Düğmeye UZUN BASINCA düzenleme modu: sürükle-taşı
/// (konum PDF sayfa biriminde, kalıcı) ve "Sil" (×). Sayfa kutusu -> ekran dönüşümü: ölçek = yerleşim genişliği / sayfa genişliği.
class PdfPageLayerOverlay extends StatelessWidget {
  const PdfPageLayerOverlay({
    super.key,
    required this.state,
    required this.page,
    required this.pageWidth,
    required this.pageHeight,
    required this.onOpenWindow,
  });

  final PdfLayerState state;

  /// 0'dan.
  final int page;
  final double pageWidth;
  final double pageHeight;
  final void Function(PdfPageLayer layer) onOpenWindow;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final layers = state.questionLayersOn(page);
          if (layers.isEmpty) return const SizedBox.shrink();
          return LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth.isFinite ? c.maxWidth : pageWidth;
            final scale = w / pageWidth;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                IgnorePointer(
                  child: CustomPaint(
                    painter: _FramePainter(
                      [for (final l in layers) if (l.number == state.active) (l.box!, true)],
                      scale,
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                for (final l in layers)
                  _LayerButton(
                    key: ValueKey('layer-btn-${l.id}'),
                    state: state,
                    layer: l,
                    scale: scale,
                    pageWidth: pageWidth,
                    pageHeight: pageHeight,
                    onOpenWindow: onOpenWindow,
                  ),
              ],
            );
          });
        },
      );
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.boxes, this.scale, this.color);
  final List<(PdfBox, bool)> boxes;
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (b, active) in boxes) {
      final r = Rect.fromLTRB(b.left * scale, b.top * scale, b.right * scale, b.bottom * scale);
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = active ? 2 : 1
          ..color = color.withValues(alpha: active ? 0.8 : 0.35),
      );
    }
  }

  @override
  bool shouldRepaint(_FramePainter o) => true;
}

const double _btn = 34;
const double _noteW = 220;

class _LayerButton extends StatefulWidget {
  const _LayerButton({
    super.key,
    required this.state,
    required this.layer,
    required this.scale,
    required this.pageWidth,
    required this.pageHeight,
    required this.onOpenWindow,
  });
  final PdfLayerState state;
  final PdfPageLayer layer;
  final double scale;
  final double pageWidth;
  final double pageHeight;
  final void Function(PdfPageLayer) onOpenWindow;

  @override
  State<_LayerButton> createState() => _LayerButtonState();
}

class _LayerButtonState extends State<_LayerButton> {
  Offset? _drag; // sürüklenirken ekran konumu (yerleşim birimi)
  bool _edit = false; // uzun basış: taşı / sil
  Offset _dragStart = Offset.zero;
  Offset _tapAt = Offset.zero;
  late final TextEditingController _note = TextEditingController(text: widget.layer.note);

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Offset get _stored => widget.layer.buttonAt ?? widget.layer.defaultButtonAt;

  Offset _clamp(Offset o) => Offset(
        o.dx.clamp(0.0, (widget.pageWidth * widget.scale - _btn).clamp(0.0, double.infinity)),
        o.dy.clamp(0.0, (widget.pageHeight * widget.scale - _btn).clamp(0.0, double.infinity)),
      );

  void _commit() {
    final d = _drag;
    setState(() => _drag = null);
    if (d != null) widget.state.setButtonAt(widget.layer.id, d / widget.scale);
  }

  Future<void> _menu() async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(_tapAt.dx, _tapAt.dy, _tapAt.dx + 1, _tapAt.dy + 1),
      items: const [
        PopupMenuItem(value: 'pencere', child: Text('Seçili kısmı ayrı pencerede aç')),
        PopupMenuItem(value: 'katman', child: Text('Katman ekle')),
        PopupMenuItem(value: 'not', child: Text('Not ekle')),
      ],
    );
    switch (v) {
      case 'pencere':
        widget.onOpenWindow(widget.layer);
      case 'katman':
        await widget.state.addLike(widget.layer);
      case 'not':
        await widget.state.setNoteOpen(widget.layer.id, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = widget.layer;
    final pos = _drag ?? _clamp(_stored * widget.scale);
    final active = l.number == widget.state.active;
    final noteLeft = (pos.dx + _noteW > widget.pageWidth * widget.scale) ? pos.dx + _btn - _noteW : pos.dx;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (l.noteOpen)
          Positioned(
            left: noteLeft.clamp(0.0, double.infinity),
            top: pos.dy + _btn + 4,
            width: _noteW,
            child: Material(
              key: Key('layer-note-${l.number}'),
              color: Colors.white,
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    key: Key('layer-note-tab-${l.number}'),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                    onTap: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      widget.state.setNoteOpen(l.id, false);
                    },
                    child: Container(
                      height: 28,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                      ),
                      child: Text('Not ${l.number} · kapatmak için dokun',
                          style: const TextStyle(fontSize: 12, color: Colors.black87)),
                    ),
                  ),
                  TextField(
                    key: Key('layer-note-field-${l.number}'),
                    controller: _note,
                    minLines: 3,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(color: Colors.black87, fontSize: 14),
                    decoration: const InputDecoration(
                      hintText: 'Notunu yaz',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(10),
                      isDense: true,
                    ),
                    onChanged: (t) => widget.state.setNote(l.id, t),
                  ),
                ],
              ),
            ),
          ),
        Positioned(
          left: pos.dx,
          top: pos.dy,
          width: _btn,
          height: _btn,
          child: TapRegion(
            groupId: this,
            onTapOutside: (_) {
              if (_edit) setState(() => _edit = false);
            },
            child: GestureDetector(
              key: Key('layer-btn-hit-${l.number}'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_edit) {
                  setState(() => _edit = false);
                  return;
                }
                widget.state.setActive(l.number);
                if (!l.noteOpen && l.note.isNotEmpty) widget.state.setNoteOpen(l.id, true);
              },
              onDoubleTapDown: (d) => _tapAt = d.globalPosition,
              onDoubleTap: _edit ? null : _menu,
              onLongPressStart: (_) => setState(() {
                _edit = true;
                _dragStart = pos;
              }),
              onLongPressMoveUpdate: (d) => setState(() => _drag = _clamp(_dragStart + d.offsetFromOrigin)),
              onLongPressEnd: (_) => _commit(),
              onPanStart: _edit ? (_) => setState(() => _drag = pos) : null,
              onPanUpdate: _edit ? (d) => setState(() => _drag = _clamp((_drag ?? pos) + d.delta)) : null,
              onPanEnd: _edit ? (_) => _commit() : null,
              child: Opacity(
                opacity: active ? 1 : 0.4,
                child: Material(
                  color: active ? cs.primary : cs.secondaryContainer,
                  elevation: _edit ? 8 : 3,
                  shape: CircleBorder(side: _edit ? BorderSide(color: cs.primary, width: 2) : BorderSide.none),
                  child: Center(
                    child: Text(
                      '${l.number}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: active ? cs.onPrimary : cs.onSecondaryContainer,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_edit)
          Positioned(
            left: pos.dx + _btn + 4,
            top: pos.dy + (_btn - 28) / 2,
            width: 28,
            height: 28,
            child: TapRegion(
              groupId: this,
              onTapOutside: (_) {
                if (_edit) setState(() => _edit = false);
              },
              child: Material(
                color: cs.errorContainer,
                elevation: 4,
                shape: const CircleBorder(),
                child: InkResponse(
                  key: Key('layer-btn-delete-${l.number}'),
                  customBorder: const CircleBorder(),
                  onTap: () {
                    setState(() => _edit = false);
                    deleteLayerWithUndo(context, widget.state, l.number);
                  },
                  child: Tooltip(message: 'Sil', child: Icon(Icons.close, size: 16, color: cs.onErrorContainer)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
