import 'package:flutter/material.dart';

import '../../library/presentation/library_sheet.dart' show BundledTemplate;
import '../domain/book_autofill.dart';
import '../domain/pdf_import_rules.dart';

/// Form sonucu: yeni kitap, şablondan kitap ya da var olan kitaba bağlama.
class PdfBookFormResult {
  const PdfBookFormResult.newBook({
    required String this.title,
    required String this.exam,
    required String this.subject,
    required int this.pageCount,
    this.publisher,
    required this.firstPdfPage,
  })  : template = null,
        existingBookId = null;

  const PdfBookFormResult.fromTemplate(BundledTemplate this.template, {required this.firstPdfPage})
      : title = null,
        exam = null,
        subject = null,
        pageCount = null,
        publisher = null,
        existingBookId = null;

  const PdfBookFormResult.existing(String this.existingBookId, {required this.firstPdfPage})
      : title = null,
        exam = null,
        subject = null,
        pageCount = null,
        publisher = null,
        template = null;

  final String? title;
  final String? exam;
  final String? subject;
  final int? pageCount;
  final String? publisher;
  final BundledTemplate? template;
  final String? existingBookId;

  /// Kitabın 1. sayfası PDF'te kaçıncı sayfa (1'den).
  final int firstPdfPage;

  int get pageOffset => offsetFromFirstPage(firstPdfPage);
}

/// "PDF'ten kitap ekle" formu. Uygulamanın doldurabildiği alanlar "otomatik
/// dolduruldu" ipucuyla gelir; dolduramadıkları kırmızı çerçeveyle "Doldur"
/// der ve hepsi dolmadan Kaydet açılmaz. Her değer değiştirilebilir.
class PdfBookFormPage extends StatefulWidget {
  const PdfBookFormPage({
    super.key,
    required this.autofill,
    required this.pdfPageCount,
    this.templateMatch,
    this.existingMatch,
  });

  final BookAutofill autofill;

  /// PDF'in sayfa sayısı ("1. sayfa kaçıncı PDF sayfası" sınırı).
  final int pdfPageCount;

  /// Uygulamayla gelen şablonlardan eşleşen (varsa).
  final BundledTemplate? templateMatch;

  /// Kitaplıktaki benzer kitap (varsa).
  final BookSuggestion? existingMatch;

  @override
  State<PdfBookFormPage> createState() => _PdfBookFormPageState();
}

class _PdfBookFormPageState extends State<PdfBookFormPage> {
  late final TextEditingController _title;
  late final TextEditingController _publisher;
  late final TextEditingController _pages;
  late final TextEditingController _first;
  String? _exam;
  String? _subject;

