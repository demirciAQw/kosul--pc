import 'package:flutter/material.dart';

import '../../domain/library.dart';
import '../../domain/progress.dart';

/// Kapak renkleri: hepsi beyaz yazıyla okunur (koyu, doygun tonlar).
const List<Color> bookCoverPalette = [
  Color(0xFF9B2C2C), // kırmızı
  Color(0xFF1E5AA8), // mavi
  Color(0xFF1F7A4D), // yeşil
  Color(0xFF6B3FA0), // mor
  Color(0xFFB45309), // turuncu
  Color(0xFF0E7490), // turkuaz
  Color(0xFF9D2463), // pembe
  Color(0xFF475569), // arduvaz
  Color(0xFF5B6B0F), // zeytin
  Color(0xFF8A4B2A), // kahve
];

int _stableHash(String s) {
  // FNV-1a: süreçler arası kararlı (String.hashCode'a güvenme).
  var h = 0x811c9dc5;
  for (final u in s.toLowerCase().codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0x7fffffff;
  }
  return h;
}

/// Kitabın kapak rengi: dersinden kararlı; aynı ders hep aynı renk.
/// Ders yoksa kitap adından.
Color bookCoverColor(Book book) =>
    bookCoverColorFor(book.subject.trim().isNotEmpty ? book.subject : book.title);

/// Verilen anahtardan kararlı kapak rengi (kitabı olmayan PDF'ler başlığından).
Color bookCoverColorFor(String key) => bookCoverPalette[_stableHash(key) % bookCoverPalette.length];

/// Genişliğe göre raf sütun sayısı: telefonda 2-3, tablette 4-6.
int shelfColumnsFor(double width) {
  if (width >= 1100) return 6;
  if (width >= 900) return 5;
  if (width >= 600) return 4;
  if (width >= 340) return 3;
  return 2;
}

/// Gerçek kitap gibi dikey (2:3) kapak: renkli zemin, ders etiketi, büyük ad,
/// yayınevi, sağda sırt gölgesi ve altta ilerleme şeridi.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.progress,
    required this.onTap,
    this.hasPdf = false,
    this.onLongPress,
  });

  final BookProgress progress;
  final VoidCallback onTap;

  /// Kitaba bağlı PDF var: kapakta küçük "PDF" rozeti.
  final bool hasPdf;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final b = progress.book;
    final pct = (progress.ratio * 100).round();
    return BookCoverFace(
      title: b.title,
      kicker: [b.examType, b.subject].where((e) => e.trim().isNotEmpty).join(' · '),
      color: bookCoverColor(b),
      publisher: (b.publisher ?? '').trim(),
      ratio: progress.ratio,
      footer: '%$pct · ${progress.doneLeaves}/${progress.totalLeaves}',
      semanticsLabel: '${b.title}, ${b.subject}, ilerleme %$pct${hasPdf ? ', PDF var' : ''}',
      onTap: onTap,
      onLongPress: onLongPress,
      badge: hasPdf ? 'PDF' : null,
    );
  }
}

/// Kapağın çizimi (kitap ve PDF rafları ortak kullanır). [ratio] null ise
/// ilerleme şeridi çizilmez; [footer] altta tek satır yazıdır.
class BookCoverFace extends StatelessWidget {
  const BookCoverFace({
    super.key,
    required this.title,
    required this.color,
    required this.onTap,
    required this.semanticsLabel,
    this.kicker = '',
    this.publisher = '',
    this.ratio,
    this.footer,
    this.onLongPress,
    this.badge,
    this.bottomRight,
  });

  final String title;
  final String kicker;
  final Color color;
  final String publisher;
  final double? ratio;
  final String? footer;
  final String semanticsLabel;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Sağ üstte küçük rozet ("PDF").
  final String? badge;

