import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/di/core_providers.dart';
import '../../../core/text/turkish_text.dart';
import '../../../core/utils/id_generator.dart';
import '../../library/domain/book_template_usecases.dart';
import '../../library/domain/library.dart';
import '../../library/library_providers.dart';
import '../../library/presentation/library_sheet.dart' show BundledTemplate, bundledTemplatesProvider;
import '../../ocr/auto_tag_providers.dart';
import '../../ocr/domain/auto_tags.dart';
import '../domain/book_autofill.dart';
import '../domain/pdf_document_record.dart';
import '../domain/pdf_import_rules.dart';
import '../data/pdf_document_repository.dart';
import '../data/pdf_import_service.dart' show PdfImportService;
import '../pdf_providers.dart';
import 'pdf_book_form_page.dart';

/// Şablon dosyasını okur (testte değiştirilir).
final templateAssetLoaderProvider = Provider<Future<String> Function(String asset)>((ref) => rootBundle.loadString);

/// Kitap + bağ + ofset TEK işlemde: ortada hata olursa üçü de geri alınır
/// (yetim kitap kalmaz). [createBook] yeni kitabı yazıp kimliğini döndürür
/// (var olan kitaba bağlanıyorsa null). Belge satırı yoksa [StateError].
Future<String> commitPdfBook({
  required AppDatabase db,
  required PdfDocumentRepository pdfs,
  required String docId,
  required int pageOffset,
  String? existingBookId,
  Future<String> Function()? createBook,
}) {
  return db.transaction(() async {
    final bookId = existingBookId ?? await createBook!();
    if (!await pdfs.linkBook(docId, bookId)) throw StateError('PDF kaydı bulunamadı');
    if (!await pdfs.setOffset(docId, pageOffset)) throw StateError('PDF kaydı bulunamadı');
    return bookId;
  });
}

/// PDF'i kitap olarak ekler: formu uygulama doldurur, kullanıcı eksikleri
/// tamamlar. Kayıtta kitap oluşur, `bookId` ve `pageOffset` yazılır.
/// Kitap bağlandıysa true.
Future<bool> addPdfAsBook(BuildContext context, WidgetRef ref, PdfDocumentRecord doc) async {
  // Form sayfayı kapatabilir: tüm bağımlılıklar İLK await'ten önce okunur,
  // sonrasında `ref` kullanılmaz.
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final svcFuture = ref.read(pdfImportServiceProvider.future);
  final lexiconFuture = ref.read(topicLexiconProvider.future).then<TopicLexicon?>((v) => v, onError: (_) => null);
  final templatesFuture = ref
      .read(bundledTemplatesProvider.future)
      .then<List<BundledTemplate>>((v) => v, onError: (_) => const <BundledTemplate>[]);
  final books = ref.read(libraryProvider).value ?? const <Book>[];
  final pdfs = ref.read(pdfDocumentRepositoryProvider);
  final db = ref.read(appDatabaseProvider);
  final library = ref.read(libraryRepositoryProvider);
  final importTemplate = ref.read(importBookTemplateProvider);
  final loadTemplate = ref.read(templateAssetLoaderProvider);
  final ids = ref.read(idGeneratorProvider);
  final now = ref.read(clockProvider);

  // İkinci dokunuş ikinci form/kitap açmasın; hazırlık sürerken yükleniyor göstergesi.
  if (_addBookRunning[navigator] == true) return false;
  _addBookRunning[navigator] = true;
  try {
    return await _addPdfAsBook(
      context: context,
      doc: doc,
      messenger: messenger,
      navigator: navigator,
      svcFuture: svcFuture,
      lexiconFuture: lexiconFuture,
      templatesFuture: templatesFuture,
      books: books,
      pdfs: pdfs,
      db: db,
      library: library,
      importTemplate: importTemplate,
      loadTemplate: loadTemplate,
      ids: ids,
      now: now,
    );
  } finally {
    _addBookRunning[navigator] = false;
  }
}

/// Gezgin başına (ağaçlar arasında sızmaz).
final _addBookRunning = Expando<bool>('addPdfAsBook');