  BookAutofill get _a => widget.autofill;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: _a.title);
    _publisher = TextEditingController(text: _a.publisher ?? '');
    _pages = TextEditingController(text: _a.pageCount > 0 ? '${_a.pageCount}' : '');
    _first = TextEditingController(text: '${_a.firstPdfPage}');
    _exam = _a.exam;
    _subject = _a.subject;
    for (final c in [_title, _publisher, _pages, _first]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_title, _publisher, _pages, _first]) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _pagesValue => int.tryParse(_pages.text.trim());
  int? get _firstValue {
    final v = int.tryParse(_first.text.trim());
    return v != null && v >= 1 && v <= widget.pdfPageCount ? v : null;
  }

  bool get _valid =>
      _title.text.trim().isNotEmpty &&
      _exam != null &&
      _subject != null &&
      (_pagesValue ?? 0) >= 1 &&
      _firstValue != null;

  /// Alan uygulamanın doldurduğu değerde mi (kullanıcı değiştirdiyse ipucu kalkar).
  bool _isAuto(String? initial, String? current) =>
      initial != null && initial.trim().isNotEmpty && initial.trim() == (current ?? '').trim();

  InputDecoration _deco(String label, {required bool required, required bool auto, required bool empty, String? error}) {
    final scheme = Theme.of(context).colorScheme;
    final missing = required && empty;
    final border = OutlineInputBorder(borderSide: BorderSide(color: scheme.error, width: 2));
    return InputDecoration(
      labelText: required ? '$label *' : label,
      border: const OutlineInputBorder(),
      enabledBorder: missing ? border : null,
      filled: missing,
      fillColor: missing ? scheme.errorContainer.withValues(alpha: 0.35) : null,
      errorText: error,
      helperText: missing ? 'Doldur' : (auto ? 'otomatik dolduruldu' : null),
      helperStyle: TextStyle(
        color: missing ? scheme.error : scheme.primary,
        fontWeight: missing ? FontWeight.w700 : FontWeight.w500,
      ),
    );
  }

  Widget _banner({required Key key, required String text, required String action, required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Icon(Icons.auto_awesome, color: scheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: scheme.onSecondaryContainer))),
            FilledButton.tonal(key: key, onPressed: _firstValue == null ? null : onTap, child: Text(action)),
          ],
        ),
      ),
    );
  }

  void _save() {
    if (!_valid) return;
    final pub = _publisher.text.trim();
    Navigator.pop(
      context,
      PdfBookFormResult.newBook(
        title: _title.text.trim(),
        exam: _exam!,
        subject: _subject!,
        pageCount: _pagesValue!,
        publisher: pub.isEmpty ? null : pub,
        firstPdfPage: _firstValue!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.templateMatch;
    final e = widget.existingMatch;
    final subjects = subjectsFor(_exam);
    final firstEmpty = _first.text.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Kitap olarak ekle')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            'Doldurabildiklerimi doldurdum. Kırmızı alanları sen doldur; hepsini değiştirebilirsin.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          if (t != null)
            _banner(
              key: const Key('book-apply-template'),
              text: 'Şablonla eşleşti: ${t.title}',
              action: 'Uygula',
              onTap: () => Navigator.pop(context, PdfBookFormResult.fromTemplate(t, firstPdfPage: _firstValue!)),
            ),
          if (e != null)
            _banner(
              key: const Key('book-link-existing'),
              text: 'Kitaplığında benzer kitap var: ${e.title}',
              action: 'Bağla',
              onTap: () => Navigator.pop(context, PdfBookFormResult.existing(e.bookId, firstPdfPage: _firstValue!)),
            ),
          if (t != null || e != null) const SizedBox(height: 8),
          TextField(
            key: const Key('book-title'),
            controller: _title,
            decoration: _deco(
              'Kitap adı',
              required: true,
              auto: _isAuto(_a.title, _title.text),
              empty: _title.text.trim().isEmpty,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('book-publisher'),
            controller: _publisher,
            decoration: _deco(
              'Yayınevi',
              required: false,
              auto: _isAuto(_a.publisher, _publisher.text),
              empty: _publisher.text.trim().isEmpty,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const Key('book-exam'),
                  initialValue: _exam,
                  isExpanded: true,
                  hint: const Text('Seç'),
                  decoration: _deco(
                    'Sınav',
                    required: true,
                    auto: _isAuto(_a.exam, _exam),
                    empty: _exam == null,
                  ),
                  items: [for (final x in const ['TYT', 'AYT', 'YDT']) DropdownMenuItem(value: x, child: Text(x))],
                  onChanged: (v) => setState(() {
                    _exam = v;
                    _subject = resolveSubject(_subject, v);
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey('book-subject:$_exam:$_subject'),
                  initialValue: _subject,
                  isExpanded: true,
                  hint: const Text('Seç'),
                  decoration: _deco(
                    'Ders',
                    required: true,
                    auto: _isAuto(_a.subject, _subject),
                    empty: _subject == null,
                  ),
                  items: [for (final s in subjects) DropdownMenuItem(value: s, child: Text(s))],
                  onChanged: (v) => setState(() => _subject = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('book-pages'),
            controller: _pages,
            keyboardType: TextInputType.number,
            decoration: _deco(
              'Toplam sayfa',
              required: true,
              auto: _isAuto(_a.pageCount > 0 ? '${_a.pageCount}' : null, _pages.text),
              empty: (_pagesValue ?? 0) < 1,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('book-first-page'),
            controller: _first,
            keyboardType: TextInputType.number,
            decoration: _deco(
              "Kitabın 1. sayfası PDF'te kaçıncı sayfa?",
              required: true,
              auto: false,
              empty: firstEmpty,
              error: !firstEmpty && _firstValue == null ? '1 ile ${widget.pdfPageCount} arasında bir sayı yaz' : null,
            ).copyWith(helperText: firstEmpty ? 'Doldur' : "Kapak ve içindekiler numarasızsa 1'den büyük yaz"),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('book-save'),
            onPressed: _valid ? _save : null,
            icon: const Icon(Icons.check),
            label: const Text('Kitabı kaydet'),
          ),
        ],
      ),
    );
  }
}
