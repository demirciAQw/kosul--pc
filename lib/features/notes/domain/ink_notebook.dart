import 'page_template.dart';

/// Kalemli defter (T6). Anlık not ve ders notundan ayrıdır.
class InkNotebookRecord {
  const InkNotebookRecord({
    required this.id,
    required this.title,
    required this.coverColor,
    required this.defaultTemplate,
    required this.sortOrder,
    required this.pageCount,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final int coverColor;
  final PageTemplate defaultTemplate;
  final int sortOrder;

  /// Silinmemiş sayfa sayısı.
  final int pageCount;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Defter sayfası. Çizgileri: `NotePageOwner(id, pageNo)` (bkz. `ink_note_pages` belgesi).
class InkNotePageRecord {
  const InkNotePageRecord({
    required this.id,
    required this.notebookId,
    required this.pageNo,
    required this.sortOrder,
    required this.template,
    required this.width,
    required this.height,
    required this.background,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String notebookId;

  /// Değişmeyen numara: `ink_strokes.notePage` bunu taşır.
  final int pageNo;
  final int sortOrder;
  final PageTemplate template;
  final double width;
  final double height;
  final int background;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A4 oranında varsayılan sayfa boyutu (not koordinatı).
const defaultPageWidth = 1404.0;
const defaultPageHeight = 1984.0;
