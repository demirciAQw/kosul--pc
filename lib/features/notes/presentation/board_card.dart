import 'package:flutter/material.dart';

import '../domain/ink_notebook.dart';
import '../domain/page_board.dart';
import '../domain/page_size.dart';
import 'page_thumb.dart';

/// Kart başlığı: başlık yoksa "Sayfa N".
String boardCardTitle(BoardCard c) {
  final t = c.title?.trim();
  return t == null || t.isEmpty ? 'Sayfa ${c.pageNo}' : t;
}

/// Düşük ayrıntıda kart rengi: konuya göre kararlı, konusuzsa nötr.
Color boardCardColor(BoardCard c) {
  final k = c.konuId;
  if (k == null || k.isEmpty) return const Color(0xFF90A4AE);
  final h = k.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff) % 360;
  return HSLColor.fromAHSL(1, h.toDouble(), 0.45, 0.62).toColor();
}

/// Panodaki tek sayfa kartı (pano biriminde, [boardCardW] x [boardCardH] ölçeğinde çizilir;
/// görünümün ölçeği dışarıdan uygulanır). Etkileşim üst katmanda; bu widget yalnız çizer.
class BoardCardView extends StatelessWidget {
  const BoardCardView({
    super.key,
    required this.card,
    required this.page,
    required this.lowDetail,
    this.dimmed = false,
    this.matched = false,
    this.hasChildren = false,
  });

  final BoardCard card;

  /// Küçük resim için; yoksa (henüz yüklenmedi) boş kart.
  final InkNotePageRecord? page;
  final bool lowDetail;
  final bool dimmed;
  final bool matched;
  final bool hasChildren;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = boardCardTitle(card);
    final accent = boardCardColor(card);
    final Widget body;
    if (lowDetail) {
      body = ColoredBox(
        color: accent,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w700, color: Colors.black87),
            ),
          ),
        ),
      );
    } else {
      final p = page;
      body = Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: cs.surfaceContainerHighest,
              child: p == null
                  ? const SizedBox.expand()
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: p.width / (isInfinitePage(p.height) ? a4PageHeight : p.height),
                          child: PageThumb(page: p),
                        ),
                      ),
                    ),
            ),
          ),
          Container(
            height: 64,
            color: cs.surface,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                if (card.parentPageId != null) Icon(Icons.subdirectory_arrow_right, size: 30, color: cs.primary),
                if (hasChildren) Icon(Icons.account_tree_outlined, size: 28, color: cs.primary),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                  ),
                ),
                if (card.konuId != null)
                  Container(
                    key: const Key('board-konu-badge'),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(14)),
                    child: const Text('Konu', style: TextStyle(fontSize: 22, color: Colors.black87)),
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return Opacity(
      opacity: dimmed ? 0.3 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: matched ? cs.tertiary : cs.outlineVariant, width: matched ? 6 : 2),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(12), child: body),
      ),
    );
  }
}
