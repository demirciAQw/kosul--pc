import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/routes.dart';
import '../data/pdf_import_service.dart';
import '../domain/pdf_document_record.dart';
import '../domain/pdf_engine.dart';
import '../pdf_providers.dart';

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

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final file = await ref.read(pdfPickerProvider)();
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(pdfImportServiceProvider.future);
      final res = await svc.importFile(file);
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
      await _offerBook(res);
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
    if (ok == true) await repo.softDelete(d.id);
  }

  void _open(PdfDocumentRecord d) {
    final cb = widget.onOpen;
    if (cb != null) {
      cb(context, d);
    } else {
      context.push(AppRoutes.pdfReader(d.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(pdfDocumentsProvider);
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
        data: (list) => list.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Henüz PDF yok. "PDF ekle" ile bir PDF seç.'),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final d = list[i];
                  return ListTile(
                    key: Key('pdf-item-${d.id}'),
                    leading: const Icon(Icons.picture_as_pdf_outlined),
                    title: Text(d.title),
                    subtitle: Text(
                      '${d.pageCount} sayfa${d.bookId != null ? ' · kitaba bağlı' : ''}',
                    ),
                    onTap: () => _open(d),
                    trailing: PopupMenuButton<String>(
                      onSelected: (_) => _remove(d),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'kaldir',
                          child: Text('Listeden kaldır'),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
