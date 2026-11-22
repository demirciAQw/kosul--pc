import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/page_template.dart';

/// Sayfa arka planı ve şablon çizgileri. Koordinatlar not koordinatındadır;
/// [size] ekrandaki boyuta ölçeklenir (yakınlaştırmada çizgi kalınlığı da büyür).
class PageTemplatePainter extends CustomPainter {
  PageTemplatePainter({
    required this.template,
    required this.background,
    required this.pageWidth,
    required this.pageHeight,
  });

  final PageTemplate template;
  final int background;
  final double pageWidth;
  final double pageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(background));
    final lines = templateLines(template, pageWidth, pageHeight);
    if (lines.isEmpty) return;
    final sx = size.width / pageWidth, sy = size.height / pageHeight;
    final paint = Paint()
      ..color = const Color(0xFF90A4AE).withValues(alpha: 0.55)
      ..strokeWidth = (sx * 1.2).clamp(0.5, 3.0);
    if (template == PageTemplate.dots) {
      final dots = [
        for (final y in lines.horizontal)
          for (final x in lines.vertical) Offset(x * sx, y * sy),
      ];
      canvas.drawPoints(
        ui.PointMode.points,
        dots,
        paint
          ..strokeCap = StrokeCap.round
          ..strokeWidth = (sx * 4).clamp(1.5, 6.0),
      );
      return;
    }
    for (final y in lines.horizontal) {
      canvas.drawLine(Offset(0, y * sy), Offset(size.width, y * sy), paint);
    }
    for (final x in lines.vertical) {
      canvas.drawLine(Offset(x * sx, 0), Offset(x * sx, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(PageTemplatePainter old) =>
      old.template != template ||
      old.background != background ||
      old.pageWidth != pageWidth ||
      old.pageHeight != pageHeight;
}

/// Şablon adı (arayüz metni).
String templateLabel(PageTemplate t) => switch (t) {
  PageTemplate.plain => 'Düz',
  PageTemplate.ruled => 'Çizgili',
  PageTemplate.grid => 'Kareli',
  PageTemplate.dots => 'Noktalı',
};

IconData templateIcon(PageTemplate t) => switch (t) {
  PageTemplate.plain => Icons.crop_portrait_outlined,
  PageTemplate.ruled => Icons.format_align_justify,
  PageTemplate.grid => Icons.grid_4x4,
  PageTemplate.dots => Icons.grid_on,
};
