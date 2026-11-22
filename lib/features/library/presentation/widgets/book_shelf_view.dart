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
Color bookCoverColor(Book book) {
  final key = book.subject.trim().isNotEmpty ? book.subject : book.title;
  return bookCoverPalette[_stableHash(key) % bookCoverPalette.length];
}

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
  const BookCover({super.key, required this.progress, required this.onTap});

  final BookProgress progress;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = progress.book;
    final color = bookCoverColor(b);
    final pct = (progress.ratio * 100).round();
    const white = Colors.white;
    final publisher = (b.publisher ?? '').trim();
    return Semantics(
      button: true,
      label: '${b.title}, ${b.subject}, ilerleme %$pct',
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
                                [b.examType, b.subject].where((e) => e.trim().isNotEmpty).join(' · '),
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
                                  b.title,
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
                              const SizedBox(height: 6),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: LinearProgressIndicator(
                                  value: progress.ratio.clamp(0.0, 1.0),
                                  minHeight: 5,
                                  backgroundColor: const Color(0x55000000),
                                  valueColor: const AlwaysStoppedAnimation(Color(0xFFFFFFFF)),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '%$pct · ${progress.doneLeaves}/${progress.totalLeaves}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: white, fontSize: small, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
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
  });

  final List<BookProgress> items;
  final void Function(Book book) onOpen;
  final Widget? header;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = shelfColumnsFor(c.maxWidth);
        final rows = <List<BookProgress>>[
          for (var i = 0; i < items.length; i += cols)
            items.sublist(i, i + cols > items.length ? items.length : i + cols),
        ];
        return ListView(
          padding: padding,
          children: [
            if (header != null) ...[header!, const SizedBox(height: 16)],
            for (final row in rows) _ShelfRow(cols: cols, books: row, onOpen: onOpen),
          ],
        );
      },
    );
  }
}

class _ShelfRow extends StatelessWidget {
  const _ShelfRow({required this.cols, required this.books, required this.onOpen});
  final int cols;
  final List<BookProgress> books;
  final void Function(Book book) onOpen;

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
                    child: i < books.length
                        ? BookCover(progress: books[i], onTap: () => onOpen(books[i].book))
                        : const SizedBox.shrink(),
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
