import 'package:flutter/material.dart';

import '../../question_bank/domain/question_card.dart';
import '../domain/book_analysis.dart';
import '../domain/question_box.dart' show clipBoxToPage;
import '../domain/pdf_engine.dart' show PdfPageSize;

/// Duruma göre analiz rengi: yanlış kırmızı, boş gri, doğru yeşil.
Color analysisColor(QuestionStatus s) => switch (s) {
  QuestionStatus.wrong => const Color(0xFFD32F2F),
  QuestionStatus.blank => const Color(0xFF757575),
  QuestionStatus.correct => const Color(0xFF2E7D32),
};

/// Başlık şeridi yüksekliği (sayfa içeriğini örtmesin diye ince).
const double _bannerHeight = 20;

/// Analiz modunda bir sayfanın üstü: kutusu olan sorulara renkli çerçeve ve
/// numara etiketi; testin ilk sayfasında (kutusuz yanlışlar için) şerit.
/// Çerçeveler ve şerit dokunuş/kalem almaz; yalnız şeridin [Aç] düğmesi alır.
/// [analysis] null ise (mod kapalı) hiçbir şey çizilmez.
class AnalysisPageOverlay extends StatelessWidget {
  const AnalysisPageOverlay({
    super.key,
    required this.page,
    required this.pageWidth,
    required this.pageHeight,
    required this.analysis,
    required this.onOpenPanel,
  });

  final int page;
  final double pageWidth;
  final double pageHeight;
  final ValueNotifier<BookAnalysis?> analysis;
  final VoidCallback onOpenPanel;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BookAnalysis?>(
      valueListenable: analysis,
      builder: (context, a, _) {
        if (a == null) return const SizedBox.shrink();
        final boxed = [
          for (final i in a.onPage(page))
            if (i.box != null) i,
        ];
        final banners = a.bannersOn(page);
        if (boxed.isEmpty && banners.isEmpty) return const SizedBox.shrink();
        return LayoutBuilder(
          builder: (_, c) {
            final sx = c.maxWidth / pageWidth, sy = c.maxHeight / pageHeight;
            final size = PdfPageSize(pageWidth, pageHeight);
            return Stack(
              fit: StackFit.expand,
              children: [
                for (final i in boxed)
                  if (clipBoxToPage(i.box!, size) case final b?)
                    IgnorePointer(
                      child: CustomPaint(
                        key: Key('analysis-box-${i.cardId}'),
                        painter: _AnalysisBoxPainter(
                          Rect.fromLTRB(b.left * sx, b.top * sy, b.right * sx, b.bottom * sy),
                          analysisColor(i.status),
                          i.questionNo?.toString(),
                        ),
                        size: Size.infinite,
                      ),
                    ),
                if (banners.isNotEmpty)
                  // İnce sabit bant (sayfa üst kenarı): dokunuşu ve kalemi YUTMAZ;
                  // yalnız küçük "Aç" düğmesi dokunuş alır.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Stack(
                      children: [
                        IgnorePointer(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final t in banners)
                                Container(
                                  key: Key('analysis-banner-${t.nodeId}'),
                                  height: _bannerHeight,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.only(left: 8, right: 44),
                                  color: analysisColor(QuestionStatus.wrong).withValues(alpha: 0.82),
                                  child: Text(
                                    t.bannerText(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Column(
                            children: [
                              for (final t in banners)
                                InkWell(
                                  key: Key('analysis-banner-open-${t.nodeId}'),
                                  onTap: onOpenPanel,
                                  child: Container(
                                    height: _bannerHeight,
                                    width: 40,
                                    alignment: Alignment.center,
                                    color: Colors.black26,
                                    child: const Text('Aç', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 11)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _AnalysisBoxPainter extends CustomPainter {
  _AnalysisBoxPainter(this.rect, this.color, this.label);
  final Rect rect;
  final Color color;
  final String? label;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(rect, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    final text = label;
    if (text == null) return;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final chip = Rect.fromLTWH(rect.left, rect.top, tp.width + 10, tp.height + 4);
    canvas.drawRect(chip, Paint()..color = color);
    tp.paint(canvas, chip.topLeft + const Offset(5, 2));
  }

  @override
  bool shouldRepaint(_AnalysisBoxPainter o) => o.rect != rect || o.color != color || o.label != label;
}
