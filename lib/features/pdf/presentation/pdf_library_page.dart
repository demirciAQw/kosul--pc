import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../../library/domain/library.dart';
import '../../library/library_providers.dart';
import '../../library/presentation/widgets/book_shelf_view.dart';
import '../data/pdf_import_service.dart';
import '../domain/pdf_document_record.dart';
import '../domain/pdf_engine.dart';
import '../pdf_providers.dart';
import 'pdf_book_flow.dart';
import 'pdf_import_dialog.dart';

/// PDF kitaplığı: içe aktar, listele, aç. Kitap bağı yalnızca kullanıcı
/// onaylarsa kurulur; silme yumuşaktır ve onay ister.
class PdfLibraryPage extends ConsumerStatefulWidget {
  const PdfLibraryPage({super.key, this.onOpen, this.embedded = false});

  /// true: başka bir sayfa çerçevesinin içinde (başlık çubuğu yok).
  final bool embedded;

  /// Belgeyi açma (varsayılan: `/pdf/:id` rotası). Rotasız testlerde verilir.
  final void Function(BuildContext context, PdfDocumentRecord doc)? onOpen;

  @override
  ConsumerState<PdfLibraryPage> createState() => _PdfLibraryPageState();
}

class _PdfLibraryPageState extends ConsumerState<PdfLibraryPage> {
  bool _busy = false;

  /// İyimser kaldırma: akış güncellenmeden önce de listeden kalkar.
  final Set<String> _hidden = {};

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await ref.read(pdfPickerProvider)();
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(pdfImportServiceProvider.future);
      // Kopyalamadan önce: sayfa sayısı ve "zaten var mı" (bozuksa burada hata verir).
      final info = await svc.inspect(file);
      if (!mounted) return;
      final choice = await showPdfImportDialog(context, fileName: file.path.split(RegExp(r'[\\/]')).last, info: info);
      if (choice == null || !mounted) return;
      final res = await svc.importFile(file, title: choice.title);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            res.alreadyImported
                ? '"${res.document.title}" zaten kitaplıkta.'
                : '"${res.document.title}" eklendi.',
          ),
        ),
      );
      if (choice.addAsBook && res.document.bookId == null) {
        await addPdfAsBook(context, ref, res.document);
      } else {
        await _offerBook(res);
      }
    } on PdfOpenException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('PDF açılamadı: ${e.message}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('PDF eklenemedi: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _offerBook(PdfImportResult res) async {
    if (res.suggestions.isEmpty) return;
    final best = res.suggestions.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        key: const Key('pdf-book-suggestion'),
        title: const Text('Kitaba bağlansın mı?'),
        content: Text(
          '"${res.document.title}" için en benzer kitap: "${best.title}". Bağlarsan PDF sayfa numarası kitap sayfasıyla eşleşir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Hayır'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Bağla'),
          ),
        ],
      ),
    );
    if (ok == true)
      await ref
          .read(pdfDocumentRepositoryProvider)
          .linkBook(res.document.id, best.bookId);
  }

  Future<void> _remove(PdfDocumentRecord d) async {
    final repo = ref.read(pdfDocumentRepositoryProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Listeden kaldırılsın mı?'),
        content: Text(
          '"${d.title}" listeden kalkar. Dosya ve çizgilerin silinmez; PDF\'i yeniden ekleyince geri gelir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (mounted) setState(() => _hidden.add(d.id));
    try {
      await repo.softDelete(d.id);
    } catch (_) {
      if (mounted) setState(() => _hidden.remove(d.id));
      rethrow;
    }
  }

  void _open(PdfDocumentRecord d) {
    final cb = widget.onOpen;
    if (cb != null) {
      cb(context, d);
    } else {
      context.push(AppRoutes.pdfReader(d.id));
    }
  }

  Future<void> _menu(String action, PdfDocumentRecord d) async {
    switch (action) {
      case 'kitap':
        await addPdfAsBook(context, ref, d);
      case 'esle':
        await linkPdfToBook(context, ref, d);
      case 'ofset':
        await editPdfOffset(context, ref, d);
      case 'kaldir':
        await _remove(d);
    }
  }

  Widget _cover(PdfDocumentRecord d, Book? book) {
    return BookCoverFace(
      key: Key('pdf-item-${d.id}'),
      title: d.title,
      kicker: book == null ? 'PDF' : [book.examType, book.subject].where((e) => e.trim().isNotEmpty).join(' · '),
      color: book != null ? bookCoverColor(book) : bookCoverColorFor(d.title),
      publisher: book == null ? '' : book.title,
      footer: '${d.pageCount} sayfa',
      semanticsLabel: '${d.title}, ${d.pageCount} sayfa${book != null ? ', kitap: ${book.title}' : ''}',
      badge: 'PDF',
      onTap: () => _open(d),
      bottomRight: PopupMenuButton<String>(
        key: Key('pdf-menu-${d.id}'),
        iconColor: Colors.white,
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        tooltip: 'Daha fazla',
        onSelected: (a) => _menu(a, d),
        itemBuilder: (_) => [
          if (d.bookId == null) const PopupMenuItem(value: 'kitap', child: Text('Kitap olarak ekle')),
          const PopupMenuItem(value: 'esle', child: Text('Kitapla eşle')),
          const PopupMenuItem(value: 'ofset', child: Text('Sayfa ofsetini ayarla')),
          const PopupMenuItem(value: 'kaldir', child: Text('Listeden kaldır')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(pdfDocumentsProvider);
    final books = {
      for (final b in ref.watch(libraryProvider).value ?? const <Book>[]) b.id: b,
    };
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('PDF\'ler')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('pdf-import'),
        onPressed: _busy ? null : _import,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add),
        label: const Text('PDF ekle'),
      ),
      body: docs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Liste okunamadı: $e')),
        data: (all) {
          // Akış kaldırmayı doğruladıysa gizleme gereksiz.
          _hidden.removeWhere((id) => !all.any((d) => d.id == id));
          final list = [
            for (final d in all)
              if (!_hidden.contains(d.id)) d,
          ];
          return list.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Henüz PDF yok. "PDF ekle" ile bir PDF seç.'),
                  ),
                )
              : ShelfLayout<PdfDocumentRecord>(
                  items: list,
                  itemBuilder: (_, d) => _cover(d, books[d.bookId]),
                );
        },
      ),
    );
  }
}
