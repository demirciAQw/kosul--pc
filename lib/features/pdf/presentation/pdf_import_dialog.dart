import 'package:flutter/material.dart';

import '../data/pdf_import_service.dart';
import '../domain/book_autofill.dart';

/// İçe aktarma penceresinin sonucu.
class PdfImportChoice {
  const PdfImportChoice({required this.title, required this.addAsBook});
  final String title;
  final bool addAsBook;
}

/// Dosya seçilince açılan pencere: başlık (düzenlenebilir), sayfa sayısı,
/// "Kitap olarak da ekle" (varsayılan açık) ve "bu PDF zaten var" bilgisi.
Future<PdfImportChoice?> showPdfImportDialog(BuildContext context, {required String fileName, required PdfFileInfo info}) {
  return showDialog<PdfImportChoice>(
    context: context,
    builder: (_) => _PdfImportDialog(fileName: fileName, info: info),
  );
}

class _PdfImportDialog extends StatefulWidget {
  const _PdfImportDialog({required this.fileName, required this.info});
  final String fileName;
  final PdfFileInfo info;

  @override
  State<_PdfImportDialog> createState() => _PdfImportDialogState();
}

class _PdfImportDialogState extends State<_PdfImportDialog> {
  late final TextEditingController _title;
  bool _asBook = true;

  PdfFileInfo get _info => widget.info;
  bool get _exists => _info.existing != null;
  bool get _linked => _info.existing?.bookId != null;

  /// Satır varsa başlık, kitap bağı ve ofset korunur: bu yüzden başlık alanı kapalı.
  String _existsMessage() {
    final d = _info.existing!;
    final String first;
    if (d.deleted) {
      first = 'Bu PDF daha önce eklenmişti ve listeden kaldırılmıştı; geri getirilir.';
    } else if (!_info.fileOnDevice) {
      first = 'Bu PDF başka cihazdan eşitlenmiş; dosya bu cihaza kopyalanır.';
    } else {
      first = _linked ? 'Bu PDF zaten kitaplıkta ve bir kitaba bağlı.' : 'Bu PDF zaten kitaplıkta. Yeniden kopyalanmaz.';
    }
    final kept = _linked
        ? ' Eski başlık ve kitap bağı korunur; bu yüzden başlık değişmez ve "kitap olarak ekle" gösterilmez.'
        : ' Eski başlık korunur; bu yüzden başlık değişmez.';
    return '$first$kept';
  }

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: _exists ? _info.existing!.title : cleanBookTitle(widget.fileName));
    _title.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('pdf-import-dialog'),
      title: const Text('PDF ekle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.fileName, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_exists) ...[
              Container(
                key: const Key('pdf-import-exists'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  _existsMessage(),
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: const Key('pdf-import-title'),
              controller: _title,
              enabled: !_exists,
              decoration: const InputDecoration(labelText: 'Başlık', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text('${_info.pageCount} sayfa'),
            if (!_linked)
              CheckboxListTile(
                key: const Key('pdf-import-as-book'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _asBook,
                onChanged: (v) => setState(() => _asBook = v ?? false),
                title: const Text('KİTAP OLARAK DA EKLE'),
                subtitle: const Text('Kitap formunu uygulama doldurur; eksikleri sen tamamlarsın.'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
        FilledButton(
          key: const Key('pdf-import-confirm'),
          onPressed: _title.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, PdfImportChoice(title: _title.text.trim(), addAsBook: _asBook && !_linked)),
          child: const Text('İçe aktar'),
        ),
      ],
    );
  }
}