Future<bool> _addPdfAsBook({
  required BuildContext context,
  required PdfDocumentRecord doc,
  required ScaffoldMessengerState messenger,
  required NavigatorState navigator,
  required Future<PdfImportService> svcFuture,
  required Future<TopicLexicon?> lexiconFuture,
  required Future<List<BundledTemplate>> templatesFuture,
  required List<Book> books,
  required PdfDocumentRepository pdfs,
  required AppDatabase db,
  required LibraryRepository library,
  required ImportBookTemplate importTemplate,
  required Future<String> Function(String asset) loadTemplate,
  required IdGenerator ids,
  required DateTime Function() now,
}) async {
  // Yükleniyor göstergesi (kapatılamaz; ikinci dokunuşu da keser).
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: CircularProgressIndicator(key: Key('pdf-book-loading'))),
    ),
  ));
  final TopicLexicon? lexicon;
  final List<BundledTemplate> templates;
  final String text;
  final List<BookCandidate> candidates;
  try {
    final svc = await svcFuture;
    text = await svc.sampleText(doc);
    lexicon = await lexiconFuture;
    templates = await templatesFuture;
    candidates = await pdfs.bookCandidates();
  } finally {
    if (navigator.mounted) navigator.pop(); // göstergeyi kapat
  }
  if (!context.mounted) return false;

  // doc.title: kullanıcının içe aktarma penceresinde onayladığı başlık.
  final auto = buildBookAutofill(fileName: doc.fileName, pageCount: doc.pageCount, metaTitle: doc.title, text: text, lexicon: lexicon);

  final owned = {for (final b in books) normalizeTr(b.title)};
  final tmplHit = suggestBooks(
    auto.title,
    [
      for (final t in templates)
        if (!t.isSample && !owned.contains(normalizeTr(t.title))) BookCandidate(id: t.asset, title: t.title),
    ],
    minScore: 0.6,
    limit: 1,
  );
  final template = tmplHit.isEmpty ? null : templates.firstWhere((t) => t.asset == tmplHit.first.bookId);
  final existingHit = suggestBooks(auto.title, candidates, limit: 1);

  final res = await navigator.push<PdfBookFormResult>(
    MaterialPageRoute(
      builder: (_) => PdfBookFormPage(
        autofill: auto,
        pdfPageCount: doc.pageCount,
        templateMatch: template,
        existingMatch: existingHit.isEmpty ? null : existingHit.first,
      ),
    ),
  );
  if (res == null) return false;

  try {
    Future<String> Function()? create;
    String? existingId = res.existingBookId;
    if (existingId == null && res.template != null) {
      final t = res.template!;
      final same = books.where((b) => b.title == t.title).firstOrNull;
      if (same != null) {
        existingId = same.id;
      } else {
        final raw = await loadTemplate(t.asset); // işlemden önce: G/Ç işlemi tutmasın
        create = () async => (await importTemplate.call(raw)).book.id;
      }
    } else if (existingId == null) {
      final bookId = ids.next();
      create = () async {
        await library.save(
          Book(
            id: bookId,
            title: res.title!,
            publisher: res.publisher,
            examType: res.exam!,
            subject: res.subject!,
            pageCount: res.pageCount!,
            avgQuestionsPerPage: 0.5,
            createdAt: now(),
          ),
        );
        return bookId;
      };
    }
    await commitPdfBook(
      db: db,
      pdfs: pdfs,
      docId: doc.id,
      pageOffset: res.pageOffset,
      existingBookId: existingId,
      createBook: create,
    );
  } on BookTemplateException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Kitap eklenemedi: ${e.message}')));
    return false;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Kitap eklenemedi: $e')));
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('"${res.title ?? doc.title}" kitap olarak eklendi.')));
  return true;
}

/// "Kitapla eşle": kitaplıktaki bir kitabı seç (benzerler üstte). Bağlıysa
/// "Bağı kaldır" da var.
Future<void> linkPdfToBook(BuildContext context, WidgetRef ref, PdfDocumentRecord doc) async {
  final books = [...(ref.read(libraryProvider).value ?? const <Book>[])];
  final hits = suggestBooks(
    doc.title,
    [for (final b in books) BookCandidate(id: b.id, title: b.title)],
    limit: 3,
  ).map((s) => s.bookId).toList();
  books.sort((a, b) {
    final ia = hits.indexOf(a.id), ib = hits.indexOf(b.id);
    if (ia != ib) return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    return a.title.compareTo(b.title);
  });
  final picked = await showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      key: const Key('pdf-link-dialog'),
      title: const Text('Hangi kitapla eşleşsin?'),
      children: [
        if (books.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Kitaplıkta kitap yok.')),
        for (final b in books)
          SimpleDialogOption(
            key: Key('pdf-link-${b.id}'),
            onPressed: () => Navigator.pop(c, b.id),
            child: Text('${b.title}${b.id == doc.bookId ? '  (bağlı)' : ''}'),
          ),
        if (doc.bookId != null)
          SimpleDialogOption(
            key: const Key('pdf-unlink'),
            onPressed: () => Navigator.pop(c, ''),
            child: const Text('Bağı kaldır'),
          ),
      ],
    ),
  );
  if (picked == null) return;
  await ref.read(pdfDocumentRepositoryProvider).linkBook(doc.id, picked.isEmpty ? null : picked);
}

/// "Sayfa ofsetini ayarla": kitabın 1. sayfası PDF'te kaçıncı sayfa.
Future<void> editPdfOffset(BuildContext context, WidgetRef ref, PdfDocumentRecord doc) async {
  final value = await showDialog<int>(context: context, builder: (_) => _OffsetDialog(doc: doc));
  if (value != null) await ref.read(pdfDocumentRepositoryProvider).setOffset(doc.id, offsetFromFirstPage(value));
}

class _OffsetDialog extends StatefulWidget {
  const _OffsetDialog({required this.doc});
  final PdfDocumentRecord doc;

  @override
  State<_OffsetDialog> createState() => _OffsetDialogState();
}

class _OffsetDialogState extends State<_OffsetDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: '${firstPageFromOffset(widget.doc.pageOffset)}');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = int.tryParse(_ctrl.text.trim());
    final ok = v != null && v >= 1 && v <= widget.doc.pageCount;
    return AlertDialog(
      key: const Key('pdf-offset-dialog'),
      title: const Text('Sayfa ofseti'),
      content: TextField(
        key: const Key('pdf-offset-field'),
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Kitabın 1. sayfası PDF\'te kaçıncı sayfa?',
          helperText: '1 ile ${widget.doc.pageCount} arası',
          errorText: ok ? null : 'Geçerli bir sayı yaz',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Vazgeç')),
        FilledButton(
          key: const Key('pdf-offset-save'),
          onPressed: ok ? () => Navigator.pop(context, v) : null,
          child: const Text('Kaydet'),
        ),
      ],
    );
  }
}