  /// Sağ altta ek bileşen (ör. ⋮ menüsü).
  final Widget? bottomRight;

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: LayoutBuilder(
          builder: (context, c) {
            final titleSize = (c.maxWidth * 0.125).clamp(12.0, 20.0);
            final small = (c.maxWidth * 0.085).clamp(9.0, 12.0);
            return DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(3),
                  right: Radius.circular(8),
                ),
                boxShadow: const [
                  BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(2, 3)),
                ],
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color.lerp(color, white, 0.12)!, color],
                ),
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(3),
                  right: Radius.circular(8),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: onTap,
                    onLongPress: onLongPress,
                    child: Stack(
                      children: [
                        // Sağda ince sırt gölgesi.
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: c.maxWidth * 0.07,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Color(0x00000000), Color(0x55000000)],
                              ),
                            ),
                          ),
                        ),
                        // Sol kenarda açık çizgi (kapak kenarı).
                        const Positioned(
                          top: 0,
                          bottom: 0,
                          left: 0,
                          width: 2,
                          child: ColoredBox(color: Color(0x33FFFFFF)),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(c.maxWidth * 0.1, 10, c.maxWidth * 0.14, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                kicker,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: white.withValues(alpha: 0.85),
                                  fontSize: small,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.4,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(height: 2, width: 22, color: white.withValues(alpha: 0.6)),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 5,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: white,
                                    fontSize: titleSize,
                                    fontWeight: FontWeight.w800,
                                    height: 1.15,
                                  ),
                                ),
                              ),
                              if (publisher.isNotEmpty)
                                Text(
                                  publisher,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: white.withValues(alpha: 0.85), fontSize: small),
                                ),
                              if (ratio != null) ...[
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: ratio!.clamp(0.0, 1.0),
                                    minHeight: 5,
                                    backgroundColor: const Color(0x55000000),
                                    valueColor: const AlwaysStoppedAnimation(Color(0xFFFFFFFF)),
                                  ),
                                ),
                              ],
                              if (footer != null) ...[
                                const SizedBox(height: 3),
                                Text(
                                  footer!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: white, fontSize: small, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (badge != null)
                          Positioned(
                            top: 6,
                            right: c.maxWidth * 0.1,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: white,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                child: Text(
                                  badge!,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: small,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (bottomRight != null) Positioned(bottom: 0, right: c.maxWidth * 0.04, child: bottomRight!),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Raf düzeni: kapaklar sütun sütun dizilir, her satırın altında ahşap raf.
class BookShelfView extends StatelessWidget {
  const BookShelfView({
    super.key,
    required this.items,
    required this.onOpen,
    this.header,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 96),
    this.pdfBookIds = const {},
    this.onLongPress,
  });

  final List<BookProgress> items;
  final void Function(Book book) onOpen;
  final Widget? header;
  final EdgeInsets padding;

  /// PDF'i olan kitapların kimlikleri (kapakta "PDF" rozeti).
  final Set<String> pdfBookIds;

  /// Kapağa uzun basma (ör. "PDF'te aç").
  final void Function(Book book)? onLongPress;

  @override
  Widget build(BuildContext context) {
    return ShelfLayout<BookProgress>(
      items: items,
      header: header,
      padding: padding,
      itemBuilder: (context, p) => BookCover(
        progress: p,
        onTap: () => onOpen(p.book),
        hasPdf: pdfBookIds.contains(p.book.id),
        onLongPress: onLongPress == null ? null : () => onLongPress!(p.book),
      ),
    );
  }
}

/// Genel raf: her satırda [shelfColumnsFor] kapak, altında ahşap raf.
class ShelfLayout<T> extends StatelessWidget {
  const ShelfLayout({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.header,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 96),
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;
  final Widget? header;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = shelfColumnsFor(c.maxWidth);
        final rows = <List<T>>[
          for (var i = 0; i < items.length; i += cols)
            items.sublist(i, i + cols > items.length ? items.length : i + cols),
        ];
        // Başlık (varsa) + satırlar tembel kurulur: uzun listede yalnızca görünenler.
        final offset = header != null ? 1 : 0;
        return ListView.builder(
          padding: padding,
          itemCount: rows.length + offset,
          itemBuilder: (context, i) {
            if (header != null && i == 0) {
              return Padding(padding: const EdgeInsets.only(bottom: 16), child: header!);
            }
            return _ShelfRow<T>(cols: cols, items: rows[i - offset], itemBuilder: itemBuilder);
          },
        );
      },
    );
  }
}

class _ShelfRow<T> extends StatelessWidget {
  const _ShelfRow({required this.cols, required this.items, required this.itemBuilder});
  final int cols;
  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final wood = dark ? const Color(0xFF4A3526) : const Color(0xFFB98A5E);
    final woodEdge = dark ? const Color(0xFF2E2016) : const Color(0xFF8C633C);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < cols; i++) ...[
                  if (i > 0) const SizedBox(width: 12),
                  Expanded(
                    child: i < items.length ? itemBuilder(context, items[i]) : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
          Container(
            height: 10,
            decoration: BoxDecoration(
              color: wood,
              border: Border(top: BorderSide(color: woodEdge, width: 2)),
              boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 4, offset: Offset(0, 3))],
            ),
          ),
        ],
      ),
    );
  }
}
