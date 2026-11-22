import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../domain/pdf_engine.dart';
import 'pdf_page_ink_layer.dart' show PdfBoxPainter;

/// Sayfa üstünde işaretli soru kutusu (bekleyen seçim ya da "PDF'te göster" vurgusu).
class PdfBoxMark {
  const PdfBoxMark(this.page, this.box, this.color);

  /// 0'dan.
  final int page;
  final PdfBox box;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is PdfBoxMark && other.page == page && other.box == box && other.color == color;
  @override
  int get hashCode => Object.hash(page, box, color);
}

/// Bir sayfanın üstüne kutuları çizer; dokunuş almaz. Kutular sayfa biriminde
/// tutulur, burada görünüm ölçeğiyle çizilir (yakınlaştırınca yerinde kalır).
class PdfPageBoxOverlay extends StatelessWidget {
  const PdfPageBoxOverlay({
    super.key,
    required this.page,
    required this.pageWidth,
    required this.pageHeight,
    required this.marks,
  });

  final int page;
  final double pageWidth;
  final double pageHeight;
  final ValueListenable<List<PdfBoxMark>> marks;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<List<PdfBoxMark>>(
        valueListenable: marks,
        builder: (_, all, _) {
          final mine = [for (final m in all) if (m.page == page) m];
          if (mine.isEmpty) return const SizedBox.shrink();
          return LayoutBuilder(
            builder: (_, c) {
              final sx = c.maxWidth / pageWidth, sy = c.maxHeight / pageHeight;
              return Stack(
                fit: StackFit.expand,
                children: [
                  for (final m in mine)
                    CustomPaint(
                      key: Key('pdf-box-mark-${m.page}'),
                      painter: PdfBoxPainter(
                        [Rect.fromLTRB(m.box.left * sx, m.box.top * sy, m.box.right * sx, m.box.bottom * sy)],
                        m.color,
                      ),
                      size: Size.infinite,
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
