import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../domain/page_size.dart';
import '../domain/page_template.dart';

/// Sayfa arka planı ve şablon çizgileri. Koordinatlar not koordinatındadır;
/// [size] ekrandaki boyuta ölçeklenir (yakınlaştırmada çizgi kalınlığı da büyür).
class PageTemplatePainter extends CustomPainter {
  PageTemplatePainter({
    required this.template,
    required this.background,
    required this.pageWidth,
    required this.pageHeight,
    this.spacingFactor = 1,
    bool? infinite,
    this.viewTransform,
    this.viewSize,
  }) : infinite = infinite ?? isInfinitePage(pageHeight),
       super(repaint: viewTransform);

  /// Sonsuz (aşağı kayan) sayfa: yalnız görünen yatay aralık çizilir ve
  /// çizgiler üstten sayılır (sayfa uzayınca yerinden oynamaz).
  final bool infinite;

  /// Sonsuz sayfada görünür aralığı bulmak için: kaydırma/zum matrisi (ekran)
  /// ve görünüm boyutu. Verilmezse (küçük resim) sayfanın tamamı çizilir.
  final ValueListenable<Matrix4>? viewTransform;
  final Size? viewSize;

  final PageTemplate template;
  final int background;
  final double pageWidth;
  final double pageHeight;

  /// Çizgi/kare aralığı çarpanı (1 = varsayılan). Yalnızca oturumda tutulur,
  /// sayfa kaydına yazılmaz.
  final double spacingFactor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(background));
    final step = defaultTemplateSpacing(pageWidth) * spacingFactor;
    final sx = size.width / pageWidth, sy = size.height / pageHeight;
    final TemplateLines lines;
    if (infinite) {
      var from = 0.0, to = pageHeight;
      final m = viewTransform?.value, vs = viewSize;
      if (m != null && vs != null && vs.height > 0) {
        final z = m.getMaxScaleOnAxis();
        if (z > 0) {
          // Görünür aralık (yerel px) + bir ekran payı, sonra not birimine.
          final top = -m.getTranslation().y / z, bot = top + vs.height / z;
          from = (top - vs.height / z * 0.5) / sy;
          to = (bot + vs.height / z * 0.5) / sy;
        }
      }
      lines = infiniteTemplateLines(
        template,
        pageWidth,
        pageHeight,
        step,
        from,
        to,
      );
    } else {
      final all = templateLines(template, pageWidth, pageHeight, spacing: step);
      lines = _visibleOnly(all, step, sx, sy);
    }
    if (lines.isEmpty) return;
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

  /// Yüksek zumda yalnız görünen çizgiler (bir aralık paylı) çizilir: %6000'de bile
  /// çizim sayısı sabit kalır. Görünüm bilinmiyorsa ya da zum küçükse hepsi çizilir.
  TemplateLines _visibleOnly(TemplateLines all, double step, double sx, double sy) {
    final m = viewTransform?.value, vs = viewSize;
    if (m == null || vs == null || vs.isEmpty) return all;
    final z = m.getMaxScaleOnAxis();
    if (z < 3) return all;
    final t = m.getTranslation();
    final left = -t.x / z / sx - step, right = (-t.x + vs.width) / z / sx + step;
    final top = -t.y / z / sy - step, bottom = (-t.y + vs.height) / z / sy + step;
    return TemplateLines(
      horizontal: [
        for (final y in all.horizontal)
          if (y >= top && y <= bottom) y,
      ],
      vertical: [
        for (final x in all.vertical)
          if (x >= left && x <= right) x,
      ],
    );
  }

  @override
  bool shouldRepaint(PageTemplatePainter old) =>
      old.template != template ||
      old.background != background ||
      old.pageWidth != pageWidth ||
      old.pageHeight != pageHeight ||
      old.infinite != infinite ||
      old.viewSize != viewSize ||
      old.viewTransform != viewTransform ||
      old.spacingFactor != spacingFactor;
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

/// Arka plan seçenekleri (argb): beyaz, krem, koyu.
const pageBackgrounds = <(String, String, int)>[
  ('white', 'Beyaz', 0xFFFFFFFF),
  ('cream', 'Krem', 0xFFFFF8E1),
  ('dark', 'Koyu', 0xFF263238),
];

/// Çizgi aralığı seçenekleri: anahtar, ad, çarpan. Yalnızca oturumda tutulur.
const pageSpacings = <(String, String, double)>[
  ('dense', 'Sık', 0.7),
  ('normal', 'Normal', 1.0),
  ('wide', 'Seyrek', 1.5),
];
