import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../pdf/domain/pdf_document_record.dart';
import '../../pdf/pdf_providers.dart';
import '../domain/library.dart';
import '../domain/progress.dart';
import '../library_providers.dart';
import 'library_sheet.dart';
import 'widgets/book_shelf_view.dart';
import 'widgets/progress_widgets.dart';
import '../../../app/widgets/home_logo_button.dart';

/// Kitaplar sekmesi: her kitabın ne kadarı bitti, ne kadarı duruyor.
/// Kitap kategorisi: sınav türüne ve yayıncıya göre üç sekme.
enum BookShelf {
  tyt('TYT'),
  ayt('AYT'),
  meb('MEB');

  const BookShelf(this.label);
  final String label;

  /// MEB ders kitapları ayrı rafta; diğerleri sınav türüne göre.
  static BookShelf of(Book book) {
    if ((book.publisher ?? '').trim().toUpperCase() == 'MEB') return BookShelf.meb;
    return book.examType == 'TYT' ? BookShelf.tyt : BookShelf.ayt;
  }
}

/// Kitaba bağlı PDF'ler. İki PDF aynı kitaba bağlıysa liste sırasındaki İLK
/// (başlığa göre; kitap ayrıntısı ve raf aynı kuralı kullanır).
Map<String, PdfDocumentRecord> pdfsByBook(Iterable<PdfDocumentRecord> docs) {
  final out = <String, PdfDocumentRecord>{};
  for (final d in docs) {
    if (d.bookId != null) out.putIfAbsent(d.bookId!, () => d);
  }
  return out;
}

/// Kitaplar sekmesi: TYT, AYT ve MEB kitapları ayrı sekmelerde; her kitabın ne
/// kadarı bitti, ne kadarı duruyor.
class BooksScreen extends ConsumerWidget {
  const BooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(bookProgressProvider);
    final all = progress.value ?? const <BookProgress>[];
    // Kitaba bağlı PDF'ler (kapakta rozet, uzun basınca "PDF'te aç").
    final pdfs = pdfsByBook(ref.watch(pdfDocumentsProvider).value ?? const <PdfDocumentRecord>[]);
    int count(BookShelf s) => all.where((p) => BookShelf.of(p.book) == s).length;

    return DefaultTabController(
      length: BookShelf.values.length,
      child: Scaffold(
        appBar: AppBar(
          leading: const HomeLogoButton(),
          leadingWidth: HomeLogoButton.width,
          title: const Text('Kitaplarım'),
          bottom: TabBar(
            tabs: [
              for (final s in BookShelf.values)
                Tab(text: count(s) == 0 ? s.label : '${s.label} (${count(s)})'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'books-add',
          onPressed: () => showLibrarySheet(context),
          icon: const Icon(Icons.library_add_outlined),
          label: const Text('Kitap ekle'),
        ),
        body: progress.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Kitaplar yüklenemedi: $e')),
          data: (list) => TabBarView(
            children: [
              for (final shelf in BookShelf.values)
                _ShelfView(
                  shelf: shelf,
                  pdfs: pdfs,
                  items: [for (final p in list) if (BookShelf.of(p.book) == shelf) p],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShelfView extends StatelessWidget {
  const _ShelfView({required this.shelf, required this.items, required this.pdfs});
  final BookShelf shelf;
  final List<BookProgress> items;

  /// Kitap kimliği → bağlı PDF.
  final Map<String, PdfDocumentRecord> pdfs;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return _EmptyBooks(shelf: shelf);
    final done = items.fold<int>(0, (a, p) => a + p.doneLeaves);
    final total = items.fold<int>(0, (a, p) => a + p.totalLeaves);
    return BookShelfView(
      items: items,
      onOpen: (book) => context.push(AppRoutes.book(book.id)),
      pdfBookIds: pdfs.keys.toSet(),
      onLongPress: (book) {
        final pdf = pdfs[book.id];
        if (pdf != null) _showBookSheet(context, book, pdf);
      },
      header: _Overview(done: done, total: total, books: items.length),
    );
  }
}

/// Kapağa uzun basınca: kitabı ya da bağlı PDF'i aç.
Future<void> _showBookSheet(BuildContext context, Book book, PdfDocumentRecord pdf) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis)),
          ListTile(
            key: const Key('book-open-pdf'),
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text("PDF'te aç"),
            onTap: () {
              Navigator.pop(sheet);
              context.push(AppRoutes.pdfReader(pdf.id));
            },
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('Kitabı aç'),
            onTap: () {
              Navigator.pop(sheet);
              context.push(AppRoutes.book(book.id));
            },
          ),
        ],
      ),
    ),
  );
}

class _Overview extends StatelessWidget {
  const _Overview({required this.done, required this.total, required this.books});
  final int done;
  final int total;
  final int books;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            ProgressRing(value: total == 0 ? 0 : done / total, size: 72),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$books kitap', style: theme.textTheme.titleMedium),
                  Text('$done / $total test ya da başlık bitti', style: theme.textTheme.bodyMedium),
                  Text('${total - done} tane duruyor', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyBooks extends StatelessWidget {
  const _EmptyBooks({required this.shelf});
  final BookShelf shelf;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 48, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('${shelf.label} rafında kitap yok', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Hazır kitaplardan ekle ya da JSON şablonu içe aktar. Çözdüğün testler burada '
              'kitap kitap görünür.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => showLibrarySheet(context),
              icon: const Icon(Icons.library_add_outlined),
              label: const Text('Kitap ekle'),
            ),
          ],
        ),
      ),
    );
  }
}
